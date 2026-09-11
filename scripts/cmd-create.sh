#!/usr/bin/env bash
# desc: Create and start a new aidc session (proxy stack + dev container).
#
# Usage: aidc create <name> [--profile P] [--repo PATH]
#
# Steps:
#   1. Validate name; fail if session already exists.
#   2. Resolve repo path; load merged config; apply CLI overrides.
#   3. Create audit dir, write config snapshot + meta.json.
#   4. Build any missing aidc/* images (squid, refresher, policy, audit,
#      dev-base) -- best-effort; if a tag already exists locally we skip.
#   5. Render the compose template into /tmp.
#   6. `docker compose up -d` the stack.
#   7. Wait for Squid healthy.
#   8. Print a session summary.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"

# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=lib/claude-state.sh
. "$AIDC_SCRIPTS/lib/claude-state.sh"
# shellcheck source=lib/network.sh
. "$AIDC_SCRIPTS/lib/network.sh"

trap 'err "command failed at line $LINENO (exit=$?)"' ERR

# ---- arg parsing -------------------------------------------------------------

NAME=""
PROFILE_OVERRIDE=""
REPO_ARG=""
WORKSPACE_ARG=""
RESUME_OVERRIDE=""   # "", "true", or "false" — empty means defer to config
PORT_FLAGS=()         # repeatable --port N or --port H:C (CLI-13)
DNS_FLAGS=()          # repeatable --dns <ip>; overrides Quad9 + config dns_servers
NETWORK_FLAGS=()      # repeatable --network <net>; merges with config networks: (NET-13)
EGRESS_OVERRIDE=""    # "", "proxied", or "direct" -- empty defers to config (NET-14)

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            [ $# -ge 2 ] || die "--profile requires a value"
            PROFILE_OVERRIDE="$2"; shift 2 ;;
        --profile=*) PROFILE_OVERRIDE="${1#--profile=}"; shift ;;
        --repo)
            [ $# -ge 2 ] || die "--repo requires a value"
            REPO_ARG="$2"; shift 2 ;;
        --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
        --workspace)
            [ $# -ge 2 ] || die "--workspace requires a value"
            WORKSPACE_ARG="$2"; shift 2 ;;
        --workspace=*) WORKSPACE_ARG="${1#--workspace=}"; shift ;;
        --resume)    RESUME_OVERRIDE="true";  shift ;;
        --no-resume) RESUME_OVERRIDE="false"; shift ;;
        --port)
            [ $# -ge 2 ] || die "--port requires a value"
            PORT_FLAGS+=("$2"); shift 2 ;;
        --port=*) PORT_FLAGS+=("${1#--port=}"); shift ;;
        --dns)
            [ $# -ge 2 ] || die "--dns requires a value"
            DNS_FLAGS+=("$2"); shift 2 ;;
        --dns=*) DNS_FLAGS+=("${1#--dns=}"); shift ;;
        --network)
            [ $# -ge 2 ] || die "--network requires a value"
            NETWORK_FLAGS+=("$2"); shift 2 ;;
        --network=*) NETWORK_FLAGS+=("${1#--network=}"); shift ;;
        --egress)
            [ $# -ge 2 ] || die "--egress requires a value (proxied|direct)"
            EGRESS_OVERRIDE="$2"; shift 2 ;;
        --egress=*) EGRESS_OVERRIDE="${1#--egress=}"; shift ;;
        -h|--help)
            cat <<'EOF'
aidc create <name> [--profile P] [--repo PATH] [--workspace PATH] [--resume|--no-resume] [--port H:C ...]

  --profile     python | node | go | rust | multi  (default: multi)
  --repo        repo to launch Claude in (becomes container's working_dir)
  --workspace   parent dir mounted into the container so sibling repos are
                visible; --repo MUST be a subdirectory of --workspace.
                If omitted, only the repo is mounted.
  --resume      pass --continue to claude on launch (resume prior conversation)
  --no-resume   start claude fresh, ignore any prior conversation
                (both override `claude_resume` from config.yaml for this session)
  --port        publish a host port to the dev container. Repeatable.
                Accepts H:C (host:container) or N (shorthand for N:N).
                Merges with `ports:` list from .aidc/config.yaml (CLI wins
                on same host port).
  --dns         DNS server IP for this session. Repeatable; order matters.
                OVERRIDES the Quad9 default and any dns_servers config list
                (no merging -- resolver order must be deterministic).
                Applies to BOTH the dev container's direct lookups AND
                squid's resolution of proxied traffic.
                Example: --dns 10.147.17.1 --dns 9.9.9.9
  --network     attach the dev container to an existing docker bridge network
                so the session can reach another stack's services by container
                name, on any port. Repeatable. Merges with the `networks:`
                config list. Survives restart, upgrade, and recreate.
                Example: --network webapp_default

                This WIDENS THE SANDBOX. Traffic to an attached network does
                not pass through squid and is invisible to taint detection,
                and the attachment is bidirectional. Attach the narrowest
                network that does the job. For a temporary attachment to a
                session that is already running, use 'aidc network <s> add'.
  --egress      proxied (default) | direct
                proxied: the session bridge is a Docker `internal` network, so
                  there is NO route to the internet except through squid. This
                  is real enforcement -- not a firewall rule the container could
                  flush, but the absence of a path.
                direct: the pre-v1.3.0 NATed bridge. The proxy still works and
                  is still the default for HTTP, but nothing STOPS a process
                  from going around it. Use only when the session genuinely
                  needs direct reachability an attached --network can't give it
                  (overlay networks like ZeroTier/Tailscale, direct DNS).
EOF
            exit 0 ;;
        --*) die "unknown flag: $1" ;;
        *)
            if [ -z "$NAME" ]; then
                NAME="$1"; shift
            else
                die "unexpected positional argument: $1"
            fi ;;
    esac
