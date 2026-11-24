# shellcheck shell=bash
# aidc's git container on the Docker backend (docs/design-12-kubernetes.md, "Git": one design on
# both backends, owner rulings 2026-11-24).
#
# The same aidc/gitctl image, gitctl and request watcher as in a cluster. What differs is only
# what Docker is:
#   - the container is aidc-git-dev, labelled as the dev container of a session named git, so
#     `aidc list|attach|logs|status` and aidc's MCP server find the git agent like any session;
#   - its homes are volumes (aidc-git-home: the agent's home and Claude; aidc-git-cred: the
#     GitHub login, gitcred's; aidc-git-run: gitrun's private copies), started from the image's
#     own folders the first time Docker mounts them;
#   - the request folder is the aidc-git-requests volume at /var/aidc/git-requests, mounted
#     into sessions made after setup at the same path;
#   - it works on the user's own working copies (owner ruling 2026-11-24, "On Docker the git
#     container works on the user's own working copies"): only those the user added (aidc repo
#     add), each mounted at its own path, the one sessions see; never cloned, locked or re-owned;
#   - its network is internal (no route out), with one proxy beside it (aidc-git-squid, alias
#     aidc-proxy) that reaches public addresses only and resolves through Quad9: the intent of
#     the git pod's NetworkPolicy. Nothing connects in.
#
# Sourced by scripts/docker/*.sh. Sources the shared libraries itself.

# shellcheck source=../lib/common.sh
. "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}/lib/common.sh"
# shellcheck source=../lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=../lib/git-common.sh
. "$AIDC_SCRIPTS/lib/git-common.sh"

# The git agent's session name, reserved on both backends, and the names of what setup makes.
# shellcheck disable=SC2034  # read by the scripts that source this
DK_GIT_SESSION=git
DK_GIT_CT=aidc-git-dev
# shellcheck disable=SC2034  # read by the scripts that source this
DK_GIT_PROXY=aidc-git-squid
DK_GIT_NET=aidc-git-net
# shellcheck disable=SC2034  # read by the scripts that source this
DK_GIT_EGRESS=aidc-git-egress
DK_GIT_REQUESTS_VOLUME=aidc-git-requests
DK_GIT_REQUESTS=/var/aidc/git-requests
# shellcheck disable=SC2034  # read by the scripts that source this
DK_GIT_VOLUMES="aidc-git-home aidc-git-cred aidc-git-run ${DK_GIT_REQUESTS_VOLUME}"

# dk_git_settings: the global config's `git:` block into AIDC_DK_GIT_MODE (git.mode: ask, the
# default, or rules) and AIDC_DK_GIT_STORAGE_WARN (git.storage_warn, default 1Gi). Dies on a
# mode that is neither.
dk_git_settings() {
    local cfg m="" w=""
    cfg=$(_aidc_global_config_file)
    if [ -n "$cfg" ]; then
        if _aidc_has_yq; then
            m=$(aidc_yq '.git.mode' "$cfg" 2>/dev/null || printf '')
            w=$(aidc_yq '.git.storage_warn' "$cfg" 2>/dev/null || printf '')
            [ "$m" = null ] && m=""
            [ "$w" = null ] && w=""
        else
            m=$(_aidc_yaml_nested "$cfg" git mode)
            w=$(_aidc_yaml_nested "$cfg" git storage_warn)
        fi
    fi
    AIDC_DK_GIT_MODE="${m:-ask}"
    # shellcheck disable=SC2034  # read by git-status.sh
    AIDC_DK_GIT_STORAGE_WARN="${w:-1Gi}"
    case "$AIDC_DK_GIT_MODE" in ask|rules) ;; *) die "git.mode '${AIDC_DK_GIT_MODE}' is not ask or rules" ;; esac
}

# dk_git_disk: the user's home on this machine, as the git container and sessions see it (the
# same path: Docker mounts host paths at their own spelling). Request paths must be inside it.
dk_git_disk() {
    local h
    h=$(realpath_portable "$(aidc_host_home)") || h="$(aidc_host_home)"
    printf '%s' "${h%/}"
}

# dk_git_path_ok <path>: an absolute path of plain names (letters, digits, '.', '_', '-'), no
# . or .. part, strictly inside the user's home: what the request watcher accepts.
dk_git_path_ok() {
    local p="$1" home c parts
    home=$(dk_git_disk)
    case "$p" in "${home}/"?*) ;; *) return 1 ;; esac
    printf '%s' "$p" | grep -Eq '^(/[A-Za-z0-9._-]+)+$' || return 1
    IFS=/ read -ra parts <<<"${p#/}"
    for c in "${parts[@]}"; do case "$c" in .|..) return 1 ;; esac; done
}

