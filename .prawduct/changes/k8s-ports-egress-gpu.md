---
schema: 1
type: feature
scope: k8s-ports-egress-gpu
date: 2026-11-24
title: Kubernetes sessions get tunnels, LAN pages, TCP egress, the GPU, --dns and --network
---
**Why:** wave W-K2 of plan-aidc-2.0 (K8S-11, K8S-14, K8S-15, NET-15, and K8S-01's cluster forms
of `--dns`, `--network` and `clean-env`), under the owner rulings of 2026-11-24 (everything ships
in 2.0; the developer chooses a login per expose; the domain comes from the user's config) and
the main agent's Q-K9 and Q-K10 calls. Issue #74 (Docker status said "declared: (none)" for
working ports) was mapped to this wave.

**What:**
- Tunnels (K8S-14): `aidc create --backend kubernetes --port H:C` and `aidc proxy <s>
  add|rm|ls|clear|up`. One local supervisor per port runs `kubectl port-forward` to the dev pod
  on 127.0.0.1, starts it again when it ends, and restarts it when the dev pod is replaced.
  Declared ports are recorded on the StatefulSet's metadata; `up` starts them on another
  machine; kill stops this machine's; status lists them.
- LAN pages (K8S-15): `--expose <port> [--login]`: a Service, an Ingress per port at
  `<session>-<user>.<domain>`, a NetworkPolicy letting only the ingress controller in, and with
  `--login` a generated username and password printed once (an apr1 hash in a Secret) through a
  Traefik Middleware or ingress-nginx annotations; another controller refuses `--login`. New
  config block `kubernetes.ingress` (domain, class, TLS secret or cluster issuer, controller and
  its pods). A page name another Ingress serves is refused. Kill removes all of it.
- TCP egress (NET-15): `--egress-tcp` / `egress_tcp:` and `aidc egress <s> add|rm|ls|clear`: a
  relay Deployment, Service and two NetworkPolicies per host (the relay may open only `<ip>/32` on
  its ports, and only the dev pod may open it). Live: never restarts the dev pod.
- Names: the dev pod's one nameserver is now a `names` container (dnsmasq, no upstream) in its
  proxy pod, answering only relay and `--network` names from a folder on the state claim; the dev
  pod's policy allows its proxy on 53 as well as 3128. The forwarder image gains dnsmasq.
- `--gpu` (K8S-11): `nvidia.com/gpu: 1` in the dev container's limits.
- `--dns` (at most three IPv4 servers): the proxy pod resolves through them, with a /32:53 egress
  rule each; the public-only squid takes them only when `AIDC_DNS_USER_CHOSEN=1` (session proxies
  set it) and still refuses private answers.
- `--network <namespace>` / `networks:` and `aidc network <s> add|rm|ls`: a NetworkPolicy to every
  pod of that namespace, its Services by name through the responder; aidc's and the system
  namespaces are refused.
- `aidc clean-env <s> --backend kubernetes` removes what a session that is not running left
  behind (keeping its audit claim); without `--backend` clean-env goes where `create` would.
- Fixes found while building: create refuses while an earlier same-named session's claims are
  still being deleted (its pods waited forever, seen live); kill records size and kill time on the
  session's own audit claim, not the oldest one of that name; a relay's Deployment no longer
  counts as the session for lookups.
- Docker (#74): `aidc status` lists declared ports from the dfwd sidecars.
- Tests: `tests/unit/test-k8s-net.sh` (new), `tests/unit/test-status-ports.sh` (new),
  `test-k8s-session.sh` and `test-squid-entrypoint.sh` extended; smoke step 4a (tunnel, page with
  login, GPU, relay with `AIDC_SMOKE_EGRESS_TCP`), the tunnel re-checked after restart, kill
  checks. Changed contracts in `test-k8s-session.sh`: the dev pod's nameserver is its proxy's
  names responder (was 192.0.2.1, an address that answers nothing), and its policy and the
  proxy's admit port 53 from the dev pod; `--port` is no longer the example of an unsupported
  flag, and `network` no longer the example of a verb the backend lacks.

## Consumer note
New cluster calls (for the per-user Role): `pods/portforward` create; `ingresses`
(networking.k8s.io) get/list/create/delete; `middlewares.traefik.io` create/delete; `secrets`
create/delete/list; `deployments`/`services`/`networkpolicies` for relays as for sessions;
`pods/exec` into the proxy's `names` container; `services` list in a `--network` namespace;
`ingresses` list across namespaces (optional: a page-name clash check that is skipped when not
allowed).