done

validate_session_name "$NAME"
require_docker
aidc_retire_auth_bridge
require_cmd jq envsubst

# ---- pre-flight: existing session? -------------------------------------------

if session_exists "$NAME"; then
    die "session '$NAME' already exists (try: aidc kill $NAME)"
fi

# ---- resolve repo path -------------------------------------------------------

if [ -z "$REPO_ARG" ]; then
    REPO_ARG="$(pwd -P)"
fi
REPO_ARG=$(translate_wsl_path "$REPO_ARG")
REPO_PATH=$(realpath_portable "$REPO_ARG")
[ -d "$REPO_PATH" ] || die "repo path does not exist: $REPO_PATH"

# Workspace: defaults to repo (only that repo is mounted). When set, the
# whole workspace dir is mounted so sibling repos are visible inside; repo
# must be a subdirectory of workspace.
if [ -n "$WORKSPACE_ARG" ]; then
    WORKSPACE_ARG=$(translate_wsl_path "$WORKSPACE_ARG")
    WORKSPACE_PATH=$(realpath_portable "$WORKSPACE_ARG")
    [ -d "$WORKSPACE_PATH" ] || die "workspace path does not exist: $WORKSPACE_PATH"
    case "$REPO_PATH/" in
        "$WORKSPACE_PATH/"*) : ;;
        *) die "--repo ($REPO_PATH) must be a subdirectory of --workspace ($WORKSPACE_PATH)" ;;
    esac
else
    WORKSPACE_PATH="$REPO_PATH"
fi

# ---- load config (per-project overrides workspace overrides global) ---------
#
# Resolution: global -> workspace (if --workspace given) -> repo. Scalars
# override; lists aggregate. The workspace path is passed only when --workspace
# was given; otherwise it's the same as repo and load_config skips the
# double-read.
load_config "$REPO_PATH" "$WORKSPACE_PATH"

if [ -n "$PROFILE_OVERRIDE" ]; then
    AIDC_PROFILE="$PROFILE_OVERRIDE"
fi
case "$AIDC_PROFILE" in
    python|node|go|rust|multi) : ;;
    *) die "invalid profile '$AIDC_PROFILE' (must be: python|node|go|rust|multi)" ;;
esac
case "$AIDC_TAINT_RESPONSE" in
    log|notify|freeze) : ;;
    *) die "invalid taint_response '$AIDC_TAINT_RESPONSE' (must be: log|notify|freeze)" ;;
esac

# ---- egress enforcement (NET-14) ---------------------------------------------
#
# proxied (default): the session bridge renders `internal: true`. Docker installs
#   no NAT for it, so there is NO route off that bridge -- squid, dual-homed onto
#   the egress network, is the only way out. This is the enforcement NET-10 always
#   claimed: not a rule inside the (privileged) dev container that it could flush,
#   but the absence of a path. Verified against a privileged container that added
#   an explicit default route via squid and still could not get out.
#
# direct: the pre-v1.3.0 NATed bridge. HTTP_PROXY still points at squid, but
#   nothing STOPS a process going around it. For sessions needing reachability an
#   attached --network cannot provide (ZeroTier/Tailscale, direct DNS).
#
# Precedence: --egress flag > `egress:` config > proxied.
_egress="${EGRESS_OVERRIDE:-}"
if [ -z "$_egress" ]; then
    _egress="${AIDC_EGRESS:-proxied}"
fi
case "$_egress" in
    proxied) NET_INTERNAL="true" ;;
    direct)  NET_INTERNAL="false" ;;
    *) die "invalid --egress/egress value '${_egress}' (must be: proxied|direct)" ;;
esac
AIDC_EGRESS="$_egress"
export AIDC_EGRESS NET_INTERNAL
if [ "$NET_INTERNAL" = "false" ]; then
    info "egress: direct -- the session bridge is NOT internal."
    info "  squid stays the configured proxy, but nothing prevents a process in the"
    info "  session from bypassing it. Blocklist and taint detection see only"
    info "  proxied traffic. Use --egress proxied for enforcement."
fi
unset _egress

# ---- attached bridge networks (NET-13) ---------------------------------------
#
# MERGE semantics (unlike --dns, which overrides): every named network is
# something the session needs to reach, so more sources means more networks.
# Sources, deduped first-wins:
#   1. --network flags (CLI), in command-line order
#   2. `networks:` list from the config layers
#
# Resolved and validated HERE -- immediately after config load, before the
# audit dir is created and long before `ensure_image` starts building. A typo'd
# network name must not cost a 20-minute dev-base build first. The rendered
# blocks are just carried forward to the compose render further down.
#
# Each network must already exist and be a bridge: compose declares them
# `external: true` and will not create them.
EXTNET_DECLARATIONS=""
DEV_NETWORKS_BLOCK="      - default"
_net_list=""
for _net in ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"}; do
    _net_list="${_net_list}${_net}
