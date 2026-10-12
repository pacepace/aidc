"""One HTTP MCP server for a session's Claude, handed over by the orchestrator.

An orchestrator that runs work in a session can give that session's Claude a
way back to it: an MCP server on the orchestrator's own API, reached with a
bearer token (``session_mcp_set``). This module puts it into the session's
Claude state.

What is written, inside the session's container, under Claude's config
directory (``CLAUDE_CONFIG_DIR``, on the session's dev-home volume):

- ``aidc-mcp/<server>.bearer``: the token, mode 0600. The only place it is kept.
- ``aidc-mcp/headers.sh``: a helper that prints the token as an Authorization
  header. Claude Code runs it on every connection and again when a call is
  refused 401 or 403 (its ``headersHelper``), so a new token is picked up by a
  running Claude with no restart.
- ``.claude.json``: ``mcpServers.<server> = {type: http, url, headersHelper}``.
  No token is in it. Written only when it differs, so handing a new token to a
  session that already has the server touches the token's file alone.

**After the seed.** A new session's ``.claude.json`` is installed on its first
start from a seed that has every ``mcpServers`` entry stripped
(``scripts/lib/claude-state.sh``). The entry here is written into the installed
file, never into the seed: while a seed is still waiting to be installed the
write is refused, since writing first would leave the seed uninstalled.

**The token is a secret.** It travels to the container on the exec's standard
input, never in a command line, and never into the audit log, a tool result or
this module's errors (:func:`scrub`).

**The URL is this server's to say.** The caller gives a path; the base is
``metallm.callback_url``, the address the orchestrator's API already has from
here. A caller cannot point a session at another host.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from typing import Any

#: A server's name: also a file name and a key in Claude's state.
SERVER_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
#: A bearer token (RFC 6750's token68), and nothing a header or a shell could misread.
BEARER_RE = re.compile(r"^[A-Za-z0-9._~+/=-]{1,4096}$")
#: A path on the orchestrator's API: absolute, no query, nothing that leaves the host.
PATH_RE = re.compile(r"^/[A-Za-z0-9._~/-]{0,512}$")

#: What stands where the token was, in anything that leaves this module.
REDACTED = "[bearer]"

ENTRY_ADDED = "added"
ENTRY_UNCHANGED = "unchanged"

#: Run inside the session's container as its user, the settings on standard input
#: as one JSON object. Prints ``added`` or ``unchanged`` for the entry. Exit 3: the
#: session's first start has not installed its Claude state yet.
INSTALL_SCRIPT = r"""
set -euo pipefail
umask 077
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
seed="${AIDC_CLAUDE_STATE_SEED:-/var/aidc/audit/claude-state-seed.json}"
state="$dir/.claude.json"
payload="$(cat)"
field() { printf '%s' "$payload" | jq -rj --arg k "$1" '.[$k]' 2>/dev/null; }
server="$(field server)"
url="$(field url)"
[ -n "$server" ] && [ -n "$url" ] || { echo "aidc: no server or url given" >&2; exit 2; }
if [ ! -e "$state" ] && [ -s "$seed" ]; then
    echo "aidc: the session's Claude state is not installed yet" >&2
    exit 3
fi
store="$dir/aidc-mcp"
mkdir -p "$store"
chmod 700 "$store"
helper="$store/headers.sh"
tmp="$store/.headers.sh.$$"
cat > "$tmp" <<'HELPER'
#!/usr/bin/env bash
# Written by aidc (session_mcp_set). Prints the Authorization header for the MCP
# server Claude Code is connecting to, from the token aidc keeps beside this file.
f="$(dirname "$0")/${CLAUDE_CODE_MCP_SERVER_NAME:-}.bearer"
if [ -r "$f" ] && [ -s "$f" ]; then
    jq -Rsc '{Authorization: ("Bearer " + .)}' < "$f"
else
    echo '{}'
fi
HELPER
chmod 700 "$tmp"
mv -f "$tmp" "$helper"
tmp="$store/.$server.bearer.$$"
field bearer > "$tmp"
[ -s "$tmp" ] || { rm -f "$tmp"; echo "aidc: no bearer given" >&2; exit 2; }
mv -f "$tmp" "$store/$server.bearer"
want="$(jq -cn --arg url "$url" --arg helper "$helper" \
    '{type: "http", url: $url, headersHelper: $helper}')"
