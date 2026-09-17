"""Session scope: an MCP server limited to named sessions (AIDC_MCP_ALLOWED_SESSIONS).

The MCP drives docker on the host, so its bearer token can reach every aidc session:
exec into it, write its files, create new ones. A test MCP whose token is handed to
an agent inside a sandbox (e.g. an orchestrator under development in a dev
container) must not carry that reach. With AIDC_MCP_ALLOWED_SESSIONS set to a
comma- or space-separated list of session names, every tool and resource refuses
any other session, session creation is refused, listings show only the allowed
sessions, and the global config resource is refused. Unset or empty, nothing is
restricted (the normal, host-trusted MCP).
"""

from __future__ import annotations

import os
import re

ENV = "AIDC_MCP_ALLOWED_SESSIONS"
# Set by `aidc mcp start` from mcp.session_create, alongside the home mount it needs.
ENABLE_CREATE_ENV = "AIDC_MCP_SESSION_CREATE"


def allowed_sessions() -> frozenset[str] | None:
    """The allowed session names, or None when the server is not scoped. Read at
    call time, so the setting cannot be half-applied."""
    raw = os.environ.get(ENV, "")
    names = frozenset(n for n in re.split(r"[,\s]+", raw) if n)
    return names or None


def refusal(name: str) -> str | None:
    """Why `name` may not be used on this server, or None when it may."""
    allowed = allowed_sessions()
    if allowed is None or name in allowed:
        return None
    return (f"session '{name}' is outside this MCP server's scope "
            f"(it only serves: {', '.join(sorted(allowed))})")


def create_refusal() -> str | None:
    if allowed_sessions() is None:
        return None
    return "this MCP server is limited to named sessions and cannot create sessions"


def session_create_enabled() -> bool:
    """Whether this server offers session_create at all.

    Creating a session means reading a repo and writing Claude's per-project memory on
    the HOST, so `aidc mcp start` has to mount the operator's home into this container —
    which the operator opts into with `mcp.session_create: true`. Off (the default), the
    tool is not registered: an orchestrator plans without it rather than calling
    something that cannot work. A scoped server never offers it (create_refusal).
    """
    return os.environ.get(ENABLE_CREATE_ENV, "").strip().lower() == "true"


def filter_list(raw: str) -> str:
    """`aidc list` output with only the allowed sessions' rows (header kept)."""
    allowed = allowed_sessions()
    if allowed is None:
        return raw
    lines = raw.splitlines()
    kept = [line for i, line in enumerate(lines)
            if i == 0 or (line.split() and line.split()[0] in allowed)]
    return "\n".join(kept) + ("\n" if raw.endswith("\n") else "")