"
done
if [ -n "${AIDC_NETWORKS:-}" ]; then
    _net_list="${_net_list}${AIDC_NETWORKS}
"
fi
_net_list=$(printf '%s' "$_net_list" | _aidc_dedupe_lines)

if [ -n "$_net_list" ]; then
    while IFS= read -r _net; do
        [ -z "$_net" ] && continue
        aidc_assert_attachable "$NAME" "$_net"
    done <<EOFNET
${_net_list}
EOFNET

    # gw_priority is what keeps aidc-<session>-net as the default gateway.
    # Compose learned the key in 2.34; older ones reject the rendered file
    # outright. Fail here with the reason rather than letting compose emit a
    # schema error about a key the user never typed.
    if ! aidc_compose_supports_gw_priority; then
        err "this docker compose does not support the 'gw_priority' network key (needs 2.34+):"
        err "  $(docker compose version 2>/dev/null || printf 'unknown version')"
        err "Without it, an attached network takes over the session's default route and all"
        err "outbound traffic -- squid-proxied included -- would exit through it."
        die "upgrade docker compose, or drop --network / the networks: config entries"
    fi

    aidc_render_extnet_blocks "$_net_list"
    # Replace the raw list with the validated one so the audit dir's
    # config-snapshot.yaml (written just below) records what was actually
    # attached, including networks that came in via --network rather than config.
    AIDC_NETWORKS="$_net_list"
    export AIDC_NETWORKS
    info "networks: $(printf '%s' "$_net_list" | tr '\n' ' ')"
    info "  attached to the dev container only; the proxy sidecars stay isolated"
    info "  traffic to these networks does NOT pass through squid and is NOT"
    info "  visible to taint detection -- this is a deliberate sandbox widening"
fi
unset _net_list _net
export EXTNET_DECLARATIONS DEV_NETWORKS_BLOCK

# ---- audit dir + snapshot ----------------------------------------------------

TS=$(aidc_timestamp)
AUDIT_DIR="${AIDC_AUDIT_DIR}/${NAME}-${TS}"
mkdir -p "$AUDIT_DIR"
AUDIT_DIR=$(realpath_portable "$AUDIT_DIR")

# Config snapshot -- a frozen record of what was active at session start.
emit_loaded_config_yaml > "${AUDIT_DIR}/config-snapshot.yaml"

# Initial meta.json. Audit sidecar's finalize.sh stamps killed_at on teardown.
jq -n \
    --arg session "$NAME" \
    --arg profile "$AIDC_PROFILE" \
    --arg repo "$REPO_PATH" \
    --arg created "$(date -u +%FT%TZ)" \
    --arg taint "$AIDC_TAINT_RESPONSE" \
    '{session:$session, profile:$profile, repo:$repo, created_at:$created, taint_response:$taint}' \
    > "${AUDIT_DIR}/meta.json"

# ---- ensure images exist -----------------------------------------------------
#
# v1 strategy: if the tag isn't present, build it. Sidecars use their own
# Dockerfile in proxy/<role>/. The dev image is single-Dockerfile (one image
# all profiles) per the task shard's "Image naming convention" note.

# ensure_image lives in lib/common.sh (inventory-driven; shared with cmd-mcp
# and cmd-proxy). We build the proxy stack + dev-base eagerly here; mcp and
# forwarder are lazy-built by their respective subcommands on first use.
for _role in squid refresher policy audit dev-base; do
    ensure_image "$_role"
done
unset _role

# ---- Claude Code memory bridge -----------------------------------------------
#
# Claude Code stores per-project memory at:
#   $HOME/.claude/projects/<encoded-repo-path>/
# where <encoded-repo-path> is the absolute path with "/" and "." replaced by "-".
# We want the container's Claude to see the same memory dir, so we:
#   1. Compute the encoded name from REPO_PATH
#   2. Ensure the host dir exists (Claude expects it)
#   3. Bind-mount it at /home/vscode/.claude/projects/<encoded-repo-path>/
#      (compose template handles the mount declaration)

ENCODED_REPO=$(printf '%s' "$REPO_PATH" | sed 's|[/.]|-|g')
HOST_CLAUDE_PROJECT_DIR="${HOME}/.claude/projects/${ENCODED_REPO}"

# Memory mount toggleable via config.
CLAUDE_MEMORY_MOUNT=""
if [ "${AIDC_SHARE_MEMORY:-true}" = "true" ]; then
    mkdir -p "$HOST_CLAUDE_PROJECT_DIR"
    CLAUDE_MEMORY_MOUNT="- ${HOST_CLAUDE_PROJECT_DIR}:/home/vscode/.claude/projects/${ENCODED_REPO}:rw"
    info "memory: sharing host's per-project Claude memory dir"
else
    info "memory: NOT shared (share_memory=false); container will use its own memory"
fi

