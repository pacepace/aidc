"""Tests for the transcript delivery loop (design-09 chunk 2, MCP-17/18/19).

Exercises _drain_transcript_once and _deliver_with_retry with an injected
post function and no-op sleep, against fixture transcript files in tmp dirs.
"""
import asyncio
import json
import os
from unittest.mock import AsyncMock, MagicMock, patch

from aidc_mcp import transcript as ts
from aidc_mcp.tools import (
    _LOOP_GUARD_IDLE_RESET_S,
    _LOOP_GUARD_MAX_CONSECUTIVE,
    _STALE_PIN_RECOVER_POLLS,
    _TORN_READ_RECOVER_POLLS,
    _baseline_watermark,
    _consumed_idle_counts,
    _deliver_with_retry,
    _drain_locks,
    _drain_transcript_once,
    _PermanentDeliveryError,
    _post_turn,
)


class _EmptyStrError(Exception):
    """Reproduces the original incident: str(exc) == '' but repr identifies it."""

    def __str__(self):
        return ""


def _http_client(post_side_effect):
    client = AsyncMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=False)
    client.post = AsyncMock(side_effect=post_side_effect)
    return client


# --- fixtures ----------------------------------------------------------------

def _user(uuid, text):
    return {"type": "user", "uuid": uuid,
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def _assistant(uuid, text, stop="end_turn", **extra):
    blocks = [{"type": "text", "text": text}] if text is not None else [{"type": "tool_use", "id": "t"}]
    return {"type": "assistant", "uuid": uuid,
            "message": {"role": "assistant", "content": blocks, "stop_reason": stop}, **extra}


def _ask_line(uuid, question="Which wins?"):
    """An assistant line that blocks on AskUserQuestion (stop_reason tool_use)."""
    block = {"type": "tool_use", "id": "aq", "name": "AskUserQuestion",
             "input": {"questions": [{"question": question,
                                      "options": [{"label": "A", "description": "first"}]}]}}
    return {"type": "assistant", "uuid": uuid,
            "message": {"role": "assistant", "content": [block], "stop_reason": "tool_use"}}


def _mk_transcript(base, session, sid, objs, mtime=None):
    d = base / session
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{sid}.jsonl"
    p.write_text("\n".join(json.dumps(o) for o in objs) + "\n", encoding="utf-8")
    if mtime is not None:
        os.utime(p, (mtime, mtime))
    return p


async def _nosleep(_d):
    return None


class Recorder:
    """Injectable post_fn(turn, attempt) -> bool."""

    def __init__(self, fail_times=0, always_fail=False):
        self.delivered = []
        self.calls = 0
        self.fail_times = fail_times
        self.always_fail = always_fail

    async def __call__(self, turn, attempt):
        self.calls += 1
        if self.always_fail:
            return False
        if self.calls <= self.fail_times:
            return False
        self.delivered.append(turn.terminal_uuid)
        return True


# --- _deliver_with_retry -----------------------------------------------------

class TestDeliverWithRetry:
    async def test_succeeds_first_try(self):
        rec = Recorder()
        assert await _deliver_with_retry(ts.Turn("a1", "x"), post_fn=rec, sleep_fn=_nosleep) is True
        assert rec.calls == 1

    async def test_retries_then_succeeds(self):
        rec = Recorder(fail_times=2)
        assert await _deliver_with_retry(ts.Turn("a1", "x"), post_fn=rec, sleep_fn=_nosleep) is True
        assert rec.calls == 3

    async def test_budget_exhausted_returns_false(self):
        rec = Recorder(always_fail=True)
        ok = await _deliver_with_retry(ts.Turn("a1", "x"), post_fn=rec, sleep_fn=_nosleep, budget=5.0)
        assert ok is False
        assert rec.calls >= 2  # tried a couple times before the next backoff blew the budget

    async def test_permanent_failure_stops_after_one_attempt(self):
        """A permanent HTTP status (e.g. 404 conversation-gone) must NOT be retried:
        the identical POST cannot succeed, and retrying floods the endpoint (the 34x
        meltdown). One attempt, then dead-letter (False)."""
        calls = 0

        async def gone(turn, attempt):
            nonlocal calls
            calls += 1
            raise _PermanentDeliveryError(404)

        ok = await _deliver_with_retry(ts.Turn("a1", "x"), post_fn=gone, sleep_fn=_nosleep)
        assert ok is False
        assert calls == 1  # <-- did NOT retry the dead conversation


# --- _drain_transcript_once (forward-only: first pass baselines, no replay) ----

async def _drain(base, state, rec, session="sess", conv="conv"):
    await _drain_transcript_once(session, conv, "http://cb", transcripts_base=base,
                                 state_dir=state, post_fn=rec, sleep_fn=_nosleep)


class TestDrain:
    async def test_forward_only_first_watch_does_not_replay_history(self, tmp_path):
        """The replay bug: a first watch on a session with existing history must
        NOT deliver that history — only turns that complete afterward."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [
            _user("u1", "a"), _assistant("a1", "OLD-1"),
            _user("u2", "b"), _assistant("a2", "OLD-2"),
        ])
        rec = Recorder()
        await _drain(base, state, rec)              # first pass = baseline only
        assert rec.delivered == []                  # <-- no replay of OLD-1/OLD-2
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.last_delivered_uuid == "a2"     # anchored at current end
        assert mark.session_id == "sid1"

    async def test_delivers_only_turns_after_baseline_then_dedups(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        hist = [_user("u1", "a"), _assistant("a1", "OLD")]
        _mk_transcript(base, "sess", "sid1", hist)
        rec = Recorder()
        await _drain(base, state, rec)              # baseline past OLD
        assert rec.delivered == []
        # New turns after watching begins.
        _mk_transcript(base, "sess", "sid1", hist + [
            _user("u2", "b"), _assistant("a2", "NEW1"),
            _user("u3", "c"), _assistant("a3", "NEW2"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a2", "a3"]
        await _drain(base, state, rec)              # dedup
        assert rec.delivered == ["a2", "a3"]

    async def test_baseline_persists_across_restart_no_replay(self, tmp_path):
        """A re-baseline with no new history re-anchors to the same turn — so a
        re-register (e.g. after MCP restart) never replays already-seen history."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u1", "a"), _assistant("a1", "OLD")])
        rec = Recorder()
        await _drain(base, state, rec)              # baseline
        # Simulate restart: the watcher is gone but the mark file remains.
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        await _drain(base, state, rec)
        assert rec.delivered == []                  # still no replay

    async def test_reconnect_reanchors_forward_and_skips_backlog(self, tmp_path):
        """Forward-only-on-connect (the catch-up fix): if history accumulates
        while the watcher is DOWN, a reconnect re-baseline re-anchors to the
        current end and must NOT replay that backlog to 'catch up' — only turns
        that complete AFTER the reconnect are delivered."""
        base = tmp_path / "t"; state = tmp_path / "s"
        hist = [_user("u1", "a"), _assistant("a1", "OLD")]
        _mk_transcript(base, "sess", "sid1", hist)
        rec = Recorder()
        await _drain(base, state, rec)              # baseline past OLD (last=a1)
        # Watcher down; the session keeps running and accumulates a BACKLOG.
        backlog = hist + [
            _user("u2", "b"), _assistant("a2", "GAP-1"),
            _user("u3", "c"), _assistant("a3", "GAP-2"),
        ]
        _mk_transcript(base, "sess", "sid1", backlog)
        # Reconnect: the re-baseline must SKIP the gap, not deliver GAP-1/GAP-2.
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        await _drain(base, state, rec)
        assert rec.delivered == []                  # <-- backlog NOT caught up
        assert ts.load_watermark(state, "sess", "conv").last_delivered_uuid == "a3"
        # A genuinely NEW turn after the reconnect IS delivered.
        _mk_transcript(base, "sess", "sid1", backlog + [
            _user("u4", "d"), _assistant("a4", "AFTER"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a4"]

    async def test_reanchor_preserves_loop_guard_run(self, tmp_path):
        """The re-anchor must NOT reset the loop-guard run — otherwise a session
        that re-registers on every send would never trip the runaway backstop."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u1", "a"), _assistant("a1", "OLD")])
        await _drain(base, state, Recorder())       # baseline
        mark = ts.load_watermark(state, "sess", "conv")
        mark.consecutive_deliveries = 7
        mark.last_delivery_at = 12345.0
        ts.save_watermark(state, mark)
        # Reconnect re-baseline: run must survive.
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        after = ts.load_watermark(state, "sess", "conv")
        assert after.consecutive_deliveries == 7
        assert after.last_delivery_at == 12345.0

    async def test_reanchor_keeps_session_pin_against_newer_mtime_sibling(self, tmp_path):
        """Reconnect re-anchor must PREFER the pinned session_id, not newest-mtime.
        A frozen sibling transcript re-touched to a newer mtime (the copy-forward
        mirror does this) would otherwise mis-pin the watcher and anchor past — and
        lose — the real session's response."""
        base = tmp_path / "t"; state = tmp_path / "s"
        # Active session sidA (older mtime) with history.
        _mk_transcript(base, "sess", "sidA",
                       [_user("u1", "a"), _assistant("a1", "OLD")], mtime=1000)
        await _drain(base, state, Recorder())       # baseline pins to sidA
        assert ts.load_watermark(state, "sess", "conv").session_id == "sidA"
        # A frozen sibling sidB gets a NEWER mtime (the mirror re-touch).
        _mk_transcript(base, "sess", "sidB",
                       [_user("x1", "z"), _assistant("b1", "SIBLING")], mtime=9000)
        # Reconnect re-baseline: must stay pinned to sidA, NOT jump to sidB.
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.session_id == "sidA"            # pin preserved by prefer_session_id
        assert mark.last_delivered_uuid == "a1"     # anchored at sidA's end, not sidB's

    async def test_reanchor_does_not_rewind_on_torn_read(self, tmp_path):
        """Prod 2026-07-18 (conv 019f6cf5): a reconnect re-baseline landed on a
        torn/partial copy-forward read of the SAME pinned file — one missing the
        tail already delivered past — and blindly took that read's last turn as
        the new anchor, rewinding it. The next drain then replayed every turn
        after the rewound anchor, INCLUDING three already-delivered ones, as a
        duplicate burst to the orchestrator. The re-anchor must detect the torn
        read (existing anchor absent from it) and leave the mark untouched."""
        base = tmp_path / "t"; state = tmp_path / "s"
        full = [
            _user("u1", "a"), _assistant("a1", "ONE"),
            _user("u2", "b"), _assistant("a2", "TWO"),
            _user("u3", "c"), _assistant("a3", "THREE"),
        ]
        _mk_transcript(base, "sess", "sid1", full)
        rec = Recorder()
        await _drain(base, state, rec)               # baseline past a3 (forward-only)
        assert rec.delivered == []
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.last_delivered_uuid == "a3"
        # Simulate the mirror caught mid-rewrite: the SAME session_id file now
        # reads back truncated, ending before a3 (and even before a1's line).
        _mk_transcript(base, "sess", "sid1", full[:1])  # only the leading user line
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        after_torn = ts.load_watermark(state, "sess", "conv")
        assert after_torn.last_delivered_uuid == "a3"   # NOT rewound to "" or a1/a2
        assert after_torn.session_id == "sid1"
        # The mirror finishes catching up: full file is back, plus genuinely new
        # turns. A real drain must deliver only what's after a3 — no replay of
        # a1/a2/a3, and no loss of the new turns either.
        _mk_transcript(base, "sess", "sid1", full + [
            _user("u4", "d"), _assistant("a4", "FOUR"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a4"]

    async def test_empty_turn_skipped_but_advances(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await _drain(base, state, rec)              # baseline past SEED
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", None),   # tool-only -> empty
            _user("u2", "b"), _assistant("a2", "REAL"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a2"]              # empty a1 not posted
        assert ts.load_watermark(state, "sess", "conv").last_delivered_uuid == "a2"

    async def test_blocked_ask_delivered_then_resumes(self, tmp_path):
        """The AskUserQuestion deadlock, end-to-end: a turn that stops on an
        interactive-input tool (stop_reason tool_use, no user line after) must be
        delivered — not left waiting for a tool_result that only a human produces.
        Then it must dedup, and delivery must resume past it once answered.

        NOTE: the answer here (tool_result + continuation) models a HUMAN answering
        the widget at the keyboard. In the orchestrated (no-human) setup this
        watcher fix is a VISIBILITY safety net only — it surfaces the blocked
        question; it does not make the widget answerable over paste+Enter. The
        primary fix is preventing the widget entirely (aidc-claude --disallowedTools
        AskUserQuestion ExitPlanMode), after which the agent asks in plain text."""
        base = tmp_path / "t"; state = tmp_path / "s"
        seed = [_user("u0", "seed"), _assistant("a0", "SEED")]
        _mk_transcript(base, "sess", "sid1", seed)
        rec = Recorder()
        await _drain(base, state, rec)                       # baseline past SEED
        assert rec.delivered == []
        # faidh blocks on a question — the transcript simply ends on the ask line.
        blocked = seed + [_user("u1", "go"), _ask_line("ask1")]
        _mk_transcript(base, "sess", "sid1", blocked)
        await _drain(base, state, rec)
        assert rec.delivered == ["ask1"]                     # <-- was silently dropped before
        await _drain(base, state, rec)
        assert rec.delivered == ["ask1"]                     # dedup, no re-deliver
        # The answer arrives (tool_result) and faidh continues to a normal turn.
        answered = blocked + [
            {"type": "user", "uuid": "tr1", "message": {"role": "user",
             "content": [{"type": "tool_result", "content": "A"}]}},
            _assistant("cont1", "applied A"),
        ]
        _mk_transcript(base, "sess", "sid1", answered)
        await _drain(base, state, rec)
        assert rec.delivered == ["ask1", "cont1"]            # resumes cleanly

    async def test_failed_delivery_dead_lettered_and_not_head_of_line(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        await _drain(base, state, Recorder())       # baseline
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "WILLFAIL"),
        ])

        class AlwaysFail:
            async def __call__(self, turn, attempt):
                return False

        await _drain(base, state, AlwaysFail())
        dl = list((state / "dead-letter").glob("*.json"))
        assert len(dl) == 1
        assert json.loads(dl[0].read_text())["turn_uuid"] == "a1"
        assert ts.load_watermark(state, "sess", "conv").last_delivered_uuid == "a1"
        # A later turn still delivers (a1 didn't block the line).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "WILLFAIL"),
            _user("u2", "b"), _assistant("a2", "OK"),
        ])
        rec = Recorder()
        await _drain(base, state, rec)
        assert rec.delivered == ["a2"]

    async def test_newer_sibling_file_does_not_divert_while_pinned(self, tmp_path):
        """The incident: the copy-forward mirror bumps an OTHER file's mtime newer
        than the active one. We must stay pinned to the session we're tracking and
        NOT rotate to (and replay) the sibling — that flap is what hammered the
        webhook. Rotation only happens when our own file is gone (next test)."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [
            _user("u1", "a"), _assistant("a1", "REAL-1"),
            _user("u2", "b"), _assistant("a2", "REAL-2"),
        ], mtime=1000)
        rec = Recorder()
        await _drain(base, state, rec)              # baseline on sid1 (past a1,a2)
        # A different transcript file gets a NEWER mtime (mirror re-touch).
        _mk_transcript(base, "sess", "sidOLD", [
            _user("z1", "x"), _assistant("z1a", "STALE"),
        ], mtime=9999)
        await _drain(base, state, rec)
        assert rec.delivered == []                  # <-- no flap, no replay
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.session_id == "sid1"            # still pinned
        assert mark.last_delivered_uuid == "a2"

    async def test_rotation_forward_baselines_when_pinned_file_gone(self, tmp_path):
        """Genuine rotation = our tracked file is gone. We adopt the new active file
        FORWARD (anchor at its end, deliver nothing from its history), then deliver
        only turns that complete afterward — never replay the new file wholesale."""
        base = tmp_path / "t"; state = tmp_path / "s"
        p1 = _mk_transcript(base, "sess", "sid1", [_user("u1", "a"), _assistant("a1", "OLD")], mtime=1000)
        rec = Recorder()
        await _drain(base, state, rec)              # baseline on sid1
        assert rec.delivered == []
        # sid1 removed; a fresh session file sid2 already has history.
        p1.unlink()
        _mk_transcript(base, "sess", "sid2", [_user("u9", "x"), _assistant("b1", "PRE")], mtime=2000)
        await _drain(base, state, rec)              # forward-baseline onto sid2
        assert rec.delivered == []                  # <-- sid2 history NOT replayed
        assert ts.load_watermark(state, "sess", "conv").session_id == "sid2"
        # A turn that completes after the rotation is delivered.
        _mk_transcript(base, "sess", "sid2", [
            _user("u9", "x"), _assistant("b1", "PRE"),
            _user("u10", "y"), _assistant("b2", "POST"),
        ], mtime=3000)
        await _drain(base, state, rec)
        assert rec.delivered == ["b2"]

    async def test_no_transcript_dir_is_noop(self, tmp_path):
        rec = Recorder()
        await _drain(tmp_path / "missing", tmp_path / "s", rec)
        assert rec.delivered == []

    async def test_torn_read_does_not_replay(self, tmp_path):
        """A half-written copy-forward can momentarily drop the last-delivered uuid
        from the file. That must NOT be read as new content and replay history."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await _drain(base, state, rec)              # baseline past a0
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "NEW"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]
        # Torn mirror write: a1 (already delivered) momentarily missing from file.
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]              # <-- a0 NOT replayed
        assert ts.load_watermark(state, "sess", "conv").last_delivered_uuid == "a1"

    async def test_stale_pin_recovers_to_newer_session(self, tmp_path):
        """A watcher pinned to a DEAD session — its transcript lingers on disk but
        the resume anchor is gone for good (torn final line / compaction) — must
        NOT torn_read_skip forever when a NEWER session transcript exists. After
        _TORN_READ_RECOVER_POLLS consecutive misses it rotates: forward-baselines
        onto the newest session and resumes delivery there.

        Regression for prod 019f1fde: the faidh watcher was welded to the runaway
        session's 34MB transcript (killed mid-write → torn final line → anchor
        unparseable) and stuck in torn_read_skip for 40+ min while the live session
        (a fresh transcript after the container rebuild) went undelivered."""
        base = tmp_path / "t"; state = tmp_path / "s"
        # Session A: baseline, then deliver one turn so the watermark pins to A@a1.
        _mk_transcript(base, "sess", "A",
                       [_user("u0", "seed"), _assistant("a0", "SEED")], mtime=1000)
        rec = Recorder()
        await _drain(base, state, rec)              # baseline on A
        _mk_transcript(base, "sess", "A", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "q"), _assistant("a1", "R"),
        ], mtime=1100)
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]
        assert ts.load_watermark(state, "sess", "conv").session_id == "A"
        # A dies: its file lingers but the anchor a1 is gone (torn/compacted); a
        # strictly-NEWER session B appears with its own history.
        _mk_transcript(base, "sess", "A",
                       [_user("u0", "seed"), _assistant("a0", "SEED")], mtime=1100)
        _mk_transcript(base, "sess", "B",
                       [_user("v0", "seed"), _assistant("b0", "SEED")], mtime=2000)
        # Below the threshold: keep skipping, stay pinned to A (no premature rotate,
        # so a transient torn read next to an mtime-flapped sibling can't divert us).
        for _ in range(_TORN_READ_RECOVER_POLLS - 1):
            await _drain(base, state, rec)
        assert ts.load_watermark(state, "sess", "conv").session_id == "A"
        assert rec.delivered == ["a1"]
        # The threshold poll: rotate onto B (forward-baseline, no replay of B).
        await _drain(base, state, rec)
        assert ts.load_watermark(state, "sess", "conv").session_id == "B"
        assert rec.delivered == ["a1"]
        # A turn completed on B afterward is delivered — the watcher is live again.
        _mk_transcript(base, "sess", "B", [
            _user("v0", "seed"), _assistant("b0", "SEED"),
            _user("v1", "q"), _assistant("b1", "R2"),
        ], mtime=2100)
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "b1"]

    async def test_absorbed_terminal_recovers_no_wedge_no_replay(self, tmp_path):
        """If settle fires early and we deliver a partial group, a later append
        absorbs that end_turn into a bigger coalesced group. Line-anchored resume
        must still progress: deliver the continuation, never wedge, never replay."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        rec = Recorder()
        # Premature: only the first segment exists when we deliver (settle off).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "go"), _assistant("a1", "FIRST"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]
        # Claude continues the SAME prompt -> a1 absorbed into a1+a2 group (terminal a2).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "go"), _assistant("a1", "FIRST"), _assistant("a2", "SECOND"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "a2"]        # continuation delivered, no replay
        # A brand-new prompt later still flows (not wedged on the vanished terminal).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "go"), _assistant("a1", "FIRST"), _assistant("a2", "SECOND"),
            _user("u2", "again"), _assistant("a3", "THIRD"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "a2", "a3"]

    async def test_settle_defers_delivery_until_transcript_quiet(self, tmp_path):
        """With a settle window, a turn is delivered only after the transcript has
        stopped growing for settle_seconds — so a still-streaming burst coalesces."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        await _baseline_watermark("sess", "conv", transcripts_base=base, state_dir=state)
        clock = [100.0]
        rec = Recorder()

        async def drain():
            await _drain_transcript_once("sess", "conv", "http://cb", transcripts_base=base,
                                         state_dir=state, post_fn=rec, sleep_fn=_nosleep,
                                         settle_seconds=4.0, now_fn=lambda: clock[0])

        # First the empty end_turn lands...
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("empty", None),
        ])
        await drain()                               # grew -> records size, waits
        assert rec.delivered == []
        clock[0] = 103.0                            # 3s later, still <4s
        await drain()
        assert rec.delivered == []
        # ...then Claude continues with the real answer (file grows again -> resets).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("empty", None), _assistant("real", "ANSWER"),
        ])
        clock[0] = 104.0
        await drain()                               # grew again -> reset settle, wait
        assert rec.delivered == []
        clock[0] = 109.0                            # now quiet for 5s >= 4s
        await drain()
        # One coalesced delivery for the whole exchange (terminal uuid = the real one).
        assert rec.delivered == ["real"]


