"""Deterministic aidc round-trip harness — proves the FULL send->reply->deliver
path WITHOUT invoking a real agent (no AI, no Claude, no network to a real service).

The pieces that are REAL here:
  - session_send's tool body (prompt injection flow, watcher auto-registration).
  - _start_watcher + _baseline_watermark (the forward-only anchor).
  - _drain_transcript_once / _drain_once_body (the watcher's actual delivery pass).
  - _post_turn (the outbound-to-metallm HTTP boundary, exact payload + URL).

The pieces that are STUBBED (the non-deterministic edges):
  - the tmux/Docker boundary (_is_claude_running / _wait_for_idle / _load_and_paste
    / _tmux_exec / _capture_pane) — no container.
  - the background poll TIMER (_run_transcript_watcher) — replaced with an
    alive-forever no-op so the drain is driven explicitly, deterministically.
  - the outbound httpx client — a FakeMetallm sink records every callback POST.
  - "Claude" — the agent is a fixture that appends a KNOWN reply line to the
    transcript file on disk. Deterministic, no AI.

This is the exact bug that burned prod for days: a metallm session hands a prompt
to aidc and either the reply never comes back, or old backlog replays. Both are
pinned below.
"""
import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import tools
from aidc_mcp import transcript as ts

# --- transcript fixture builders (a deterministic stand-in for Claude) --------

def _user(uuid, text):
    return {"type": "user", "uuid": uuid,
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def _assistant(uuid, text, stop="end_turn"):
    return {"type": "assistant", "uuid": uuid,
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}],
                        "stop_reason": stop}}


def _agent_writes(base, session, sid, objs):
    """The 'agent' (deterministic, no AI) writes/appends the session transcript."""
    d = base / session
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{sid}.jsonl"
    p.write_text("\n".join(json.dumps(o) for o in objs) + "\n", encoding="utf-8")
    return p


async def _nosleep(_seconds):
    return None


class FakeMetallm:
    """Stands in for metallm's callback endpoint: records every outbound POST so a
    test can assert the EXACT payload and URL that would reach metallm."""

    def __init__(self, *, succeed=True):
        self.posts = []
        self.succeed = succeed

    def client_factory(self):
        outer = self

        def _make(*_a, **_k):
            client = AsyncMock()
            client.__aenter__ = AsyncMock(return_value=client)
            client.__aexit__ = AsyncMock(return_value=False)

            async def _post(url, json=None, headers=None):
                outer.posts.append({"url": url, "json": json, "headers": headers})
                return MagicMock(is_success=outer.succeed,
                                 status_code=200 if outer.succeed else 502, text="")

            client.post = AsyncMock(side_effect=_post)
            return client

        return _make


# --- send-side wiring (tmux/Docker + background timer stubbed) -----------------

