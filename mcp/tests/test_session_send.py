"""Behavioral tests for the session_send tool body.

session_send is the live-session conversational path and is non-blocking: it
injects the prompt into the tmux window and returns a send-confirmation
immediately, leaving the transcript watcher to deliver Claude's reply over the
webhook. These tests drive the registered tool closure directly with every
container/tmux helper monkeypatched, so the async contract is pinned without a
real Docker session.
"""
import asyncio

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import tools


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
        self.idle_ok = True
        self.paste_ok = True
        self.paste_calls = []
        self.tmux_calls = []
        self.idle_wait_count = 0
        self.captured = False
        self.sleeps = []


@pytest.fixture
def wiring(monkeypatch):
    w = Wiring()

    async def is_running(container):
        return w.claude_running

    async def wait_idle(container, window, timeout):
        w.idle_wait_count += 1
        return w.idle_ok

    async def load_paste(container, text, window):
        w.paste_calls.append((container, text, window))
        return w.paste_ok

    async def tmux_exec(container, args):
        w.tmux_calls.append((container, args))
        return 0

    async def capture(container, window):
        # session_send must NEVER capture the pane — that was the blocking path.
        w.captured = True
        return ""

    async def fake_sleep(seconds):
        # Record the post-Enter settle without actually waiting (keeps tests fast).
        w.sleeps.append(seconds)

    monkeypatch.setattr(tools, "_is_claude_running", is_running)
    monkeypatch.setattr(tools, "_wait_for_idle", wait_idle)
    monkeypatch.setattr(tools, "_load_and_paste", load_paste)
    monkeypatch.setattr(tools, "_tmux_exec", tmux_exec)
    monkeypatch.setattr(tools, "_capture_pane", capture)
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
    # Non-blocking contract: pre-send idle check only, and no pane capture.
    assert wiring.idle_wait_count == 1
    assert wiring.captured is False
    # Post-Enter settle ran so a rapid follow-up send won't paste mid-turn.
    assert 2.0 in wiring.sleeps


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


async def test_errors_when_claude_not_running(wiring):
    app, send = _make_send()
    wiring.claude_running = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is False
    assert "not running" in res["error"]
    assert not wiring.paste_calls  # nothing injected


async def test_errors_when_session_busy(wiring):
    """If the session never goes idle, the previous turn is still in flight:
    refuse rather than paste into a running turn."""
    app, send = _make_send()
    wiring.idle_ok = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is False
    assert "busy" in res["error"]
    assert not wiring.paste_calls
    assert not _sent_enter(wiring.tmux_calls)


async def test_errors_when_paste_fails(wiring):
    app, send = _make_send()
    wiring.paste_ok = False

    res = await send(name="proj", prompt="hello", conversation_id="c1")

    assert res["ok"] is False
    assert "inject" in res["error"]
    assert not _sent_enter(wiring.tmux_calls)  # no Enter after a failed paste
