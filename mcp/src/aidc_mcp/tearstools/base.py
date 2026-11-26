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
import re
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, ClassVar

import pydantic
from threetears.observe import set_span_attribute, traced
from threetears.tool_contract import MCPToolDefinition, TearsTool, ToolResult
from threetears.tool_schema import self_contained_input_schema

from aidc_mcp import __version__, observability
from aidc_mcp.service import common as com
from aidc_mcp.tearstools.descriptions import watching_suffix

if TYPE_CHECKING:
    from threetears.mcp import CallContext

#: the mesh's namespace for aidc's tools (TRS-15): `aidc.session_send` on the mesh,
#: `session_send` on the local MCP face
MESH_PREFIX = "aidc."

#: every tool's result: the service's envelope (design-10 D6). Declared so a client is sent
#: the envelope as `structuredContent` as well as JSON text, as 1.x sent it
ENVELOPE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "ok": {"type": "boolean"},
        "data": {},
        "error": {"type": "string"},
        "error_code": {"type": "string", "enum": sorted(com.ERROR_CODES)},
    },
    "required": ["ok"],
}

#: a whole decimal integer written as text, as 1.x took for an integer argument
_WHOLE_NUMBER = re.compile(r"[+-]?[0-9]+")

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
        written = self._arguments_model.model_json_schema(by_alias=True)
        self._input_schema = nullable_kept(
            written, self_contained_input_schema(written, tool_name=self.local_name))

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

    def prepare_arguments(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        """A call's arguments as 1.x read them, before the schema checks them: an integer
        argument sent as a whole number in text ("5") becomes that number. The schema stays
        `integer`, so a caller is still shown the form to send; anything else is left as it
        came, for the schema to accept or refuse."""
        props = self._input_schema.get("properties", {})
        out = dict(arguments)
        for name, value in arguments.items():
            kind = props.get(name, {}).get("type")
            integer = kind == "integer" or (isinstance(kind, list) and "integer" in kind)
            if integer and isinstance(value, str) and _WHOLE_NUMBER.fullmatch(value):
                out[name] = int(value)
        return out

    def mcp_schema(self) -> MCPToolDefinition:
        return MCPToolDefinition(
            name=self.mcp_name(),
            version=self.mcp_version(),
            description=self.description(),
            input_schema=self._input_schema,
            output_schema=ENVELOPE_SCHEMA,
        )

    async def execute(self, ctx: CallContext | None = None, **arguments: Any) -> ToolResult:
        """Run one call of the tool in its own observability scope (a correlation id every
        log line of the call carries, one span, its duration counted; TRS-14)."""
        with observability.tool_call(self.local_name) as call:
            result = await self._traced_call(ctx, arguments)
            call["outcome"] = "ok" if result.success else "failed"
            return result

    @traced(name=observability.TOOL_SPAN)
    async def _traced_call(self, ctx: CallContext | None,
                           arguments: dict[str, Any]) -> ToolResult:
        """Check the arguments against `call`'s signature, call it, and wrap its envelope.

        The arguments are read as the 1.x server read them (pydantic, lax): defaults
        filled, a number sent as text taken as the number, an argument the tool does not
        have ignored. One that cannot be read is refused with `invalid_argument` before
        the tool does anything."""
        set_span_attribute("aidc.tool", self.local_name)
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
    """The service's progress hook for one call (MCP-07, TRS-04): each phase the service
    reports goes to the caller as `notifications/progress` (when it sent a progress token;
    the count of phases so far, the phase as the message) and as a log line. None without a
    call context."""
    if ctx is None:
        return None
    phases = 0

    async def progress(message: str) -> None:
        nonlocal phases
        phases += 1
        await ctx.report_progress(phases, None, message)
        await ctx.log("info", message)
    return progress


def nullable_kept(written: dict[str, Any], flat: dict[str, Any]) -> dict[str, Any]:
    """`flat` with null allowed again where the tool's own schema allowed it.

    tool-schema collapses an optional `anyOf: [X, null]` to `X`, and 3tears-mcp checks every
    call against the listed schema before the tool runs, so a caller sending such an argument
    as null would be refused, where 1.x took null as "not given". A prompt refused for a null
    `sent_by` is a prompt not sent, so each such argument is listed as `type: [X, "null"]`:
    still self-contained (no `$ref`, no `anyOf`), and null reaches the tool as its default."""
    out = dict(flat)
    props = {name: dict(spec) for name, spec in flat.get("properties", {}).items()}
    for name, spec in written.get("properties", {}).items():
        branches = spec.get("anyOf") if isinstance(spec, dict) else None
        if not branches or {"type": "null"} not in branches or name not in props:
            continue
        kind = props[name].get("type")
        if isinstance(kind, str):
            props[name]["type"] = [kind, "null"]
    out["properties"] = props
    return out


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
