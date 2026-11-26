"""Calling a tool the way the local face does, without the transport.

The face runs the authorizer (scope, then taint) and then the tool; a refusal answers
the authorizer's envelope, as the face does (the refusal's content). These helpers give
the tests that envelope, so a test of a tool's behaviour reads as it did when it called
the 1.x tool function. What only the wire shows (codes on the protocol result, the
listing, notifications) is tested through the real app in test_wire.py.
"""
import json
from typing import Any

from aidc_mcp import authz
from aidc_mcp.tearstools import AidcTool, ToolHooks, build_tools


def instance(tool_name: str, hooks: ToolHooks | None = None) -> AidcTool:
    return next(t for t in build_tools(hooks) if t.local_name == tool_name)


async def call(tool_name: str, /, *, ctx: Any = None, hooks: ToolHooks | None = None,
               **arguments: Any) -> dict[str, Any]:
    """The envelope a call of `tool_name` answers, refusals included."""
    refused = await authz.refusal_of(tool_name, arguments)
    if refused is not None:
        return refused
    result = await instance(tool_name, hooks).execute(ctx, **arguments)
    return json.loads(result.content)


def tool(tool_name: str, hooks: ToolHooks | None = None):
    """`tool_name` as an async function of its arguments answering its envelope; `ctx=` is
    the call context, as the face passes it."""
    async def fn(**kwargs: Any) -> dict[str, Any]:
        ctx = kwargs.pop("ctx", None)
        return await call(tool_name, ctx=ctx, hooks=hooks, **kwargs)
    return fn
