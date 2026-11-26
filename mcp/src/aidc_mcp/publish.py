"""The server's tool list as a file: every tool's name, description and input schema.

An orchestrator classifies each tool it binds (what kind of thing it is, whether it can
be undone), and a tool it has no row for arrives unclassified. So the list is published
with the code, as `mcp/published-tools.json`, and an orchestrator keeps a copy to check
its rows against. A test holds the file equal to what this code produces, so it cannot
go stale. Regenerate it with `uv run python scripts/publish_tools.py`.

Built with session_create on, so the list holds every tool a server can offer. The
schemas are 3tears' self-contained form of 1.x's (TRS-11).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

PUBLISHED = Path(__file__).resolve().parents[2] / "published-tools.json"


def published_tools() -> list[dict[str, Any]]:
    """Every tool a server can offer, sorted by name, as the local MCP face lists it (with
    no session watched)."""
    from aidc_mcp import server

    listed = server.Face(include_create=True).listing()
    return sorted(({"name": t.name, "description": t.description,
                    "input_schema": t.input_schema} for t in listed),
                  key=lambda t: str(t["name"]))


def render() -> str:
    return json.dumps(published_tools(), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    PUBLISHED.write_text(render(), encoding="utf-8")
    print(f"wrote {PUBLISHED}")
    return 0
