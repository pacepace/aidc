#!/usr/bin/env bash
# Render compose.yaml.template by substituting ${VAR} placeholders from env.
# Used by `aidc create`.
#
# Usage:
#   cat proxy/compose.yaml.template | proxy/compose-render.sh > /tmp/aidc-render.yaml
#
# Required environment variables:
#   SESSION                  per-session identifier (e.g. "my-feature")
#   PROFILE                  dev profile name (e.g. "python")
#   REPO_PATH                absolute path to repo (mounted at the same path inside the container)
#   AUDIT_DIR                absolute path to per-session audit dir on host
#   HOST_CLAUDE_PROJECT_DIR  absolute path to host's ~/.claude/projects/<encoded-repo>/
#   ENCODED_REPO             repo path with "/" replaced by "-" (Claude's memory dir name)
#   TAINT_RESPONSE           one of: log | notify | freeze   (product default: freeze)
#   TLD_TAINTS               "true" | "false"
#   NOTIFY_WEBHOOK           optional webhook URL (may be empty)
#
# Computed:
#   DOCKER_SOCK_MOUNT        expands to a "- /var/run/docker.sock:..." mount line
#                            only when TAINT_RESPONSE=freeze; empty otherwise.
#   CLAUDE_MEMORY_MOUNT etc. expand to optional bind-mount lines set by
#                            `aidc create` before invoking this script; empty
#                            otherwise (the line collapses).

set -euo pipefail

# AIDC_VERSION_TAG is REQUIRED (no permissive default). Set by the dispatcher;
# absence here is a project-state bug. Fail loudly rather than render a broken
# compose file with `image: aidc/squid:` (no tag).
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG must be set; aidc dispatcher should have exported it}"

# Defaults for optional vars so envsubst doesn't choke under `set -u`-style
# downstream usage. These are intentionally permissive — `aidc create` is the
# authoritative validator. The fallback here mirrors the product default
# (freeze; see aidc_config_defaults) for standalone renders.
: "${TAINT_RESPONSE:=freeze}"
: "${TLD_TAINTS:=false}"
: "${NOTIFY_WEBHOOK:=}"
: "${CLAUDE_MODE:=yolo}"
: "${CLAUDE_RESUME:=true}"
: "${GIT_USER_NAME:=}"
: "${GIT_USER_EMAIL:=}"

# Compute the conditional docker-socket mount. In freeze mode (the product
# default) the policy sidecar needs the host docker socket so it can
# `docker pause` the dev container. In log/notify mode the socket is omitted
# entirely to preserve isolation.
if [ "${TAINT_RESPONSE}" = "freeze" ]; then
    DOCKER_SOCK_MOUNT="- /var/run/docker.sock:/var/run/docker.sock:rw"
else
    DOCKER_SOCK_MOUNT=""
fi
export DOCKER_SOCK_MOUNT

# Optional bind-mounts set by aidc create. Defaults are empty so the lines
# collapse to nothing in the rendered YAML.
: "${CLAUDE_MEMORY_MOUNT:=}"
: "${CLAUDE_SETTINGS_MOUNT:=}"
# Plugin bridge (share_plugins): host ~/.claude/plugins/ read-only at both the
# container home path (cache resolves by convention) and its own host-absolute
# path (marketplace resolves by stored installLocation). ABS is empty when it
# would duplicate the home-path mount. See cmd-create.sh for the rationale.
: "${CLAUDE_PLUGINS_MOUNT:=}"
: "${CLAUDE_PLUGINS_MOUNT_ABS:=}"
# Transcript mirror surface (design-09, MCP-15): binds the session's
# MCP-readable transcript dir into the dev container so the in-container mirror
# can copy-forward Claude's JSONL there. Empty -> line collapses (no surfacing).
: "${TRANSCRIPT_MIRROR_MOUNT:=}"
export CLAUDE_MEMORY_MOUNT CLAUDE_SETTINGS_MOUNT TRANSCRIPT_MIRROR_MOUNT
: "${AIDC_SHARE_PLUGINS:=}"
export CLAUDE_PLUGINS_MOUNT CLAUDE_PLUGINS_MOUNT_ABS AIDC_SHARE_PLUGINS

# Declared port forwards (CLI-13), rendered as SERVICES rather than a `ports:`
# key on dev. Since NET-14 the session bridge is internal, which has no NAT --
# `ports:` on the dev service would silently do nothing. Each declared port
# instead becomes a dual-homed aidc/forwarder sidecar that publishes the host
# port on `egress` and reaches dev across `default`. Empty when none declared.
: "${PORT_FORWARDER_SERVICES:=}"
export PORT_FORWARDER_SERVICES

