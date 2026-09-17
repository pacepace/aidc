"""Behavioral tests for the session_send tool body.

session_send is the live-session conversational path and is non-blocking: it
injects the prompt into the tmux window and returns a send-confirmation
immediately, leaving the transcript watcher to deliver Claude's reply over the
webhook. These tests drive the registered tool closure directly with every
container/tmux helper monkeypatched, so the async contract is pinned without a
real Docker session.
"""
import asyncio
import json

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import tools
from aidc_mcp import transcript as ts

# The wiring fixture patches asyncio.sleep MODULE-WIDE (tools.asyncio is the real
# asyncio module) with a non-yielding stub, so a test cannot use asyncio.sleep to
# hand control to a background task. Capture the genuine one at import time.
_REAL_SLEEP = asyncio.sleep


async def _let_drainer_run(session: str, ticks: int = 50) -> None:
    """Yield to the event loop until the drainer has emptied `session`'s queue."""
    for _ in range(ticks):
        await _REAL_SLEEP(0)
        if session not in tools._pending_sends:
            return


def _make_send():
    app = FastMCP("t")
    tools.register(app)
    return app, app._tool_manager._tools["session_send"].fn


class _StubTask:
    """Stands in for an asyncio.Task already present in _session_watchers."""

    def cancel(self):
        pass


class Wiring:
    """Mutable happy-path config + call record for the patched I/O helpers."""

    def __init__(self):
        self.claude_running = True
        self.container = tools.CONTAINER_EXISTS
        self.container_id = "id-1"
        self.idle_ok = True
        self.paste_ok = True
        self.paste_calls = []
        self.tmux_calls = []
        self.free_checks = 0
        self.captured = False
        self.sleeps = []


@pytest.fixture
def wiring(monkeypatch):
    w = Wiring()

    async def is_running(container):
        return w.claude_running

    async def check_free(container, name):
        w.free_checks += 1
        if not w.claude_running:
            return "claude_not_running"
        if w.idle_ok is True:
            return ""
        return w.idle_ok or "claude_busy"   # a reason string, or False for busy

    async def container_state(container):
        return w.container

    async def container_id(container):
        return "" if w.container == tools.CONTAINER_GONE else w.container_id

    async def load_paste(container, text, window):
        w.paste_calls.append((container, text, window))
        return w.paste_ok

    async def tmux_exec(container, args):
        w.tmux_calls.append((container, args))
        return 0

    async def capture(container, window):
        # Only the free check reads the screen; it is patched above, so any capture
        # means some path reads the pane on its own.
        w.captured = True
        return ""

    async def fake_sleep(seconds):
        # Record poll sleeps without actually waiting, but yield: a drainer that never
        # gives up would otherwise spin without letting the test run.
        w.sleeps.append(seconds)
        await _REAL_SLEEP(0)

    monkeypatch.setattr(tools, "_is_claude_running", is_running)
    monkeypatch.setattr(tools, "_check_free", check_free)
    monkeypatch.setattr(tools, "_container_state", container_state)
    monkeypatch.setattr(tools, "_container_id", container_id)
    monkeypatch.setattr(tools, "_load_and_paste", load_paste)
    monkeypatch.setattr(tools, "_tmux_exec", tmux_exec)
    monkeypatch.setattr(tools, "_capture_screen", capture)
    monkeypatch.setattr(tools.asyncio, "sleep", fake_sleep)
    return w


def _sent_enter(tmux_calls):
    """True if an Enter keypress was sent into the session window."""
    return any(args and args[0] == "send-keys" and args[-1] == "Enter" for _, args in tmux_calls)


