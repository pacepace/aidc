# Security model

Covered elsewhere; this file only points there.

- `docs/security-model.md` — the threat model, what aidc does and does not protect
  against, the taint model, and the deliberate holes (attached networks, TCP egress relays, a
  repo's own config).
- `docs/requirements.md` — the enforceable rules: NET (egress enforcement, relays), SEC (taint,
  repo-config trust), MCP-12 (sessions cannot reach the control plane), REL-09 (14-day
  supply-chain cooldown).