# Authentication: the container owns its Claude config directory.
#
# The compose template sets CLAUDE_CONFIG_DIR=/home/vscode/.claude, so Claude's
# credentials, its ~/.claude.json and its session state all live on the
# dev-home volume -- the same layout as Anthropic's reference devcontainer.
# Nothing auth-related is bind-mounted from the host: Claude Code replaces
# .credentials.json and .claude.json by rename on every refresh and login, so
# a single-file bind mount goes stale on one side (dangling inode,
# anthropics/claude-code#18443) and cannot be written on the other (EBUSY).
# That is what made in-container logins expire and account switches not stick.
#
# Two ways in:
#
# 1. Long-lived OAuth token (~/.config/aidc/claude-oauth-token, written by
#    `aidc claude-token setup`): injected as CLAUDE_CODE_OAUTH_TOKEN. No login,
#    no refresh -- but the token is inference-only, so Remote Control is not
#    available in sessions that use it.
# 2. Otherwise, `/login` once inside the session (aidc attach <name>). That
#    claude.ai session belongs to the container: it refreshes on the volume,
#    survives restart and upgrade, supports Remote Control, and may be a
#    different account from the host's. `aidc kill` discards it.
AIDC_CLAUDE_TOKEN_FILE="${HOME}/.config/aidc/claude-oauth-token"
AIDC_CLAUDE_TOKEN=""
USING_LONG_LIVED_TOKEN=0

if [ -f "$AIDC_CLAUDE_TOKEN_FILE" ]; then
    AIDC_CLAUDE_TOKEN=$(cat "$AIDC_CLAUDE_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    case "$AIDC_CLAUDE_TOKEN" in
        sk-ant-oat01-*)
            USING_LONG_LIVED_TOKEN=1
            info "auth: long-lived CLAUDE_CODE_OAUTH_TOKEN from ${AIDC_CLAUDE_TOKEN_FILE} (no login needed; Remote Control unavailable)"
            ;;
        *)
            info "auth: ${AIDC_CLAUDE_TOKEN_FILE} exists but token shape is invalid; ignoring it (run 'aidc claude-token setup' to fix)"
            AIDC_CLAUDE_TOKEN=""
            ;;
    esac
fi
if [ "$USING_LONG_LIVED_TOKEN" -eq 0 ]; then
    info "auth: log in inside the session once it is up ('aidc attach ${NAME}', then /login)"
fi
export AIDC_CLAUDE_TOKEN USING_LONG_LIVED_TOKEN

# Settings bridge. settings.json holds theme / output style / env.
CLAUDE_SETTINGS_MOUNT=""
HOST_CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
if [ -f "$HOST_CLAUDE_SETTINGS" ]; then
    CLAUDE_SETTINGS_MOUNT="- ${HOST_CLAUDE_SETTINGS}:/home/vscode/.claude/settings.json:rw"
    info "settings: bridged from host ~/.claude/settings.json"
else
    info "settings: no host settings.json"
fi

# Onboarding seed. ~/.claude.json holds hasCompletedOnboarding, theme, output
# style and the per-project trust decision; without it the container's first
# launch runs the theme picker and the trust dialog before the login. The
# container's own copy is seeded ONCE, from the host's file minus the host's
# account and every other project's state (lib/claude-state.sh); user-main.sh
# installs it on first start only, so whatever Claude writes there afterwards
# (the account you log in with, settings you change) is never overwritten.
CLAUDE_STATE_SEED="${AUDIT_DIR}/claude-state-seed.json"
HOST_CLAUDE_STATE="${HOME}/.claude.json"
if [ -f "$HOST_CLAUDE_STATE" ]; then
    if ( umask 0077; aidc_claude_state_seed "$HOST_CLAUDE_STATE" "$REPO_PATH" "$WORKSPACE_PATH" > "$CLAUDE_STATE_SEED" ); then
        info "state: seeded from host ~/.claude.json (onboarding + this project's trust; no account)"
    else
        rm -f "$CLAUDE_STATE_SEED"
        info "state: could not read host ~/.claude.json (Claude will run first-launch onboarding inside)"
    fi
else
    info "state: no host ~/.claude.json (Claude will run first-launch onboarding inside)"
fi

# Plugin bridge. ~/.claude/plugins/ holds the installed plugin caches AND the
# marketplace registry. Two facts about how Claude Code resolves plugins drive
# the DUAL mount below:
#   1. The plugin CACHE is found by convention (a scan of ~/.claude/plugins/
#      cache/), so it resolves once mounted at the container's home path.
#   2. The MARKETPLACE is loaded via the absolute installLocation recorded in
#      known_marketplaces.json (a host path like /Users/you/.claude/plugins/
#      marketplaces/<name>), so it only resolves when that SAME host-absolute
#      path also exists inside the container.
# We therefore mount the host plugins dir at BOTH the container home path and
# its own host-absolute path (the second is skipped when they coincide, e.g. a
# Linux host whose home is already /home/vscode). This mirrors the workspace
# mount, which is bound at ${WORKSPACE_PATH}:${WORKSPACE_PATH} for the same
# path-alignment reason.
#
# Read-only is deliberate: the plugins dir is shared mutable state across every
# Claude session (host + all containers). A container writing back would race
# the host's registry, could evict cache versions the host still uses, and would
# poison installed_plugins.json with container paths. The host stays the single
# writer; host updates flow in on the next container start. Enablement is handled
# container-locally by the entrypoint (managed-settings.json) so it never leaks
# onto the host's settings.json.
CLAUDE_PLUGINS_MOUNT=""
CLAUDE_PLUGINS_MOUNT_ABS=""
HOST_CLAUDE_PLUGINS="${HOME}/.claude/plugins"
if [ "${AIDC_SHARE_PLUGINS:-true}" = "true" ] && [ -d "$HOST_CLAUDE_PLUGINS" ]; then
    CLAUDE_PLUGINS_MOUNT="- ${HOST_CLAUDE_PLUGINS}:/home/vscode/.claude/plugins:ro"
    if [ "$HOST_CLAUDE_PLUGINS" != "/home/vscode/.claude/plugins" ]; then
        CLAUDE_PLUGINS_MOUNT_ABS="- ${HOST_CLAUDE_PLUGINS}:${HOST_CLAUDE_PLUGINS}:ro"
    fi
    info "plugins: bridged from host ~/.claude/plugins (read-only; enabled in-container)"
