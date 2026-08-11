"""Audit log. Append-only, line-per-event JSON. Lives at
/var/log/aidc-mcp/access.log inside the container, which is bind-mounted
to the host's private XDG state dir
(${XDG_STATE_HOME:-~/.local/state}/aidc-mcp/, mode 0700)."""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

_AUDIT_PATH = Path(os.environ.get("AIDC_MCP_AUDIT_LOG", "/var/log/aidc-mcp/access.log"))
_LOCK = threading.Lock()


def _ensure_parent() -> None:
    _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)


def log_event(kind: str, **fields: Any) -> None:
    """Append one structured event to the audit log.

    Sensitive fields (the bearer token in particular) are NEVER logged
    here; callers are responsible for not passing them in.
    """
    _ensure_parent()
    event: dict[str, Any] = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": kind,
        **fields,
    }
    line = json.dumps(event, separators=(",", ":")) + "\n"
    with _LOCK:
        with _AUDIT_PATH.open("a", encoding="utf-8") as fh:
            fh.write(line)