# The working copies the user added (aidc repo add), one absolute path a line: the only folders
# of theirs the git container sees.
dk_git_repos_file() { printf '%s/.config/aidc/git-repos' "$(aidc_host_home)"; }
dk_git_repos() {
    local f
    f=$(dk_git_repos_file)
    [ -f "$f" ] || return 0
    grep -E '^/' "$f" 2>/dev/null | while IFS= read -r p; do dk_git_path_ok "$p" && printf '%s\n' "$p"; done
    return 0
}

# dk_git_origin <working-copy>: its origin URL, read from the one file (no include followed).
dk_git_origin() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$1/.git/config" --get remote.origin.url 2>/dev/null
}

# dk_git_slug <url>: owner/name of https://github.com/<owner>/<name>[.git], the only origin
# gitctl takes (the same check: gitctl-rules.sh); returns 1 for anything else.
dk_git_slug() {
    # shellcheck source=../../gitctl/gitctl-rules.sh
    . "${AIDC_ROOT:?AIDC_ROOT not set}/gitctl/gitctl-rules.sh"
    gitctl_slug_from_url "$1" || return 1
    printf '%s' "$GITCTL_SLUG"
}

# dk_git_state: "running", "stopped", "absent" (never set up), or "unknown" (docker did not
# answer). Never "absent" for a daemon that did not answer.
dk_git_state() {
    local out
    if out=$(docker inspect -f '{{.State.Running}}' "$DK_GIT_CT" 2>&1); then
        [ "$out" = true ] && { printf 'running'; return 0; }
        printf 'stopped'; return 0
    fi
    case "$out" in *"No such"*|*"no such"*) printf 'absent' ;; *) printf 'unknown' ;; esac
}

# dk_git_target: dies unless the git container runs, saying which of "not set up", "stopped"
# and "docker did not answer" it was.
dk_git_target() {
    require_docker
    case "$(dk_git_state)" in
        running) ;;
        absent) die "no git container on this machine: run \`aidc git setup\`" ;;
        stopped) die "the git container is not running: run \`aidc git setup\`" ;;
        *) die "cannot reach the git container: docker did not answer" ;;
    esac
}

# dk_git_exec <args...>: run in the git container as the agent, with no stdin.
dk_git_exec() { docker exec -u git "$DK_GIT_CT" "$@" </dev/null; }
# dk_git_exec_in <args...>: the same, stdin passed in.
dk_git_exec_in() { docker exec -i -u git "$DK_GIT_CT" "$@"; }

