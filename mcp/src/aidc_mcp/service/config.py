"""The orchestrator's settings, read from the `orchestrator:` section of the aidc config.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import os
from pathlib import Path

# Config file lives in the same directory as the token file (both on the
# aidc-config volume, mounted at /aidc-config/ in the container).
# Override AIDC_MCP_TOKEN_FILE to relocate both simultaneously.
_CONFIG_PATH = (
    Path(os.environ.get("AIDC_MCP_TOKEN_FILE", "/aidc-config/mcp-token")).parent / "config.yaml"
)


def _yaml_scalar(raw: str) -> str:
    """Parse the value half of a `key: value` config line into a plain string.

    Strips an inline `# comment` and surrounding quotes. The comment strip is
    NOT optional politeness: the config template shipped in the README (and by
    `aidc config default`) documents every key with a trailing comment —

        callback_url: ""    # base URL of the orchestrator's callback endpoint (e.g. https://...)

    — so filling it in the obvious way (replace the `""`, keep the comment) used
    to yield a URL with the whole comment glued onto it, and every callback POST
    went to an unresolvable host. The shell config parser (lib/config.sh) has
    always stripped these; this parser did not, so the two disagreed about the
    same file.

    Follows the YAML rule that `#` opens a comment only at line start or after
    whitespace, so a `#` inside an unquoted value (a URL fragment) survives. A
    quoted value is taken up to its closing quote, so a `# ` inside quotes is
    content, not a comment.
    """
    value = raw.strip()
    if value[:1] in ("'", '"'):
        quote = value[0]
        end = value.find(quote, 1)
        if end != -1:
            return value[1:end]
        return value[1:]
    cut = len(value)
    for i, ch in enumerate(value):
        if ch == "#" and (i == 0 or value[i - 1].isspace()):
            cut = i
            break
    return value[:cut].strip()


#: The config section holding the orchestrator's settings, and the error when its callback URL
#: is missing; one place, so every reader and every message agree.
ORCHESTRATOR_SECTION = "orchestrator"


CALLBACK_URL_UNSET = f"{ORCHESTRATOR_SECTION}.callback_url not set in ~/.config/aidc/config.yaml"


def _orchestrator_setting(key: str) -> str | None:
    """The scalar `orchestrator.<key>` from the aidc config file, or None when unset.

    Inside the container the config lives at /aidc-config/config.yaml
    (mounted from ~/.config/aidc/config.yaml on the host).
    """
    if not _CONFIG_PATH.exists():
        return None
    in_orchestrator_section = False
    for line in _CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == f"{ORCHESTRATOR_SECTION}:":
            in_orchestrator_section = True
            continue
        if in_orchestrator_section:
            if stripped.startswith(f"{key}:"):
                return _yaml_scalar(stripped.split(":", 1)[1])
            # A non-empty, non-comment line at column 0 is a new top-level key.
            if stripped and not stripped.startswith("#") and not line[0:1].isspace():
                break
    return None


def orchestrator_callback_url() -> str:
    """Read orchestrator.callback_url from the aidc config file."""
    return (_orchestrator_setting("callback_url") or "").rstrip("/")


def _callback_url_misplaced() -> str | None:
    """The top-level section, other than `orchestrator:`, that holds a `callback_url` key,
    or None. A config written before the section was renamed still has its settings under
    the former name; they are not read (no fallback), but the error says where they are."""
    if not _CONFIG_PATH.exists():
        return None
    section = None
    for line in _CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0:1].isspace():
            head = stripped.split("#", 1)[0].rstrip()
            section = head[:-1] if head.endswith(":") else None
            continue
        if section and section != ORCHESTRATOR_SECTION and stripped.startswith("callback_url:"):
            return section
    return None


def callback_url_unset() -> str:
    """The error for a missing orchestrator.callback_url, naming the section to rename when
    the settings sit under another one."""
    misplaced = _callback_url_misplaced()
    if misplaced is None:
        return CALLBACK_URL_UNSET
    return (f"{CALLBACK_URL_UNSET}: callback_url is under `{misplaced}:`, which is not read; "
            f"rename that section to `{ORCHESTRATOR_SECTION}:` (keys unchanged) "
            "and restart aidc-mcp")


def orchestrator_send_speaker() -> bool:
    """Read orchestrator.send_speaker (default false). Off until the orchestrator records a
    `speaker: "human"` turn instead of dropping it (design 10 D4)."""
    return (_orchestrator_setting("send_speaker") or "").lower() == "true"


def orchestrator_turn_settle_seconds(default: float = 4.0) -> float:
    """Read orchestrator.turn_settle_seconds from the aidc config file.

    How long the transcript must stay quiet (no new bytes) after an end_turn before
    the turn is delivered. This coalesces a multi-segment response — Claude emitting
    an empty end_turn and then continuing with the real answer — into one delivery,
    so the watcher signals "ready" once per exchange instead of mid-stream. <= 0
    disables the wait. Default 4s.
    """
    value = _orchestrator_setting("turn_settle_seconds")
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default
