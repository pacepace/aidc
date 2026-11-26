"""MCP resources: read-only data exposed as URIs (MCP-09), served by 3tears-mcp (TRS-06).

These are lighter than tools (no side effects), and a client on a stateful session can
subscribe to updates. The session scope (MCP-31) is the authorizer's (authz.py): a
resource of a session outside it, or the global config on a scoped server, is refused
before its reader runs. The readers here only read.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from threetears.mcp import McpResource, McpResourceTemplate

from aidc_mcp import scope
from aidc_mcp.authz import PERMISSION
from aidc_mcp.offload import off_loop

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
    silently break audit reads — used by the resources here (it was copy-pasted
    three times, one of which was case-sensitive). service.sessions.audit_get does not
    parse it: it reads the dir from the audit sidecar's mount (session_facts.audit_dir)."""
    for raw in status.splitlines():
        line = raw.strip()
        low = line.lower()
        if low.startswith("audit:") or low.startswith("audit dir"):
            parts = line.split(None, 1)
            if len(parts) == 2:
                return Path(parts[1].lstrip(":").strip())
    return None


@off_loop
def list_all_sessions() -> str:
    """Live list of all aidc sessions on this host."""
    return json.dumps({"raw": scope.filter_list(_run(["list"]))})


@off_loop
def show_global_config() -> str:
    """Effective global aidc config (merged defaults + ~/.config/aidc/config.yaml)."""
    return json.dumps({"raw": _run(["config", "global"])})


@off_loop
def session_status_resource(name: str) -> str:
    """Live status for one named session."""
    return json.dumps({"raw": _run(["status", name])})


@off_loop
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


@off_loop
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


def all_resources() -> list[McpResource | McpResourceTemplate]:
    """Every resource and template the server offers (MCP-09), the same URIs as 1.x."""
    def fixed(uri: str, reader: Any) -> McpResource:
        return McpResource(uri=uri, name=reader.__name__, required_permission=PERMISSION,
                           reader=reader, description=reader.__doc__, mime_type="text/plain")

    def template(uri: str, reader: Any) -> McpResourceTemplate:
        return McpResourceTemplate(uri_template=uri, name=reader.__name__,
                                   required_permission=PERMISSION, reader=reader,
                                   description=reader.__doc__, mime_type="text/plain")

    return [
        fixed("aidc://sessions", list_all_sessions),
        fixed("aidc://config", show_global_config),
        template("aidc://sessions/{name}/status", session_status_resource),
        template("aidc://sessions/{name}/audit", session_audit_listing),
        template("aidc://sessions/{name}/audit/{filename}", session_audit_file),
    ]
