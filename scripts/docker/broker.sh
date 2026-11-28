# shellcheck shell=bash
# The user's Claude account broker on the Docker backend (K8S-27, K8S-28; owner ruling 2026-11-28,
# "Account switching on Docker too"; docs/design-12-kubernetes.md, "The broker on Docker").
#
# The same aidc/broker image and claude-broker program as in a cluster. What differs is only what
# Docker is:
#   - the broker is the container aidc-claude-broker, one per machine user (a Docker daemon serves
#     one user's aidc, as the git container aidc-git-dev does);
#   - the accounts' logins, refresh tokens included, are on the volume aidc-claude-accounts, which
#     only the broker mounts (the cluster's claude-accounts claim);
#   - every broker-managed session's Claude config dir is its own folder of the volume
#     aidc-claude-config (the cluster's claude-config claim), mounted at /home/vscode/.claude by
#     that session's dev container alone (a volume subpath); the broker mounts it whole and writes
#     the active account's credentials, without the refresh token, into each folder by rename, so
#     a switch reaches running sessions on their next message, conversation kept;
#   - its settings (claude_accounts, claude_account_switch) are a file copied into the container
#     when it is made (`aidc claude broker start` makes it again with changed settings);
#   - its network is a bridge of its own (aidc-claude-broker-net) with Quad9 for names and nothing
#     published: nothing connects in. It runs Claude Code only for a login and for a fixed
#     one-word prompt with no tools.
# Sessions made with no broker running keep today's ways (their own /login, or the long-lived
# token); a session's choice is in its compose file, so restart and upgrade keep it.
#
# Sourced by scripts/docker/lib.sh (and through it by aidc create, aidc kill, aidc git setup and
# scripts/docker/claude.sh). Sources the shared libraries itself; its functions report their own
# failures (on stderr) and return non-zero, never die.

# shellcheck source=../lib/common.sh
. "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}/lib/common.sh"
# shellcheck source=../lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"

# shellcheck disable=SC2034  # read by the scripts that source this
DK_BROKER_CT=aidc-claude-broker
DK_BROKER_NET=aidc-claude-broker-net
DK_BROKER_ACCOUNTS_VOLUME=aidc-claude-accounts
DK_CLAUDE_CONFIG_VOLUME=aidc-claude-config
# Where the broker mounts the two volumes (broker/claude-broker.sh: BROKER_HOME, BROKER_ACCESS),
# and its settings: the same paths as in a cluster.
DK_BROKER_HOME=/var/lib/claude-broker
DK_BROKER_ACCESS=/var/aidc/claude-config
DK_BROKER_CONFIG_DIR=/etc/claude-broker
# The git agent's folder of aidc-claude-config (claude-broker.sh: BROKER_GIT_SESSION).
DK_BROKER_GIT_FOLDER=git

dk_broker_image() { printf 'aidc/broker:%s' "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"; }

# dk_broker_state: RUNNING or NOT RUNNING (stopped, or never started); returns 2, saying why on
# stdout, when docker did not answer. Never NOT RUNNING for a daemon that did not answer.
dk_broker_state() {
    local out
    if out=$(docker inspect -f '{{.State.Running}}' "$DK_BROKER_CT" 2>&1); then
        if [ "$out" = true ]; then printf 'RUNNING'; else printf 'NOT RUNNING'; fi
        return 0
    fi
    case "$out" in *"No such"*|*"no such"*) printf 'NOT RUNNING'; return 0 ;; esac
    printf 'docker did not answer: %s' "$(printf '%s' "$out" | head -n1)"
    return 2
}

# dk_broker_exec <claude-broker args...>: run claude-broker in the broker's container (as its own
# user, the image's), with no stdin. dk_broker_exec_tty: the same on this terminal, for Claude's
# own login.
dk_broker_exec() { docker exec "$DK_BROKER_CT" claude-broker "$@" </dev/null; }
dk_broker_exec_tty() { docker exec -it -e "TERM=${TERM:-xterm-256color}" "$DK_BROKER_CT" claude-broker "$@"; }

