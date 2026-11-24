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
#     aidc-proxy) that reaches public addresses only and resolves through Quad9 (squid's own
#     dns_nameservers, which its entrypoint requires there): the intent of the git pod's
#     NetworkPolicy. Nothing connects in. The git container itself resolves only aidc-proxy
#     (Docker's DNS on the internal network); its --dns is Quad9 so nothing else is asked.
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
DK_GIT_SESSION="$AIDC_GIT_SESSION"
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

# The list of repos the user added (aidc repo add|remove), one lower-case owner/name a line, in
# a folder of its own on this machine, bind-mounted read-only into the git container at
# /etc/aidc/git-repos: gitctl's gitrun copies, and gitcred acts on, only a repo on it. Nothing in
# the container can write it (a read-only mount; gitwc, the user's uid, included). A folder, not
# the file, is mounted, so a list replaced here (a new file, renamed into place) is the one the
# running container reads.
dk_git_added_dir() { printf '%s/.config/aidc/git-added' "$(aidc_host_home)"; }
dk_git_added() {
    local f
    f="$(dk_git_added_dir)/repos"
    [ -f "$f" ] || return 0
    grep -E '^[a-z0-9][a-z0-9-]*/[a-z0-9._-]+$' "$f" 2>/dev/null || true
}
# dk_git_added_change add|remove <owner/name>: put the repo on the list or take it off.
# Returns 1, saying why on stderr, when the list could not be written.
dk_git_added_change() {
    local d slug cur new
    d=$(dk_git_added_dir)
    slug=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    mkdir -p "$d" || { printf '[aidc] error: cannot make %s\n' "$d" >&2; return 1; }
    cur=$(dk_git_added)
    if [ "$1" = add ]; then new=$(printf '%s\n%s\n' "$cur" "$slug" | grep -v '^$' | sort -u)
    else new=$(printf '%s\n' "$cur" | grep -vxF -- "$slug" | grep -v '^$' || true); fi
    { printf '%s\n' "$new" | grep -v '^$' > "$d/repos.tmp" || true; } \
        && chmod 0644 "$d/repos.tmp" && mv -f "$d/repos.tmp" "$d/repos" \
        || { printf '[aidc] error: cannot write %s/repos\n' "$d" >&2; return 1; }
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

# dk_git_mount_ok <path>: the recorded working copy is still there as recorded: no symlink at
# it or on the way (the recorded form is fully resolved, so its realpath must be itself), with
# a .git folder that is not a symlink. Docker's bind mount follows symlinks: a session that
# replaced a working copy in its workspace with a symlink to another folder of the user's would
# otherwise have that folder mounted read-write at the trusted path.
dk_git_mount_ok() {
    local p="$1" r
    [ -d "$p" ] && [ ! -L "$p" ] || return 1
    r=$(realpath_portable "$p" 2>/dev/null) || return 1
    [ "$r" = "$p" ] || return 1
    [ -d "$p/.git" ] && [ ! -L "$p/.git" ]
}

# dk_git_inode <path>: the folder's device and inode on this machine, as <device>:<inode> (no
# symlink followed), or nothing. Both, because an inode number is unique only within one
# filesystem: a folder on another filesystem can have the same one.
dk_git_inode() { stat -c %d:%i -- "$1" 2>/dev/null || stat -f %d:%i -- "$1" 2>/dev/null || true; }

# dk_git_check_mounts <path>...: after the start, each working copy the container sees at its
# path is the folder this machine has there (the same device and inode, and still as
# recorded), so a symlink swapped in between dk_git_mount_ok and Docker's mount, then swapped
# back, is caught. On Linux only: there a bind mount shows the source folder's own device and
# inode; Docker Desktop's file sharing (macOS) need not. Returns 1, naming the path, on a
# mismatch.
dk_git_check_mounts() {
    local p seen want
    [ $# -gt 0 ] && [ "$(uname -s)" = Linux ] || return 0
    for p in "$@"; do
        want=$(dk_git_inode "$p")
        seen=$(docker exec -u git "$DK_GIT_CT" stat -c %d:%i -- "$p" </dev/null 2>/dev/null) || seen=""
        if [ -z "$want" ] || [ "$seen" != "$want" ] || ! dk_git_mount_ok "$p"; then
            printf '%s\n' "$p"; return 1
        fi
    done
}

# dk_git_start: (re)create the git container with the current settings and the added working
# copies mounted, and wait for it. The volumes, networks and proxy must exist (aidc git setup).
# A working copy that is gone, or is no longer at its recorded path as recorded (a symlink at
# it or on the way: dk_git_mount_ok), is left out with a warning (Docker would make an empty
# root-owned folder in place of a gone one, and follow a symlink to another folder).
dk_git_start() {
    local disk transcripts token="" tokfile mounts=() mounted=() p bad added
    dk_git_settings
    disk=$(dk_git_disk)
    transcripts=$(dk_git_transcripts_dir)
    tokfile="$(aidc_host_home)/.config/aidc/claude-oauth-token"
    if [ -f "$tokfile" ]; then
        token=$(tr -d '[:space:]' < "$tokfile" 2>/dev/null || true)
        case "$token" in sk-ant-oat01-*) ;; *) token="" ;; esac
    fi
    # The list of added repos: made here (an empty list) when missing, so Docker does not make
    # a root-owned folder in its place; mounted read-only.
    added=$(dk_git_added_dir)
    { mkdir -p "$added" && { [ -f "$added/repos" ] || : > "$added/repos"; }; } || die "cannot make ${added}"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if dk_git_mount_ok "$p"; then mounts+=(-v "${p}:${p}:rw"); mounted+=("$p")
        else info "warning: ${p} is gone, not a working copy, or reached through a symlink; not mounted (aidc repo remove ${p})"; fi
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
        -v "${transcripts}:/var/aidc/transcript-out:rw" -v "${added}:/etc/aidc/git-repos:ro" \
        ${mounts[@]+"${mounts[@]}"} \
        "aidc/gitctl:${AIDC_VERSION_TAG}" >/dev/null || die "could not start the git container"
    if ! bad=$(dk_git_check_mounts ${mounted[@]+"${mounted[@]}"}); then
        docker rm -f "$DK_GIT_CT" >/dev/null 2>&1 || true
        die "${bad} changed while the git container started (the folder it mounted is not the one there now): the git container is removed; check ${bad}, then aidc git setup"
    fi
    dk_git_wait_ready || die "the git container did not become ready; see: docker logs ${DK_GIT_CT}"
}