async def test_sent_immediately_without_blocking_when_watching(wiring):
    """Happy path: a session with an open webhook gets the prompt pasted + Enter,
    and returns a 'sent' confirmation without ever waiting for / capturing a reply."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()

    res = await send(name="proj", prompt="line one\nline two", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "sent"
    assert "response" not in res["data"]  # reply comes via webhook, not inline
    assert "webhook" in res["data"]["delivery"]
    # Prompt pasted with newlines flattened to spaces, then Enter sent.
    assert wiring.paste_calls[0][1] == "line one line two"
    assert _sent_enter(wiring.tmux_calls)
    # Non-blocking contract: two consecutive free readings before the paste, and no
    # pane capture of a reply.
    assert wiring.free_checks == 2
    assert wiring.captured is False
    # Until the transcript shows the prompt, a follow-up send reads the session busy.
    assert tools._sent_awaiting_echo["proj"][0] == "line one line two"


async def test_sent_warns_when_no_webhook_open(wiring):
    """No conversation_id and no existing watcher -> still sends, but the return
    says plainly that the reply will not be auto-delivered (never silently dropped)."""
    app, send = _make_send()

    res = await send(name="proj", prompt="hello")

    assert res["ok"] is True
    assert res["data"]["status"] == "sent"
    assert "NOT" in res["data"]["delivery"]
    assert "session_invoke" in res["data"]["delivery"]
    assert wiring.paste_calls  # the prompt still went in
    assert _sent_enter(wiring.tmux_calls)


async def test_no_webhook_reason_names_missing_conversation_id(wiring):
    """The warning must say WHICH gate closed. Both gates (no conversation_id,
    no callback_url) used to produce the same opaque message, so a misconfigured
    deployment looked identical to a non-metallm caller."""
    app, send = _make_send()

    res = await send(name="proj", prompt="hello")

    assert res["ok"] is True
    assert "conversation_id" in res["data"]["delivery"]
    assert "Do NOT re-send" in res["data"]["delivery"]


async def test_no_webhook_reason_names_missing_callback_url(wiring, monkeypatch):
    """A conversation_id arrived but metallm.callback_url is unset — the exact
    prod misconfiguration (2026-07-26) that dropped every reply. The reply is
    still lost, but the return now names the config key to fix."""
    app, send = _make_send()
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "")

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "sent"
    assert "callback_url" in res["data"]["delivery"]
    assert "proj" not in tools._session_watchers
    assert wiring.paste_calls  # the prompt still went in


async def test_auto_starts_watcher_with_conversation_id(wiring, monkeypatch):
    """First send with a conversation_id opens the webhook (registers a watcher)
    so subsequent replies have somewhere to land."""
    app, send = _make_send()

    async def baseline(name, conversation_id):
        return None

    async def fake_watcher(*a, **k):
        await asyncio.Event().wait()  # stay alive until the cleanup fixture cancels

    async def announce(app_):
        return None

    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    monkeypatch.setattr(tools, "_baseline_watermark", baseline)
    monkeypatch.setattr(tools, "_run_transcript_watcher", fake_watcher)
    monkeypatch.setattr(tools, "_announce_watchers", announce)

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "sent"
    assert "webhook" in res["data"]["delivery"]
    assert "proj" in tools._session_watchers


async def test_errors_when_the_session_does_not_exist(wiring):
    app, send = _make_send()
    wiring.container = tools.CONTAINER_GONE
    tools._sent_awaiting_echo["proj"] = ("from before it was killed", 0.0)

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is False
    assert "no session named" in res["error"]
    assert res["error_code"] == "no_such_session"
    assert not wiring.paste_calls
    assert "proj" not in tools._pending_sends
    assert "proj" not in tools._sent_awaiting_echo   # its send-path state is forgotten
    # Checked before the webhook opens: nothing is started or saved for it.
    assert "proj" not in tools._session_watchers
    assert not ts.watch_path(tools._WATCHER_STATE_DIR, "proj").exists()


async def test_claude_not_running_holds_the_prompt_instead_of_refusing(wiring):
    """A restarting Claude is not a reason to lose the prompt."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.claude_running = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "queued"
    assert res["data"]["waiting_reason"] == "claude_not_running"
    assert "not running" in res["data"]["delivery"]

    wiring.claude_running = True
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["hello"]


