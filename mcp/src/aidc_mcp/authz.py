"""aidc's authorizer: the session scope and the taint gate, decided before a tool runs (TRS-12).

3tears-mcp asks the authorizer about every tool call before the handler, with the call's
tool name and arguments, and about every resource request with the URI's variables. So
the refusals that 1.x wrapped around each tool are made once, here, for every face:

- **Scope** (MCP-31): on a server limited to named sessions (`AIDC_MCP_ALLOWED_SESSIONS`),
  a tool given any other session's `name` is refused with `out_of_scope` before it does
  anything, and so is a resource of another session; the global config is not served.
- **Taint**: a tool that puts work into a session (`TAINT_GUARDED`) is refused with
  `tainted` while the session's policy sidecar says it is tainted. The flag is read on
  every call; when the sidecar cannot be asked, the call goes ahead and the failure is
  logged (fail open: refusing every send whenever docker is slow would stop all work,
  and a session whose sidecar is gone has lost its proxy too).

A refusal answers with aidc's envelope as the result's content, as 1.x's wrappers did,
and its code on the protocol result (TRS-05). It is logged to the access log as a
`tool_call` with `refused=`, as before.
"""

from __future__ import annotations

import uuid
from collections.abc import Mapping
from typing import Any

from threetears.mcp import Identity, Refusal, ResourceRequest, ToolCall

from aidc_mcp import audit, auth, scope
from aidc_mcp import session_facts as sf
from aidc_mcp.service import common as com
from aidc_mcp.tearstools.base import MESH_PREFIX

#: the permission every aidc tool and resource requires; the one caller holds it
PERMISSION = "aidc"

#: the one caller a token holder is: an aidc install has one user, with every permission
ADMIN = Identity(principal_type="user",
                 principal_id=uuid.UUID("00000000-0000-0000-0000-00000000a1dc"), is_admin=True)


async def resolve_identity(token: str) -> Identity:
    """3tears-mcp's bearer resolver: the admin identity for the current token (auth.py reads
    the file as it is now, so a rotated token is refused at once, TRS-08). Any other token
    raises, which the server answers as IDENTITY_UNAVAILABLE, running nothing."""
    if not auth.token_matches(token):
        raise RuntimeError("the bearer token is not this server's token")
    return ADMIN

#: the tools that put work into a session: a prompt, a command, a file. Each refuses a
#: tainted session. Stopping work (session_interrupt) and taking a queued prompt back
#: (session_queue_cancel) put nothing in, and stay open.
TAINT_GUARDED = frozenset({
    "session_send", "session_resend", "session_invoke", "session_invoke_async",
    "session_exec", "file_put",
})

#: the tools whose `name` is not an existing session the scope limits: session_create names
#: the session it makes, and a scoped server refuses creating at all (create_not_allowed)
_NAME_IS_NOT_A_SESSION = frozenset({"session_create"})

#: the resource a scoped server does not serve
_GLOBAL_CONFIG = "aidc://config"


def _taint_refusal(name: str, taint: dict[str, str]) -> dict[str, Any]:
    domain = f" ({taint['domain']})" if taint.get("domain") else ""
    return com.envelope_err(
        f"The session '{name}' was tainted at {taint.get('at') or 'an unknown time'} by "
        f"{taint.get('trigger') or 'unknown'}{domain}. Nothing was sent to it. A tainted "
        "session takes no more work: only the person can kill it and create it again.",
        {"tainted": taint}, code="tainted")


def local_name(tool_name: str) -> str:
    """The tool's local name, whichever face asks: the mesh calls `session_send`
    `aidc.session_send` (TRS-15), and the guards below are the tool's, not the face's."""
    return tool_name.removeprefix(MESH_PREFIX)


async def refusal_of(tool_name: str, arguments: Mapping[str, Any]) -> dict[str, Any] | None:
    """The envelope refusing this call before the tool runs, or None to let it run.
    Logs a refusal to the access log."""
    tool_name = local_name(tool_name)
    name = arguments.get("name")
    if tool_name in _NAME_IS_NOT_A_SESSION or not isinstance(name, str):
        return None
    why = scope.refusal(name)
    if why is not None:
        audit.log_event("tool_call", tool=tool_name, session=name, refused="out_of_scope")
        return com.envelope_err(why, code="out_of_scope")
    if tool_name not in TAINT_GUARDED:
        return None
    try:
        taint = await sf.read_taint(name)
    except sf.TaintUnknown as exc:
        audit.log_event("session_taint_unreadable", session=name, tool=tool_name,
                        error=str(exc)[:300])
        return None
    if taint is None:
        return None
    audit.log_event("tool_call", tool=tool_name, session=name, refused="tainted",
                    tainted_at=taint.get("at", ""), trigger=taint.get("trigger", ""))
    return _taint_refusal(name, taint)


def resource_refusal(uri: str, variables: Mapping[str, Any]) -> str | None:
    """Why a resource request is refused on this server, or None when it is served."""
    if uri == _GLOBAL_CONFIG and scope.allowed_sessions() is not None:
        return "the aidc config is not available on an MCP server limited to named sessions"
    name = variables.get("name")
    if isinstance(name, str):
        return scope.refusal(name)
    return None


class AidcAuthorizer:
    """The authorizer the local MCP face runs (3tears-mcp's CallAuthorizer and
    ResourceAuthorizer). The one admin identity holds every permission; what it may do
    to a session is the scope's and the taint flag's to say."""

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None

    async def allows(self, identity: Identity, permission: str) -> bool:
        return identity.is_admin and permission == PERMISSION

    async def authorize_call(self, identity: Identity, call: ToolCall) -> bool | Refusal:
        if not await self.allows(identity, call.required_permission):
            return False
        envelope = await refusal_of(call.tool_name, call.arguments)
        if envelope is None:
            return True
        return Refusal(code=envelope["error_code"], message=envelope["error"],
                       argument="name", content=envelope)

    async def authorize_resource(self, identity: Identity,
                                 request: ResourceRequest) -> bool | Refusal:
        if not await self.allows(identity, request.required_permission):
            return False
        why = resource_refusal(request.uri, request.variables)
        if why is None:
            return True
        if request.action != "list":
            audit.log_event("resource_read", uri=request.uri, refused="out_of_scope")
        return Refusal(code="out_of_scope", message=why)