# dk_git_repo_arg <path>: the working copy (or a worktree inside one) the git container sees
# at that path: one the user added, or a folder below one. Dies otherwise.
dk_git_repo_arg() {
    local p r
    p=$(translate_wsl_path "$1")
    p=$(realpath_portable "$p") || die "${1}: no such folder"
    dk_git_path_ok "$p" || die "${p}: not a folder below your home ($(dk_git_disk)) named with letters, digits, '.', '_' and '-' only"
    while IFS= read -r r; do
        case "$p" in "$r"|"$r"/*) printf '%s' "$p"; return 0 ;; esac
    done < <(dk_git_repos)
    die "${p} is not in a repo the git container works on: aidc repo add <working copy> first (aidc repo list)"
}

# The MCP server's transcript folder for a session (cmd-create.sh, "transcript mirror surface"):
# the git agent's goes there too, so an orchestrator reads it like any session's.
dk_git_transcripts_dir() {
    printf '%s/transcripts/%s' "${AIDC_MCP_STATE_HOST:-${XDG_STATE_HOME:-$(aidc_host_home)/.local/state}/aidc-mcp}" "$DK_GIT_SESSION"
}

# The seed step, a one-shot root container from the gitctl image, with no network and only the
# capabilities a copy and a chown need, as the git pod's seed-home init step: a new home starts
# as a copy of the image's /home/git; the login's folder is gitcred's (0711), gitrun's store
# gitrun's alone (0700); the request folder the agent's, setgid in the session group (2755).
# A request folder that holds anything and is not the agent's is refused, not taken. Then, as
# the git user with no capabilities, the home gets the image's Claude when it is older
# (claude-refresh.sh, the refresh-claude init step).
# shellcheck disable=SC2016  # run by the step's shell
DK_GIT_SEED_SCRIPT='set -eu
[ -e /seed/.profile ] || cp -a /home/git/. /seed/
chown 2000:2000 /seed && chmod 0700 /seed
chown 2001:2001 /cred && chmod 0711 /cred
chown 2002:2002 /run-store && chmod 0700 /run-store
if [ "$(stat -c %u /requests)" != 2000 ]; then
    if [ -n "$(ls -A /requests)" ]; then echo "refused: the request folder holds files and is not the git container'"'"'s" >&2; exit 3; fi
    chown 2000:1000 /requests
fi
chmod 2755 /requests
echo seeded'
dk_git_seed() {
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN --cap-add FOWNER \
        --cap-add DAC_OVERRIDE --security-opt no-new-privileges \
        -v aidc-git-home:/seed -v aidc-git-cred:/cred -v aidc-git-run:/run-store \
        -v "${DK_GIT_REQUESTS_VOLUME}:/requests" --entrypoint /bin/sh \
        "aidc/gitctl:${AIDC_VERSION_TAG}" -c "$DK_GIT_SEED_SCRIPT" >/dev/null || return 1
    docker run --rm --network none --user 2000:2000 --cap-drop ALL --security-opt no-new-privileges \
        -v aidc-git-home:/seed --entrypoint /opt/aidc/lib/gitctl/claude-refresh.sh \
        "aidc/gitctl:${AIDC_VERSION_TAG}" /home/git /seed >&2 || return 1
}

# dk_git_own_transcripts <host-dir>: the MCP server's transcript folder for the git agent,
# made here and given to the agent (uid 2000, which writes it), group the user's so the user
# can list it; the server reads it as root.
dk_git_own_transcripts() {
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN --cap-add FOWNER \
        --security-opt no-new-privileges -v "${1}:/t" --entrypoint /bin/sh \
        "aidc/gitctl:${AIDC_VERSION_TAG}" -c "chown 2000:$(id -g) /t && chmod 0750 /t" >/dev/null
}

# dk_git_wait_ready: wait up to a minute for the git container's tmux (its main process starts
# it); returns 1 when it never came.
dk_git_wait_ready() {
    local i
    for i in $(seq 60); do
        dk_git_exec tmux has-session -t main >/dev/null 2>&1 && return 0
        [ "$i" -lt 60 ] && sleep 1
    done
    return 1
}

# dk_git_start: (re)create the git container with the current settings and the added working
# copies mounted, and wait for it. The volumes, networks and proxy must exist (aidc git setup).
# A working copy that is gone is left out (Docker would make an empty root-owned folder in its
# place), with a warning.
dk_git_start() {
    local disk transcripts token="" tokfile mounts=() p
    dk_git_settings
    disk=$(dk_git_disk)
    transcripts=$(dk_git_transcripts_dir)
    tokfile="$(aidc_host_home)/.config/aidc/claude-oauth-token"
    if [ -f "$tokfile" ]; then
        token=$(tr -d '[:space:]' < "$tokfile" 2>/dev/null || true)
        case "$token" in sk-ant-oat01-*) ;; *) token="" ;; esac
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -d "$p/.git" ]; then mounts+=(-v "${p}:${p}:rw")
        else info "warning: ${p} is gone or not a working copy; not mounted (aidc repo remove ${p})"; fi
    done < <(dk_git_repos)
    docker rm -f "$DK_GIT_CT" >/dev/null 2>&1 || true
    docker run -d --name "$DK_GIT_CT" --hostname git --restart unless-stopped \
        --network "$DK_GIT_NET" --dns 9.9.9.9 --dns 149.112.112.112 \
        --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add AUDIT_WRITE \
        --label "aidc.session=${DK_GIT_SESSION}" --label aidc.role=dev --label aidc.profile=git-agent \
        --label aidc.git=container \
        -e HOME=/home/git -e "AIDC_USER=$(id -un)" -e AIDC_SESSION="$DK_GIT_SESSION" -e AIDC_BACKEND=docker \
        -e AIDC_GIT_REQUESTS="$DK_GIT_REQUESTS" -e "AIDC_GIT_MODE=${AIDC_DK_GIT_MODE}" \
        -e AIDC_GIT_NOTIFY=/opt/aidc/lib/gitctl/git-notify.sh -e "AIDC_GIT_DISK=${disk}" \
        -e HTTPS_PROXY=http://aidc-proxy:3128 -e HTTP_PROXY=http://aidc-proxy:3128 \
        -e https_proxy=http://aidc-proxy:3128 -e http_proxy=http://aidc-proxy:3128 \
        -e NO_PROXY=localhost,127.0.0.1 -e no_proxy=localhost,127.0.0.1 \
        -e "CLAUDE_CODE_OAUTH_TOKEN=${token}" \
        -v aidc-git-home:/home/git -v aidc-git-cred:/var/lib/gitctl/gitcred \
        -v aidc-git-run:/var/lib/gitctl/gitrun -v "${DK_GIT_REQUESTS_VOLUME}:${DK_GIT_REQUESTS}" \
        -v "${transcripts}:/var/aidc/transcript-out:rw" \
        ${mounts[@]+"${mounts[@]}"} \
        "aidc/gitctl:${AIDC_VERSION_TAG}" >/dev/null || die "could not start the git container"
    dk_git_wait_ready || die "the git container did not become ready; see: docker logs ${DK_GIT_CT}"
}
