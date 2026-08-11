# task-07: Proxy Stack — Docker Compose Template

## Objective

Define the `docker-compose.yaml` template that wires Squid + refresher + policy + audit + the dev container into one cohesive stack per session. The CLI (task-08) renders this template with session-specific values; this shard delivers the template and its render contract.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NET-06 | Refresher signals Squid via `kill -HUP` in shared PID namespace | P0 |
| NET-07 | Policy sidecar tails Squid log via shared volume | P0 |
| NET-08 | Audit aggregator gets read-only access to all logs + state | P0 |
| NET-10 | Proxy stack lives outside the dev container in a separate network | P0 |
| CTR-09 | Dev container has no `/var/run/docker.sock` mount | P0 |
| CTR-11 | Stack runs cross-platform (macOS/Linux/WSL2) | P0 |
| CLI-12 | Resources named `aidc-<session>-<role>` | P0 |

---

## Design Context

From `docs/design-04-proxy-stack.md`:
> Both containers share a named volume (`blocklists:/etc/squid/blocklists`). Compose configures the refresher with `pid: "service:squid"`. The refresher sends `kill -HUP 1` (Squid's PID 1 in the shared namespace).

> Order matters: proxy stack must be ready before the dev container starts pulling base images, or those pulls go direct and bypass policy.

From `docs/design-07-safety-model.md`:
> Response `freeze` — additionally call `docker pause aidc-<session>-dev`. The compose template mounts `/var/run/docker.sock` from the host into the policy container ONLY when `taint_response: freeze`.

---

## Files to Create

### `proxy/compose.yaml.template`

A `${VARIABLE}` template that `aidc create` renders. Variables to substitute:

| Variable | Source | Example |
|----------|--------|---------|
| `${SESSION}` | CLI arg | `my-feature` |
| `${PROFILE}` | CLI arg / config | `python` |
| `${REPO_PATH}` | CLI arg / cwd | `/Users/pace/code/proj` |
| `${AUDIT_DIR}` | config | `/Users/pace/aidc-audit/my-feature-20260521T143000` |
| `${TAINT_RESPONSE}` | config | `notify` |
| `${TLD_TAINTS}` | config | `false` |
| `${NOTIFY_WEBHOOK}` | config | (optional, may be empty) |
| `${DOCKER_SOCK_MOUNT}` | computed | `- /var/run/docker.sock:/var/run/docker.sock` (when freeze mode) or empty |

Template content (compose v3.8+ syntax):

```yaml
name: aidc-${SESSION}

networks:
  default:
    name: aidc-${SESSION}-net
    driver: bridge

volumes:
  blocklist:
    name: aidc-${SESSION}-blocklist
  state:
    name: aidc-${SESSION}-state
  squid-log:
    name: aidc-${SESSION}-squid-log
  aidc-log:
    name: aidc-${SESSION}-aidc-log
  dev-home:
    name: aidc-${SESSION}-dev-home

services:
  squid:
    image: aidc/squid:local
    container_name: aidc-${SESSION}-squid
    networks:
      default:
        aliases:
          - aidc-proxy
    volumes:
      - blocklist:/etc/squid:rw    # blocklist.txt + state-actor-tlds.txt live here
      - squid-log:/var/log/squid
    healthcheck:
      test: ["CMD", "/usr/local/bin/healthcheck.sh"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

  refresher:
    image: aidc/refresher:local
    container_name: aidc-${SESSION}-refresher
    pid: "service:squid"           # shares PID namespace so kill -HUP 1 reaches squid
    volumes:
      - blocklist:/etc/squid:rw    # writes /etc/squid/blocklist.txt
      - aidc-log:/var/log/aidc     # writes refresher.log
    depends_on:
      squid:
        condition: service_healthy
    restart: unless-stopped

  policy:
    image: aidc/policy:local
    container_name: aidc-${SESSION}-policy
    environment:
      AIDC_SESSION: "${SESSION}"
      AIDC_TAINT_RESPONSE: "${TAINT_RESPONSE}"
      AIDC_TLD_TAINTS: "${TLD_TAINTS}"
      AIDC_NOTIFY_WEBHOOK: "${NOTIFY_WEBHOOK}"
    volumes:
      - blocklist:/etc/squid:ro
      - squid-log:/var/log/squid:ro
      - aidc-log:/var/log/aidc:rw   # writes policy-events.log
      - state:/var/state:rw
      - ${AUDIT_DIR}:/var/aidc/audit:rw
      ${DOCKER_SOCK_MOUNT}          # added only in freeze mode
    depends_on:
      squid:
        condition: service_healthy
    restart: unless-stopped

  audit:
    image: aidc/audit:local
    container_name: aidc-${SESSION}-audit
    environment:
      AIDC_SESSION: "${SESSION}"
      AIDC_PROFILE: "${PROFILE}"
    volumes:
      - squid-log:/var/log/squid:ro
      - aidc-log:/var/log/aidc:ro
      - state:/var/state:ro
      - dev-home:/var/aidc/dev-home:ro
      - ${AUDIT_DIR}:/var/aidc/audit:rw
    depends_on:
      squid:
        condition: service_healthy
    restart: unless-stopped

  dev:
    image: aidc/dev-${PROFILE}:local
    container_name: aidc-${SESSION}-dev
    privileged: true                # required for DinD
    networks:
      - default
    environment:
      HTTP_PROXY: "http://aidc-proxy:3128"
      HTTPS_PROXY: "http://aidc-proxy:3128"
      NO_PROXY: "localhost,127.0.0.1"
    dns:
      - 9.9.9.9
      - 149.112.112.112
    volumes:
      - ${REPO_PATH}:/workspaces/repo:rw
      - dev-home:/home/vscode:rw
      - ${AUDIT_DIR}:/var/aidc/audit:ro     # transparency: Claude can see logs about it
    depends_on:
      squid:
        condition: service_healthy
      refresher:
        condition: service_started
    restart: unless-stopped
    command: ["bash", "-c", "/usr/local/bin/aidc-tmux-start.sh && tail -f /dev/null"]
```

### `proxy/compose-render.sh`

A small helper used by `aidc create` to substitute the variables (since envsubst behavior with conditional blocks like `${DOCKER_SOCK_MOUNT}` needs careful handling). Reads the template from stdin and a `KEY=value` set from the environment.

```bash
#!/usr/bin/env bash
# Render compose.yaml.template by substituting ${VAR} placeholders from env.
# Used by `aidc create`.
set -euo pipefail

# Compute conditional values
if [ "${TAINT_RESPONSE:-notify}" = "freeze" ]; then
    DOCKER_SOCK_MOUNT="- /var/run/docker.sock:/var/run/docker.sock:rw"
else
    DOCKER_SOCK_MOUNT=""
fi
export DOCKER_SOCK_MOUNT

# Use envsubst restricted to known variables to avoid surprising substitution
envsubst '${SESSION} ${PROFILE} ${REPO_PATH} ${AUDIT_DIR} ${TAINT_RESPONSE} ${TLD_TAINTS} ${NOTIFY_WEBHOOK} ${DOCKER_SOCK_MOUNT}'
```

Used as: `cat proxy/compose.yaml.template | proxy/compose-render.sh > /tmp/aidc-render.yaml`. The CLI then runs `docker compose -f /tmp/aidc-render.yaml -p aidc-${SESSION} up -d`.

---

## Implementation Notes

1. **Compose version.** No `version:` key — modern Docker Compose ignores it and the spec recommends omitting. Project name comes from the top-level `name:` field.

2. **Per-session networks.** Each session gets its own bridge network. Cross-session isolation is automatic; no shared network.

3. **Network alias `aidc-proxy`.** The dev container's `HTTP_PROXY` env points at `http://aidc-proxy:3128`. The Squid service has `aidc-proxy` as a network alias so this resolves. This means the dev container's Dockerfile can be session-agnostic — it doesn't bake in a session name.

4. **`pid: "service:squid"` for the refresher.** This is the magic that lets `kill -HUP 1` from inside the refresher land on Squid's PID 1. Tested on Linux and Docker Desktop; behaves identically in WSL2.

5. **Docker socket mount conditional.** Only present when `freeze` taint response is configured. The render script handles this — for non-freeze modes, the placeholder is replaced with an empty string and YAML stays valid.

6. **Restart policies.** All sidecars use `unless-stopped` so they survive transient crashes but respect `docker compose down`. The dev container also uses `unless-stopped` so a transient OOM doesn't kill the session.

7. **Privileged on dev container only.** Squid + sidecars run UNprivileged. Only the dev container needs `--privileged` for DinD.

8. **DNS configuration.** Both `dns:` on the dev container (durable) AND post-create writing resolv.conf (belt-and-suspenders).

9. **Audit dir handling.** The `${AUDIT_DIR}` is the per-session subdirectory; `aidc create` creates it on the host before `docker compose up`. The compose mount is host-bind, so audit content persists after teardown.

10. **Healthcheck dependency.** `depends_on: condition: service_healthy` requires the dependent's healthcheck to pass. Squid has a healthcheck (task-03); refresher/policy/audit do not (they're "started is enough"). The dev container waits for both Squid healthy AND refresher started, so the first refresh has at least begun.

