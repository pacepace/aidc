# Data model

aidc's own files are config YAML and each session's audit dir, documented where they are written.
aidc-mcp's durable state (TRS-25, from 2.0) is one store: a 3tears L3 holding a few tables,
SQLite (`<watcher-state>/aidc-state.sqlite`, one process). On a mesh the same tables move to the
Postgres L3 by configuration; that switch is built with the mesh face (adoption chunk 21).

## Persisted-format questions (asked before the fields were designed)

A persisted format is lock-in, so these were settled first (planning: enumerate the data's
consumers and queries, then design).

1. **Who reads it, and what do they ask?**
   - aidc-mcp after a restart: every saved send queue and every saved webhook (all rows of a
     table); a session's watermark, ledger, send record and prompt origin by key.
   - Tools: `session_status` (a session's queue), `session_resend` (a conversation's ledger and
     watermark), `session_queue_cancel` (a session's queue).
   - A person after an incident: which prompts wait where, what was delivered to which
     conversation, what was dead-lettered and why. 1.x answered this with readable JSON files in
     `watcher-state/`; 2.0 answers it with `python -m aidc_mcp.store` in the server's container,
     which prints the whole store as the same JSON documents.
   - No query reads across sessions except "all queues" and "all webhooks" at start, and "all
     dead letters" for a person. Nothing aggregates.
2. **Columns or documents?** Every 1.x file is a JSON document with a documented shape (design
   10 S4, D7, S6, S7, S8), read by tolerant loaders. Each row keeps that document whole in a
   `document` JSONB column, beside the columns its key is made of. The documented shapes stay the
   contract; a field added to one is a document change, not a table change. Rejected: one column
   per field, which would freeze every shape into DDL for no query that needs it.
3. **Keys.** The natural keys, as 1.x named the files: a session's name, or a session and a
   conversation id. A row's primary key is a text `key` (the session, or the session and the
   conversation joined by U+001F, a character neither ever holds), with `session` (and
   `conversation_id`) as columns of their own. The delivery ledger is one row per
   (session, conversation, fingerprint), keyed the same way. Dead letters are keyed by a fresh
   UUID: there is no natural key, and two can be identical.
4. **Types that survive the move to Postgres.** Only `string`, `uuid`, `jsonb` and
   `datetimetz` columns: the four both 3tears stores keep alike. Times inside documents stay the
   ISO strings and epoch numbers 1.x wrote, since the documents' readers expect them.
5. **Growth and retention.** As 1.x: a send record holds at most 200 entries for 24 hours, the
   pasted-ids record 500; the ledger grows by one row per delivered turn (1.x's file did the
   same); dead letters are kept for a person to read. Nothing is evicted silently.
6. **Concurrency and lifetime.** One process per store (the SQLite store's file lock). On
   Docker each MCP has its own state dir (aidc-mcp and aidc-mcp-dev do). On Kubernetes the
   per-user server is one replica and must be replaced, not rolled (`Recreate`; chunk 10). A
   second process on the same file is refused at start, never two writers.
7. **Versioning.** The store records its own format (the SQLite file's `user_version`, refused
   when it is another's). A new nullable column or a new table is additive; anything else is a
   migration in aidc's code, tested.
8. **Upgrade from 1.x.** The first start on a state dir holding 1.x files reads each one into
   the store (idempotently, so a start killed half way finishes on the next), then moves them to `watcher-state/migrated-1x/` (kept,
   not deleted, so a downgrade can move them back). A file 1.x would have read as empty or
   corrupt is moved without a row, as 1.x would have ignored it. Debug captures
   (`watcher-state/screens/`) are not state and stay files.

## Tables

All tables carry `date_created` (immutable) and `date_updated` (`datetimetz`).

| Table | Key | Columns | Document (1.x file it replaces) |
|---|---|---|---|
| `watermarks` | session, conversation | `session`, `conversation_id` | the Watermark (`<s>__<c>.json`) |
| `deliveries` | session, conversation, fingerprint | `session`, `conversation_id`, `fingerprint` | none: the row is the fact (`<s>__<c>.delivered`) |
| `send_queues` | session | `session` | design 10 S4's queue object (`<s>.send-queue.json`) |
| `watches` | session | `session` | design 10 D7's watch object (`<s>.watch.json`) |
| `sent_prompts` | session | `session` | the send record list (`<s>.sent-prompts.json`) |
| `prompt_origins` | session | `session` | the origin record (`<s>.prompt-origin.json`) |
| `joined_batches` | session | `session` | the joined-batch list (`<s>.joined-batches.json`) |
| `pasted_ids` | session | `session` | the pasted prompt ids (`<s>.pasted-prompts.json`) |
| `markers` | session, kind | `session`, `kind` | the marker's content (`<s>.working-text-seen`, `<s>.interrupt-reported`) |
| `dead_letters` | a UUID | `kind` (`reply`, `send`), `session`, `conversation_id`, `reason` | the dead letter as 1.x wrote it (`dead-letter/*.json`) |

The module is `mcp/src/aidc_mcp/store.py`; the functions that read and write each
document keep their 1.x names and arguments in `transcript.py`, so their callers did not change.
