"""The server's tool list as a file: every tool's name, description and input schema.

An orchestrator classifies each tool it binds (what kind of thing it is, whether it can
be undone), and a tool it has no row for arrives unclassified. So the list is published
with the code, as `mcp/published-tools.json`, and an orchestrator keeps a copy to check
its rows against. A test holds the file equal to what this code produces, so it cannot
go stale. Regenerate it with `uv run python scripts/publish_tools.py`.

Built with session_create on, so the list holds every tool a server can offer.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

from aidc_mcp import scope, tools

PUBLISHED = Path(__file__).resolve().parents[2] / "published-tools.json"


def published_tools() -> list[dict[str, Any]]:
    """Every tool a server can offer, sorted by name."""
    before = os.environ.get(scope.ENABLE_CREATE_ENV)
    os.environ[scope.ENABLE_CREATE_ENV] = "true"
    try:
        app = FastMCP("aidc")
        tools.register(app)
        listed = asyncio.run(app.list_tools())
    finally:
        if before is None:
            os.environ.pop(scope.ENABLE_CREATE_ENV, None)
        else:
            os.environ[scope.ENABLE_CREATE_ENV] = before
        tools._tool_base_desc.clear()
    return sorted(({"name": t.name, "description": t.description or "",
                    "input_schema": t.inputSchema} for t in listed),
                  key=lambda t: str(t["name"]))


def render() -> str:
    return json.dumps(published_tools(), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    PUBLISHED.write_text(render(), encoding="utf-8")
    print(f"wrote {PUBLISHED}")
    return 0
