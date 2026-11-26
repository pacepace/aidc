"""A process that makes one kind of state write through aidc's own functions, says it
returned, and waits to be killed with SIGKILL (test_state_store.py). Run as
`python state_writer_child.py <state dir> <kind>`."""
import sys
import time
from pathlib import Path

from aidc_mcp import transcript as ts
from aidc_mcp.service import callbacks as cbk


def write(base: Path, kind: str) -> None:
    if kind == "watermark":
        ts.save_watermark(base, ts.Watermark("s", "c", last_delivered_uuid="a7"))
    elif kind == "ledger":
        ts.record_delivered(base, "s", "c", "fp-acked")
    elif kind == "queue":
        ts.save_send_queue(base, "s", [ts.QueuedPrompt("waiting", "t", prompt_id="p-k")])
    elif kind == "watch":
        ts.save_watch(base, "s", "c", "http://cb", session_instance="id-1")
    elif kind == "sent":
        ts.record_sent_prompt(base, "s", "pasted words", sent_by="u-1")
    elif kind == "dead_letter":
        cbk.write_dead_letter(base, "s", "c", ts.Turn("t-9", "lost reply", ok=True))
    else:
        raise SystemExit(f"unknown kind {kind!r}")
    print(f"acked {kind}", flush=True)
    time.sleep(3600)


if __name__ == "__main__":
    write(Path(sys.argv[1]), sys.argv[2])