# The volumes' step, a one-shot root container from the broker image with no network and only a
# chown's capabilities: both volumes the broker's (uid 1000, the session user's uid) and closed to
# others (0700). A new volume is root-owned; nothing else in it is touched.
# shellcheck disable=SC2016  # run by the step's shell
DK_BROKER_SEED_SCRIPT='set -eu
chown 1000:1000 /accounts /config && chmod 0700 /accounts /config
echo seeded'

# dk_broker_volumes: the two volumes, made when missing, and readied. Returns 1, saying why.
dk_broker_volumes() {
    local v
    for v in "$DK_BROKER_ACCOUNTS_VOLUME" "$DK_CLAUDE_CONFIG_VOLUME"; do
        docker volume inspect "$v" >/dev/null 2>&1 \
            || docker volume create --label aidc.claude=volume "$v" >/dev/null \
            || { err "could not create the volume ${v}"; return 1; }
    done
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN --cap-add FOWNER \
        --security-opt no-new-privileges \
        -v "${DK_BROKER_ACCOUNTS_VOLUME}:/accounts" -v "${DK_CLAUDE_CONFIG_VOLUME}:/config" \
        --entrypoint /bin/sh "$(dk_broker_image)" -c "$DK_BROKER_SEED_SCRIPT" >/dev/null \
        || { err "could not prepare the Claude account broker's volumes"; return 1; }
}

# dk_broker_start: the broker's image (built when missing), volumes, network and container, made
# again with the current settings; waits until it runs. Accounts and sessions' folders are kept
# (volumes); sessions keep their last credentials meanwhile. Returns 1, saying why.
dk_broker_start() {
    local cfg i
    ensure_image broker || { err "could not build $(dk_broker_image)"; return 1; }
    dk_broker_volumes || return 1
    if ! docker network inspect "$DK_BROKER_NET" >/dev/null 2>&1; then
        docker network create --label aidc.claude=network "$DK_BROKER_NET" >/dev/null \
            || { err "could not create the network ${DK_BROKER_NET}"; return 1; }
    fi
    docker rm -f "$DK_BROKER_CT" >/dev/null 2>&1 || true
    docker create --name "$DK_BROKER_CT" --hostname claude-broker --restart unless-stopped \
        --network "$DK_BROKER_NET" --dns 9.9.9.9 --dns 149.112.112.112 \
        --cap-drop ALL --security-opt no-new-privileges \
        --label aidc.claude=broker --label "aidc.user=$(id -un 2>/dev/null || echo unknown)" \
        -e "BROKER_HOME=${DK_BROKER_HOME}" -e "BROKER_ACCESS=${DK_BROKER_ACCESS}" \
        -e "BROKER_CONFIG=${DK_BROKER_CONFIG_DIR}/config.json" \
        -v "${DK_BROKER_ACCOUNTS_VOLUME}:${DK_BROKER_HOME}" -v "${DK_CLAUDE_CONFIG_VOLUME}:${DK_BROKER_ACCESS}" \
        "$(dk_broker_image)" >/dev/null \
        || { err "could not make the Claude account broker's container"; return 1; }
    # Its settings, copied in by the docker client (no path of this machine is mounted, so it
    # works the same from aidc-mcp's container). Names and thresholds only: readable (0644).
    cfg=$(mktemp -d) || { err "cannot make a temporary folder"; return 1; }
    if ! { chmod 0755 "$cfg" && aidc_claude_broker_config_json > "$cfg/config.json" && chmod 0644 "$cfg/config.json" \
            && docker cp "$cfg" "${DK_BROKER_CT}:${DK_BROKER_CONFIG_DIR}" >/dev/null; }; then
        rm -rf "$cfg"
        err "could not give the Claude account broker its settings"
        return 1
    fi
    rm -rf "$cfg"
    docker start "$DK_BROKER_CT" >/dev/null || { err "could not start the Claude account broker; see: docker logs ${DK_BROKER_CT}"; return 1; }
    for i in $(seq 30); do
        [ "$(docker inspect -f '{{.State.Running}}' "$DK_BROKER_CT" 2>/dev/null)" = true ] && return 0
        [ "$i" -lt 30 ] && sleep 1
    done
    err "the Claude account broker did not stay up; see: docker logs ${DK_BROKER_CT}"
    return 1
}

