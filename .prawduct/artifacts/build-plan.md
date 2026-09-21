---
artifact: build-plan
version: 1
scope: egress-tcp
branch: feature/egress-tcp
---

# Build Plan — egress_tcp and repo-config trust

**Work:** `egress-tcp` · **Branch:** `feature/egress-tcp` (off `develop`) · **Started:** 2026-09-21
**Critic mode:** cumulative-final (one boundary review after the last chunk)

## Why

A session cannot reach a TCP service the host can reach — Pace's case is YugabyteDB
(`yuga.ranch.illuminati.org:5433`, Postgres wire, TLS) over ZeroTier — because a session's only way
out is Squid, which carries HTTP. aidc is used by other people, so the answer must be general: a
way for the operator to name the TCP endpoints a session may reach, with nothing about any one
network built in.

While checking how such a setting would be configured, a second problem surfaced: a repo's own
`.aidc/config.yaml` (and a workspace's) can set nearly every setting, including ones that weaken
the sandbox — `egress: direct` (no isolation at all), `networks`, `ports`, the `share_*` host mounts,
`taint_response`, `audit_dir`, `notify_webhook`, `dns_servers`. The repo is writable from inside the
session, so an agent can write that file and the next `aidc create` on the repo gives it a weaker
sandbox. `egress_tcp` must not inherit that, and the existing keys should not keep it.

## Confidence check

- **Problem:** a session cannot reach a non-HTTP TCP service the host can reach; and repo-controlled
  config can weaken the sandbox.
- **Success:** with `egress_tcp: [yuga.ranch.illuminati.org:5433]` in the operator's config,
  `psql "postgresql://…@yuga.ranch.illuminati.org:5433/faidh_dev?sslmode=require"` works inside the
  session, nothing else opens, each connection is logged to the session audit dir. A repo config
  that sets a weakening key is listed at `aidc create` and ignored unless `--trust-repo-config`.
- **Out of scope:** UDP; HTTP (Squid carries it); YugabyteDB smart-driver discovery (list each node,
  or use `load_balance=false`); re-resolving a destination whose address changes (recreate).

## Requirements

- **NET-15** (new): operator-declared TCP egress.
- **SEC-09** (new): repo-controlled configuration cannot weaken the sandbox.
Both written into `docs/requirements.md` in Chunk A/B.

## Design decisions

- [DECISION: one relay per destination HOST, listening on each of its ports (not one per host:port as
  first written): Docker answers an alias with every container that carries it, so two relays for one
  host could hand a client the relay for the other port. Found while building; NET-15 amended.]
- [DECISION: live relays survive restart and upgrade (first plan: lost on upgrade). Upgrade recreates
  only dev and a relay targets an address, not dev, so there was nothing to lose. NET-15 amended.]
- [DECISION: names are resolved on the host, except for sessions created through aidc-mcp's
  session_create, which runs `aidc create` inside the aidc-mcp container and so resolves there
  (host upstream DNS, no per-link resolvers). Resolving on the host from inside the container is
  not possible, and refusing egress_tcp there would remove the feature for orchestrated sessions.
  Documented in README and NET-15; `aidc egress ls` shows the address to check.]
- [DECISION: MCP session_create has no way to pass --trust-repo-config, so orchestrator-created
  sessions never apply a repo's widening settings. Intended: that is exactly the untrusted path. The
  refusals appear in the create log. Recorded in README.]
- [DECISION: relays render into the session's compose file like the declared port forwarders, on the
  session network (aliased to the destination's hostname) and the egress network | alternatives:
  `aidc network` (a local bridge, no route to remote addresses), `--egress direct` (removes
  isolation), Squid CONNECT (Postgres clients cannot use an HTTP proxy), ZeroTier in the container
  (the whole overlay) | Pace approved 2026-09-21]
- [DECISION: the destination is resolved on the HOST at create/add time and the relay targets the
  address | the relay carries the destination's name as an alias on the session network, so if it
  resolved the name itself Docker's DNS would answer with the relay's own address and it would
  connect to itself; the host's resolver is also the one known to work (split DNS over ZeroTier) |
  cost: an address change needs `aidc egress <s> rm/add` or a recreate]
- [DECISION: TLS is not terminated — the relay is plain TCP, so `sslmode=verify-full` still checks
  the real hostname on the client side]
- [DECISION: the relay refuses the aidc-mcp bind address:port, keeping MCP-12]
- [DECISION: repo/workspace config may set only keys that are harmless or tightening: `profile`,
  `claude_mode`, `claude_resume`, `blocklist_additions`, `container_only_paths`,
  `state_actor_tlds` additions. Everything else is operator-only (global config or CLI flag); a
  repo value is listed and ignored unless `--trust-repo-config` | Pace approved the rule for
  `egress_tcp`/`networks`/`ports` 2026-09-21; the wider key list shipped and Pace was told
  2026-09-21 that he can narrow it — revisit on his answer]
- [ASSUMPTION: breaking a repo that relies on its own `networks:`/`ports:`/`egress:` is acceptable —
  the fix is one flag, and the create output names it | MED impact | Pace can veto]

## Chunks

### Chunk A: repo-config trust (SEC-09)
- `load_config` classifies keys; weakening keys from workspace/project config go to
  `AIDC_REPO_REQUESTED` (a list of `key=value` lines) instead of being applied, unless
  `AIDC_TRUST_REPO_CONFIG=true`.
- `aidc create --trust-repo-config` sets it; create prints the requested items and the flag.
- Tests: `tests/unit/test-config-sources.sh` — each weakening key from a repo config is ignored and
  reported; with the flag it applies; tightening keys apply either way; global config unaffected.
- Done when: tests pass, SEC-09 written, README config section says which keys a repo may set.

### Chunk B: egress_tcp at create (NET-15)
- `egress_tcp:` list (operator-only per Chunk A) and repeatable `--egress-tcp host:port`.
- Validate host (DNS name or IPv4) and port; resolve on the host; refuse an unresolvable name and
  the MCP address:port.
- Render `egress-<slug>` services on the forwarder image (proxy/forwarder/Dockerfile), networks `default` (alias = hostname) and
  `egress`, socat `-d -d -lf /var/aidc/audit/egress-<slug>.log TCP-LISTEN:<port>,fork,reuseaddr
  TCP:<address>:<port>`, audit dir mounted rw.
- Tests: unit test of the rendered service and the refusals; smoke test with a throwaway TCP
  server on a separate bridge, reached from dev by hostname, and the connection in the audit log.
- Done when: tests + smoke pass.

### Chunk C: `aidc egress` and docs
- `aidc egress <session> add|rm|ls|clear <host:port>` for a running session (adhoc relays named
  `aidc-<s>-egressx-<slug>`, labelled). They survive restart and upgrade like `aidc network`
  attachments (upgrade recreates only dev; a relay targets an address, not dev); `aidc kill`
  sweeps them before `compose down` (they attach to the session networks). A host that already
  has a declared relay cannot get a live one (one alias, one relay) — recreate instead.
- `aidc status` lists relays.
- Docs: README (config + a "reaching a database on another network" section), design doc,
  CHANGELOG, requirements.
- Done when: tests pass; cumulative Critic run and blocking findings resolved.

## Status

- [x] Chunk A: repo-config trust (SEC-09) — built, unit-tested; reviewed with the cumulative Critic
- [x] Chunk B: egress_tcp at create (NET-15) — reviewed: rev-20260921T204623Z-fa131876, verified rev-20260921T210529Z-fbc10ffb
- [x] Chunk C: `aidc egress` and docs — same reviews; smoke 81/81 at dcce369
