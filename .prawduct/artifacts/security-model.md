# Security model

Covered elsewhere; this file only points there.

- `docs/security-model.md` — the threat model, what aidc does and does not protect
  against, the taint model, and the deliberate holes (attached networks, TCP egress relays, a
  repo's own config, what a session can ask the git container to do).
- `docs/design-12-kubernetes.md` "Git" — the git container's boundaries (gitctl's users and
  verbs, bundles, the request folder) and its recorded residuals.
- `docs/requirements.md` — the enforceable rules: NET (egress enforcement, relays), SEC (taint,
  repo-config trust), MCP-12 (sessions cannot reach the control plane), REL-09 (14-day
  supply-chain cooldown), K8S-04/K8S-24 (the git container and its hard rules).