async def test_queues_instead_of_dropping_when_session_busy(wiring):
    """A busy session must not COST the prompt. The old behaviour waited 30s and
    returned an error, discarding it — prod 2026-08-22 conv 01a01cf6 lost a 1021-char
    prompt that way to a turn which ran 22 minutes, and nothing on either side
    retried it. Now it queues: ok=True, status "queued", nothing pasted yet."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "queued"
    assert res["data"]["queued_behind"] == 0
    # Held, not injected into the running turn.
    assert not wiring.paste_calls
    assert not _sent_enter(wiring.tmux_calls)
    assert [q.text for q in tools._pending_sends["proj"]] == ["hello"]
    assert res["data"]["waiting_reason"] == "claude_busy"
    # The caller is told plainly not to retry — re-sending is what produced the
    # duplicate-prompt shape this replaces.
    assert "do NOT re-send" in res["data"]["delivery"]
    assert "session_resend" in res["data"]["delivery"]


async def test_queued_prompts_are_injected_in_order_when_the_turn_ends(wiring):
    """The drainer injects the backlog once the pane frees up, oldest first."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False

    assert (await send(name="proj", prompt="first", conversation_id="c1"))["data"][
        "status"] == "queued"
    second = await send(name="proj", prompt="second", conversation_id="c1")
    assert second["data"]["queued_behind"] == 1

    # The turn ends: the pane goes idle and the drainer catches up.
    wiring.idle_ok = True
    await _let_drainer_run("proj")

    assert [text for _, text, _ in wiring.paste_calls] == ["first", "second"]
    assert _sent_enter(wiring.tmux_calls)
    assert "proj" not in tools._pending_sends


async def test_send_queues_behind_a_waiting_prompt_even_when_idle(wiring):
    """Order is the whole point: with something already queued, a new send must
    NOT jump the line by pasting just because the pane looks idle right now."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    tools._pending_sends["proj"] = [ts.QueuedPrompt("earlier", "t", 0, "claude_busy")]

    res = await send(name="proj", prompt="later", conversation_id="c1")

    assert res["data"]["status"] == "queued"
    assert not wiring.paste_calls
    assert [q.text for q in tools._pending_sends["proj"]] == ["earlier", "later"]
    assert res["data"]["waiting_reason"] == "queued_behind"


async def test_refuses_once_the_queue_is_full(wiring):
    """A wedged session must not accumulate prompts without bound."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    tools._pending_sends["proj"] = [ts.QueuedPrompt(f"q{i}", "t")
                                    for i in range(tools._PENDING_MAX_DEPTH)]

    res = await send(name="proj", prompt="one too many", conversation_id="c1")

    assert res["ok"] is False
    assert "queued" in res["error"]
    assert res["error_code"] == "queue_full"
    assert len(tools._pending_sends["proj"]) == tools._PENDING_MAX_DEPTH


async def test_a_long_busy_turn_never_costs_the_prompt(wiring):
    """No deadline: a turn that runs for hours keeps the prompt waiting, then it lands."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False

    await send(name="proj", prompt="hello", conversation_id="c1")
    await _let_drainer_run("proj", ticks=500)
    assert [q.text for q in tools._pending_sends["proj"]] == ["hello"]
    assert not list((tools._WATCHER_STATE_DIR / "dead-letter").glob("send__*"))

    wiring.idle_ok = True
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["hello"]


async def test_spawn_drainer_does_not_start_a_second_one(wiring):
    """One drainer per session. Two would race to pop the same queue head and
    could paste the same prompt twice."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False

    await send(name="proj", prompt="a", conversation_id="c1")
    first = tools._pending_drainers["proj"]
    await send(name="proj", prompt="b", conversation_id="c1")

    assert tools._pending_drainers["proj"] is first


