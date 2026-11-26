"""aidc-mcp's durable state on the 3tears SQLite L3 (TRS-25, store.py).

A write that returned is in the store after the process is killed with SIGKILL; the 1.x
state files are read in once on upgrade and kept aside; one process holds a state dir."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from aidc_mcp import store
from aidc_mcp import transcript as ts
from tests.logs import patch_log_event
from tests.statefiles import STORE_FILES, dead_letters, stored

CHILD = Path(__file__).with_name("state_writer_child.py")
MCP_DIR = Path(__file__).resolve().parents[1]


def _killed_after(base: Path, kind: str) -> None:
    """Run the child until it says the write returned, then SIGKILL it: no close, no
    exit handler, nothing after the acknowledgement."""
    child = subprocess.Popen([sys.executable, str(CHILD), str(base), kind],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             cwd=MCP_DIR, env={**os.environ, "PYTHONPATH": str(MCP_DIR)})
    try:
        line = child.stdout.readline().strip()
        assert line == f"acked {kind}", (line, child.stderr.read() if child.poll() else "")
    finally:
        os.kill(child.pid, signal.SIGKILL)
        child.wait()
    assert child.returncode == -signal.SIGKILL


@pytest.mark.parametrize("kind,read_back", [
    ("watermark", lambda b: ts.load_watermark(b, "s", "c").last_delivered_uuid == "a7"),
    ("ledger", lambda b: ts.load_delivered(b, "s", "c") == {"fp-acked"}),
    ("queue", lambda b: [q.prompt_id for q in ts.load_send_queues(b)[0]["s"]] == ["p-k"]),
    ("watch", lambda b: ts.load_watches(b)[0][0]["session_instance"] == "id-1"),
    ("sent", lambda b: ts.take_sent_prompt(b, "s", "pasted words") == "u-1"),
    ("dead_letter", lambda b: [d["content"] for d in dead_letters(b)] == ["lost reply"]),
])
def test_an_acknowledged_write_survives_a_kill_9(tmp_path, kind, read_back):
    base = tmp_path / "state"
    _killed_after(base, kind)
    assert read_back(base), kind


def test_a_second_process_on_the_same_state_dir_is_refused(tmp_path):
    # one process holds a state dir: a second server on it would be a second writer
    from threetears.core.backends.sqlite_file import SqliteStoreLockedError
    base = tmp_path / "state"
    ts.save_watch(base, "s", "c", "http://cb")   # this process opens and holds it
    code = ("import sys; from threetears.core.backends import SqliteL3Backend\n"
            f"SqliteL3Backend({str(base / store.FILE_NAME)!r}).open()")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert out.returncode != 0 and SqliteStoreLockedError.__name__ in out.stderr


# --- the upgrade from 1.x's files ------------------------------------------------------

def _write_1x_state(base: Path) -> None:
    """A state dir as aidc 1.x left it: one file of each kind."""
    base.mkdir(parents=True)
    w = lambda name, doc: (base / name).write_text(json.dumps(doc), encoding="utf-8")  # noqa: E731
    w("proj__conv-1.json", {"session": "proj", "conversation_id": "conv-1",
                            "session_id": "sid", "last_delivered_uuid": "a3",
                            "fast_consecutive": 4, "updated_at": "x"})
    (base / "proj__conv-1.delivered").write_text("fp-a\nfp-b\n", encoding="utf-8")
    w("proj.send-queue.json", {"session": "proj", "updated_at": "x", "prompts": [
        {"text": "waiting", "enqueued_at": "t", "prompt_id": "p-1",
         "conversation_id": "conv-1"}]})
    w("proj.watch.json", {"session": "proj", "conversation_id": "conv-1",
                          "callback_base": "http://cb", "session_instance": "id-1"})
    w("proj.sent-prompts.json", [{"fp": ts.prompt_fingerprint("hello"), "at": time.time(),
                                  "by": "u-1"}])
    w("proj.prompt-origin.json", {"origin": "person", "sent_by": "u-1", "at": 1.0})
    w("proj.pasted-prompts.json", [{"id": "p-0", "at": "2026-10-25T10:00:00Z"}])
    w("proj.working-text-seen", {"session_instance": "id-1"})
    (base / "dead-letter").mkdir()
    w("dead-letter/proj__conv-1__a9.json", {"session": "proj", "conversation_id": "conv-1",
                                            "turn_uuid": "a9", "content": "lost"})
    w("dead-letter/send__proj__abc.json", {"session": "proj", "prompt": "gone",
                                           "reason": "session_killed"})
    (base / "screens").mkdir()
    (base / "screens" / "proj-unrecognized.ansi").write_text("debug capture")


def test_the_1x_state_files_are_read_in_once_and_kept_aside(tmp_path):
    base = tmp_path / "state"
    _write_1x_state(base)
    mark = ts.load_watermark(base, "proj", "conv-1")       # the first use reads them in
    assert mark.last_delivered_uuid == "a3" and mark.consecutive_deliveries == 4
    assert ts.load_delivered(base, "proj", "conv-1") == {"fp-a", "fp-b"}
    assert [q.text for q in ts.load_send_queues(base)[0]["proj"]] == ["waiting"]
    assert ts.load_watches(base)[0][0]["session_instance"] == "id-1"
    assert ts.take_sent_prompt(base, "proj", "hello") == "u-1"
    assert ts.last_prompt_origin(base, "proj") == ("person", "u-1")
    assert ts.pasted_at_of(base, "proj", "p-0") == "2026-10-25T10:00:00Z"
    assert stored(base, "markers", "proj", "working-text-seen") == {"session_instance": "id-1"}
    assert sorted(d["reason"] or d["kind"] for d in store.for_dir(base).dead_letters()) == [
        "reply", "session_killed"]
    # the files are kept for a downgrade, out of the way; debug captures are not state
    left = {p.name for p in base.iterdir()}
    assert left - STORE_FILES == {store.MIGRATED_DIR, "screens"}
    assert (base / store.MIGRATED_DIR / "proj.send-queue.json").exists()
    assert (base / store.MIGRATED_DIR / "dead-letter" / "send__proj__abc.json").exists()


def test_a_restart_after_the_upgrade_reads_nothing_twice(tmp_path):
    base = tmp_path / "state"
    _write_1x_state(base)
    ts.load_watches(base)
    store.close_all(within=[tmp_path])                    # the server restarts
    assert len(store.for_dir(base).dead_letters()) == 2   # not read in again
    assert ts.load_delivered(base, "proj", "conv-1") == {"fp-a", "fp-b"}


def test_an_upgrade_killed_half_way_finishes_on_the_next_start_without_duplicates(tmp_path):
    # reading a 1.x file in is idempotent, so files left behind by a killed start are read
    # in again on the next one, and what was already stored is not stored twice
    base = tmp_path / "state"
    _write_1x_state(base)
    ts.load_watches(base)
    store.close_all(within=[tmp_path])
    for p in (base / store.MIGRATED_DIR / "dead-letter").iterdir():   # "not moved yet"
        (base / "dead-letter").mkdir(exist_ok=True)
        p.rename(base / "dead-letter" / p.name)
    assert len(store.for_dir(base).dead_letters()) == 2


def test_a_1x_file_that_1x_would_have_read_as_nothing_is_kept_aside_unstored(tmp_path):
    base = tmp_path / "state"
    base.mkdir()
    (base / "proj.watch.json").write_text("{not json")
    assert ts.load_watches(base) == ([], [])
    assert (base / store.MIGRATED_DIR / "proj.watch.json").read_text() == "{not json"


def test_a_1x_send_queue_that_cannot_be_read_is_named_in_the_log(tmp_path, monkeypatch):
    """1.x logged an unreadable queue (its prompts left for a person) at every start; it is
    read in once now, so the upgrade names it once."""
    base = tmp_path / "state"
    base.mkdir()
    (base / "proj.send-queue.json").write_text("{torn")
    (base / "proj.watch.json").write_text(json.dumps({"session": "proj"}))
    logged = []
    patch_log_event(monkeypatch, lambda kind, **f: logged.append((kind, f)))
    ts.load_watches(base)
    read_in = [f for k, f in logged if k == "state_1x_read_in"]
    assert len(read_in) == 1 and read_in[0]["files"] == 2
    assert read_in[0]["unstored"] == ["proj.send-queue.json"]
    unreadable = [f for k, f in logged if k == "state_1x_file_unreadable"]
    assert [f["file"] for f in unreadable] == ["proj.send-queue.json"]
    assert Path(unreadable[0]["kept_in"]).read_text() == "{torn"


def test_a_failing_store_raises_one_type_an_oserror(tmp_path, monkeypatch):
    """Whatever the SQLite L3 raises (a full disk is sqlite3's OperationalError) leaves the
    store as StoreError, an OSError, so a caller that logs a failed state write and carries
    on, as 1.x's callers did, still catches it; the backend's error is its cause."""
    import sqlite3

    async def disk_full(*a, **k):
        raise sqlite3.OperationalError("database or disk is full")
    base = tmp_path / "state"
    ts.save_watch(base, "s", "c", "http://cb")
    monkeypatch.setattr(store.StateStore, "_put", disk_full)
    with pytest.raises(store.StoreError) as raised:
        ts.save_watch(base, "s", "c2", "http://cb")
    assert isinstance(raised.value, OSError)
    assert isinstance(raised.value.__cause__, sqlite3.OperationalError)


def test_a_conversations_ledger_is_read_through_its_index(tmp_path, monkeypatch):
    """The ledger only grows, across every session; one conversation's is read on every
    delivery pass, so that read must be the index's (a range of it), never a scan of the
    whole table."""
    import sqlite3

    from threetears.core.backends import sqlite_file
    base = tmp_path / "state"
    for conv in ("c1", "c2"):
        for n in range(3):
            ts.record_delivered(base, "s", conv, f"fp-{conv}-{n}")
    ts.record_delivered(base, "other", "c1", "fp-x")
    reads = []
    real_run = sqlite_file._run

    def traced(conn, query, params):
        if "deliveries" in query and query.lstrip().upper().startswith("SELECT"):
            reads.append((sqlite_file._sqlite_statement(query),
                          [sqlite_file._bound(v) for v in params]))
        return real_run(conn, query, params)
    monkeypatch.setattr(sqlite_file, "_run", traced)
    assert ts.load_delivered(base, "s", "c1") == {"fp-c1-0", "fp-c1-1", "fp-c1-2"}
    assert reads
    conn = sqlite3.connect(f"file:{base / store.FILE_NAME}?mode=ro", uri=True)
    try:
        for sql, params in reads:
            plan = " ".join(row[-1] for row in conn.execute(f"EXPLAIN QUERY PLAN {sql}", params))
            assert store.LEDGER_INDEX in plan and "SCAN deliveries" not in plan.replace(
                f"USING INDEX {store.LEDGER_INDEX}", ""), plan
    finally:
        conn.close()


def test_the_store_can_be_printed_whole_for_a_person(tmp_path):
    base = tmp_path / "state"
    _write_1x_state(base)
    ts.load_watches(base)            # the server's first start read the 1.x files in
    out = store.dump(base)
    assert out["send_queues"]["proj"]["prompts"][0]["text"] == "waiting"
    assert {d["fingerprint"] for d in out["deliveries"]} == {"fp-a", "fp-b"}
    assert len(out["dead_letters"]) == 2
    json.dumps(out)   # it is JSON


def test_the_store_can_be_printed_while_the_server_holds_it(tmp_path):
    # the server holds the store for as long as it runs; a person reads it beside it
    base = tmp_path / "state"
    ts.save_watch(base, "s", "c", "http://cb")           # this process holds it now
    code = ("import json; from aidc_mcp import store\n"
            f"print(json.dumps(store.dump({str(base)!r})))")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                         cwd=MCP_DIR)
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout)["watches"]["s"]["callback_base"] == "http://cb"


def test_a_server_whose_store_another_process_holds_stops_at_start(tmp_path, monkeypatch):
    """One process per store: the second server on a state dir says so and does not
    serve, rather than failing at its first tool call (data-model item 6)."""
    from aidc_mcp import server
    from aidc_mcp.service import state as ss
    base = tmp_path / "state"
    base.mkdir(parents=True)
    holder = subprocess.Popen(
        [sys.executable, "-c",
         "import sys, time; from threetears.core.backends import SqliteL3Backend\n"
         f"b = SqliteL3Backend({str(base / store.FILE_NAME)!r}); b.open(); print('held', flush=True)\n"
         "time.sleep(60)"],
        stdout=subprocess.PIPE, text=True, cwd=MCP_DIR)
    try:
        assert holder.stdout.readline().strip() == "held"
        monkeypatch.setattr(ss, "WATCHER_STATE_DIR", base)
        logged = []
        patch_log_event(monkeypatch, lambda kind, **f: logged.append(kind))
        assert server.open_state_store() is False
        assert "state_store_unavailable" in logged
    finally:
        holder.kill()
        holder.wait()