else
    info "plugins: NOT shared (share_plugins=false or no host plugins dir)"
fi

# ---- transcript mirror surface (design-09, MCP-15) --------------------------
#
# The MCP server is a single long-lived container and cannot take a per-session
# mount; the one RW host path it already mounts is its audit volume
# (${XDG_STATE_HOME:-~/.local/state}/aidc-mcp -> /var/log/aidc-mcp). So we
# surface this session's Claude transcripts under that volume at
# transcripts/<session>/, and bind that dir into the dev container at
# /var/aidc/transcript-out. An in-container mirror (user-main.sh) copy-forwards
# ~/.claude/projects/<enc>/*.jsonl into it every ~2s, giving MCP direct, scoped,
# per-session read access with no blanket mount of the host's ~/.claude/projects.
# See docs/design-09-callback-delivery.md. Must match cmd-mcp.sh's AUDIT_DIR base.
MCP_AUDIT_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/aidc-mcp"
MCP_TRANSCRIPTS_DIR="${MCP_AUDIT_BASE}/transcripts/${NAME}"
mkdir -p "$MCP_TRANSCRIPTS_DIR"
# Keep the whole tree private (transcripts hold conversation content).
chmod 0700 "$MCP_AUDIT_BASE" "$MCP_TRANSCRIPTS_DIR"
TRANSCRIPT_MIRROR_MOUNT="- ${MCP_TRANSCRIPTS_DIR}:/var/aidc/transcript-out:rw"
export TRANSCRIPT_MIRROR_MOUNT
info "transcript mirror: ${MCP_TRANSCRIPTS_DIR} -> dev:/var/aidc/transcript-out"

# ---- render compose ----------------------------------------------------------

COMPOSE_OUT="/tmp/aidc-${NAME}.yaml"

export SESSION="$NAME"
export PROFILE="$AIDC_PROFILE"
export REPO_PATH
export WORKSPACE_PATH
export AUDIT_DIR
export ENCODED_REPO
export HOST_CLAUDE_PROJECT_DIR
export CLAUDE_MEMORY_MOUNT
export CLAUDE_SETTINGS_MOUNT
export CLAUDE_PLUGINS_MOUNT
export CLAUDE_PLUGINS_MOUNT_ABS
export AIDC_SHARE_PLUGINS
export CLAUDE_MODE="${AIDC_CLAUDE_MODE:-yolo}"

# Resume: --resume / --no-resume override the config value for this session.
if [ -n "$RESUME_OVERRIDE" ]; then
    CLAUDE_RESUME="$RESUME_OVERRIDE"
    info "claude resume: ${CLAUDE_RESUME} (from CLI flag)"
else
    CLAUDE_RESUME="${AIDC_CLAUDE_RESUME:-true}"
fi
export CLAUDE_RESUME

# Bridge host git identity into the container. Read from the host's
# user-level git config; missing values yield empty env (the entrypoint
# skips the .gitconfig write in that case rather than producing a broken
# config).
GIT_USER_NAME="$(git config --get user.name 2>/dev/null || true)"
GIT_USER_EMAIL="$(git config --get user.email 2>/dev/null || true)"
export GIT_USER_NAME GIT_USER_EMAIL
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    info "git identity: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
else
    info "git identity: NOT bridged (set host's git config --global user.name and user.email)"
fi
export TAINT_RESPONSE="$AIDC_TAINT_RESPONSE"
export TLD_TAINTS="$AIDC_TLD_TAINTS"
export NOTIFY_WEBHOOK="$AIDC_NOTIFY_WEBHOOK"