async def test_claude_stopping_holds_the_queue(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False
    await send(name="proj", prompt="hello", conversation_id="c1")

    wiring.claude_running = False
    await _let_drainer_run("proj", ticks=200)
    assert [q.text for q in tools._pending_sends["proj"]] == ["hello"]
    assert tools._pending_sends["proj"][0].waiting_reason == "claude_not_running"

    wiring.claude_running = True
    wiring.idle_ok = True
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["hello"]


async def test_killing_the_session_dead_letters_every_waiting_prompt(wiring):
    """The only way a prompt leaves the queue unpasted, and it is still recorded."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False
    await send(name="proj", prompt="one", conversation_id="c1")
    await send(name="proj", prompt="two", conversation_id="c1")

    wiring.container = tools.CONTAINER_GONE
    await _let_drainer_run("proj", ticks=200)

    assert "proj" not in tools._pending_sends
    dead = sorted(json.loads(p.read_text())["prompt"] for p in
                  (tools._WATCHER_STATE_DIR / "dead-letter").glob("send__proj__*.json"))
    assert dead == ["one", "two"]
    assert not ts.send_queue_path(tools._WATCHER_STATE_DIR, "proj").exists()


async def test_failed_pastes_retry_past_three_attempts_then_land(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False
    await send(name="proj", prompt="hello", conversation_id="c1")

    fails = {"left": 5}

    async def flaky_paste(container, text, window):
        wiring.paste_calls.append((container, text, window))
        fails["left"] -= 1
        return fails["left"] < 0

    tools._load_and_paste = flaky_paste   # restored by monkeypatch at teardown
    wiring.idle_ok = True
    await _let_drainer_run("proj", ticks=300)

    assert len(wiring.paste_calls) == 6
    assert "proj" not in tools._pending_sends
    # Backoff between failed pastes: 2, 4, 8 … s, capped.
    retries = [x for x in wiring.sleeps if x not in (0.0, tools._FREE_POLL_S)]
    assert retries == [2.0, 4.0, 8.0, 16.0, 32.0]
    assert not list((tools._WATCHER_STATE_DIR / "dead-letter").glob("send__*"))


async def test_queue_is_persisted_and_resumed_after_a_restart(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "input_has_text"
    await send(name="proj", prompt="first", conversation_id="c1")
    await send(name="proj", prompt="second", conversation_id="c1")
    await _let_drainer_run("proj", ticks=20)

    saved, _ = ts.load_send_queues(tools._WATCHER_STATE_DIR)
    assert [(q.text, q.waiting_reason) for q in saved["proj"]] == [
        ("first", "input_has_text"), ("second", "queued_behind")]

    # The MCP restarts: in-memory state is gone, the file is not.
    for task in tools._pending_drainers.values():
        task.cancel()
    await _REAL_SLEEP(0)
    tools._pending_sends.clear()
    tools._pending_drainers.clear()
    tools._queue_loaded.clear()

    wiring.idle_ok = True
    await tools.resume_send_queues()
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["first", "second"]
    assert not ts.send_queue_path(tools._WATCHER_STATE_DIR, "proj").exists()


async def test_resume_dead_letters_queues_of_sessions_that_are_gone(wiring):
    ts.save_send_queue(tools._WATCHER_STATE_DIR, "gone",
                       [ts.QueuedPrompt("orphan", "2026-09-17T02:00:00Z")])
    wiring.container = tools.CONTAINER_GONE
    await tools.resume_send_queues()
    assert "gone" not in tools._pending_sends
    [dead] = (tools._WATCHER_STATE_DIR / "dead-letter").glob("send__gone__*.json")
    assert json.loads(dead.read_text())["reason"] == "session_killed"


async def test_queued_prompts_record_the_session_they_were_accepted_for(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "claude_busy"
    await send(name="proj", prompt="hello", conversation_id="c1")
    [q] = ts.load_send_queues(tools._WATCHER_STATE_DIR)[0]["proj"]
    assert (q.conversation_id, q.container_id) == ("c1", "id-1")


async def test_a_prompt_sent_without_a_conversation_records_the_open_webhooks(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    ts.save_watch(tools._WATCHER_STATE_DIR, "proj", "c-watched", "http://cb")
    wiring.idle_ok = "claude_busy"
    await send(name="proj", prompt="hello")
    [q] = ts.load_send_queues(tools._WATCHER_STATE_DIR)[0]["proj"]
    assert q.conversation_id == "c-watched"


async def test_a_session_recreated_during_the_wait_does_not_get_the_old_prompt(wiring):
    """The drainer checks the prompt's session again under the paste lock: the wait for
    a free session can be long enough for it to be killed and created again."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "claude_busy"
    await send(name="proj", prompt="for the old session", conversation_id="c1")

    async def recreated_while_waiting(container, name):
        wiring.container_id = "id-2"
        return ""

    wiring.idle_ok = True
    tools._check_free = recreated_while_waiting   # restored by monkeypatch at teardown
    await _let_drainer_run("proj", ticks=100)

    assert not wiring.paste_calls
    assert "proj" not in tools._pending_sends
    [dead] = (tools._WATCHER_STATE_DIR / "dead-letter").glob("send__proj__*.json")
    assert json.loads(dead.read_text())["prompt"] == "for the old session"


async def test_a_prompt_is_not_lost_when_the_queue_list_is_replaced_during_enqueue(
        wiring, monkeypatch):
    """_enqueue_send awaits the container id; the drainer can replace the session's
    queue list meanwhile. The prompt must land in the list that is kept."""
    replacement = [ts.QueuedPrompt("kept", "2026-09-17T04:00:00Z", container_id="id-1")]

    async def container_id(container):
        tools._pending_sends["proj"] = replacement
        return "id-1"

    monkeypatch.setattr(tools, "_container_id", container_id)
    await tools._enqueue_send("proj", "aidc-proj-dev", "new", "claude_busy")
    assert [q.text for q in tools._pending_sends["proj"]] == ["kept", "new"]


async def test_an_unreadable_saved_queue_is_kept_aside_not_overwritten(wiring):
    path = ts.send_queue_path(tools._WATCHER_STATE_DIR, "proj")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json")
    # Startup cannot tell whose it is (the name is inside the file): logged, left alone.
    await tools.resume_send_queues()
    assert path.read_text() == "{not json"

    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "claude_busy"
    await send(name="proj", prompt="new", conversation_id="c1")
    [aside] = path.parent.glob(f"{path.name}.unreadable-*")
    assert aside.read_text() == "{not json"
    assert [q.text for q in ts.load_send_queues(path.parent)[0]["proj"]] == ["new"]


async def test_the_drainer_reports_a_prompt_that_has_waited_long(wiring, monkeypatch):
    notices = []

    async def capture(name, items, error_code):
        notices.append((name, [q.text for q, _ in items], error_code))

    monkeypatch.setattr(tools, "_PROMPT_WAITING_S", 0.0)
    monkeypatch.setattr(tools, "_notify_prompts", capture)
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "claude_busy"
    await send(name="proj", prompt="stuck", conversation_id="c1")
    for _ in range(20):
        await _REAL_SLEEP(0)
    assert notices == [("proj", ["stuck"], "prompt_waiting")]


async def test_a_saved_queue_goes_before_a_send_that_beats_startup_resume(wiring):
    """After a restart, a session_send can arrive before startup has resumed the saved
    queue. The saved prompts still go first, and resume does not load them twice."""
    ts.save_send_queue(tools._WATCHER_STATE_DIR, "proj", [
        ts.QueuedPrompt("saved", "2026-09-17T02:00:00Z", waiting_reason="claude_busy",
                        conversation_id="c1", container_id="id-1")])
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()

    res = await send(name="proj", prompt="new", conversation_id="c1")
    assert res["data"]["status"] == "queued"
    await tools.resume_send_queues()
    await _let_drainer_run("proj", ticks=100)

    assert [text for _, text, _ in wiring.paste_calls] == ["saved", "new"]


async def test_status_line_shows_while_waiting_on_unsent_text_and_clears_on_paste(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "input_has_text"
    await send(name="proj", prompt="hello", conversation_id="c1")
    await _let_drainer_run("proj", ticks=20)

    options = [args for _, args in wiring.tmux_calls if args[:1] == ["set-option"]]
    assert options[-1] == ["set-option", "-t", "main", "@aidc_waiting",
                           tools._WAITING_ON_INPUT_TEXT]

    wiring.idle_ok = True
    await _let_drainer_run("proj")
    options = [args for _, args in wiring.tmux_calls if args[:1] == ["set-option"]]
    assert options[-1] == ["set-option", "-t", "main", "-u", "@aidc_waiting"]


async def test_status_line_clears_when_the_wait_changes_to_another_reason(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "input_has_text"
    await send(name="proj", prompt="hello", conversation_id="c1")
    await _let_drainer_run("proj", ticks=20)
    wiring.idle_ok = "claude_busy"
    await _let_drainer_run("proj", ticks=20)
    options = [args for _, args in wiring.tmux_calls if args[:1] == ["set-option"]]
    assert options[-1] == ["set-option", "-t", "main", "-u", "@aidc_waiting"]


async def test_session_status_lists_waiting_prompts_with_reasons(wiring, monkeypatch):
    app = FastMCP("t")
    tools.register(app)
    status = app._tool_manager._tools["session_status"].fn
    monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": "ok", "stderr": ""})
    tools._pending_sends["proj"] = [
        ts.QueuedPrompt("x" * 300, "2026-09-17T02:00:00Z", 2, "paste_failing")]

    res = status(name="proj")

    [entry] = res["data"]["send_queue"]
    assert entry["prompt_preview"] == "x" * 120
    assert entry["waiting_reason"] == "paste_failing"
    assert "failing" in entry["waiting_because"]
    assert entry["paste_attempts"] == 2


async def test_a_failed_paste_is_queued_and_retried_not_refused(wiring):
    """A paste that does not land is one failed attempt, not a failed send: the prompt
    is queued and pasted once the paste works."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.paste_ok = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "queued"
    assert res["data"]["waiting_reason"] == "paste_failing"
    assert not _sent_enter(wiring.tmux_calls)  # no Enter after a failed paste
    assert tools._pending_sends["proj"][0].paste_attempts == 1   # the failed paste counts

    wiring.paste_ok = True
    await _let_drainer_run("proj", ticks=100)
    assert "proj" not in tools._pending_sends
    assert [text for _, text, _ in wiring.paste_calls][-1] == "hello"
    assert _sent_enter(wiring.tmux_calls)


# --- injected-prompt record (terminal-typed prompt attribution) ----------------
# The watcher tells a prompt the orchestrator sent from one a person typed at the
# pane ONLY by this record, so every path that pastes must write it — and only
# after the paste landed.

async def test_direct_send_records_the_injected_prompt(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()

    await send(name="proj", prompt="fix the\nfailing test", conversation_id="c1")

    # Recorded in its pasted (newline-folded) form; matching is whitespace-insensitive.
    assert ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "fix the failing test")


async def test_queued_send_records_only_once_injected(wiring):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False

    await send(name="proj", prompt="later", conversation_id="c1")
    assert not ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "later")  # not yet

    wiring.idle_ok = True
    await _let_drainer_run("proj")
    assert ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "later")


async def test_inject_is_the_single_recording_point(wiring):
    """Every paste path goes through _inject, and _inject records on success —
    so no caller can forget to (the record is what keeps a reply from being
    framed as the person's)."""
    assert await tools._inject("aidc-proj-dev", "via inject", tools._SESSION_WINDOW, session="proj")
    assert ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "via inject")
    wiring.paste_ok = False
    assert not await tools._inject("aidc-proj-dev", "lost", tools._SESSION_WINDOW, session="proj")
    assert not ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "lost")


async def test_failed_paste_records_nothing(wiring):
    app, send = _make_send()
    wiring.paste_ok = False

    await send(name="proj", prompt="hello", conversation_id="c1")

    assert not ts.consume_sent_prompt(tools._WATCHER_STATE_DIR, "proj", "hello")


async def test_record_write_failure_does_not_fail_the_send(wiring, monkeypatch):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()

    def boom(*a, **k):
        raise OSError("read-only")

    monkeypatch.setattr(ts, "record_sent_prompt", boom)
    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is True
    assert res["data"]["status"] == "sent"


async def test_a_docker_error_is_not_a_killed_session(wiring):
    """Only a definite 'no such container' ends a queue. A daemon hiccup must not
    dead-letter prompts the orchestrator is waiting on."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False
    await send(name="proj", prompt="hello", conversation_id="c1")

    wiring.container = tools.CONTAINER_UNKNOWN
    await _let_drainer_run("proj", ticks=200)
    assert [q.text for q in tools._pending_sends["proj"]] == ["hello"]
    assert not list((tools._WATCHER_STATE_DIR / "dead-letter").glob("send__*"))

    wiring.container = tools.CONTAINER_EXISTS
    wiring.idle_ok = True
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["hello"]


async def test_resume_keeps_a_queue_when_docker_cannot_answer(wiring):
    ts.save_send_queue(tools._WATCHER_STATE_DIR, "proj",
                       [ts.QueuedPrompt("kept", "2026-09-17T02:00:00Z")])
    wiring.container = tools.CONTAINER_UNKNOWN
    wiring.idle_ok = False
    await tools.resume_send_queues()
    assert [q.text for q in tools._pending_sends["proj"]] == ["kept"]


async def test_status_line_clears_after_a_failed_paste_then_a_successful_one(wiring):
    """Waiting on typed text, the person clears it, one paste fails, the retry lands:
    the notice must not stay up."""
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = "input_has_text"
    await send(name="proj", prompt="hello", conversation_id="c1")
    await _let_drainer_run("proj", ticks=20)

    fails = {"left": 1}

    async def flaky_paste(container, text, window):
        wiring.paste_calls.append((container, text, window))
        fails["left"] -= 1
        return fails["left"] < 0

    tools._load_and_paste = flaky_paste
    wiring.idle_ok = True
    await _let_drainer_run("proj", ticks=100)

    assert "proj" not in tools._pending_sends
    options = [args for _, args in wiring.tmux_calls if args[:1] == ["set-option"]]
    assert options[-1] == ["set-option", "-t", "main", "-u", "@aidc_waiting"]
    assert "proj" not in tools._waiting_notice_shown


async def test_a_recurring_drainer_error_restarts_with_backoff_not_a_spin(wiring, monkeypatch):
    app, send = _make_send()
    tools._session_watchers["proj"] = _StubTask()
    wiring.idle_ok = False
    await send(name="proj", prompt="hello", conversation_id="c1")

    async def broken(container, name, timeout):
        raise RuntimeError("boom")

    monkeypatch.setattr(tools, "_wait_until_free", broken)
    await _let_drainer_run("proj", ticks=60)

    assert [q.text for q in tools._pending_sends["proj"]] == ["hello"]
    restarts = [x for x in wiring.sleeps if x not in (0.0, tools._FREE_POLL_S)]
    assert restarts[:4] == [2.0, 4.0, 8.0, 16.0]


async def test_resume_remembers_the_notice_is_showing_so_it_is_cleared(wiring):
    """The tmux option outlives an MCP restart. A queue saved while waiting on input
    must clear it when its prompt is pasted after resuming."""
    ts.save_send_queue(tools._WATCHER_STATE_DIR, "proj",
                       [ts.QueuedPrompt("waiting", "2026-09-17T02:00:00Z", 0, "input_has_text")])
    wiring.idle_ok = True
    await tools.resume_send_queues()
    await _let_drainer_run("proj")
    assert [text for _, text, _ in wiring.paste_calls] == ["waiting"]
    options = [args for _, args in wiring.tmux_calls if args[:1] == ["set-option"]]
    assert options[-1] == ["set-option", "-t", "main", "-u", "@aidc_waiting"]
