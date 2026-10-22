"""A transcript is parsed once, not on every poll.

The watcher polls every two seconds. Production (2026-10-12) held one watch on a
session with a 35 MB transcript and 633 MB of earlier ones beside it, and the
server sat at 85% of a core: each idle poll parsed every file again. These tests
hold the two halves of the fix: what is read is exactly what a plain read gives,
and a file that has not changed costs no parsing.
"""
import json
import os
import time

import pytest

from aidc_mcp import transcript as ts
from aidc_mcp.tools import _STALE_PIN_RECOVER_POLLS, _drain_transcript_once

OLD = time.time() - 3600  # long past the settle window: the stamp alone is believed


def _line(uuid, text="x", role="assistant", stamp="2026-10-12T00:00:00.000Z"):
    return {"type": role, "uuid": uuid, "timestamp": stamp,
            "message": {"role": role, "stop_reason": "end_turn",
                        "content": [{"type": "text", "text": text}]}}


def _write(path, raw: bytes, mtime=OLD):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def _jsonl(objs) -> bytes:
    return ("\n".join(json.dumps(o) for o in objs) + "\n").encode()


def _plain(path):
    """What the code did before: the whole file, decoded and parsed."""
    text = path.read_text(encoding="utf-8", errors="replace")
    return ts.parse_jsonl(text), len(text.encode("utf-8"))


@pytest.fixture
def parsed(monkeypatch):
    """Every text handed to parse_jsonl, so a test can say how much was parsed."""
    seen: list[str] = []
    real = ts.parse_jsonl

    def counting(data):
        seen.append(data)
        return real(data)

    monkeypatch.setattr(ts, "parse_jsonl", counting)
    return seen


def _lines_parsed(seen) -> int:
    return sum(len([ln for ln in text.splitlines() if ln.strip()]) for text in seen)


class TestWhatIsReadIsWhatAPlainReadGives:
    @pytest.mark.parametrize("raw", [
        b"",
        _jsonl([_line("a"), _line("b")]),
        _jsonl([_line("a")]) + b'{"type": "assistant", "uuid": "torn", "mess',     # a write in progress
        _jsonl([_line("a")]) + json.dumps(_line("whole-no-newline")).encode(),     # complete, no newline yet
        b'{"type":"user","uuid":"crlf"}\r\n{"type":"user","uuid":"cr"}\r{"type":"user","uuid":"n"}\n',
        b'{"type":"user","uuid":"bad \xff\xfe bytes"}\n{"type":"user","uuid":"ok"}\n',
        '{"type":"user","uuid":"sep","t":"a b"}\n{"type":"user","uuid":"ok"}\n'.encode(),
        b'not json\n[1, 2]\n\n   \n{"type":"user","uuid":"ok"}\n',
    ])
    def test_a_first_read(self, tmp_path, raw):
        path = _write(tmp_path / "s" / "a.jsonl", raw)
        assert ts.read_transcript(path) == _plain(path)

    def test_a_file_that_grows_a_line_at_a_time_and_a_torn_line_that_completes(self, tmp_path):
        path = tmp_path / "s" / "a.jsonl"
        raw = b""
        steps = [
            _jsonl([_line("a")]),
            b'{"type": "assistant", "uu',                    # torn
            b'id": "b", "message": {"role": "assistant"}}',  # completed, no newline
            b"\n" + _jsonl([_line("c")]),
            b'{"type":"user","uuid":"crlf"}\r',
            b'\n{"type":"user","uuid":"bad \xff"}\n',
        ]
        for i, more in enumerate(steps):
            raw += more
            _write(path, raw, mtime=OLD + i)
            assert ts.read_transcript(path) == _plain(path), f"after step {i}"
        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["a", "b", "c", "crlf", "bad �"]

    def test_a_file_rewritten_shorter_is_read_from_its_start(self, tmp_path):
        path = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line("a"), _line("b"), _line("c")]))
        ts.read_transcript(path)
        _write(path, _jsonl([_line("z")]), mtime=OLD + 1)
        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["z"]
        assert ts.read_transcript(path) == _plain(path)

    def test_a_file_rewritten_longer_with_other_lines_is_not_taken_for_one_that_grew(self, tmp_path):
        """Growth alone does not show the start is the same: a compaction can leave a longer file."""
        path = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line("a"), _line("b")]))
        ts.read_transcript(path)
        _write(path, _jsonl([_line("y"), _line("z"), _line("w")]), mtime=OLD + 1)
        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["y", "z", "w"]

    def test_the_list_returned_is_the_callers_own(self, tmp_path):
        path = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line("a")]))
        ts.read_transcript(path)[0].clear()     # the list of a first read
        ts.read_transcript(path)[0].clear()     # and of a read answered from what was kept
        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["a"]

    def test_a_missing_file_raises_as_a_plain_read_does(self, tmp_path):
        with pytest.raises(OSError):
            ts.read_transcript(tmp_path / "s" / "none.jsonl")
        with pytest.raises(OSError):
            ts.newest_message_ts_of(tmp_path / "s" / "none.jsonl")