# ---- declared port forwards (CLI-13) -----------------------------------------
#
# Sources, in dedupe order (first-wins on host port):
#   1. --port flags (CLI), in command-line order
#   2. ports: list from .aidc/config.yaml (project) and ~/.config/aidc/config.yaml (global)
#
# Spec accepted as "H:C" or "N" (shorthand for "N:N"). Validation is a cheap
# regex bound to 1-5 digits per side; docker compose enforces the real range
# at create time.
PORT_FORWARDER_SERVICES=""
# Bash 3.2 doesn't support associative arrays; track seen host ports in a
# delimited string. Wrap with spaces so substring tests match whole tokens.
_ports_seen=" "
_ports_yaml=""
_ports_summary=""
_validate_port_pair() {
    case "$1" in
        [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}
# Each declared port becomes a dual-homed aidc/forwarder SERVICE rather than a
# `ports:` entry on dev. Since NET-14 the session bridge is `internal`, which
# has no NAT, so publishing from dev itself would silently do nothing. The
# sidecar publishes on `egress` and reaches dev across `default`.
#
# Named aidc-<session>-dfwd-<hostport> ("declared forward"), deliberately
# distinct from the adhoc aidc-<session>-fwd-<hostport> that `aidc proxy`
# creates -- remove_adhoc_forwards() filters on "-fwd-", which does not match
# "-dfwd-", so a restart/upgrade sweep never touches these.
_emit_port_pair() {
    local spec="$1" host_p container_p
    case "$spec" in
        *:*) host_p="${spec%%:*}"; container_p="${spec##*:}" ;;
        *)   host_p="$spec";       container_p="$spec" ;;
    esac
    _validate_port_pair "$host_p" || die "invalid host port in --port/config entry: ${spec}"
    _validate_port_pair "$container_p" || die "invalid container port in --port/config entry: ${spec}"
    case "$_ports_seen" in
        *" ${host_p} "*) return 0 ;;   # first-wins; later duplicates dropped silently
    esac
    _ports_seen="${_ports_seen}${host_p} "
    _ports_yaml="${_ports_yaml}
  dfwd-${host_p}:
    image: aidc/forwarder:${AIDC_VERSION_TAG}
    container_name: aidc-${NAME}-dfwd-${host_p}
    networks:
      default: {}
      egress: {}
    ports:
      - \"${host_p}:${container_p}\"
    command:
      - \"TCP-LISTEN:${container_p},fork,reuseaddr\"
      - \"TCP:aidc-${NAME}-dev:${container_p}\"
    depends_on:
      - dev
    restart: unless-stopped
"
    if [ -z "$_ports_summary" ]; then
        _ports_summary="${host_p}:${container_p}"
    else
        _ports_summary="${_ports_summary},${host_p}:${container_p}"
    fi
}
for _spec in ${PORT_FLAGS[@]+"${PORT_FLAGS[@]}"}; do
    _emit_port_pair "$_spec"
done
if [ -n "${AIDC_PORTS:-}" ]; then
    while IFS= read -r _spec; do
        [ -z "$_spec" ] && continue
        _emit_port_pair "$_spec"
    done <<EOF
${AIDC_PORTS}
EOF
fi
if [ -n "$_ports_yaml" ]; then
    PORT_FORWARDER_SERVICES=$(printf '%s' "$_ports_yaml")
    info "ports: ${_ports_summary} (via dual-homed forwarder sidecars)"
fi
unset _ports_seen _ports_yaml _ports_summary _spec
export PORT_FORWARDER_SERVICES

# ---- per-session DNS (--dns flags / dns_servers config) ----------------------
#
# OVERRIDE semantics, not merge: DNS resolver order must be deterministic.
#   - CLI --dns flags given        -> use exactly those, in order
#   - else config dns_servers set  -> use exactly those (aggregated across
#                                     global/workspace/repo config layers)
#   - else                         -> Quad9 default (NET-03 threat-intel DNS)
#
# The chosen list applies to BOTH resolution paths:
#   DNS_BLOCK    dev container's `dns:` (direct lookups: db conns, ssh, dig)
#   DNS_SERVERS  squid's dns_nameservers (proxied HTTP/HTTPS traffic)
#
# NOTE: overriding DNS trades away Quad9's DNS-level malware blocking for
# this session. The squid blocklist (primary enforcement) still applies.
DNS_SERVERS=""
DNS_BLOCK=""
_dns_list=""
if [ "${#DNS_FLAGS[@]}" -gt 0 ] 2>/dev/null; then
    _dns_list=$(printf '%s\n' "${DNS_FLAGS[@]}")
elif [ -n "${AIDC_DNS_SERVERS:-}" ]; then
    _dns_list="$AIDC_DNS_SERVERS"
fi
if [ -n "$_dns_list" ]; then
    # Validate each entry: IPv4/IPv6 charset only.
    while IFS= read -r _ip; do
        [ -z "$_ip" ] && continue
        case "$_ip" in
            *[!0-9a-fA-F:.]*) die "invalid DNS server address: '${_ip}'" ;;
        esac
    done <<EOFDNS
${_dns_list}
EOFDNS
    DNS_SERVERS=$(printf '%s' "$_dns_list" | tr '\n' ' ' | sed 's/ $//')
    DNS_BLOCK=$(printf '%s\n' "$_dns_list" | awk 'NF { printf "      - %s\n", $0 }' | sed '$ s/$//')
    # Strip trailing newline from DNS_BLOCK (command substitution does it).
    info "dns: ${DNS_SERVERS} (overriding Quad9 default for this session)"
fi
unset _dns_list _ip
export DNS_SERVERS DNS_BLOCK