# dk_broker_stop: stops it; the container, volumes and sessions' folders are kept (sessions keep
# the last credentials until they expire). Returns 1 when docker refused.
dk_broker_stop() {
    case "$(dk_broker_state 2>/dev/null)" in RUNNING) ;; *) return 0 ;; esac
    docker stop "$DK_BROKER_CT" >/dev/null || { err "could not stop the Claude account broker"; return 1; }
}

# dk_claude_session_ready <session>: when the broker runs, the session's folder of
# aidc-claude-config, made and given the active account's credentials now, so its Claude starts
# logged in; sets DK_CLAUDE_VIA=broker and the compose pieces (CLAUDE_CONFIG_MOUNT,
# CLAUDE_CONFIG_VOLUME_DECL, CLAUDE_BROKER=1). Otherwise DK_CLAUDE_VIA=none and the pieces empty:
# the session keeps its Claude config dir on its dev-home volume (its own /login, or the
# long-lived token). Never fails: a broker that does not answer leaves the session on today's way.
dk_claude_session_ready() {
    local session="$1" state rc=0
    DK_CLAUDE_VIA=none CLAUDE_CONFIG_MOUNT="" CLAUDE_CONFIG_VOLUME_DECL="" CLAUDE_BROKER=""
    state=$(dk_broker_state) || rc=$?
    if [ "$rc" != 0 ]; then
        info "Claude: cannot tell whether your account broker runs (${state}); ${session} logs in itself"
        return 0
    fi
    [ "$state" = RUNNING ] || return 0
    # The folder is a volume subpath: Docker Engine 26 or later.
    if ! dk_engine_has_subpath; then
        info "Claude: your account broker runs, but this Docker Engine ($(docker version -f '{{.Server.Version}}' 2>/dev/null || echo unknown)) cannot mount a session's folder (needs 26 or later); ${session} logs in itself"
        return 0
    fi
    if ! dk_broker_exec session "$session" >/dev/null 2>&1; then
        info "Claude: your account broker did not answer for ${session}; it logs in itself (aidc attach ${session}, then /login)"
        return 0
    fi
    # shellcheck disable=SC2034  # read by aidc create
    DK_CLAUDE_VIA=broker CLAUDE_BROKER=1
    # shellcheck disable=SC2034  # read by aidc create (compose-render.sh)
    CLAUDE_CONFIG_MOUNT="- {type: volume, source: claude-config, target: /home/vscode/.claude, volume: {subpath: ${session}}}"
    # shellcheck disable=SC2034  # read by aidc create (compose-render.sh)
    CLAUDE_CONFIG_VOLUME_DECL="  claude-config:
    name: ${DK_CLAUDE_CONFIG_VOLUME}
    external: true"
    info "Claude: ${session} uses your account broker's active account (aidc claude account list)"
}

# dk_engine_has_subpath: 0 when the Docker Engine mounts volume subpaths (26.0 or later).
dk_engine_has_subpath() {
    local v
    v=$(docker version -f '{{.Server.Version}}' 2>/dev/null) || return 1
    case "${v%%.*}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${v%%.*}" -ge 26 ]
}

# dk_claude_create_cleanup <session> <exit-status> <compose-started 0|1>: aidc create's exit trap.
# A create that failed after the broker made the session's folder and before compose was asked to
# start the session leaves nothing aidc kill would find: the folder is forgotten here. Once
# compose was asked, the session's containers may hold the folder, and aidc kill removes it.
dk_claude_create_cleanup() {
    [ "${DK_CLAUDE_VIA:-none}" = broker ] && [ "$2" != 0 ] && [ "$3" != 1 ] || return 0
    dk_claude_session_forget "$1"
}

