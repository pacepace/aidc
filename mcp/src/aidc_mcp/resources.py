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
from typing import Any

from threetears.mcp import McpResource, McpResourceTemplate

from aidc_mcp import backend, scope, session_facts
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


@off_loop
def list_all_sessions() -> str:
    """Live list of all aidc sessions on this host."""
    return json.dumps({"raw": scope.filter_list(_run(["list", *backend.cli_backend_args()]))})


@off_loop
def show_global_config() -> str:
    """Effective global aidc config (merged defaults + ~/.config/aidc/config.yaml)."""
    return json.dumps({"raw": _run(["config", "global"])})


@off_loop
def session_status_resource(name: str) -> str:
    """Live status for one named session."""
    return json.dumps({"raw": _run(["status", name, *backend.cli_backend_args()])})


#: Lists the audit dir given first, as NUL-separated name, size and 1 for a folder (0 not).
_AUDIT_LIST_SCRIPT = r"""cd -- "$1" 2>/dev/null || exit 3
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || continue
  if [ -d "$f" ]; then d=1; else d=0; fi
  printf '%s\0%s\0%s\0' "$f" "$(stat -c %s -- "$f" 2>/dev/null || echo 0)" "$d"
done"""

#: Prints the file named second, in the audit dir given first: exit 3 when there is no audit
#: dir, 4 when no such file, 5 when the name leads outside the dir (a .. or a symlink).
_AUDIT_FILE_SCRIPT = r"""cd -- "$1" 2>/dev/null || exit 3
case "/$2/" in */../*|//*) exit 5 ;; esac
d=$(pwd -P)
f=$(readlink -f -- "$2" 2>/dev/null) || exit 4
case "$f" in "$d"/*) ;; *) exit 5 ;; esac
[ -f "$f" ] || exit 4
exec cat -- "$f"
"""


def _backend_run(argv: list[str]) -> subprocess.CompletedProcess[bytes]:
    """Run a backend command (docker or kubectl, from aidc_mcp.backend); the seam tests
    replace. A command that cannot run is a failed one, never a raise."""
    try:
        return subprocess.run(argv, capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return subprocess.CompletedProcess(argv, -1, b"", str(exc).encode())


def _in_audit_sidecar(name: str, script: str, *args: str) -> subprocess.CompletedProcess[bytes]:
    """`script` run in the session's audit sidecar, which mounts its audit dir: the dir is
    read where it is on both backends (on Docker a host folder this server's container does
    not mount, on Kubernetes a volume claim)."""
    tgt = backend.target(name, backend.ROLE_AUDIT)
    return _backend_run(backend.exec_argv(
        tgt, ["sh", "-c", script, "aidc-audit", session_facts.AUDIT_MOUNT, *args]))


def _audit_where(name: str) -> str:
    """Where the session's audit trail is (session_facts.audit_dir's answer)."""
    tgt = backend.target(name, backend.ROLE_AUDIT)
    res = _backend_run([backend.program(), *backend.mount_source_args(
        tgt, session_facts.AUDIT_MOUNT)])
    where = (backend.mount_source(res.stdout, tgt, session_facts.AUDIT_MOUNT)
             if res.returncode == 0 else None)
    return where or session_facts.AUDIT_MOUNT


@off_loop
def session_audit_listing(name: str) -> str:
    """File listing of the session's audit dir."""
    res = _in_audit_sidecar(name, _AUDIT_LIST_SCRIPT)
    if res.returncode != 0:
        return json.dumps({"error": "audit dir not found"})
    fields = res.stdout.decode("utf-8", errors="replace").split("\0")
    files: list[dict[str, Any]] = []
    for i in range(0, len(fields) - 2, 3):
        fname, size, is_dir = fields[i:i + 3]
        files.append({"name": fname, "size": int(size) if size.isdigit() else 0,
                      "is_dir": is_dir == "1"})
    files.sort(key=lambda f: str(f["name"]))
    return json.dumps({"audit_dir": _audit_where(name), "files": files})


@off_loop
def session_audit_file(name: str, filename: str) -> str:
    """Contents of a specific file in the session's audit dir."""
    res = _in_audit_sidecar(name, _AUDIT_FILE_SCRIPT, filename)
    if res.returncode == 5:
        return json.dumps({"error": "path traversal denied"})
    if res.returncode == 4:
        return json.dumps({"error": "file not found"})
    if res.returncode != 0:
        return json.dumps({"error": "audit dir not found"})
    path = f"{session_facts.AUDIT_MOUNT}/{filename}"
    try:
        return json.dumps({"path": path, "content": res.stdout.decode("utf-8")})
    except UnicodeDecodeError:
        return json.dumps({"path": path, "content": "(binary; use file_get tool)"})


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