[ -s "$state" ] || printf '{}' > "$state"
if jq -e --arg n "$server" --argjson want "$want" '.mcpServers[$n] == $want' "$state" \
        >/dev/null 2>&1; then
    echo unchanged
else
    tmp="$dir/.claude.json.aidc.$$"
    jq --arg n "$server" --argjson want "$want" '.mcpServers[$n] = $want' "$state" > "$tmp"
    mv -f "$tmp" "$state"
    echo added
fi
"""


class SessionMcpError(Exception):
    """The server could not be handed over. ``code`` is one of the tool's error codes."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Handed:
    """What was written.

    :ivar server: the server's name
    :ivar url: its URL
    :ivar entry: ``added`` when Claude's state gained or changed the server, ``unchanged``
        when it already had it and only the token was replaced
    """

    server: str
    url: str
    entry: str


def scrub(text: str, bearer: str) -> str:
    """``text`` with every occurrence of the token replaced."""
    return text.replace(bearer, REDACTED) if bearer else text


def check(server: str, path: str, bearer: str, base_url: str) -> str:
    """The server's URL, once everything given is usable.

    :raises SessionMcpError: naming what is wrong, never quoting the token
    """
    if not SERVER_NAME_RE.match(server or ""):
        raise SessionMcpError(
            "server must be a short lowercase name: letters, digits and hyphens, at most 31",
            "invalid_argument")
    if not PATH_RE.match(path or "") or ".." in path or "//" in path:
        raise SessionMcpError(
            "path must be an absolute path on the orchestrator's API, such as /api/v1/mcp; "
            "this server adds the host", "invalid_argument")
    if not BEARER_RE.match(bearer or ""):
        raise SessionMcpError(
            "bearer must be a token of letters, digits and . _ ~ + / = - with no spaces",
            "invalid_argument")
    if not base_url:
        raise SessionMcpError(
            "metallm.callback_url not set in ~/.config/aidc/config.yaml", "not_configured")
    return f"{base_url.rstrip('/')}{path}"


def _exec(container: str, payload: str, timeout: float) -> subprocess.CompletedProcess[str]:
    """The install script in the session's container; the settings go in on stdin."""
    argv = ["docker", "exec", "-i", "-u", "vscode", container, "bash", "-c", INSTALL_SCRIPT]
    return subprocess.run(argv, input=payload, capture_output=True, text=True, timeout=timeout)


def hand(name: str, *, server: str, path: str, bearer: str, base_url: str,
         timeout: float = 30.0, run: Any = _exec) -> Handed:
    """Give the session ``name``'s Claude the MCP server, or replace its token.

    :param name: the aidc session
    :param server: what Claude calls the server
    :param path: the server's path on the orchestrator's API
    :param bearer: the token Claude sends as its Authorization header
    :param base_url: the orchestrator's API as this server reaches it
    :param run: runs the install script (tests stand one in)
    :raises SessionMcpError: when what was given is unusable, or the write did not happen;
        its message never holds the token
    """
    url = check(server, path, bearer, base_url)
    payload = json.dumps({"server": server, "url": url, "bearer": bearer})
    try:
        proc = run(f"aidc-{name}-dev", payload, timeout)
    except subprocess.TimeoutExpired as exc:
        raise SessionMcpError(f"timeout after {timeout}s writing the session's Claude state",
                              "timeout") from exc
    except OSError as exc:
        raise SessionMcpError(scrub(f"could not reach the session: {exc}", bearer),
                              "command_failed") from exc
    said = scrub((proc.stderr or "").strip(), bearer)
    if proc.returncode == 3:
        raise SessionMcpError(
            "the session is still starting: its Claude state is not installed yet. "
            "Try again shortly",
            "session_not_ready")
    if proc.returncode != 0 and "No such container" in said:
        raise SessionMcpError(f"no such session: {name}", "no_such_session")
    entry = (proc.stdout or "").strip().splitlines()[-1:] or [""]
    if proc.returncode != 0 or entry[0] not in (ENTRY_ADDED, ENTRY_UNCHANGED):
        raise SessionMcpError(
            f"the session's Claude state was not written: {said[-400:] or 'no reason given'}",
            "command_failed")
    return Handed(server=server, url=url, entry=entry[0])
