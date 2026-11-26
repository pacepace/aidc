"""The base of every aidc tool: one 3tears `TearsTool` over the service (TRS-10).

A tool is a class with a `call` method. `call`'s signature is the tool's arguments
(`Annotated[..., Field(description=...)]`, as the 1.x server read them) and its docstring
is the tool's description; it calls the service and returns the service's envelope
({"ok": true, "data": ...} or {"ok": false, "error", "error_code", "data"?}). The base
turns that into the tool's schema and its `ToolResult`: the envelope as JSON content,
`success` equal to `ok`, and the aidc code also in `metadata["error_code"]`.
`ToolResult.error_code` stays unset: aidc's codes are carried by the faces from the
metadata, and none of the five platform codes means what an aidc code means.

Nothing here imports an MCP type. A tool that talks to its caller while it runs (progress,
log lines, cancellation) receives the face's call context as `ctx`; the context's type is
named for type checking only, so the faces without one (a test, the mesh) pass None.
"""

from __future__ import annotations

import annotationlib
import inspect
import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, ClassVar

import pydantic
from threetears.tool_contract import MCPToolDefinition, TearsTool, ToolResult
from threetears.tool_schema import self_contained_input_schema

from aidc_mcp import __version__
from aidc_mcp.service import common as com
from aidc_mcp.tearstools.descriptions import watching_suffix

if TYPE_CHECKING:
    from threetears.mcp import CallContext

#: the mesh's namespace for aidc's tools (TRS-15): `aidc.session_send` on the mesh,
#: `session_send` on the local MCP face
MESH_PREFIX = "aidc."

#: call's parameters that are not arguments of the tool
_NOT_ARGUMENTS = frozenset({"self", "ctx"})


async def _nothing() -> None:
    return None


@dataclass(frozen=True)
class ToolHooks:
    """What a face hands its tools: how to tell its clients that the tool list changed.

    `announce` runs after the set of watched sessions changes (session_send starting a
    webhook, session_watch, session_unwatch): the session tools' descriptions name the
    watched sessions (MCP-21), so the face tells its clients to list the tools again.
    """

    announce: Callable[[], Awaitable[None]] = field(default=_nothing)


class AidcTool(TearsTool):
    """One aidc tool. Subclasses set `local_name` and define `call`."""

    face_mcp = True

    #: the tool's name on the local MCP face; its mesh name is `aidc.<local_name>`
    local_name: ClassVar[str]

    def __init__(self, hooks: ToolHooks | None = None) -> None:
        self.hooks = hooks if hooks is not None else ToolHooks()
        self._arguments_model = _arguments_model(self.local_name, type(self).call)
        self._input_schema = self_contained_input_schema(
            self._arguments_model.model_json_schema(by_alias=True), tool_name=self.local_name)

    #: the tool's work, `call(ctx, **arguments)`, returning the service's envelope. Each tool
    #: defines it with its own arguments, which are the tool's schema
    call: Callable[..., Awaitable[dict[str, Any]]]

    def description(self) -> str:
        """The tool's description: `call`'s docstring, as the 1.x server listed it."""
        return type(self).call.__doc__ or ""

    def mcp_name(self) -> str:
        return MESH_PREFIX + self.local_name

    def mcp_version(self) -> str:
        return __version__

    def mcp_schema(self) -> MCPToolDefinition:
        return MCPToolDefinition(
            name=self.mcp_name(),
            version=self.mcp_version(),
            description=self.description(),
            input_schema=self._input_schema,
        )

    async def execute(self, ctx: CallContext | None = None, **arguments: Any) -> ToolResult:
        """Check the arguments against `call`'s signature, call it, and wrap its envelope.

        The arguments are read as the 1.x server read them (pydantic, lax): defaults
        filled, a number sent as text taken as the number, an argument the tool does not
        have ignored. One that cannot be read is refused with `invalid_argument` before
        the tool does anything."""
        try:
            parsed = self._arguments_model.model_validate(arguments)
        except pydantic.ValidationError as exc:
            first = exc.errors()[0]
            where = ".".join(str(p) for p in first.get("loc", ())) or "arguments"
            return envelope_result(com.envelope_err(
                f"{where}: {first.get('msg', 'invalid')}", code="invalid_argument"))
        values = {name: getattr(parsed, name) for name in type(parsed).model_fields}
        return envelope_result(await self.call(ctx, **values))


class SessionAwareTool(AidcTool):
    """A tool whose description ends with the sessions that have an open webhook right now
    (MCP-21), so a model picks one of them as `name`. Read on every listing."""

    def description(self) -> str:
        return super().description() + watching_suffix()


def progress_of(ctx: CallContext | None) -> Callable[[str], Awaitable[None]] | None:
    """The service's progress hook for one call: each phase the service reports goes to the
    caller as a log line (MCP-07). None without a call context."""
    if ctx is None:
        return None

    async def progress(message: str) -> None:
        await ctx.log("info", message)
    return progress


def envelope_result(envelope: dict[str, Any]) -> ToolResult:
    """The service's envelope as a ToolResult: JSON content, `success` = `ok`, the aidc
    code also in the metadata."""
    content = json.dumps(envelope, ensure_ascii=False, default=str)
    if envelope.get("ok"):
        return ToolResult(success=True, content=content)
    code = envelope.get("error_code")
    return ToolResult(success=False, content=content, error=str(envelope.get("error") or ""),
                      metadata={"error_code": code} if isinstance(code, str) else None)


def _arguments_model(tool_name: str, call: Callable[..., Any]) -> type[pydantic.BaseModel]:
    """A pydantic model of `call`'s arguments, built the way the 1.x server built its own
    (one field per parameter, its annotation and default), so the schema it gives is the
    one 1.x published before flattening."""
    fields: dict[str, Any] = {}
    hints = _hints(call)
    for param in inspect.signature(call).parameters.values():
        if param.name in _NOT_ARGUMENTS or param.kind in (param.VAR_KEYWORD, param.VAR_POSITIONAL):
            continue
        annotation = hints.get(param.name, Any)
        default = ... if param.default is inspect.Parameter.empty else param.default
        fields[param.name] = (annotation, default)
    return pydantic.create_model(f"{tool_name}Arguments", **fields)


def _hints(call: Callable[..., Any]) -> dict[str, Any]:
    """`call`'s argument annotations, evaluated in its module, with Annotated metadata kept
    (the Field descriptions). `ctx` is left out: its type is named for type checking only,
    so it is never evaluated."""
    module = inspect.getmodule(call)
    namespace = dict(vars(module)) if module is not None else {}
    written = annotationlib.get_annotations(call, format=annotationlib.Format.STRING)
    return {name: eval(text, namespace)  # noqa: S307 -- the tool's own annotation, in its module
            for name, text in written.items() if name not in _NOT_ARGUMENTS and name != "return"}
