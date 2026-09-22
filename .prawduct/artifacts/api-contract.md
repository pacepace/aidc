# API contract

aidc's programmatic interface is the MCP control plane that orchestrators call. It is covered
elsewhere; this file only points there.

- `.prawduct/artifacts/boundary-patterns.md` — every contract with another program: tool
  envelopes and error codes, the callback payload, the CLI inside aidc-mcp, the transcript mirror,
  and the compose file.
- `docs/done/design-08-mcp-control.md`, `docs/done/design-09-callback-delivery.md`,
  `docs/design-10-turn-state-and-sending.md` — the tools, the callback delivery, and turn state
  (design 10 D5/D6 pin the payload and the error codes).
- README, "MCP control plane (reference)" — the operator's view.

## Compatibility (decided 2026-09-22)

The MCP interface follows aidc's version number. Adding a tool, a field or a default-off setting
can happen in any release. Removing or changing an existing tool, field, callback or error code
happens only in a major release (v2.0), and is announced in the CHANGELOG, so an orchestrator
built against any 1.x keeps working through every 1.x upgrade.
