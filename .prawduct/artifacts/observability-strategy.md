# Observability

Covered elsewhere; this file only points there.

- Per session, the audit dir (`~/aidc-audit/<session>-<time>/`): squid's access log, policy
  events (taint), the config snapshot, meta.json, and one connection log per TCP egress relay.
  `docs/done/design-04-proxy-stack.md` and `design-07-safety-model.md` ("Forensics") describe
  them.
- Live: `aidc status`, `aidc logs`, `aidc list` (README, "Watching it").
- The control plane: aidc-mcp's own audit log (`mcp/src/aidc_mcp/audit.py`).