@pytest.fixture
def harness(tmp_path, monkeypatch):
    """A round-trip rig: session_send injects with no container; the watcher's
    baseline/state are redirected to tmp dirs; the background poll timer is a
    no-op; the outbound HTTP boundary is a FakeMetallm sink. The drain is driven
    explicitly by the test for determinism."""
    base = tmp_path / "transcripts"
    state = tmp_path / "watcher-state"
    metallm = FakeMetallm()
    paste_calls: list[str] = []

    async def is_running(container):
        return True

    async def wait_idle(container, window, timeout):
        return True

    async def load_paste(container, text, window):
        paste_calls.append(text)
        return True

    async def tmux_exec(container, args):
        return 0

    async def capture(container, window):
        return ""

    async def announce(app):
        return None

    async def fake_watcher(*a, **k):
        # Stand in for the background poll loop: stay alive (the conftest cancels
        # it) but never actually poll — the test drives the drain explicitly.
        await asyncio.Event().wait()

    # Redirect the REAL baseline onto the tmp dirs (session_send/_start_watcher
    # call it by module-global name, so this rebinding takes effect).
    real_baseline = tools._baseline_watermark

    async def baseline_tmp(name, conversation_id):
        await real_baseline(name, conversation_id, transcripts_base=base, state_dir=state)

    monkeypatch.setattr(tools, "_is_claude_running", is_running)
    monkeypatch.setattr(tools, "_wait_for_idle", wait_idle)
    monkeypatch.setattr(tools, "_load_and_paste", load_paste)
    monkeypatch.setattr(tools, "_tmux_exec", tmux_exec)
    monkeypatch.setattr(tools, "_capture_pane", capture)
    monkeypatch.setattr(tools, "_announce_watchers", announce)
    monkeypatch.setattr(tools, "_run_transcript_watcher", fake_watcher)
    monkeypatch.setattr(tools, "_baseline_watermark", baseline_tmp)
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://metallm.local")
    monkeypatch.setattr(tools, "_load_token", lambda: "tok")
    monkeypatch.setattr(tools.httpx, "AsyncClient", metallm.client_factory())
    monkeypatch.setattr(tools.asyncio, "sleep", _nosleep)

    app = FastMCP("t")
    tools.register(app)
    send = app._tool_manager._tools["session_send"].fn
    resend_tool = app._tool_manager._tools["session_resend"].fn

    async def drain():
        """One REAL delivery pass (what the background watcher would run), pointed
        at the tmp dirs, using the REAL _post_turn -> FakeMetallm HTTP boundary."""
        await tools._drain_transcript_once(
            "proj", "conv-1", "http://metallm.local",
            transcripts_base=base, state_dir=state, sleep_fn=_nosleep,
        )

    async def resend(turn_uuid=None):
        """The REAL resend path, pointed at the tmp dirs + FakeMetallm boundary."""
        return await tools._resend_reply(
            "proj", "conv-1", "http://metallm.local", turn_uuid=turn_uuid,
            transcripts_base=base, state_dir=state, sleep_fn=_nosleep,
        )

    class Rig:
        pass

    rig = Rig()
    rig.base = base
    rig.state = state
    rig.metallm = metallm
    rig.paste_calls = paste_calls
    rig.send = send
    rig.drain = drain
    rig.resend = resend
    rig.resend_tool = resend_tool
    return rig


# --- Deliverable 1: the full round-trip proves the reply comes back exactly once


async def test_fresh_session_reply_delivered_exactly_once(harness):
    """FULL round-trip on a FRESH aidc session (no transcript yet at connect):
    session_send injects the prompt and opens the webhook; the agent appends a
    KNOWN reply; the real watcher drain delivers it back to metallm EXACTLY ONCE.

    This is the 'reply never comes back' bug: on a fresh session the baseline
    anchors with an empty session_id, and the first drain used to treat the very
    first transcript as a rotation and forward-baseline PAST the reply — silently
    swallowing it. Regression-locked here end-to-end."""
    h = harness
    # Fresh session: the transcript dir exists but is empty when we connect.
    (h.base / "proj").mkdir(parents=True)

    res = await h.send(name="proj", prompt="what does foo() do?", conversation_id="conv-1")
    assert res["ok"] is True
    assert res["data"]["status"] == "sent"
    assert "proj" in tools._session_watchers          # webhook opened
    assert h.paste_calls == ["what does foo() do?"]    # prompt actually injected
    # Baseline anchored forward with nothing to skip (fresh session).
    mark = ts.load_watermark(h.state, "proj", "conv-1")
    assert mark.last_delivered_uuid == ""

    # The agent (deterministic, no AI) produces its reply: the injected prompt +
    # a KNOWN assistant answer land in a brand-new transcript file.
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "what does foo() do?"),
        _assistant("a1", "foo() returns the answer."),
    ])

    await h.drain()

    # The reply came BACK — exactly one callback POST, with the exact payload/URL
    # metallm would receive.
    assert len(h.metallm.posts) == 1
    post = h.metallm.posts[0]
    assert post["url"] == "http://metallm.local/api/v1/internal/callback/conv-1"
    assert post["json"] == {"content": "foo() returns the answer.", "ok": True,
                            "source": "agent_watch", "session": "proj"}
    assert post["headers"]["Authorization"] == "Bearer tok"

    # Exactly-once: re-draining (the watcher polls repeatedly) does NOT re-deliver.
    await h.drain()
    await h.drain()
    assert len(h.metallm.posts) == 1