# --- the backend interface of `aidc git` (scripts/git/git-*.sh) -----------------------------
# Each scripts/git/git-<verb>.sh is one script for both backends; what differs is only how the
# git container is reached, so each backend's lib defines the same gb_* functions.

# gb_require: what every verb needs here before anything is asked.
gb_require() { require_docker; }
# gb_target: dies unless the git container runs.
gb_target() { dk_git_target; }
# gb_exec ARGS / gb_exec_in ARGS / gb_exec_tty ARGS: run in the git container as the agent:
# no stdin; stdin passed in; interactive, on the user's terminal.
gb_exec() { dk_git_exec "$@"; }
gb_exec_in() { dk_git_exec_in "$@"; }
gb_exec_tty() { docker exec -it -u git -e "TERM=${TERM:-xterm-256color}" "$DK_GIT_CT" "$@"; }
# gb_repo_arg PATH: the working copy the git container sees for PATH, or dies.
gb_repo_arg() { dk_git_repo_arg "$1"; }
# gb_repos: every working copy the git container works on, one a line; gb_repo_ok PATH: a path
# of that list fit to hand over.
gb_repos() { dk_git_repos; }
gb_repo_ok() { dk_git_path_ok "$1"; }
# shellcheck disable=SC2034  # GB_* are read by scripts/git/git-*.sh
# gb_settings: GB_MODE / GB_MODE_KEY, GB_STORAGE_WARN / GB_STORAGE_KEY (dies on a bad mode).
gb_settings() {
    dk_git_settings
    GB_MODE="$AIDC_DK_GIT_MODE" GB_MODE_KEY=git.mode
    # shellcheck disable=SC2034  # read by scripts/git/git-status.sh
    GB_STORAGE_WARN="$AIDC_DK_GIT_STORAGE_WARN" GB_STORAGE_KEY=git.storage_warn
}
# gb_session_token NAME: the session's own git token (AIDC_GIT_TOKEN in its dev container,
# read from docker), or dies saying why.
gb_session_token() {
    local token
    session_exists "$1" || die "no session '${1}'"
    token=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_name "$1" dev)" 2>/dev/null \
        | sed -n 's/^AIDC_GIT_TOKEN=//p' | head -n1) || true
    printf '%s' "$token" | grep -Eq '^[0-9a-f]{64}$' \
        || die "session '${1}' was created before sessions had their own git mode: create it again (aidc kill ${1}; aidc create ${1})"
    printf '%s' "$token"
}
# gb_sessions: "<session> <token>" for every session on this machine that has a token; returns
# 1 when docker did not answer (then nothing may be pruned).
gb_sessions() {
    local names n tok
    names=$(docker ps -a --filter label=aidc.role=dev --format '{{.Label "aidc.session"}}' 2>/dev/null) || return 1
    while IFS= read -r n; do
        { [ -n "$n" ] && ! aidc_is_git_session "$n"; } || continue
        tok=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_name "$n" dev)" 2>/dev/null \
            | sed -n 's/^AIDC_GIT_TOKEN=//p' | head -n1) || continue
        printf '%s' "$tok" | grep -Eq '^[0-9a-f]{64}$' && printf '%s %s\n' "$n" "$tok"
    done <<<"$names"
    return 0
}
# The status lines' label width, and the lines only this backend has.
# shellcheck disable=SC2034  # read by scripts/git/git-status.sh
GB_STATUS_W=11
# shellcheck disable=SC2034  # GB_UP is read by scripts/git/git-status.sh
# gb_status_head: the container's own lines; GB_UP=1 when it runs (it can be asked).
gb_status_head() {
    local state
    printf 'git container: %s (Docker; the git agent, session %s)\n' "$DK_GIT_CT" "$DK_GIT_SESSION"
    state=$(dk_git_state); GB_UP=0; GB_STATE="$state"
    case "$state" in
        running) printf 'container: running\n'; GB_UP=1 ;;
        stopped) printf 'container: not running (aidc git setup; docker logs %s)\n' "$DK_GIT_CT" ;;
        absent) printf 'container: not set up (run: aidc git setup)\n' ;;
        *) printf 'container: unknown (docker did not answer)\n' ;;
    esac
}
# gb_status_tail: egress (an internal network, out only through the public-only proxy; anything
# else is reported, never assumed) and the working copies added.
gb_status_tail() {
    local internal proxy_env proxy_up n
    internal=$(docker network inspect -f '{{.Internal}}' "$DK_GIT_NET" 2>/dev/null || true)
    proxy_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DK_GIT_PROXY" 2>/dev/null || true)
    proxy_up=$(docker inspect -f '{{.State.Running}}' "$DK_GIT_PROXY" 2>/dev/null || true)
    if [ "$internal" = true ] && printf '%s\n' "$proxy_env" | grep -qx 'AIDC_PUBLIC_ONLY=1' && [ "$proxy_up" = true ]; then
        printf 'egress:    enforced: internal network, out only through its proxy to public addresses (Quad9 DNS); no connections in\n'
    elif [ -z "$internal" ] && [ "${GB_STATE:-}" = absent ]; then
        printf 'egress:    not set up\n'
    else
        printf 'egress:    NOT ENFORCED: network internal=%s, proxy running=%s, public-only=%s\n' "${internal:-?}" "${proxy_up:-?}" \
            "$(printf '%s\n' "$proxy_env" | grep -qx 'AIDC_PUBLIC_ONLY=1' && echo yes || echo no)"
    fi
    n=$(dk_git_repos | grep -c . || true)
    printf 'repos:     %s working cop%s added (aidc repo list)\n' "$n" "$([ "$n" = 1 ] && echo y || echo ies)"
}