# ---- container-only-path overlays (CLI-18/19) -------------------------------
#
# For each entry in AIDC_CONTAINER_ONLY_PATHS, expand globs against the
# workspace root, then declare a session-scoped Docker named volume per
# resolved path and mount it at that path in the dev container. Result:
# the container sees an empty dir there while the host's same-named dir
# is invisible from inside.
#
# Slug rules (per task-16):
#   - Path is relative to workspace; convert to a Docker-safe slug.
#   - Replace '/' with '-'.
#   - Replace leading '.' with 'dot' (so .venv -> dotvenv).
#   - Lowercase only; underscores and digits pass through.
#   - Reject any other char with a clear error.
OVERLAY_VOLUMES_DECLARATIONS=""
OVERLAY_VOLUMES_MOUNTS=""

_aidc_slug_path() {
    # Convert relative path -> Docker-safe slug.
    local p="$1"
    # Strip leading slash if any (shouldn't be, but defensive).
    p="${p#/}"
    # Leading dot -> "dot".
    if [ "${p#.}" != "$p" ]; then
        p="dot${p#.}"
    fi
    # / -> -
    p="${p//\//-}"
    # Validate charset: lowercase + digits + underscore + dash.
    case "$p" in
        *[!a-z0-9_-]*|"")
            die "container_only_paths: slug '${p}' contains characters outside [a-z0-9_-] after normalization"
            ;;
    esac
    printf '%s' "$p"
}

if [ -n "${AIDC_CONTAINER_ONLY_PATHS:-}" ]; then
    # Validate raw patterns BEFORE expanding. Reject ** (recursive glob is
    # a footgun), absolute paths, and .. traversal.
    while IFS= read -r _pat; do
        [ -z "$_pat" ] && continue
        if printf '%s' "$_pat" | grep -q '\*\*'; then
            die "container_only_paths '${_pat}' uses ** (recursive glob is not supported)"
        fi
        if printf '%s' "$_pat" | grep -q '^/'; then
            die "container_only_paths '${_pat}' must be relative to the workspace"
        fi
        if printf '%s' "$_pat" | grep -q '\.\.'; then
            die "container_only_paths '${_pat}' must not contain .."
        fi
    done <<EOFCO_VAL
${AIDC_CONTAINER_ONLY_PATHS}
EOFCO_VAL
    unset _pat

    # Annotate each pattern with whether it has glob metacharacters BEFORE
    # entering the expansion subshell -- bash's parser doesn't love case
    # patterns containing `*` and `?` inside nested $(...) command
    # substitutions. Format: "GLOB|<pattern>" or "LIT|<pattern>".
    _annotated=$(
        while IFS= read -r _g; do
            [ -z "$_g" ] && continue
            if printf '%s' "$_g" | grep -q '[*?]'; then
                printf 'GLOB|%s\n' "$_g"
            else
                printf 'LIT|%s\n' "$_g"
            fi
        done <<EOFCO_ANN
${AIDC_CONTAINER_ONLY_PATHS}
EOFCO_ANN
    )

    # Expand globs in a subshell so shopt nullglob doesn't leak. For each
    # entry:
    #   - LIT: emit pattern literally (the container creates the dir at
    #     mount time -- handles "I declared .venv before running uv sync").
    #   - GLOB: expand against the workspace; emit matches only. No match
    #     means no overlay for that pattern (correct semantics: "wherever
    #     these match" -- if nothing matches, nothing to overlay).
    _expanded=$(
        cd "$WORKSPACE_PATH" || exit 1
        shopt -s nullglob
        while IFS='|' read -r _kind _pat; do
            [ -z "$_pat" ] && continue
            if [ "$_kind" = "GLOB" ]; then
                for _match in $_pat; do
                    printf '%s\n' "$_match"
                done
            else
                printf '%s\n' "$_pat"
            fi
        done <<EOFCO
${_annotated}
EOFCO
    )
    if [ -n "$_expanded" ]; then
        # Dedupe and accumulate volume declarations + mount lines.
        _seen_slug=" "
        _decls=""
        _mounts=""
        _expanded_resolved=""
        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            slug=$(_aidc_slug_path "$rel_path")
            # Dedupe by slug (in case workspace + project lists overlap).
            case "$_seen_slug" in
                *" ${slug} "*) continue ;;
            esac
            _seen_slug="${_seen_slug}${slug} "
            vol_name="aidc-sovl-${NAME}-${slug}"
            mount_path="${WORKSPACE_PATH}/${rel_path}"
            _decls="${_decls}  ${vol_name}:
    name: ${vol_name}
"
            _mounts="${_mounts}      - ${vol_name}:${mount_path}:rw
"
            _expanded_resolved="${_expanded_resolved}${rel_path}
"
        done <<<"$_expanded"
        if [ -n "$_decls" ]; then
            OVERLAY_VOLUMES_DECLARATIONS=$(printf '%s' "$_decls")
            OVERLAY_VOLUMES_MOUNTS=$(printf '%s' "$_mounts")
            # Replace the raw glob list with the post-expansion resolved list
            # so the audit dir's config-snapshot.yaml reflects what was
            # actually mounted.
            AIDC_CONTAINER_ONLY_PATHS=$(printf '%s' "$_expanded_resolved" | _aidc_dedupe_lines)
            export AIDC_CONTAINER_ONLY_PATHS
            info "container-only paths: $(printf '%s' "$AIDC_CONTAINER_ONLY_PATHS" | tr '\n' ' ')"
        fi
        unset _seen_slug _decls _mounts _expanded_resolved
    fi
    unset _expanded