async def test_forward_only_backlog_not_replayed_only_new_reply(harness):
    """Forward-only-on-connect: pre-existing backlog written BEFORE the baseline is
    NEVER delivered on (re)connect; only a NEW reply that completes AFTER the
    watermark is. This is the 'old backlog replays' half of the prod disaster."""
    h = harness
    # The session already ran before metallm connected: two OLD turns on disk.
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "old q1"), _assistant("old1", "OLD ANSWER 1"),
        _user("u2", "old q2"), _assistant("old2", "OLD ANSWER 2"),
    ])

    # metallm connects and sends. The baseline must anchor PAST the backlog.
    res = await h.send(name="proj", prompt="new question", conversation_id="conv-1")
    assert res["ok"] is True
    mark = ts.load_watermark(h.state, "proj", "conv-1")
    assert mark.session_id == "sid-A"
    assert mark.last_delivered_uuid == "old2"          # anchored at current end

    # A drain right now must deliver NOTHING — the backlog is not caught up.
    await h.drain()
    assert h.metallm.posts == []

    # The agent answers the new prompt (appended after the backlog).
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "old q1"), _assistant("old1", "OLD ANSWER 1"),
        _user("u2", "old q2"), _assistant("old2", "OLD ANSWER 2"),
        _user("u3", "new question"), _assistant("a3", "THE NEW ANSWER"),
    ])
    await h.drain()

    # Only the NEW reply is delivered; the OLD backlog is never posted.
    assert [p["json"]["content"] for p in h.metallm.posts] == ["THE NEW ANSWER"]


async def test_multi_turn_back_and_forth_each_reply_once(harness):
    """A back-and-forth conversation: each subsequent send's reply is delivered
    exactly once, in order, and no earlier turn is ever re-sent."""
    h = harness
    (h.base / "proj").mkdir(parents=True)

    # Turn 1.
    await h.send(name="proj", prompt="q1", conversation_id="conv-1")
    _agent_writes(h.base, "proj", "sid-A", [_user("u1", "q1"), _assistant("a1", "A1")])
    await h.drain()

    # Turn 2 (watcher already open — no re-baseline, continues forward).
    await h.send(name="proj", prompt="q2", conversation_id="conv-1")
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "q1"), _assistant("a1", "A1"),
        _user("u2", "q2"), _assistant("a2", "A2"),
    ])
    await h.drain()

    assert [p["json"]["content"] for p in h.metallm.posts] == ["A1", "A2"]


async def test_failed_callback_retries_then_dead_letters_never_silent(harness):
    """If metallm is unreachable, the reply is NOT silently lost: it is retried and
    then dead-lettered (recorded on disk), and the watermark still advances so the
    line does not wedge. (Retry sleeps are a no-op here, so the bounded backoff
    runs instantly to budget exhaustion.)"""
    h = harness
    h.metallm.succeed = False                          # metallm returns non-2xx forever
    (h.base / "proj").mkdir(parents=True)

    await h.send(name="proj", prompt="q", conversation_id="conv-1")
    _agent_writes(h.base, "proj", "sid-A", [_user("u1", "q"), _assistant("a1", "UNDELIVERABLE")])
    await h.drain()

    dead = list((h.state / "dead-letter").glob("*.json"))
    assert len(dead) == 1
    assert json.loads(dead[0].read_text())["content"] == "UNDELIVERABLE"
    assert ts.load_watermark(h.state, "proj", "conv-1").last_delivered_uuid == "a1"


# --- Deliverable 2: resend a lost/missed reply, WITHOUT a backlog replay -------


