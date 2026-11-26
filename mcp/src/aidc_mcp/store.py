"""aidc-mcp's durable state on a 3tears L3 (TRS-25): one SQLite file per state dir.

The send queues, delivery watermarks and ledger, webhooks, send records, prompt origins,
joined batches, pasted prompt ids, session markers and dead letters are rows of a few
3tears collections over one store, `<state dir>/aidc-state.sqlite` (the 3tears SQLite L3:
write-ahead log, every commit synced, one process). Each row keeps the JSON document 1.x
kept in a file, under the key 1.x named the file by (`.prawduct/artifacts/data-model.md`).

The callers are synchronous, as 1.x's file writes were: transcript.py's persistence
functions keep their names and arguments, and a write returns once it is committed. The
store's statements run on one loop thread of this module's, which every caller (the
server's loop, a worker thread) waits on for the statement's length, as it waited on the
file write before. Each write to a store is serialized there (one at a time); a caller
that reads a document and writes it back (a send record, the pasted ids) is not atomic
across threads, as 1.x's read-then-rename was not, and relies on its own callers' order.

The first open of a state dir that holds 1.x files reads each one into the store, then moves
them to `migrated-1x/` beside it, kept for a downgrade. Reading one in is idempotent (a
document replaces its key's row, a ledger line or dead letter is keyed by what it is), so a
start killed half way reads the rest in on the next one.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import threading
import uuid
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TypeVar

import sqlalchemy
from threetears.core.backends import SqliteL3Backend
from threetears.core.cache import SQLiteBackend
from threetears.core.collections import NO_L2
from threetears.core.collections.registry import CollectionRegistry
from threetears.core.collections.schema_backed import (
    DATETIMETZ_TYPE,
    JSONB_TYPE,
    STRING_TYPE,
    UUID_TYPE,
    Column,
    TableSchema,
    collection_for_schema,
)
from threetears.core.config import DefaultCoreConfig
from threetears.core.eviction import Declared, Policy

T = TypeVar("T")

#: the store's file in a state dir
FILE_NAME = "aidc-state.sqlite"
#: where the 1.x files go once read in
MIGRATED_DIR = "migrated-1x"

#: names a 1.x dead-letter file's row, so reading it in twice stores it once
_DEAD_LETTER_NS = uuid.UUID("6f1d2b0e-4c55-4a8e-9b1d-a1dc0000d1e7")

#: separates the parts of a row's key: neither a session name nor a conversation id holds it
KEY_SEP = "\x1f"

_DATES = [Column("date_created", DATETIMETZ_TYPE, immutable=True),
          Column("date_updated", DATETIMETZ_TYPE)]

#: the L1 in front is a cache of the file: a row it evicts is read back from the file
_L1 = Declared(Policy.EVICTABLE, "aidc-mcp state: a cache of the SQLite L3, read back on eviction")


def _documents(name: str, *parts: str) -> TableSchema:
    """A table of JSON documents under a text key made of `parts`, each also a column."""
    return TableSchema(
        name=name, primary_key="key",
        columns=[Column("key", STRING_TYPE), *(Column(p, STRING_TYPE) for p in parts),
                 Column("document", JSONB_TYPE), *_DATES],
        cas_column="date_updated", l1_eviction=_L1)


#: each kind of state, by the name its callers use
TABLES: dict[str, TableSchema] = {
    "watermarks": _documents("watermarks", "session", "conversation_id"),
    "send_queues": _documents("send_queues", "session"),
    "watches": _documents("watches", "session"),
    "sent_prompts": _documents("sent_prompts", "session"),
    "prompt_origins": _documents("prompt_origins", "session"),
    "joined_batches": _documents("joined_batches", "session"),
    "pasted_ids": _documents("pasted_ids", "session"),
    "markers": _documents("markers", "session", "kind"),
    "deliveries": TableSchema(
        name="deliveries", primary_key="key",
        columns=[Column("key", STRING_TYPE), Column("session", STRING_TYPE),
                 Column("conversation_id", STRING_TYPE), Column("fingerprint", STRING_TYPE),
                 *_DATES],
        cas_column="date_updated", l1_eviction=_L1),
    "dead_letters": TableSchema(
        name="dead_letters", primary_key="id",
        columns=[Column("id", UUID_TYPE), Column("kind", STRING_TYPE),
                 Column("session", STRING_TYPE), Column("conversation_id", STRING_TYPE),
                 Column("reason", STRING_TYPE), Column("document", JSONB_TYPE), *_DATES],
        cas_column="date_updated", l1_eviction=_L1),
}

_COLLECTION_CLASSES = {name: collection_for_schema(schema) for name, schema in TABLES.items()}


def key_of(*parts: str) -> str:
    return KEY_SEP.join(parts)


@dataclass(frozen=True)
class Row:
    """One stored row: its key, its document, and its other columns."""

    key: str
    document: Any
    columns: dict[str, Any]


# --- the loop the stores run on ------------------------------------------------------

_loop_lock = threading.Lock()
_loop: asyncio.AbstractEventLoop | None = None


def _store_loop() -> asyncio.AbstractEventLoop:
    global _loop
    with _loop_lock:
        if _loop is None or _loop.is_closed():
            loop = asyncio.new_event_loop()
            threading.Thread(target=loop.run_forever, name="aidc-state-store",
                             daemon=True).start()
            _loop = loop
        return _loop


def _run[T](make: Callable[[], Awaitable[T]]) -> T:
    """Run a coroutine on the stores' loop and wait for its result. Never called from
    that loop itself (it would wait on itself)."""
    async def call() -> T:
        return await make()
    return asyncio.run_coroutine_threadsafe(call(), _store_loop()).result()


def _now() -> datetime:
    return datetime.now(UTC)


class StateStore:
    """The store of one state dir: its L3 file and a collection per table."""

    def __init__(self, base_dir: Path) -> None:
        self.base_dir = Path(base_dir)
        self.path = self.base_dir / FILE_NAME
        self._backend: SqliteL3Backend | None = None
        self._collections: dict[str, Any] = {}
        self._lock: asyncio.Lock | None = None

    # opened and closed on the stores' loop
    async def _open(self) -> None:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        backend = SqliteL3Backend(self.path)
        backend.open()
        # the L1 holds a table per collection, so reads are served from memory once read
        l1 = SQLiteBackend(f"aidc_state_{uuid.uuid4().hex[:12]}")
        metadata = sqlalchemy.MetaData()
        for schema in TABLES.values():
            schema.to_sqlalchemy_table(metadata)
        l1.initialize(metadata)
        registry = CollectionRegistry()
        registry.configure(l1_backend=l1, l3_pool=backend)
        self._collections = {name: cls(registry, DefaultCoreConfig(), NO_L2)
                             for name, cls in _COLLECTION_CLASSES.items()}
        self._backend = backend
        self._lock = asyncio.Lock()
        await self._migrate_1x()

    async def _close(self) -> None:
        if self._backend is not None:
            self._backend.close()
            self._backend = None

    @property
    def backend(self) -> SqliteL3Backend:
        assert self._backend is not None, "the state store is not open"
        return self._backend

    # --- documents -------------------------------------------------------------------

    def get(self, table: str, key: str) -> Any | None:
        """The document stored under `key`, or None."""
        return _run(lambda: self._get(table, key))

    async def _get(self, table: str, key: str) -> Any | None:
        entity = await self._collections[table].get(key)
        return None if entity is None else entity.document

    def put(self, table: str, key: str, document: Any, **columns: str) -> None:
        """Store `document` under `key` (replacing what was there), with its key's columns.
        Returns once it is committed."""
        _run(lambda: self._locked(lambda: self._put(table, key, document, columns)))

    async def _put(self, table: str, key: str, document: Any, columns: dict[str, Any]) -> None:
        coll = self._collections[table]
        entity = await coll.get(key)
        if entity is None:
            now = _now()
            entity = coll.create({"key": key, **columns, "document": document,
                                  "date_created": now, "date_updated": now})
        else:
            entity.document = document
            entity.date_updated = _now()
        await coll.save_entity(entity)

    def delete(self, table: str, key: str) -> None:
        _run(lambda: self._locked(lambda: self._delete(table, key)))

    async def _delete(self, table: str, key: str) -> None:
        coll = self._collections[table]
        if await coll.get(key) is not None:
            await coll.delete(key)

    def rows(self, table: str, **filters: str) -> list[Row]:
        """Every row of `table` whose columns equal `filters`, in key order."""
        return _run(lambda: self._rows(table, filters))

    async def _rows(self, table: str, filters: dict[str, str]) -> list[Row]:
        found = await self.backend.scan(table, filters or None)
        pk = str(TABLES[table].primary_key)
        out = [Row(key=str(r[pk]), document=r.get("document"),
                   columns={k: v for k, v in r.items() if k not in (pk, "document")})
               for r in found]
        return sorted(out, key=lambda r: r.key)

    # --- the delivery ledger -----------------------------------------------------------

    def ledger(self, session: str, conversation_id: str) -> set[str]:
        return {str(r.columns["fingerprint"])
                for r in self.rows("deliveries", session=session,
                                   conversation_id=conversation_id)}

    def ledger_add(self, session: str, conversation_id: str, fingerprint: str) -> None:
        key = key_of(session, conversation_id, fingerprint)

        async def add() -> None:
            coll = self._collections["deliveries"]
            if await coll.get(key) is None:
                now = _now()
                await coll.save_entity(coll.create({
                    "key": key, "session": session, "conversation_id": conversation_id,
                    "fingerprint": fingerprint, "date_created": now, "date_updated": now}))
        _run(lambda: self._locked(add))

    # --- dead letters ------------------------------------------------------------------

    def add_dead_letter(self, kind: str, session: str, conversation_id: str, reason: str,
                        document: Any) -> None:
        async def add() -> None:
            coll = self._collections["dead_letters"]
            now = _now()
            await coll.save_entity(coll.create({
                "id": uuid.uuid4(), "kind": kind, "session": session,
                "conversation_id": conversation_id, "reason": reason, "document": document,
                "date_created": now, "date_updated": now}))
        _run(lambda: self._locked(add))

    def dead_letters(self, **filters: str) -> list[dict[str, Any]]:
        """Every dead letter matching `filters`, oldest first: its document, with when it
        was written and its kind, session, conversation and reason."""
        found = _run(lambda: self.backend.scan("dead_letters", filters or None))
        found.sort(key=lambda r: r["date_created"])
        return [{"kind": r["kind"], "session": r["session"],
                 "conversation_id": r["conversation_id"], "reason": r["reason"],
                 "at": r["date_created"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "document": r["document"]} for r in found]

    # --- serialized writes ---------------------------------------------------------------

    async def _locked(self, step: Callable[[], Awaitable[T]]) -> T:
        assert self._lock is not None
        async with self._lock:
            return await step()

    # --- reading 1.x's files once --------------------------------------------------------

    async def _migrate_1x(self) -> None:
        """Read the 1.x state files of this dir into the store, then move them aside."""
        found = _legacy_files(self.base_dir)
        if not found:
            return
        for path, step in found:
            await step(self, path)
        aside = self.base_dir / MIGRATED_DIR
        aside.mkdir(exist_ok=True)
        for path, _ in found:
            target = aside / path.relative_to(self.base_dir)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(target))
        legacy_dl = self.base_dir / "dead-letter"
        if legacy_dl.is_dir() and not any(legacy_dl.iterdir()):
            legacy_dl.rmdir()


def _read_json(path: Path) -> Any | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):
        return None


def _session_of(path: Path, suffix: str, document: Any) -> str | None:
    """The session a per-session 1.x file belongs to: its document's own `session` when it
    names one (a slug cannot be undone), else the file name less its suffix."""
    if isinstance(document, dict) and isinstance(document.get("session"), str) \
            and document["session"]:
        return str(document["session"])
    name = path.name[: -len(suffix)]
    return name or None


def _per_session(table: str, suffix: str) -> Callable[[StateStore, Path], Awaitable[None]]:
    async def step(store: StateStore, path: Path) -> None:
        document = _read_json(path)
        session = _session_of(path, suffix, document)
        if document is None or session is None:
            return   # 1.x would have read it as nothing: moved aside, not stored
        await store._put(table, session, document, {"session": session})
    return step


async def _watermark_step(store: StateStore, path: Path) -> None:
    document = _read_json(path)
    if not isinstance(document, dict):
        return
    session = document.get("session")
    conversation = document.get("conversation_id")
    if not (isinstance(session, str) and isinstance(conversation, str)):
        session, _, conversation = path.name[:-len(".json")].partition("__")
    await store._put("watermarks", key_of(session, conversation), document,
                     {"session": session, "conversation_id": conversation})


async def _ledger_step(store: StateStore, path: Path) -> None:
    session, _, conversation = path.name[:-len(".delivered")].partition("__")
    mark = _read_json(store.base_dir / f"{session}__{conversation}.json")
    if isinstance(mark, dict):
        session = str(mark.get("session") or session)
        conversation = str(mark.get("conversation_id") or conversation)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    coll = store._collections["deliveries"]
    for fingerprint in {ln.strip() for ln in lines if ln.strip()}:
        key = key_of(session, conversation, fingerprint)
        if await coll.get(key) is None:
            now = _now()
            await coll.save_entity(coll.create({
                "key": key, "session": session, "conversation_id": conversation,
                "fingerprint": fingerprint, "date_created": now, "date_updated": now}))


def _marker_step(kind: str, suffix: str) -> Callable[[StateStore, Path], Awaitable[None]]:
    async def step(store: StateStore, path: Path) -> None:
        document = _read_json(path)
        if not isinstance(document, dict):
            return
        session = path.name[: -len(suffix)]
        await store._put("markers", key_of(session, kind), document,
                         {"session": session, "kind": kind})
    return step


async def _dead_letter_step(store: StateStore, path: Path) -> None:
    document = _read_json(path)
    if not isinstance(document, dict):
        return
    kind = "send" if path.name.startswith("send__") else "reply"
    coll = store._collections["dead_letters"]
    dl_id = uuid.uuid5(_DEAD_LETTER_NS, path.name)
    if await coll.get(dl_id) is not None:
        return
    when = datetime.fromtimestamp(path.stat().st_mtime, UTC)
    await coll.save_entity(coll.create({
        "id": dl_id, "kind": kind, "session": str(document.get("session", "")),
        "conversation_id": str(document.get("conversation_id", "")),
        "reason": str(document.get("reason", "")), "document": document,
        "date_created": when, "date_updated": when}))


#: 1.x's files: what each name ends with, and how it is read in
_LEGACY: tuple[tuple[str, Callable[[StateStore, Path], Awaitable[None]]], ...] = (
    (".send-queue.json", _per_session("send_queues", ".send-queue.json")),
    (".watch.json", _per_session("watches", ".watch.json")),
    (".sent-prompts.json", _per_session("sent_prompts", ".sent-prompts.json")),
    (".prompt-origin.json", _per_session("prompt_origins", ".prompt-origin.json")),
    (".joined-batches.json", _per_session("joined_batches", ".joined-batches.json")),
    (".pasted-prompts.json", _per_session("pasted_ids", ".pasted-prompts.json")),
    (".working-text-seen", _marker_step("working-text-seen", ".working-text-seen")),
    (".interrupt-reported", _marker_step("interrupt-reported", ".interrupt-reported")),
    (".delivered", _ledger_step),
)


def _legacy_files(base: Path) -> list[tuple[Path, Callable[[StateStore, Path], Awaitable[None]]]]:
    if not base.is_dir():
        return []
    found: list[tuple[Path, Callable[[StateStore, Path], Awaitable[None]]]] = []
    for path in sorted(base.iterdir()):
        if not path.is_file():
            continue
        for suffix, step in _LEGACY:
            if path.name.endswith(suffix):
                found.append((path, step))
                break
        else:
            if "__" in path.name and path.name.endswith(".json"):
                found.append((path, _watermark_step))
    dl = base / "dead-letter"
    if dl.is_dir():
        found += [(p, _dead_letter_step) for p in sorted(dl.glob("*.json"))]
    return found


# --- one store per state dir -----------------------------------------------------------

_stores_lock = threading.Lock()
_stores: dict[Path, StateStore] = {}


def for_dir(base_dir: Path | str) -> StateStore:
    """The open store of `base_dir`, opened (and 1.x's files read in) on first use."""
    resolved = Path(base_dir).resolve()
    with _stores_lock:
        store = _stores.get(resolved)
        if store is None:
            store = StateStore(resolved)
            _run(store._open)
            _stores[resolved] = store
        return store


def close_all(within: Iterable[Path] | None = None) -> None:
    """Close the open stores (those under `within`, when given). Their next use reopens."""
    with _stores_lock:
        for path in list(_stores):
            if within is not None and not any(_under(path, w) for w in within):
                continue
            store = _stores.pop(path)
            _run(store._close)


def _under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(Path(parent).resolve())
    except ValueError:
        return False
    return True


def dump(base_dir: Path | str) -> dict[str, Any]:
    """The whole store as JSON-able documents, for a person reading it after an incident.

    Read straight from the file, read-only, beside the server that holds it (the store
    admits one process, and a person reads while the server runs): each row's document is
    the JSON text the store keeps, and the other columns as they are."""
    import sqlite3

    path = Path(base_dir) / FILE_NAME
    if not path.exists():
        return {table: [] if table in ("dead_letters", "deliveries") else {} for table in TABLES}
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    out: dict[str, Any] = {}
    try:
        present = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        for table in TABLES:
            rows = ([dict(r) for r in conn.execute(f'SELECT * FROM "{table}" ORDER BY 1')]
                    if table in present else [])
            for r in rows:
                if isinstance(r.get("document"), str):
                    r["document"] = json.loads(r["document"])
            if table == "dead_letters":
                rows.sort(key=lambda r: r["date_created"])
                out[table] = [{"at": r["date_created"], "kind": r["kind"],
                               "session": r["session"],
                               "conversation_id": r["conversation_id"],
                               "reason": r["reason"], "document": r["document"]}
                              for r in rows]
            elif table == "deliveries":
                out[table] = [{k: r[k] for k in ("session", "conversation_id", "fingerprint",
                                                  "date_created")} for r in rows]
            else:
                out[table] = {str(r["key"]).replace(KEY_SEP, " / "): r["document"] for r in rows}
    finally:
        conn.close()
    return out


def main() -> int:
    """`python -m aidc_mcp.store [state dir]`: print the store as JSON."""
    import sys
    base = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "AIDC_MCP_WATCHER_STATE", "/var/log/aidc-mcp/watcher-state")
    print(json.dumps(dump(base), indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
