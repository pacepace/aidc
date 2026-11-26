"""Reading a session's Claude Code hook events (MCP-46): the format the session's
aidc-hook-event writes, read back in order. The writer is .devcontainer/hook-event.sh,
tested in tests/unit/test-hook-event.sh; here the reader runs that same script, so the two
sides of the format are tested against each other."""
import json
import os
import pathlib
import subprocess
import time

from aidc_mcp import hook_events as he

HOOK = pathlib.Path(__file__).resolve().parents[2] / ".devcontainer" / "hook-event.sh"


def _fire(mirror, payload):
    """The hook as Claude Code runs it in the session: its input on stdin, from the Claude
    in tmux window main:claude (a stand-in tmux names the pane's window)."""
    bin_dir = mirror.parent / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "tmux"
    stub.write_text("#!/bin/sh\necho main:claude\n")
    stub.chmod(0o755)
    subprocess.run(["bash", str(HOOK)], input=json.dumps(payload), text=True, check=True,
                   env={**os.environ, "AIDC_HOOK_EVENTS_DIR": str(he.events_dir(mirror)),
                        "TMUX_PANE": "%0", "PATH": f"{bin_dir}:{os.environ['PATH']}"})
    time.sleep(0.002)   # distinct nanosecond names, as real hooks seconds apart have


def test_what_the_session_writes_is_read_back_in_order(tmp_path):
    mirror = tmp_path / "proj"
    mirror.mkdir()
    _fire(mirror, {"hook_event_name": "UserPromptSubmit", "session_id": "s1",
                   "prompt": "run the tests"})
    _fire(mirror, {"hook_event_name": "Notification", "session_id": "s1",
                   "notification_type": "permission_prompt",
                   "message": "Claude needs your permission to use Bash"})
    _fire(mirror, {"hook_event_name": "Stop", "session_id": "s1",
                   "last_assistant_message": "All 12 tests pass.", "stop_hook_active": False})
    events = he.read_events(mirror)
    assert [e.event for e in events] == [he.USER_PROMPT_SUBMIT, he.NOTIFICATION, he.STOP]
    assert events[0].prompt == "run the tests"
    assert events[1].notification_type == he.PERMISSION_PROMPT
    assert events[2].last_assistant_message == "All 12 tests pass."
    assert all(e.session_id == "s1" and e.at.endswith("Z") for e in events)
    assert events[2].data["stop_hook_active"] is False   # the hook's own fields are kept


def test_events_after_one_already_read_are_the_newer_ones_only(tmp_path):
    mirror = tmp_path / "proj"
    mirror.mkdir()
    _fire(mirror, {"hook_event_name": "Stop", "session_id": "s1"})
    [first] = he.read_events(mirror)
    _fire(mirror, {"hook_event_name": "Notification", "notification_type": "idle_prompt"})
    [newer] = he.read_events(mirror, after=first.name)
    assert newer.notification_type == he.IDLE_PROMPT
    assert he.read_events(mirror, after=newer.name) == []


def test_files_that_are_not_events_are_skipped(tmp_path):
    d = he.events_dir(tmp_path / "proj")
    d.mkdir(parents=True)
    (d / "1700000000000000000-1.json").write_text("{damaged")
    (d / "1700000000000000001-1.json").write_text('{"no": "event"}')
    (d / ".1700000000000000002-1.tmp").write_text('{"event": "Stop"}')   # mid-write
    (d / "notes.txt").write_text("x")
    (d / "1700000000000000003-1.json").write_text('{"event": "Stop", "at": "t"}')
    assert [e.name for e in he.read_events(tmp_path / "proj")] == ["1700000000000000003-1.json"]


def test_a_session_without_events_has_none(tmp_path):
    assert he.read_events(tmp_path / "never-mirrored") == []


def test_a_field_a_newer_claude_code_adds_is_kept_and_a_wrong_type_is_empty():
    e = he.parse_event("1700000000000000000-1.json", json.dumps(
        {"event": "Stop", "at": "t", "session_id": 5, "last_assistant_message": ["x"],
         "new_field": {"a": 1}}))
    assert e is not None and e.data["new_field"] == {"a": 1}
    assert e.session_id == "" and e.last_assistant_message == ""
