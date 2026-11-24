---
artifact: build-plan
version: 1
scope: k8s-ports-egress-gpu
branch: feature/k8s-git-container
base: develop
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/requirements.md
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
  - artifact: .prawduct/artifacts/archive/build-plan-k8s-hardening.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI, shellcheck --severity=warning, shell tests stub docker and kubectl on PATH → conforms"
      - "no private names in the repo (cluster, nodes, domains, other projects) → conforms: the wildcard domain, ingress class and TLS source live only in the user's config; tests and docs use example.org names; every added line is grepped before commit"
      - "supply-chain cooldown (REL-09) → conforms: dnsmasq comes from the forwarder image's pinned alpine base, like socat"
partition: serial, one delegate on this branch (every chunk touches scripts/k8s/manifests.sh and session-create.sh); the main agent runs the Critic and integrates
---

# Build Plan — Kubernetes ports, LAN pages, TCP egress, GPU, DNS and networks (W-K2)

**Work:** `k8s-ports-egress-gpu` (wave W-K2 of `plan-aidc-2.0.md`) · **Branch:**
`feature/k8s-git-container` (stacked, no PR until 2.0) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing it. W-K2 in `plan-aidc-2.0.md` §3 names the chunks, their
requirements (K8S-11, K8S-14, K8S-15, NET-15, K8S-01) and their "done when"; the leftovers
mapped to it are #74 (Docker status lists declared ports) and D8 (relays coexist with the
public-only squid). Bound by the owner rulings of 2026-11-24: everything ships in 2.0, nothing
filed; the developer chooses per expose whether a page has a login (aidc imposes none); the
wildcard domain comes from the user's config, never the repo. Main-agent calls in plan §5 bind
too: Q-K9 (`aidc egress add` stays live, names resolved through the session's own proxy pod,
not hostAliases) and Q-K10 (`--dns`, `--network`, `clean-env` get cluster forms where
meaningful; where one cannot exist, propose the K8S-01 amendment, do not make it).

**Product:** a developer on the cluster backend gets what Docker gives: a session's ports on
their machine (a tunnel that comes back by itself), a page on the home network at a stable name
with or without a login, a LAN database reached by its real name and nothing else on the LAN,
the GPU when asked, their own DNS servers, and another namespace's services when they widen the
sandbox on purpose.

**Architecture (must hold):** the backend seam (dispatcher → `scripts/k8s/session-<verb>.sh`;
no docker in shared libraries); every cluster call goes through `k8s_kubectl` (the per-user RBAC
wave derives the Role from them); a session's only way out is its squid plus the relays and
namespaces the user named, each fenced by its own NetworkPolicy in the node's namespace; the dev
pod has no cluster DNS: its one resolver is the session's names responder, which answers only
the names aidc put there and forwards nothing; nothing private (domain, cluster names) in the
repo.

**Constraints:** tests are contracts (never weakened); shellcheck warning-clean; every
`tests/unit/*.sh` exits 0; live checks on the reference cluster from a scratch HOME whose config
holds the domain and ingress settings; all test sessions, ingresses, relays and their audit
claims removed after.

**Level:** High for 01, 04, 05; Medium for 02 (ingress controllers differ: Traefik is live,
ingress-nginx is rendered and tested, others documented) and 03 (the names responder is new
machinery; checked live end to end).

## Build Chunks

### Chunk 01: tunnel (K8S-14) and status lists ports (#74)
- `aidc create --backend kubernetes --port N|H:C` (repeatable, merges the `ports:` config as
  on Docker) records the ports on the dev StatefulSet (`aidc/ports`, metadata only: no restart)
  and starts one local supervisor per port on this machine: `kubectl port-forward` (through
  `k8s_kubectl`, the user's own credentials) to the session's dev pod on 127.0.0.1:H, started
  again when it exits or when the dev pod is replaced (uid watch), logging to a file the user
  can read. `aidc proxy <s> add|rm|ls|clear|up` on Kubernetes manages them; `up` restarts the
  declared ones on another machine (K8S-21). `aidc kill` stops this machine's supervisors.
  `aidc status` lists declared ports and whether a tunnel runs here.
- #74: Docker `aidc status` lists declared ports from the `dfwd` sidecars (dev's own published
  ports kept for direct-egress sessions).
- Done when: unit tests (supervisor restarts on exit and on a new pod uid; proxy verbs; status);
  live: a port answers on localhost and again after `aidc restart`.

