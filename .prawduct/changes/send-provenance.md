---
schema: 1
type: fix
scope: send-provenance
date: 2026-11-08
title: A pasted prompt says who sent it
---
**Why:** asked by the metallm session, approved by Pace 2026-11-08. A pasted prompt and a typed
one look the same to the session's Claude, so an orchestrator's send, or one it made for a
person, read as the session's own person typing (live 2026-11-07 18:39:44Z: an agent's vote
prompt was answered as the person's).

**What:**
- Every prompt `session_send` pastes opens with `[Sent through aidc by <sender>, from
  conversation <id>. Not typed at this terminal.]` and a space (design 10 S8). One line, not a
  header line and a blank line: the paste is not bracketed, so a newline would submit the header
  alone. A prompt starting with `/` or `!` goes in as given.
- Framed once, where `session_send` makes the queue entry: `text` stays the caller's prompt,
  `paste_text` holds the framed form, and pasting now, joining and the drainer all paste
  `paste()`, which the send record, the echo hold and an unsubmitted paste match. A batch keeps
  each prompt's header. `_inject` adds nothing. Previews, dead letters, notices and
  `working_on` show the prompt, not the header.
- The header names the call's own `conversation_id`, never the webhook's. An empty prompt is
  not framed.
- `sender_label` (optional, declared in the schema) names the sender; cleaned to one line,
  brackets removed, at most 120 characters; kept on the queue entry beside `sent_by`. The
  callback payload is unchanged.
- `session_run` (not advertised) frames its turns and takes `sender_label`. `session_resend`
  pastes nothing.
- A queue saved by an earlier `aidc-mcp` (entries with no `paste_text` key) is framed on load,
  except a batch already in the input box.
- `mcp/published-tools.json` regenerated.

## Consumer note
none: migrated from the legacy change log, which held no consumer note; replace this line with the note if consumers need one