# --- _post_turn instrumentation (MCP-19; the original "logs why" contract) ----

class TestPostTurnInstrumentation:
    async def _events_for(self, post_side_effect):
        logged = []
        with (
            patch("aidc_mcp.tools.httpx.AsyncClient", return_value=_http_client(post_side_effect)),
            patch("aidc_mcp.tools._load_token", return_value="tok"),
            patch("aidc_mcp.tools.log_event", side_effect=lambda k, **f: logged.append((k, f))),
        ):
            ok = await _post_turn("http://cb", "conv", ts.Turn("a1", "hi"), attempt=0, session="faidh")
        return ok, logged

    async def test_payload_carries_session_name(self):
        """The callback body must name WHICH session finished the turn.

        The orchestrator gates session_send on a per-session BUSY marker (set when
        its own send is accepted) and clears it on this callback — without the
        session name a multi-session conversation cannot tell whose reply arrived,
        and the wrong session would be released.
        """
        captured = {}

        async def ok_post(url, **kw):
            captured.update(kw.get("json") or {})
            return MagicMock(is_success=True, status_code=202, text="")

        with (
            patch("aidc_mcp.tools.httpx.AsyncClient", return_value=_http_client(ok_post)),
            patch("aidc_mcp.tools._load_token", return_value="tok"),
            patch("aidc_mcp.tools.log_event"),
        ):
            ok = await _post_turn("http://cb", "conv", ts.Turn("a1", "hi"),
                                  attempt=0, session="faidh")

        assert ok is True
        assert captured["session"] == "faidh"
        # the existing contract fields are unchanged
        assert captured["content"] == "hi"
        assert captured["source"] == "agent_watch"

    async def test_payload_carries_prompt_origin(self):
        """Whose prompt the turn answers travels as its own field, so the
        orchestrator can render a terminal-typed exchange differently later
        without parsing the content framing."""
        captured = {}

        async def ok_post(url, **kw):
            captured.update(kw.get("json") or {})
            return MagicMock(is_success=True, status_code=202, text="")

        with (
            patch("aidc_mcp.tools.httpx.AsyncClient", return_value=_http_client(ok_post)),
            patch("aidc_mcp.tools._load_token", return_value="tok"),
            patch("aidc_mcp.tools.log_event"),
        ):
            await _post_turn("http://cb", "conv",
                             ts.Turn("a1", "hi", prompt_origin="terminal"),
                             attempt=0, session="faidh")
        assert captured["prompt_origin"] == "terminal"

    async def test_failed_post_logs_type_and_nonempty_repr(self):
        async def boom(*a, **kw):
            raise _EmptyStrError()

        ok, logged = await self._events_for(boom)
        assert ok is False
        f = next(fields for k, fields in logged if k == "transcript_callback_failed")
        assert f["error_type"] == "_EmptyStrError"
        assert f["error"]  # repr is non-empty even though str(exc) == ""

    async def test_non_2xx_logs_http_error(self):
        async def bad(*a, **kw):
            return MagicMock(is_success=False, status_code=502, text="upstream down")

        ok, logged = await self._events_for(bad)
        assert ok is False           # 5xx is transient -> retryable, returns False
        f = next(fields for k, fields in logged if k == "transcript_callback_http_error")
        assert f["status"] == 502 and "upstream down" in f["body"]
        assert f["retryable"] is True

    async def test_404_raises_permanent_and_is_marked_non_retryable(self):
        """404 conversation-gone is permanent: _post_turn raises rather than
        returning False, so the retry loop stops instead of hammering."""
        async def gone(*a, **kw):
            return MagicMock(is_success=False, status_code=404,
                             text='{"detail":"conversation not found"}')

        logged = []
        with (
            patch("aidc_mcp.tools.httpx.AsyncClient", return_value=_http_client(gone)),
            patch("aidc_mcp.tools._load_token", return_value="tok"),
            patch("aidc_mcp.tools.log_event", side_effect=lambda k, **f: logged.append((k, f))),
        ):
            try:
                await _post_turn("http://cb", "conv", ts.Turn("a1", "hi"), attempt=0, session="faidh")
                raised = False
            except _PermanentDeliveryError as exc:
                raised = True
                assert exc.status == 404
        assert raised
        f = next(fields for k, fields in logged if k == "transcript_callback_http_error")
        assert f["status"] == 404 and f["retryable"] is False

    async def test_429_is_retryable(self):
        """Rate-limit (429) is transient — returns False (retry), does not raise."""
        async def throttled(*a, **kw):
            return MagicMock(is_success=False, status_code=429, text="slow down")

        ok, logged = await self._events_for(throttled)
        assert ok is False
        f = next(fields for k, fields in logged if k == "transcript_callback_http_error")
        assert f["retryable"] is True

    async def test_success_logs_ok(self):
        async def good(*a, **kw):
            return MagicMock(is_success=True, status_code=200, text="")

        ok, logged = await self._events_for(good)
        assert ok is True
        kinds = [k for k, _ in logged]
        assert "transcript_callback_attempt" in kinds and "transcript_callback_ok" in kinds