# dk_claude_session_forget <session>: the killed session's folder of aidc-claude-config removed:
# by the broker when it runs (under its lock, so no pass writes it again), else, or for what the
# broker cannot remove (a folder Docker made root-owned for a nested mount), by a one-shot root
# container from the broker image with no network. A failure is said, never fatal.
dk_claude_session_forget() {
    local session="$1"
    docker volume inspect "$DK_CLAUDE_CONFIG_VOLUME" >/dev/null 2>&1 || return 0
    if [ "$(dk_broker_state 2>/dev/null)" = RUNNING ] && dk_broker_exec forget "$session" >/dev/null 2>&1; then
        return 0
    fi
    if ! docker image inspect "$(dk_broker_image)" >/dev/null 2>&1; then
        info "Claude: could not remove ${session}'s Claude config dir ($(dk_broker_image) is not built); a session made again with that name would find it"
        return 0
    fi
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE \
        --security-opt no-new-privileges -v "${DK_CLAUDE_CONFIG_VOLUME}:/config" \
        --entrypoint /bin/rm "$(dk_broker_image)" -rf -- "/config/${session}" >/dev/null 2>&1 \
        || info "Claude: could not remove ${session}'s Claude config dir (in the volume ${DK_CLAUDE_CONFIG_VOLUME})"
    return 0
}

# dk_git_uses_broker: 0 when the git container's Claude config dir should be its folder of
# aidc-claude-config: the broker runs now, or the git container running now has it already
# (moved once, it stays, so a start while the broker is stopped keeps its history); never on an
# engine that cannot mount a volume subpath.
dk_git_uses_broker() {
    dk_engine_has_subpath || return 1
    [ "$(dk_broker_state 2>/dev/null)" = RUNNING ] && return 0
    docker inspect -f '{{range .Mounts}}{{.Name}}|{{.Destination}} {{end}}' "${DK_GIT_CT:-aidc-git-dev}" 2>/dev/null \
        | grep -q "${DK_CLAUDE_CONFIG_VOLUME}|/home/git/.claude"
}

# The git agent's folder, as the git pod's init steps make it: as root, made and given to the
# agent (2000) with the session group (1000, the broker's: it writes the credentials as that
# group, of which the git user is a member), 0770; then, as the agent with no capabilities,
# filled once (.aidc-seeded) from the Claude config its home had, its own history included.
# shellcheck disable=SC2016  # run by the steps' shells
DK_GIT_CLAUDE_DIR_SCRIPT='set -eu
d=/config/git
[ ! -L "$d" ] || rm -f "$d"
mkdir -p "$d" && chown 2000:1000 "$d" && chmod 0770 "$d"
echo made'
# shellcheck disable=SC2016
DK_GIT_CLAUDE_SEED_SCRIPT='set -eu
d=/claude-config-own
if [ ! -e "$d/.aidc-seeded" ]; then
    if [ -d /seed/.claude ]; then (cd /seed/.claude && tar -cf - .) | tar -C "$d" -xf -; fi
    mkdir -p "$d/projects" && : > "$d/.aidc-seeded"
fi
echo seeded'

# dk_git_claude_ready: the git agent's folder made and filled, and, when the broker runs, its
# credentials written now. Returns 1, saying why, when the folder could not be made.
dk_git_claude_ready() {
    local img="aidc/gitctl:${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN --cap-add FOWNER \
        --cap-add DAC_OVERRIDE --security-opt no-new-privileges -v "${DK_CLAUDE_CONFIG_VOLUME}:/config" \
        --entrypoint /bin/sh "$img" -c "$DK_GIT_CLAUDE_DIR_SCRIPT" >/dev/null \
        || { err "could not make the git agent's Claude config dir"; return 1; }
    docker run --rm --network none --user 2000:2000 --cap-drop ALL --security-opt no-new-privileges \
        -v aidc-git-home:/seed:ro \
        --mount "type=volume,src=${DK_CLAUDE_CONFIG_VOLUME},dst=/claude-config-own,volume-subpath=${DK_BROKER_GIT_FOLDER}" \
        --entrypoint /bin/sh "$img" -c "$DK_GIT_CLAUDE_SEED_SCRIPT" >/dev/null \
        || { err "could not fill the git agent's Claude config dir"; return 1; }
    if [ "$(dk_broker_state 2>/dev/null)" = RUNNING ]; then
        dk_broker_exec session "$DK_BROKER_GIT_FOLDER" >/dev/null 2>&1 \
            || info "Claude: your account broker did not answer for the git agent; it writes its login within a minute"
    fi
    return 0
}