# NET-14 egress enforcement. "true" (default) renders the session bridge
# `internal: true`: Docker installs no NAT for it, so nothing on that bridge can
# reach the outside except through dual-homed squid. `--egress direct` renders
# "false", restoring the pre-NET-14 NATed bridge.
: "${NET_INTERNAL:=true}"
case "$NET_INTERNAL" in
    true|false) ;;
    *) printf 'compose-render: NET_INTERNAL must be true or false (got %s)\n' "$NET_INTERNAL" >&2; exit 1 ;;
esac
export NET_INTERNAL

# Container-only-path overlays (CLI-18/19). Two blocks:
#   - OVERLAY_VOLUMES_DECLARATIONS: top-level `volumes:` block additions, e.g.
#         aidc-sovl-foo-dotvenv:
#           name: aidc-sovl-foo-dotvenv
#   - OVERLAY_VOLUMES_MOUNTS: dev service `volumes:` block additions, e.g.
#         - aidc-sovl-foo-dotvenv:/workspace/foo/.venv:rw
# Both empty when no container_only_paths declared.
: "${OVERLAY_VOLUMES_DECLARATIONS:=}"
: "${OVERLAY_VOLUMES_MOUNTS:=}"
export OVERLAY_VOLUMES_DECLARATIONS OVERLAY_VOLUMES_MOUNTS

# Long-lived Claude OAuth token (from `aidc claude-token setup`). Empty when
# not configured; renders to CLAUDE_CODE_OAUTH_TOKEN="" in the container env,
# which Claude treats as unset.
: "${AIDC_CLAUDE_TOKEN:=}"
export AIDC_CLAUDE_TOKEN

# Per-session DNS (from --dns flags or dns_servers config). Two renderings
# of the same list:
#   DNS_SERVERS  space-separated, for the squid container's env (entrypoint
#                rewrites squid.conf's dns_nameservers line)
#   DNS_BLOCK    yaml "- ip" lines indented for the dev service's dns: key
# Defaults preserve the Quad9 pair (NET-03) when no override given.
: "${DNS_SERVERS:=}"
: "${DNS_BLOCK:=      - 9.9.9.9
      - 149.112.112.112}"
export DNS_SERVERS DNS_BLOCK

# Attached foreign bridge networks (NET-13). Set by `aidc create` from
# --network flags + the `networks:` config key, via aidc_render_extnet_blocks
# in scripts/lib/network.sh. Two blocks:
#   EXTNET_DECLARATIONS  top-level `networks:` additions (external: true)
#   DEV_NETWORKS_BLOCK   the dev service's `networks:` value
# The DEV_NETWORKS_BLOCK default below is the no-attachment rendering, so a
# standalone render (or any session without --network) produces exactly the
# pre-NET-13 compose file.
: "${EXTNET_DECLARATIONS:=}"
: "${DEV_NETWORKS_BLOCK:=      - default}"
export EXTNET_DECLARATIONS DEV_NETWORKS_BLOCK

# Restrict envsubst to the known variable set so unrelated `${...}` tokens
# (e.g. shell-style references inside service commands) survive untouched.
exec envsubst '${SESSION} ${PROFILE} ${REPO_PATH} ${WORKSPACE_PATH} ${AUDIT_DIR} ${HOST_CLAUDE_PROJECT_DIR} ${ENCODED_REPO} ${TAINT_RESPONSE} ${TLD_TAINTS} ${NOTIFY_WEBHOOK} ${DOCKER_SOCK_MOUNT} ${CLAUDE_MEMORY_MOUNT} ${CLAUDE_SETTINGS_MOUNT} ${CLAUDE_PLUGINS_MOUNT} ${CLAUDE_PLUGINS_MOUNT_ABS} ${AIDC_SHARE_PLUGINS} ${TRANSCRIPT_MIRROR_MOUNT} ${CLAUDE_MODE} ${CLAUDE_RESUME} ${GIT_USER_NAME} ${GIT_USER_EMAIL} ${PORT_FORWARDER_SERVICES} ${NET_INTERNAL} ${AIDC_VERSION_TAG} ${OVERLAY_VOLUMES_DECLARATIONS} ${OVERLAY_VOLUMES_MOUNTS} ${AIDC_CLAUDE_TOKEN} ${DNS_SERVERS} ${DNS_BLOCK} ${EXTNET_DECLARATIONS} ${DEV_NETWORKS_BLOCK}'