# --- loop guard (prod incident 2026-07-03: orchestrator<->session runaway) ----
# An aidc session has no human at the pane, so a runaway where the orchestrator
# (MetaLLM) and this session answer each other forever has no natural end. The
# guard is RATE-based: it caps consecutive RAPID deliveries (each within the fast
# gap of the prior); a slower gap (real work) resets the run, so a legitimate long
# task never trips. The run is durable so a short MCP restart stays latched.

class TestLoopGuard:
    async def _drain_at(self, base, state, rec, wall):
        await _drain_transcript_once(
            "sess", "conv", "http://cb", transcripts_base=base, state_dir=state,
            post_fn=rec, sleep_fn=_nosleep, wall_now_fn=lambda: wall,
        )

    def _turns(self, n):
        """seed + n completed user->assistant turns (terminal uuids a1..aN)."""
        objs = [_user("u0", "seed"), _assistant("a0", "SEED")]
        for i in range(1, n + 1):
            objs += [_user(f"u{i}", f"q{i}"), _assistant(f"a{i}", f"r{i}")]
        return objs

    async def test_rapid_burst_trips(self, tmp_path):
        """Rapid-fire deliveries (constant clock, no idle gap) stop at the cap; the
        overflow is dead-lettered, not POSTed, watermark advances."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await self._drain_at(base, state, rec, wall=1000.0)          # baseline
        overflow = 5
        _mk_transcript(base, "sess", "sid1", self._turns(_LOOP_GUARD_MAX_CONSECUTIVE + overflow))
        await self._drain_at(base, state, rec, wall=1000.0)          # constant clock -> one run
        assert rec.delivered == [f"a{i}" for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + 1)]
        assert len(list((state / "dead-letter").glob("*.json"))) == overflow
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.last_delivered_uuid == f"a{_LOOP_GUARD_MAX_CONSECUTIVE + overflow}"
        assert mark.consecutive_deliveries == _LOOP_GUARD_MAX_CONSECUTIVE + overflow

    async def test_slow_deliveries_still_trip(self, tmp_path):
        """Regression for the 019f1fde dodge: deliveries spaced far beyond the old
        45s rate threshold (context-bloated turns) but within the idle reset STILL
        trip. Timing is not the signal — an unbroken run of deliveries is. The old
        rate-based guard reset on each of these gaps and never fired."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await self._drain_at(base, state, rec, wall=1000.0)          # baseline
        wall = 1000.0
        overflow = 3
        # One new turn per pass, each spaced a quarter of the idle reset apart:
        # far slower than the old fast gap (would have reset every time), but not
        # idle, so the run accumulates and trips.
        slow_gap = _LOOP_GUARD_IDLE_RESET_S / 4
        for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + overflow + 1):
            _mk_transcript(base, "sess", "sid1", self._turns(i))     # one new turn per pass
            wall += slow_gap
            await self._drain_at(base, state, rec, wall=wall)
        assert rec.delivered == [f"a{i}" for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + 1)]
        assert len(list((state / "dead-letter").glob("*.json"))) == overflow

    async def test_long_idle_resets_the_run(self, tmp_path):
        """A genuinely idle gap (orchestrator stopped driving, longer than any
        single turn) resets the run, so a session that goes quiet and later resumes
        is not latched and keeps delivering — the reset a slow runaway can't reach
        because its turns, though slow, never idle that long."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await self._drain_at(base, state, rec, wall=1000.0)          # baseline
        wall = 1000.0
        # Deliver right up to the cap (not over), rapid.
        for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + 1):
            _mk_transcript(base, "sess", "sid1", self._turns(i))
            wall += 1.0
            await self._drain_at(base, state, rec, wall=wall)
        assert len(rec.delivered) == _LOOP_GUARD_MAX_CONSECUTIVE
        assert not (state / "dead-letter").exists()                  # at cap, not over
        # A long idle, then one more turn: the idle resets the run, so the turn
        # delivers instead of tripping (it would trip without the reset).
        _mk_transcript(base, "sess", "sid1", self._turns(_LOOP_GUARD_MAX_CONSECUTIVE + 1))
        wall += _LOOP_GUARD_IDLE_RESET_S + 1
        await self._drain_at(base, state, rec, wall=wall)
        assert rec.delivered[-1] == f"a{_LOOP_GUARD_MAX_CONSECUTIVE + 1}"
        assert not (state / "dead-letter").exists()

    async def test_empty_turns_do_not_count(self, tmp_path):
        """Empty (tool-only) turns are not deliveries and must not advance the
        run — otherwise a normal empty-then-real burst would false-trip."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await self._drain_at(base, state, rec, wall=1000.0)          # baseline
        # MAX real turns, each PRECEDED by an empty tool-only turn, all rapid-fire.
        # If empties counted, 2*MAX would trip mid-way; they don't, so all MAX
        # reals deliver.
        objs = [_user("u0", "seed"), _assistant("a0", "SEED")]
        for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + 1):
            objs += [_user(f"ue{i}", "x"), _assistant(f"e{i}", None)]   # empty
            objs += [_user(f"ur{i}", "y"), _assistant(f"a{i}", f"r{i}")]  # real
        _mk_transcript(base, "sess", "sid1", objs)
        await self._drain_at(base, state, rec, wall=1000.0)
        assert rec.delivered == [f"a{i}" for i in range(1, _LOOP_GUARD_MAX_CONSECUTIVE + 1)]
        assert not (state / "dead-letter").exists()

    async def test_short_restart_stays_latched(self, tmp_path):
        """The run is durable, so an MCP restart shorter than the idle reset (mark
        reloaded from disk) keeps the guard latched — no silent resume."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await self._drain_at(base, state, rec, wall=1000.0)          # baseline
        _mk_transcript(base, "sess", "sid1", self._turns(_LOOP_GUARD_MAX_CONSECUTIVE + 1))
        await self._drain_at(base, state, rec, wall=1000.0)          # trips on the overflow
        assert len(rec.delivered) == _LOOP_GUARD_MAX_CONSECUTIVE
        # "Restart": fresh Recorder + one more turn, gap < idle reset. The persisted
        # run is already past the cap, so the new turn is dropped — no resume.
        rec2 = Recorder()
        _mk_transcript(base, "sess", "sid1", self._turns(_LOOP_GUARD_MAX_CONSECUTIVE + 2))
        await self._drain_at(base, state, rec2, wall=1001.0)         # 1s later, < idle reset
        assert rec2.delivered == []

    async def test_old_watermark_without_new_fields_loads(self, tmp_path):
        """A watermark written before the loop-guard fields existed (missing
        consecutive_deliveries / last_delivery_at) loads with zero defaults, no
        crash — existing prod watermark files must not KeyError after deploy."""
        state = tmp_path / "s"; state.mkdir()
        p = ts.watermark_path(state, "sess", "conv")
        p.write_text(json.dumps({
            "session": "sess", "conversation_id": "conv", "session_id": "sid1",
            "byte_offset": 100, "last_delivered_uuid": "a1", "updated_at": "x",
        }), encoding="utf-8")
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.consecutive_deliveries == 0
        assert mark.last_delivery_at == 0.0
        assert mark.last_delivered_uuid == "a1"     # existing fields still load

    async def test_pre_rename_watermark_maps_fast_consecutive(self, tmp_path):
        """Back-compat: a watermark written by the previous (rate-based) build
        stored the run as ``fast_consecutive``. It must map onto the renamed
        ``consecutive_deliveries`` so a deploy mid-incident doesn't silently reset
        a latched run and let another cap's worth of echoes through."""
        state = tmp_path / "s"; state.mkdir()
        p = ts.watermark_path(state, "sess", "conv")
        p.write_text(json.dumps({
            "session": "sess", "conversation_id": "conv", "session_id": "sid1",
            "byte_offset": 100, "last_delivered_uuid": "a1",
            "fast_consecutive": 17, "last_delivery_at": 1234.5, "updated_at": "x",
        }), encoding="utf-8")
        mark = ts.load_watermark(state, "sess", "conv")
        assert mark.consecutive_deliveries == 17
        assert mark.last_delivery_at == 1234.5