fi
export OVERLAY_VOLUMES_DECLARATIONS OVERLAY_VOLUMES_MOUNTS

# The rendered compose embeds CLAUDE_CODE_OAUTH_TOKEN (and other secrets) and
# lives in world-readable /tmp. Create it 0600 in a umask subshell BEFORE any
# secret is written, so it never exists world-readable even briefly. Re-asserted
# after the yq splice below (which rewrites the file in place and can reset mode).
( umask 0077
  "$AIDC_ROOT/proxy/compose-render.sh" \
      < "$AIDC_ROOT/proxy/compose.yaml.template" \
      > "$COMPOSE_OUT" )
chmod 600 "$COMPOSE_OUT"

# Inject aidc.session / aidc.role labels onto every service so list/status
# can discover sessions even when container_name is unknown. The template
# doesn't include labels, so we splice them in post-render via yq if
# available; otherwise we fall back to appending via a YAML-aware insertion.
# Best-effort: if either path fails we still proceed (label is a nicety,
# not load-bearing for container_name lookups).
if command -v yq >/dev/null 2>&1; then
    for svc in squid refresher policy audit dev; do
        # Compute the role label. Sidecar role = service name; dev = "dev".
        yq eval -i "
            .services.${svc}.labels[\"aidc.session\"] = \"${NAME}\" |
            .services.${svc}.labels[\"aidc.role\"] = \"${svc}\" |
            .services.${svc}.labels[\"aidc.profile\"] = \"${AIDC_PROFILE}\"
        " "$COMPOSE_OUT" 2>/dev/null || true
    done
fi

# Re-assert 0600: yq -i rewrites the file in place, which can reset its mode to
# the umask default (0644). The file carries CLAUDE_CODE_OAUTH_TOKEN.
chmod 600 "$COMPOSE_OUT"

# ---- bring up the stack ------------------------------------------------------

PROJECT=$(compose_project_name "$NAME")

# Ensure the cross-session pyenv-versions volume exists. The compose file
# declares it as external: true, which means compose won't auto-create it
# (deliberately — we want it shared across every aidc session, never owned
# by a single compose project).
if ! docker volume inspect aidc-pyenv-versions >/dev/null 2>&1; then
    info "creating shared volume aidc-pyenv-versions (first time on this host)"
    docker volume create aidc-pyenv-versions >/dev/null
fi

info "starting compose project: $PROJECT"
docker compose -p "$PROJECT" -f "$COMPOSE_OUT" up -d

# ---- wait for Squid healthy --------------------------------------------------

SQUID_CT="$(container_name "$NAME" squid)"
info "waiting for $SQUID_CT to report healthy..."
HEALTHY=0
i=0
while [ $i -lt 60 ]; do
    status=$(docker inspect --format '{{.State.Health.Status}}' "$SQUID_CT" 2>/dev/null || printf 'none')
    case "$status" in
        healthy)   HEALTHY=1; break ;;
        unhealthy) die "squid reported unhealthy; check: docker logs $SQUID_CT" ;;
    esac
    i=$((i + 1))
    sleep 1
done
[ "$HEALTHY" -eq 1 ] || die "squid did not become healthy within 60s"

# ---- wait for dev container's entrypoint to finish setup --------------------
#
# Squid being healthy doesn't mean the dev container is ready. The entrypoint
# still has to: start inner dockerd, write the gitconfig, maybe `pyenv install`
# a Python version the repo asked for (this is the slow case — 2-5 min source
# compile), then start tmux. Until tmux is up, `aidc attach` returns "no sessions".
#
# Poll for tmux. Surface the latest entrypoint log line every few seconds so
# the user can see what's taking the time (pyenv compile is the usual culprit).

DEV_CT="$(container_name "$NAME" dev)"
info "waiting for $DEV_CT setup to finish..."
if ! wait_for_dev_ready "$NAME"; then
    die "dev container did not become ready in time; check 'docker logs $DEV_CT'"
fi

# ---- summary -----------------------------------------------------------------

if [ "${USING_LONG_LIVED_TOKEN:-0}" = "1" ]; then
    CLAUDE_AUTH_LINE="  claude:     long-lived OAuth token (no login; Remote Control unavailable)"
else
    CLAUDE_AUTH_LINE="  claude:     log in once inside: 'aidc attach ${NAME}', then /login (persists across restart/upgrade)"
fi

if [ "$WORKSPACE_PATH" != "$REPO_PATH" ]; then
    WORKSPACE_LINE="
  workspace:  ${WORKSPACE_PATH}"
else
    WORKSPACE_LINE=""
fi

cat <<EOF
Session '${NAME}' created.
  profile:    ${AIDC_PROFILE}
  repo:       ${REPO_PATH}${WORKSPACE_LINE}
  audit:      ${AUDIT_DIR}
  memory:     ${HOST_CLAUDE_PROJECT_DIR}
${CLAUDE_AUTH_LINE}
  compose:    ${COMPOSE_OUT}
Attach with: aidc attach ${NAME}
EOF