---

## Anti-patterns

- DO NOT mount Docker socket into the dev container. The threat model rejects this (CTR-09).
- DO NOT use `network_mode: host`. The point is network isolation.
- DO NOT skip the `pid: service:squid` directive. Signal delivery depends on it.
- DO NOT make `${REPO_PATH}` optional — every session must have a mounted repo.
- AVOID hardcoding image tags as `:latest`. Use `:local` which is built locally; switch to digest pins for distributed releases (P2).

---

## Success Criteria

- [ ] `proxy/compose.yaml.template` exists and is valid YAML after template substitution
- [ ] `compose-render.sh` correctly substitutes all variables, handles the freeze-mode conditional
- [ ] `docker compose -f <rendered> config` validates without errors
- [ ] Rendered compose has the dev container WITHOUT Docker socket mount in non-freeze mode
- [ ] Rendered compose has the dev container WITHOUT any `~/.ssh`, `~/.gitconfig`, `~/.docker` mounts
- [ ] Refresher service has `pid: service:squid`
- [ ] Dev container's HTTP_PROXY points at `aidc-proxy:3128` and Squid has that alias
- [ ] Healthcheck wires dependencies so dev container starts after Squid is healthy

---

## Verification

```bash
# Render the template with sample values
export SESSION=smoke
export PROFILE=multi
export REPO_PATH=/tmp/aidc-smoke-repo
export AUDIT_DIR=/tmp/aidc-smoke-audit
export TAINT_RESPONSE=notify
export TLD_TAINTS=false
export NOTIFY_WEBHOOK=
mkdir -p "$REPO_PATH" "$AUDIT_DIR"

cat proxy/compose.yaml.template | bash proxy/compose-render.sh > /tmp/aidc-compose-test.yaml

# Validate
docker compose -f /tmp/aidc-compose-test.yaml config > /dev/null && echo "compose validates"

# Check key invariants
docker compose -f /tmp/aidc-compose-test.yaml config | grep -q 'docker.sock:/var/run/docker.sock' && \
    echo "FAIL: docker sock mount present in non-freeze mode" || \
    echo "OK: no docker sock mount in non-freeze mode"

docker compose -f /tmp/aidc-compose-test.yaml config | grep -q 'aidc-proxy' && echo "OK: aidc-proxy alias present"

docker compose -f /tmp/aidc-compose-test.yaml config | grep -A2 'refresher:' | grep -q 'pid:' && echo "OK: refresher has pid mode"

# Switch to freeze mode and re-render
export TAINT_RESPONSE=freeze
cat proxy/compose.yaml.template | bash proxy/compose-render.sh > /tmp/aidc-compose-freeze.yaml
docker compose -f /tmp/aidc-compose-freeze.yaml config | grep -q 'docker.sock' && \
    echo "OK: freeze mode has docker sock mount" || \
    echo "FAIL: freeze mode missing docker sock mount"

# Cleanup
rm -rf /tmp/aidc-smoke-repo /tmp/aidc-smoke-audit /tmp/aidc-compose-test.yaml /tmp/aidc-compose-freeze.yaml
```

---

## Enforcement Test Suggestions

- [ ] Dev container never gets a docker.sock mount unless taint_response=freeze — suggested test: render with both modes, assert socket present only in freeze
- [ ] Forbidden mounts (SSH/gitconfig/docker config) absent from all renders — suggested test: grep
- [ ] Refresher always has `pid: service:squid` — suggested test: yq query on rendered output
