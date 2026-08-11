"""MCP resources — read-only data exposed as URIs.

These are lighter than tools (no side effects) and the client can
subscribe to updates. We push update notifications when the underlying
data changes (e.g., a new session appears, a taint flag is written).
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

AIDC = os.environ.get("AIDC_CLI", "/aidc/scripts/aidc")


def _run(args: list[str]) -> str:
    """Run aidc CLI, return stdout (empty on failure)."""
    try:
        proc = subprocess.run([AIDC, *args], capture_output=True, text=True, timeout=30)
        return proc.stdout if proc.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def parse_audit_dir(status: str) -> Path | None:
    """Extract the session's audit dir from `aidc status` stdout.

    The CLI prints a line like ``audit: /path/to/dir`` (or ``audit dir: ...``).
    Matched case-insensitively so a header-case change in the CLI does not
    silently break audit reads — shared by resources here and tools.audit_get
    (previously copy-pasted three times, one of which was case-sensitive)."""
    for raw in status.splitlines():
        line = raw.strip()
        low = line.lower()
        if low.startswith("audit:") or low.startswith("audit dir"):
            parts = line.split(None, 1)
            if len(parts) == 2:
                return Path(parts[1].lstrip(":").strip())
    return None


def register(app: Any) -> None:
    """Attach every resource to the given FastMCP app."""

    @app.resource("aidc://sessions")
    def list_all_sessions() -> str:
        """Live list of all aidc sessions on this host."""
        return json.dumps({"raw": _run(["list"])})

    @app.resource("aidc://config")
    def show_global_config() -> str:
        """Effective global aidc config (merged defaults + ~/.config/aidc/config.yaml)."""
        return json.dumps({"raw": _run(["config", "global"])})

    @app.resource("aidc://sessions/{name}/status")
    def session_status_resource(name: str) -> str:
        """Live status for one named session."""
        return json.dumps({"raw": _run(["status", name])})

    @app.resource("aidc://sessions/{name}/audit")
    def session_audit_listing(name: str) -> str:
        """File listing of the session's audit dir."""
        audit_dir = parse_audit_dir(_run(["status", name]))
        if audit_dir is None or not audit_dir.exists():
            return json.dumps({"error": "audit dir not found"})
        files = []
        for p in sorted(audit_dir.iterdir()):
            try:
                files.append({"name": p.name, "size": p.stat().st_size, "is_dir": p.is_dir()})
            except OSError:
                continue
        return json.dumps({"audit_dir": str(audit_dir), "files": files})

    @app.resource("aidc://sessions/{name}/audit/{filename}")
    def session_audit_file(name: str, filename: str) -> str:
        """Contents of a specific file in the session's audit dir."""
        audit_dir = parse_audit_dir(_run(["status", name]))
        if audit_dir is None:
            return json.dumps({"error": "audit dir not found"})
        target = audit_dir / filename
        # Refuse traversal outside the audit dir.
        try:
            target.resolve().relative_to(audit_dir.resolve())
        except (ValueError, OSError):
            return json.dumps({"error": "path traversal denied"})
        if not target.exists() or not target.is_file():
            return json.dumps({"error": "file not found"})
        try:
            return json.dumps({"path": str(target), "content": target.read_text(encoding="utf-8")})
        except UnicodeDecodeError:
            return json.dumps({"path": str(target), "content": "(binary; use file_get tool)"})