class TestAnUnchangedFileCostsNoParsing:
    def test_a_second_read_of_an_unchanged_file_parses_nothing(self, tmp_path, parsed):
        path = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line(f"u{i}") for i in range(50)]))
        first = ts.read_transcript(path)
        assert _lines_parsed(parsed) == 50
        parsed.clear()

        assert ts.read_transcript(path) == first
        assert _lines_parsed(parsed) == 0

    def test_a_file_that_grew_has_only_its_new_lines_parsed(self, tmp_path, parsed):
        path = tmp_path / "s" / "a.jsonl"
        lines = [_line(f"u{i}") for i in range(50)]
        _write(path, _jsonl(lines))
        ts.read_transcript(path)
        parsed.clear()

        _write(path, _jsonl([*lines, _line("new1"), _line("new2")]), mtime=OLD + 1)
        objs, _ = ts.read_transcript(path)
        assert [o["uuid"] for o in objs][-2:] == ["new1", "new2"] and len(objs) == 52
        assert _lines_parsed(parsed) == 2

    def test_a_same_size_rewrite_inside_the_clocks_tick_is_still_seen(self, tmp_path):
        """Written twice with one size and one timestamp: the stamp cannot tell, so a
        file that was fresh when read is checked by its bytes."""
        path = tmp_path / "s" / "a.jsonl"
        now = time.time()
        _write(path, _jsonl([_line("aaaa")]), mtime=now)
        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["aaaa"]
        before = os.stat(path)

        with path.open("r+b") as fh:        # in place: same inode, same size
            fh.write(_jsonl([_line("bbbb")]))
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        after = os.stat(path)
        assert (after.st_ino, after.st_size, after.st_mtime_ns) == (
            before.st_ino, before.st_size, before.st_mtime_ns)

        assert [o["uuid"] for o in ts.read_transcript(path)[0]] == ["bbbb"]

    def test_only_one_transcript_is_kept_per_session(self, tmp_path):
        first = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line("a")]))
        second = _write(tmp_path / "s" / "b.jsonl", _jsonl([_line("b")]))
        other = _write(tmp_path / "t" / "c.jsonl", _jsonl([_line("c")]))
        for path in (first, other, second):
            ts.read_transcript(path)
        assert set(ts._parsed) == {second, other}

        ts.forget_transcripts(tmp_path / "s")
        assert set(ts._parsed) == {other}

    def test_forgetting_keeps_the_stamps_of_files_still_on_disk(self, tmp_path):
        kept = _write(tmp_path / "s" / "a.jsonl", _jsonl([_line("a")]))
        gone = _write(tmp_path / "s" / "b.jsonl", _jsonl([_line("b")]))
        ts.newest_message_ts_of(kept)
        ts.newest_message_ts_of(gone)
        gone.unlink()

        ts.forget_transcripts(tmp_path / "s")
        assert set(ts._newest_ts) == {kept}


class _Recorder:
    def __init__(self):
        self.delivered = []

    async def __call__(self, turn, attempt):
        self.delivered.append(turn.terminal_uuid)
        return True


async def _poll(base, state, rec):
    await _drain_transcript_once("sess", "conv", "http://x", transcripts_base=base,
                                 state_dir=state, post_fn=rec)


class TestTheWatchersIdlePoll:
    """The poll that was the server's CPU: nothing new in the pinned transcript, so
    every earlier transcript beside it was read to see whether Claude had moved on."""

    def _session(self, base, siblings=6, lines=40):
        for n in range(siblings):
            _write(base / "sess" / f"old{n}.jsonl",
                   _jsonl([_line(f"o{n}-{i}", stamp="2026-09-01T00:00:00.000Z") for i in range(lines)]))
        return _write(base / "sess" / "live.jsonl",
                      _jsonl([_line("u0", role="user"), _line("a0")]), mtime=OLD + 10)

    async def test_an_idle_poll_parses_nothing_once_each_file_has_been_read(self, tmp_path, parsed):
        base, state = tmp_path / "t", tmp_path / "s"
        self._session(base)
        rec = _Recorder()
        await _poll(base, state, rec)      # baseline
        await _poll(base, state, rec)      # the first idle poll reads every sibling once
        assert _lines_parsed(parsed) >= 6 * 40
        parsed.clear()

        for _ in range(5):
            await _poll(base, state, rec)

        assert _lines_parsed(parsed) == 0
        assert rec.delivered == []

    async def test_a_sibling_that_changes_later_is_read_again_and_followed(self, tmp_path, parsed):
        """Keeping what was read must not hide Claude moving to a new transcript."""
        base, state = tmp_path / "t", tmp_path / "s"
        self._session(base)
        rec = _Recorder()
        for _ in range(3):
            await _poll(base, state, rec)
        assert ts.load_watermark(state, "sess", "conv").session_id == "live"

        _write(base / "sess" / "old0.jsonl",
               _jsonl([_line("n0", role="user", stamp="2026-10-12T09:00:00.000Z"),
                       _line("n1", stamp="2026-10-12T09:00:01.000Z")]), mtime=OLD + 20)
        for _ in range(_STALE_PIN_RECOVER_POLLS):
            await _poll(base, state, rec)

        assert ts.load_watermark(state, "sess", "conv").session_id == "old0"
        assert rec.delivered == []          # followed forward, nothing replayed

    async def test_new_lines_in_the_pinned_transcript_are_the_only_lines_parsed(self, tmp_path, parsed):
        base, state = tmp_path / "t", tmp_path / "s"
        live = self._session(base)
        rec = _Recorder()
        for _ in range(3):
            await _poll(base, state, rec)
        parsed.clear()

        _write(live, _jsonl([_line("u0", role="user"), _line("a0"),
                             _line("u1", role="user", stamp="2026-10-12T00:00:05.000Z"),
                             _line("a1", "done", stamp="2026-10-12T00:00:06.000Z")]), mtime=OLD + 30)
        await _poll(base, state, rec)

        assert rec.delivered == ["a1"]
        assert _lines_parsed(parsed) == 2
