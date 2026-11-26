"""Reading and writing aidc-mcp's state store from tests (store.py).

1.x kept each kind of state as a file in the state dir, and tests looked at the files.
From 2.0 the state is rows of the store in that dir; these say what a test asked of the
files: is it stored, what does it hold, what was dead-lettered."""
from pathlib import Path
from typing import Any

from aidc_mcp import store

#: what the store keeps in a state dir: its file, the write-ahead log beside it, its lock
STORE_FILES = {store.FILE_NAME, f"{store.FILE_NAME}-wal", f"{store.FILE_NAME}-shm",
               f"{store.FILE_NAME}.lock"}


def stored(base: Path, table: str, *key: str) -> Any | None:
    """The document stored under the key, or None."""
    return store.for_dir(base).get(table, store.key_of(*key))


def put_raw(base: Path, table: str, document: Any, *key: str, **columns: str) -> None:
    """Store `document` as it is, however malformed: what a damaged row would hold."""
    store.for_dir(base).put(table, store.key_of(*key), document, **columns)


def dead_letters(base: Path, kind: str | None = None, session: str | None = None
                 ) -> list[dict[str, Any]]:
    """The dead letters' documents, oldest first."""
    filters = {k: v for k, v in (("kind", kind), ("session", session)) if v is not None}
    return [d["document"] for d in store.for_dir(base).dead_letters(**filters)]


def forget(base: Path, table: str, *key: str) -> None:
    """Remove the row under the key, as deleting 1.x's file did."""
    store.for_dir(base).delete(table, store.key_of(*key))
