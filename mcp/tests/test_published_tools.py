"""mcp/published-tools.json is what the code offers, so a copy an orchestrator keeps
is a true copy. A new tool, a renamed one or a changed schema fails here until the
file is regenerated (uv run python scripts/publish_tools.py)."""
import json

from aidc_mcp import publish


def test_the_published_file_is_what_the_code_offers():
    assert publish.PUBLISHED.exists(), "run: uv run python scripts/publish_tools.py"
    assert publish.PUBLISHED.read_text(encoding="utf-8") == publish.render()


def test_the_published_list_names_every_tool_and_no_withdrawn_one():
    names = {t["name"] for t in json.loads(publish.PUBLISHED.read_text(encoding="utf-8"))}
    assert {"session_create", "session_send", "session_transcript", "session_interrupt",
            "session_queue_cancel", "repo_status", "repo_diff", "repo_log", "repo_branches",
            "file_get", "file_list", "file_search"} <= names
    assert not names & {"taint_mark", "session_kill", "session_run"}