# --- stale-pin rotation follow (prod 019f1fde: pin welded to a dead session) ---

def _ts(o, timestamp):
    o["timestamp"] = timestamp
    return o


class TestStalePinRotation:
    """The pin selects the pinned transcript while it EXISTS, and Claude never
    deletes a rotated-away transcript — so a watcher can weld itself to a fully
    consumed, frozen session and deliver nothing forever. The watcher must follow
    a genuine rotation forward, WITHOUT false-firing on the copy-forward mirror's
    mtime churn."""

    async def _drain_rot(self, base, state, rec, sess, conv):
        await _drain_transcript_once(sess, conv, "http://cb", transcripts_base=base,
                                     state_dir=state, post_fn=rec, sleep_fn=_nosleep)

    async def test_follows_rotation_when_pinned_fully_consumed(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "rot", "c"
        _consumed_idle_counts.pop((sess, conv), None)
        # OLD session, fully consumed. First watch baselines onto it (only file).
        _mk_transcript(base, sess, "old", [
            _ts(_user("u1", "hi"), "2026-07-04T04:00:00.000Z"),
            _ts(_assistant("a1", "OLD"), "2026-07-04T04:00:01.000Z"),
        ])
        rec = Recorder()
        await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "old"
        assert rec.delivered == []                    # forward-only baseline, no replay

        # Claude rotates: a NEW session file appears with strictly-newer content.
        _mk_transcript(base, sess, "new", [
            _ts(_user("u2", "go"), "2026-07-04T18:00:00.000Z"),
            _ts(_assistant("a2", "NEW"), "2026-07-04T18:00:01.000Z"),
        ])
        # Gated: no rotation before the sustained-poll threshold.
        for _ in range(_STALE_PIN_RECOVER_POLLS - 1):
            await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "old"
        # One more poll trips it — rotate forward onto "new".
        await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "new"

        # Rotation forward-baselines (no replay of "new"'s history); a turn AFTER delivers.
        _mk_transcript(base, sess, "new", [
            _ts(_user("u2", "go"), "2026-07-04T18:00:00.000Z"),
            _ts(_assistant("a2", "NEW"), "2026-07-04T18:00:01.000Z"),
            _ts(_user("u3", "more"), "2026-07-04T18:05:00.000Z"),
            _ts(_assistant("a3", "FRESH"), "2026-07-04T18:05:01.000Z"),
        ])
        await self._drain_rot(base, state, rec, sess, conv)
        assert "a3" in rec.delivered

    async def test_follows_rotation_with_trailing_non_turn_tail(self, tmp_path):
        """Real prod shape (faidh 1b968f61): the pinned session's tail holds a bare
        user line AFTER the last delivered turn — so `suffix` is non-empty yet there
        are NO deliverable turns. Rotation must still follow (gate is 'no new turns',
        not 'empty suffix' — the bug the first fix shipped with)."""
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "tail", "c"
        _consumed_idle_counts.pop((sess, conv), None)
        _mk_transcript(base, sess, "old", [
            _ts(_user("u1", "hi"), "2026-07-04T04:00:00.000Z"),
            _ts(_assistant("a1", "OLD"), "2026-07-04T04:00:01.000Z"),
            _ts(_user("u2", "leftover prompt, never answered"), "2026-07-04T04:00:02.000Z"),
        ])
        rec = Recorder()
        await self._drain_rot(base, state, rec, sess, conv)   # baseline anchors on a1
        mark = ts.load_watermark(state, sess, conv)
        assert mark.session_id == "old" and mark.last_delivered_uuid == "a1"
        # A strictly-newer session appears (the real rotation).
        _mk_transcript(base, sess, "new", [
            _ts(_user("u3", "go"), "2026-07-04T18:00:00.000Z"),
            _ts(_assistant("a2", "NEW"), "2026-07-04T18:00:01.000Z"),
        ])
        for _ in range(_STALE_PIN_RECOVER_POLLS):
            await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "new"

    async def test_does_not_rotate_on_mtime_flap(self, tmp_path):
        """A frozen sibling re-touched to a NEWER mtime (the mirror flap the pin was
        added to survive) must NOT trigger rotation — content timestamps decide."""
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "flap", "c"
        _consumed_idle_counts.pop((sess, conv), None)
        # Active (pinned) session has the NEWEST content, older mtime.
        _mk_transcript(base, sess, "active", [
            _ts(_user("u1", "hi"), "2026-07-04T18:00:00.000Z"),
            _ts(_assistant("a1", "ACTIVE"), "2026-07-04T18:00:01.000Z"),
        ], mtime=1000)
        rec = Recorder()
        await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "active"
        # A frozen OLD sibling, re-touched to a much NEWER mtime but OLDER content.
        _mk_transcript(base, sess, "old", [
            _ts(_user("u0", "old"), "2026-07-04T04:00:00.000Z"),
            _ts(_assistant("a0", "OLD"), "2026-07-04T04:00:01.000Z"),
        ], mtime=99999)
        for _ in range(_STALE_PIN_RECOVER_POLLS + 2):
            await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "active"  # no flap rotation

    async def test_rotation_delivers_each_turn_exactly_once(self, tmp_path):
        """Rotation forward-baselines (anchor at the new session's end), so it must
        NEVER re-deliver a turn that existed at rotation time — and the turns after
        rotation must each be delivered exactly once (guard the count, not just
        membership: a re-delivery would still satisfy `x in delivered`)."""
        from collections import Counter
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "rot1", "c"
        _consumed_idle_counts.pop((sess, conv), None)
        _mk_transcript(base, sess, "old", [
            _ts(_user("u1", "hi"), "2026-07-04T04:00:00.000Z"),
            _ts(_assistant("a1", "OLD"), "2026-07-04T04:00:01.000Z"),
        ])
        rec = Recorder()
        await self._drain_rot(base, state, rec, sess, conv)          # baseline onto "old"
        # Claude rotates to a NEW session that already has one completed turn.
        new_objs = [_ts(_user("u2", "go"), "2026-07-04T18:00:00.000Z"),
                    _ts(_assistant("b1", "AT-ROTATION"), "2026-07-04T18:00:01.000Z")]
        _mk_transcript(base, sess, "new", new_objs)
        for _ in range(_STALE_PIN_RECOVER_POLLS + 1):
            await self._drain_rot(base, state, rec, sess, conv)
        assert ts.load_watermark(state, sess, conv).session_id == "new"
        # Then three fresh turns arrive on "new".
        for i in range(2, 5):
            new_objs += [_ts(_user(f"u{i}", "more"), f"2026-07-04T18:0{i}:00.000Z"),
                         _ts(_assistant(f"b{i}", f"FRESH{i}"), f"2026-07-04T18:0{i}:01.000Z")]
            _mk_transcript(base, sess, "new", new_objs)
            for _ in range(2):
                await self._drain_rot(base, state, rec, sess, conv)
        counts = Counter(rec.delivered)
        assert "b1" not in counts                       # forward-only: never replayed
        assert counts == Counter(["b2", "b3", "b4"])    # each exactly once, no dupes


class TestDeliveryLedgerNeverReplays:
    """The structural guarantee: the same message CONTENT is delivered to a
    conversation at most once, EVER — independent of the watermark.

    Every prior replay incident (mtime-flap rotation, torn-read rewind, reconnect
    catch-up, retry storm) was a different watermark bug that re-surfaced an
    already-delivered turn. Rather than keep fixing causes one at a time, the
    durable delivery ledger backstops all of them at the POST boundary: a turn
    whose fingerprint is already recorded is never sent again, no matter how the
    watermark was corrupted. These tests corrupt the watermark on purpose."""

    async def test_rewind_into_delivered_region_cannot_replay(self, tmp_path):
        """The re-delivery incidents (torn-read rewind, rotation replay): a
        watermark bug rewinds the resume anchor back INTO the already-delivered
        region, so the next drain re-reads and re-extracts turns that were already
        sent. Every one of them must be suppressed by the ledger; only
        genuinely-new content flows."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await _drain(base, state, rec)                       # baseline past SEED (anchor a0)
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "REPLY-ONE"),
            _user("u2", "b"), _assistant("a2", "REPLY-TWO"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "a2"]
        # Corrupt the watermark: rewind the resume anchor back to the baseline
        # point, so a1 and a2 (both already delivered) are re-read and re-extracted.
        # This is exactly the shape of the torn-read / rotation replay bugs.
        mark = ts.load_watermark(state, "sess", "conv")
        mark.last_delivered_uuid = "a0"
        ts.save_watermark(state, mark)
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "a2"]                 # <-- ledger blocked the replay
        # A brand-new turn still gets through (the ledger only blocks re-sends).
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "REPLY-ONE"),
            _user("u2", "b"), _assistant("a2", "REPLY-TWO"),
            _user("u3", "c"), _assistant("a3", "REPLY-THREE"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1", "a2", "a3"]

    async def test_ledger_is_durable_across_reload(self, tmp_path):
        """The ledger lives on disk, so it survives an MCP restart: a fresh process
        that reloads it (and even resets the watermark) still cannot replay."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await _drain(base, state, rec)                       # baseline
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "ONLY-ONCE"),
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]
        # The ledger file exists and holds exactly the delivered fingerprint.
        assert ts.load_delivered(state, "sess", "conv") == {ts.content_fingerprint("ONLY-ONCE")}
        # Simulate a restart: drop the watermark, re-baseline (as a reconnect
        # does), then rewind its anchor back into the delivered region so a1 is
        # re-read. Without the durable ledger this replays a1; with it, the
        # on-disk fingerprint held across the reload suppresses it.
        ts.watermark_path(state, "sess", "conv").unlink()
        rec2 = Recorder()
        await _drain(base, state, rec2)                      # first pass = baseline again (anchor a1)
        mark = ts.load_watermark(state, "sess", "conv")
        mark.last_delivered_uuid = "a0"                      # rewind behind a1
        ts.save_watermark(state, mark)
        await _drain(base, state, rec2)
        assert rec2.delivered == []                          # <-- durable ledger held

    async def test_failed_delivery_not_recorded_so_can_still_deliver(self, tmp_path):
        """Only a CONFIRMED delivery is recorded — a dead-lettered turn stays
        eligible, so a genuine delivery failure does not permanently swallow it."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        await _drain(base, state, Recorder())                # baseline
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "IMPORTANT"),
        ])

        class AlwaysFail:
            async def __call__(self, turn, attempt):
                return False

        await _drain(base, state, AlwaysFail())              # fails -> dead-letter, NOT recorded
        assert ts.load_delivered(state, "sess", "conv") == set()
        # The watermark advanced past a1 (dead-lettered), so a re-read won't retry
        # it — but the ledger did NOT record it, so it was never marked delivered.
        # Prove the ledger's contract directly: the same content, seen fresh in a
        # NEW conversation, still delivers (it was never confirmed anywhere).
        rec = Recorder()
        await _drain(base, state, rec, conv="conv2")         # baseline for conv2
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "IMPORTANT"),
            _user("u2", "b"), _assistant("a2", "MORE"),
        ])
        await _drain(base, state, rec, conv="conv2")
        assert rec.delivered == ["a2"]

    async def test_identical_content_in_distinct_turns_is_deduped(self, tmp_path):
        """The literal 'never the same message again' semantic: two DISTINCT turns
        (different uuids) carrying byte-identical text — the second is suppressed.
        In an unattended loop, an identical repeated message IS the pathology."""
        base = tmp_path / "t"; state = tmp_path / "s"
        _mk_transcript(base, "sess", "sid1", [_user("u0", "seed"), _assistant("a0", "SEED")])
        rec = Recorder()
        await _drain(base, state, rec)                       # baseline
        _mk_transcript(base, "sess", "sid1", [
            _user("u0", "seed"), _assistant("a0", "SEED"),
            _user("u1", "a"), _assistant("a1", "on it"),
            _user("u2", "b"), _assistant("a2", "on it"),     # same text, new uuid
        ])
        await _drain(base, state, rec)
        assert rec.delivered == ["a1"]                       # a2 (identical) suppressed


class TestExactlyOnceUnderConcurrentPasses:
    """Regression: every reply delivered TWICE. The durable watermark makes
    delivery exactly-once, but advancing it is a read-modify-write across the
    await-heavy POST. When two delivery passes for the same (session,
    conversation) overlap — a session_watch replacement handing off to a fresh
    watcher, or any duplicate watcher — both load the pre-delivery mark and both
    POST the same turn. The per-key drain lock must serialize them so the second
    pass sees the advanced mark and dedups."""

    async def test_two_overlapping_passes_deliver_turn_once(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "dup", "c"
        _drain_locks.pop((sess, conv), None)
        hist = [_user("u1", "a"), _assistant("a1", "OLD")]
        _mk_transcript(base, sess, "sid1", hist)

        delivered: list[str] = []
        started = asyncio.Event()

        async def slow_post(turn, attempt):
            # Yield control WHILE "posting" so a second pass can interleave — the
            # exact window the old code delivered twice in (mark not yet advanced).
            started.set()
            await asyncio.sleep(0)
            delivered.append(turn.terminal_uuid)
            return True

        async def drain():
            await _drain_transcript_once(sess, conv, "http://cb", transcripts_base=base,
                                         state_dir=state, post_fn=slow_post, sleep_fn=_nosleep)

        await drain()                                   # baseline past OLD
        assert delivered == []
        _mk_transcript(base, sess, "sid1", hist + [_user("u2", "b"), _assistant("a2", "NEW")])
        # Two delivery passes racing on the same key (the overlap the fix guards).
        await asyncio.gather(drain(), drain())
        assert delivered == ["a2"]                      # exactly once, not twice

    async def test_lock_serializes_does_not_drop(self, tmp_path):
        """The lock must not swallow a turn: after two racing passes the mark is
        advanced and a later turn still delivers (exactly-once, no drop)."""
        base = tmp_path / "t"; state = tmp_path / "s"
        sess, conv = "dup2", "c"
        _drain_locks.pop((sess, conv), None)
        _mk_transcript(base, sess, "sid1", [_user("u1", "a"), _assistant("a1", "OLD")])
        rec = Recorder()

        async def drain():
            await _drain_transcript_once(sess, conv, "http://cb", transcripts_base=base,
                                         state_dir=state, post_fn=rec, sleep_fn=_nosleep)

        await drain()
        _mk_transcript(base, sess, "sid1", [
            _user("u1", "a"), _assistant("a1", "OLD"),
            _user("u2", "b"), _assistant("a2", "NEW1"),
        ])
        await asyncio.gather(drain(), drain())
        assert rec.delivered == ["a2"]
        _mk_transcript(base, sess, "sid1", [
            _user("u1", "a"), _assistant("a1", "OLD"),
            _user("u2", "b"), _assistant("a2", "NEW1"),
            _user("u3", "c"), _assistant("a3", "NEW2"),
        ])
        await drain()
        assert rec.delivered == ["a2", "a3"]            # later turn still delivered once


# --- terminal-typed prompt attribution (the "where did that come from?" bug) ---
# A person attached to the session's tmux pane types straight into Claude; the
# reply comes over the same webhook, and the orchestrator — which never saw the
# prompt — read it as an answer to whatever IT last sent. The drain now prepends
# any prompt the MCP did not inject itself.

class ContentRecorder:
    """post_fn that keeps the whole delivered Turn, not just its uuid."""

    def __init__(self):
        self.turns = []

    async def __call__(self, turn, attempt):
        self.turns.append(turn)
        return True


def _typed(uuid, text):
    """A user line exactly as Claude Code writes a typed OR pasted prompt."""
    return {"type": "user", "uuid": uuid, "promptSource": "typed",
            "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}


class TestTerminalPromptAttribution:
    async def _seeded(self, tmp_path):
        base = tmp_path / "t"; state = tmp_path / "s"
        seed = [_user("u0", "seed"), _assistant("a0", "SEED")]
        _mk_transcript(base, "sess", "sid1", seed)
        rec = ContentRecorder()
        await _drain(base, state, rec)          # baseline past SEED
        return base, state, rec, seed

    async def test_typed_prompt_is_prepended_to_the_reply(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "what is the NATS rewrite?"), _assistant("a1", "It is X."),
        ])
        await _drain(base, state, rec)
        assert len(rec.turns) == 1
        out = rec.turns[0]
        assert out.text == ts.render_delivery("It is X.", ["what is the NATS rewrite?"])
        assert out.text.startswith(ts.TERMINAL_PROMPT_NOTE)
        assert out.prompt_origin == "terminal"

    async def test_orchestrator_prompt_is_delivered_bare(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "fix the failing test")   # what session_send did
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "fix the failing test"), _assistant("a1", "Fixed."),
        ])
        await _drain(base, state, rec)
        assert [t.text for t in rec.turns] == ["Fixed."]
        assert rec.turns[0].prompt_origin == "orchestrator"
        # The record entry was consumed by the match.
        assert ts.consume_sent_prompt(state, "sess", "fix the failing test") is False

    async def test_record_entry_is_consumed_once(self, tmp_path):
        """The orchestrator sends 'next' once; the person then types 'next' too.
        Only the first is the orchestrator's."""
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "next")
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "next"), _assistant("a1", "step 2"),
            _typed("u2", "next"), _assistant("a2", "step 3"),
        ])
        await _drain(base, state, rec)
        assert [t.prompt_origin for t in rec.turns] == ["orchestrator", "terminal"]
        assert rec.turns[0].text == "step 2"
        assert rec.turns[1].text == ts.render_delivery("step 3", ["next"])

    async def test_mixed_prompts_prepend_only_the_typed_ones(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "queued ask")
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "/login"), _typed("u2", "queued ask"),
            _assistant("a1", "done"),
        ])
        await _drain(base, state, rec)
        assert rec.turns[0].text == ts.render_delivery("done", ["/login"])
        assert rec.turns[0].prompt_origin == "terminal"

    async def test_system_sourced_turn_has_unknown_origin_and_no_note(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        note = {"type": "user", "uuid": "u1", "promptSource": "system",
                "origin": {"kind": "task-notification"},
                "message": {"role": "user", "content": "<task-notification>x</task-notification>"}}
        _mk_transcript(base, "sess", "sid1", seed + [note, _assistant("a1", "The task finished.")])
        await _drain(base, state, rec)
        assert rec.turns[0].text == "The task finished."
        assert rec.turns[0].prompt_origin == ""

    async def test_empty_turn_still_consumes_its_record_entry(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "just run it")
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "just run it"), _assistant("a1", None),   # tool-only, no text
        ])
        await _drain(base, state, rec)
        assert rec.turns == []
        assert ts.consume_sent_prompt(state, "sess", "just run it") is False

    async def test_ledger_dedups_on_the_bare_reply_after_a_rewind(self, tmp_path):
        """Exactly-once must survive attribution: a re-surfaced turn's record entry
        is gone by then (so its framing would differ), and the ledger must still
        recognise it. The fingerprint is therefore on the bare reply."""
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "q")
        _mk_transcript(base, "sess", "sid1", seed + [_typed("u1", "q"), _assistant("a1", "R")])
        await _drain(base, state, rec)
        assert [t.text for t in rec.turns] == ["R"]
        mark = ts.load_watermark(state, "sess", "conv")
        mark.last_delivered_uuid = "a0"                 # rewind into delivered region
        ts.save_watermark(state, mark)
        await _drain(base, state, rec)
        assert [t.text for t in rec.turns] == ["R"]     # not re-posted, framed or not

    async def test_resurfaced_turn_does_not_consume_a_fresh_record_entry(self, tmp_path):
        """After a watermark rewind the already-delivered turn is re-read. Its own
        record entry was consumed the first time; if attribution ran again it would
        eat the entry for the orchestrator's NEXT identical send, and that later
        reply would go out framed as the person's."""
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "continue")
        _mk_transcript(base, "sess", "sid1", seed + [_typed("u1", "continue"), _assistant("a1", "R1")])
        await _drain(base, state, rec)
        assert rec.turns[0].prompt_origin == "orchestrator"
        # The orchestrator sends "continue" again; then the watermark rewinds.
        ts.record_sent_prompt(state, "sess", "continue")
        mark = ts.load_watermark(state, "sess", "conv")
        mark.last_delivered_uuid = "a0"
        ts.save_watermark(state, mark)
        await _drain(base, state, rec)                       # deduped, no attribution
        assert len(rec.turns) == 1
        _mk_transcript(base, "sess", "sid1", seed + [
            _typed("u1", "continue"), _assistant("a1", "R1"),
            _typed("u2", "continue"), _assistant("a2", "R2"),
        ])
        await _drain(base, state, rec)
        assert rec.turns[1].text == "R2"                     # entry was still there
        assert rec.turns[1].prompt_origin == "orchestrator"

    async def test_terminal_prompt_event_reports_record_health(self, tmp_path):
        base, state, rec, seed = await self._seeded(tmp_path)
        ts.record_sent_prompt(state, "sess", "never matched")   # a stuck entry
        _mk_transcript(base, "sess", "sid1", seed + [_typed("u1", "typed"), _assistant("a1", "R")])
        events = []
        with patch("aidc_mcp.tools.log_event", side_effect=lambda k, **f: events.append((k, f))):
            await _drain(base, state, rec)
        ev = next(f for k, f in events if k == "transcript_terminal_prompt")
        assert ev["prompts"] == 1 and ev["record_remaining"] == 1

    async def test_dead_letter_carries_the_framed_content(self, tmp_path):
        base, state, _, seed = await self._seeded(tmp_path)
        _mk_transcript(base, "sess", "sid1", seed + [_typed("u1", "typed q"), _assistant("a1", "R")])
        rec = Recorder(always_fail=True)
        await _drain_transcript_once("sess", "conv", "http://cb", transcripts_base=base,
                                     state_dir=state, post_fn=rec, sleep_fn=_nosleep)
        dead = list((state / "dead-letter").glob("sess__conv__a1.json"))
        assert len(dead) == 1
        assert json.loads(dead[0].read_text())["content"] == ts.render_delivery("R", ["typed q"])

    async def test_unwritable_record_counts_prompt_as_the_orchestrators(self, tmp_path):
        """Never err toward 'the person said this': if the record cannot be
        updated the prompt is treated as the MCP's own (no note)."""
        base, state, rec, seed = await self._seeded(tmp_path)
        _mk_transcript(base, "sess", "sid1", seed + [_typed("u1", "q"), _assistant("a1", "R")])
        with patch("aidc_mcp.tools.ts.consume_sent_prompt", side_effect=OSError("ro")):
            await _drain(base, state, rec)
        assert rec.turns[0].text == "R"
        assert rec.turns[0].prompt_origin == "orchestrator"
