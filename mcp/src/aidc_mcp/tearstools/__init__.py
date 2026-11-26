"""aidc's tools, one 3tears TearsTool each, over the service (TRS-10).

`build_tools` makes the instances every face serves: the local MCP face and the mesh
face register the same objects. A tool imports no MCP type; the faces adapt them.
"""

from __future__ import annotations

from aidc_mcp.tearstools import repository, sessions, talk
from aidc_mcp.tearstools.base import MESH_PREFIX, AidcTool, ToolHooks, envelope_result

#: every tool class, in the order 1.x registered them. session_create is offered only where
#: the operator turned it on (MCP-38), which the face decides
TOOL_CLASSES: tuple[type[AidcTool], ...] = (
    sessions.SessionCreate,
    sessions.SessionMcpSet,
    sessions.SessionList,
    sessions.SessionStatus,
    sessions.SessionExec,
    talk.SessionInvoke,
    talk.SessionInvokeAsync,
    talk.SessionSend,
    talk.SessionWatch,
    talk.SessionResend,
    talk.SessionUnwatch,
    repository.FileGet,
    repository.FileList,
    repository.FileSearch,
    repository.RepoStatus,
    repository.RepoDiff,
    repository.RepoLog,
    repository.RepoBranches,
    sessions.SessionTranscript,
    sessions.SessionInterrupt,
    talk.SessionQueueCancel,
    sessions.FilePut,
    sessions.AuditGet,
)


def build_tools(hooks: ToolHooks | None = None, *, include_create: bool = True) -> list[AidcTool]:
    """One instance of every tool, sharing the face's hooks."""
    return [cls(hooks) for cls in TOOL_CLASSES
            if include_create or cls is not sessions.SessionCreate]


__all__ = ["MESH_PREFIX", "TOOL_CLASSES", "AidcTool", "ToolHooks", "build_tools",
           "envelope_result"]
