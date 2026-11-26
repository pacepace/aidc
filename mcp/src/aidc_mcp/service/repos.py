"""Read-only access to a session's repository.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

from typing import Any

from aidc_mcp import audit, repo
from aidc_mcp import session_facts as sf
from aidc_mcp.service import common as com


def _repo_refusal(exc: repo.RepoRefusal) -> dict[str, Any]:
    """The failure envelope for a repository call that could not run. Each code is
    written out: the set of codes is a contract (ERROR_CODES), checked from this
    file's source."""
    said = str(exc)
    if exc.code == "outside_repo":
        return com.envelope_err(said, code="outside_repo")
    if exc.code == "invalid_argument":
        return com.envelope_err(said, code="invalid_argument")
    if exc.code == "not_found":
        return com.envelope_err(said, code="not_found")
    if exc.code == "timeout":
        return com.envelope_err(said, code="timeout")
    return com.envelope_err(said, code="command_failed")


async def in_repo(name: str, tool: str, run: Any) -> dict[str, Any]:
    """Run one read of the session's repository: `run(repo_dir)` -> data. The data is
    marked untrusted: it is the repository's text, not instructions."""
    repo_dir = await sf.repo_path(name)
    if repo_dir is None:
        audit.log_event("tool_call", tool=tool, session=name, ok=False,
                        error_code="no_such_session")
        return com.envelope_err(f"There is no session named '{name}' (or its dev container is "
                                "gone). Check session_list.", code="no_such_session")
    try:
        data = await run(repo_dir)
    except repo.RepoRefusal as exc:
        audit.log_event("tool_call", tool=tool, session=name, ok=False, error_code=exc.code)
        return _repo_refusal(exc)
    audit.log_event("tool_call", tool=tool, session=name, ok=True, cut=bool(data.get("cut")))
    return com.envelope_ok({"session": name, **data, "untrusted": True})


async def tree(name: str) -> dict[str, Any] | None:
    """The working tree in brief: branch, head, how many paths changed, the first 20."""
    repo_dir = await sf.repo_path(name)
    if repo_dir is None:
        return None
    try:
        st = await repo.status(name, repo_dir)
    except repo.RepoRefusal as exc:
        return {"error": str(exc)}
    return {"branch": st["branch"], "head": st["head"], "changes": len(st["changes"]),
            "dirty": [c["path"] for c in st["changes"][:20]]}