async def test_resend_redelivers_last_reply_and_does_not_replay_backlog(harness):
    """The user's explicit need: re-deliver a reply that was lost/missed. Resend
    re-sends the session's most recent reply exactly once, WITHOUT moving the
    watermark — so the forward-only watcher is undisturbed and no backlog replays."""
    h = harness
    (h.base / "proj").mkdir(parents=True)

    # A two-turn exchange, both delivered normally by the watcher.
    await h.send(name="proj", prompt="q1", conversation_id="conv-1")
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "q1"), _assistant("a1", "ANSWER ONE"),
        _user("u2", "q2"), _assistant("a2", "ANSWER TWO"),
    ])
    await h.drain()
    assert [p["json"]["content"] for p in h.metallm.posts] == ["ANSWER ONE", "ANSWER TWO"]
    mark_before = ts.load_watermark(h.state, "proj", "conv-1").last_delivered_uuid
    assert mark_before == "a2"

    # metallm says "the last reply never arrived" — resend it.
    ok, turn = await h.resend()
    assert ok is True
    assert turn.terminal_uuid == "a2"
    # Exactly ONE new callback, carrying the exact last reply + correct URL.
    assert len(h.metallm.posts) == 3
    last = h.metallm.posts[-1]
    assert last["url"] == "http://metallm.local/api/v1/internal/callback/conv-1"
    assert last["json"] == {"content": "ANSWER TWO", "ok": True,
                            "source": "agent_watch", "session": "proj"}

    # The watermark did NOT move — resend is out-of-band.
    assert ts.load_watermark(h.state, "proj", "conv-1").last_delivered_uuid == mark_before
    # And a normal drain still delivers nothing (NO backlog replay from the resend).
    await h.drain()
    assert len(h.metallm.posts) == 3


async def test_resend_then_watcher_does_not_double_deliver(harness):
    """A resent turn is recorded in the delivery ledger, so if the watcher later
    drains that same turn (resend can target a reply the watcher has not yet
    reached), it dedups instead of delivering a second copy. Closes the resend
    double-delivery hole: the exactly-once invariant holds across BOTH paths."""
    h = harness
    (h.base / "proj").mkdir(parents=True)
    await h.send(name="proj", prompt="q1", conversation_id="conv-1")
    await h.drain()                                  # baseline, nothing delivered yet
    # The agent produces a reply the watcher has NOT drained yet.
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "q1"), _assistant("a1", "THE REPLY"),
    ])
    # Operator resends it out-of-band (e.g. the watcher was wedged/late).
    ok, turn = await h.resend()
    assert ok is True and turn.terminal_uuid == "a1"
    assert [p["json"]["content"] for p in h.metallm.posts] == ["THE REPLY"]
    # The watcher now catches up and drains a1 — it must NOT re-send it.
    await h.drain()
    assert [p["json"]["content"] for p in h.metallm.posts] == ["THE REPLY"]  # still one


async def test_resend_specific_turn_by_uuid(harness):
    """A specific earlier reply can be resent by its turn uuid (not just the last)."""
    h = harness
    (h.base / "proj").mkdir(parents=True)
    await h.send(name="proj", prompt="q1", conversation_id="conv-1")
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "q1"), _assistant("a1", "FIRST REPLY"),
        _user("u2", "q2"), _assistant("a2", "SECOND REPLY"),
    ])
    await h.drain()
    h.metallm.posts.clear()

    ok, turn = await h.resend(turn_uuid="a1")
    assert ok is True and turn.terminal_uuid == "a1"
    assert [p["json"]["content"] for p in h.metallm.posts] == ["FIRST REPLY"]


async def test_resend_nothing_to_send_when_no_reply(harness):
    """Resend on a session with no completed reply reports nothing to send (no crash,
    no spurious POST)."""
    h = harness
    (h.base / "proj").mkdir(parents=True)
    await h.send(name="proj", prompt="q1", conversation_id="conv-1")
    # Only a user line + an empty (tool-only) assistant turn — no deliverable reply.
    _agent_writes(h.base, "proj", "sid-A", [
        _user("u1", "q1"), _assistant("a1", None),
    ])
    ok, turn = await h.resend()
    assert ok is False and turn is None
    assert h.metallm.posts == []


async def test_resend_tool_requires_conversation_id(harness):
    """The session_resend TOOL refuses without a conversation_id (metallm injects
    it) rather than guessing where to deliver."""
    h = harness
    res = await h.resend_tool(name="proj")
    assert res["ok"] is False
    assert "conversation_id" in res["error"]