### Chunk 02: LAN pages (K8S-15)
- `aidc create --expose <port> [--login]`: a ClusterIP Service for the dev pod, an Ingress at
  `<session>-<user>.<domain>` (further ports `<session>-<port>-<user>.<domain>`), an ingress
  NetworkPolicy admitting only the ingress controller's pods to those ports. Config
  `kubernetes.ingress`: `domain`, `class`, TLS (`tls_secret` in the user's namespace,
  `cluster_issuer` via cert-manager, or the controller's default certificate), the controller's
  namespace and pod labels (defaults known for Traefik and ingress-nginx). `--login`: a
  generated username and password printed once, stored only as an htpasswd hash: Traefik
  (basicAuth Middleware) and ingress-nginx (auth annotations); another controller refuses
  `--login` and says so. A host already used by another Ingress is refused. Removed at kill.
- Done when: unit tests (render per controller, refusals, kill); live through the cluster's
  ingress from this machine (curl with the name resolved to the ingress), with and without
  login.

### Chunk 03: `--egress-tcp` and `aidc egress` on Kubernetes (NET-15)
- One relay per destination host: a Deployment running socat from the forwarder image (one
  listener per port, logging each connection to the session's audit claim), a ClusterIP Service,
  and NetworkPolicies: dev pod → relay on those ports; relay ← dev pod only; relay → exactly
  `<ip>/32` on those ports. Names: a `names` container in the proxy pod (dnsmasq from the
  forwarder image, no upstream, reloaded when its hosts file changes) is the dev pod's only
  nameserver; aidc writes relay names there. Live add/rm never restarts the dev pod (Q-K9).
  Resolved on this machine, as on Docker; loopback refused. Relays reached directly, not through
  squid (D8): checked live.
- Done when: unit tests; live: a session reaches one LAN TCP service by name and nothing else on
  the LAN; add and rm live; the dev pod's uid unchanged.

### Chunk 04: `--gpu` (K8S-11)
- `nvidia.com/gpu: 1` in the dev container's limits only when asked; node selector unchanged.
- Done when: rendered-manifest test (present with, absent without); live `nvidia-smi -L` in a
  `--gpu` session and no GPU without it (the reference cluster's GPU node is free).

### Chunk 05: `--dns`, `--network`, `clean-env` on Kubernetes (Q-K10)
- `--dns <ip>` (and `dns_servers:`): squid's resolvers and the proxy pod's own, with an egress
  rule for each server's /32:53 (a private resolver is allowed by name, as on Docker).
- `--network <namespace>` (and `networks:`), `aidc network <s> add|rm|ls`: the dev pod may reach
  that namespace's pods on any port (bypassing squid, said loudly as on Docker), and its
  Services' names resolve through the names responder. aidc's own namespaces, the user's own,
  and the system namespaces are refused.
- `aidc clean-env <session> --backend kubernetes`: removes what a session left behind when it is
  not running (a half-made create), keeping the audit claim; this machine's tunnels too.
- Done when: unit tests; live `--dns` and `--network` checks.

**Type:** cumulative-final — the main agent runs one review over the wave.

## Decisions made mid-build
- (01) Tunnels listen on 127.0.0.1 only. Docker's `--port` publishes on every interface; the brief's "done when" is the port answering locally, and a tunnel carrying the user's cluster credentials is not offered to the LAN (pages are the LAN path). Owner can ask for a bind-address option.
- (01) Declared ports live on the StatefulSet's metadata (`aidc/ports`), which changes nothing in the pod; `aidc proxy <s> up` starts them on another machine (K8S-21). Ad-hoc tunnels are this machine's only, as Docker's ad-hoc forwards are the host's.
- (02) Page names: the first exposed port is `<session>-<user>.<domain>` (the design's name), further ones `<session>-<port>-<user>.<domain>` (one wildcard level, so the certificate covers them). Names can collide across sessions and users (both contain hyphens): create refuses a name another Ingress serves (in the user's namespace, and cluster-wide when the user may read it). `--login` covers every page of the session; the password is shown once and is not kept (to change it, create the session again).
- (02) The controller is configured, not discovered at create: with per-user credentials (W-K5) a user cannot read IngressClasses or another namespace's pods. Defaults follow the usual installs (Traefik in kube-system as k3s ships it; ingress-nginx in ingress-nginx); the reference cluster runs Traefik 3 with its default TLS store holding the wildcard certificate, read-only inspection of its existing Ingresses.
- (03) Names through a dnsmasq responder in the proxy pod (Q-K9 as decided): `--hostsdir` with inotify, not SIGHUP (the root shell could not signal dnsmasq after it dropped to its own user: seen live), and `--except-interface=lo` (dnsmasq's default answers only its own subnet; the dev pod's queries come through the Service). The dev pod's nameserver moves from an unanswering address to this responder; it forwards nothing, so the smoke's "a DNS lookup is blocked" still holds.
- (03) A relay declared at create can be changed live on Kubernetes (Docker refuses: there it lives in the compose file). The aidc-mcp refusal of MCP-12 has no cluster target until the per-user MCP server (W-M*) has an address.
- (05) `--dns` on the public-only squid: the entrypoint refused any DNS override; session proxies now set `AIDC_DNS_USER_CHOSEN=1`, the one exception, and squid's address check still refuses private answers. So `--dns` here changes who answers public names; internal names go through `--egress-tcp` (resolved on the user's machine). IPv4 and at most three (a pod's limit).
- (05) `--network` is a namespace (any port, Services by name). Refused: the user's own namespace (the git login, other sessions), every `<prefix>-*` namespace, and kube-system, kube-public, kube-node-lease, default.
- (05) `clean-env` has a cluster form (a session's leftovers when it is not running); Docker's `--project` (container-only-path volumes) has no counterpart. No K8S-01 amendment is proposed: every verb and flag of this wave has a cluster form.
- (found) Three defects fixed on the way, each with a test: create while an earlier same-named session's claims were still being deleted left its pods waiting forever (now refused, saying why); kill recorded size and kill time on the oldest kept audit claim of that name rather than the session's own; a relay's Deployment made a half-removed session look present to lookups.
