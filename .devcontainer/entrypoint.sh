#!/usr/bin/env bash
# aidc dev container entrypoint.
#
# Starts the inner Docker daemon (DinD) before handing off to the container's
# CMD (tmux + tail). The compose template runs this container with
# `privileged: true`, which is what dockerd needs to set up its bridge,
# manage iptables, and mount its storage (fuse-overlayfs needs /dev/fuse).
#
# We start dockerd as a child here rather than in post-create.sh because:
#   1. dockerd must be running before any Claude-driven `docker build/run`
#      can succeed, and Claude can run those any time after attach.
#   2. post-create.sh is a Dev Container lifecycle hook that runs only on
#      VS Code attach, not on plain `docker compose up` startup.
set -euo pipefail

log() { printf '[aidc-entrypoint] %s\n' "$*" >&2; }

# Start the inner Docker daemon (DinD). We always attempt it and let it fail
# gracefully (logged, non-fatal) when the container isn't actually privileged
# -- e.g. running this image standalone for inspection. dockerd startup +
# watchdog both live in this one script so the VS Code Dev Containers path
# (which overrides our entrypoint entirely) gets the same self-healing
# behavior by calling it from postStartCommand.
/usr/local/bin/aidc-dockerd-start.sh || log "WARN: dockerd start failed (continuing)"

# Bridge git identity from host into the container so commits land with the
# right name + email. The values come from compose env (AIDC_GIT_USER_NAME /
# AIDC_GIT_USER_EMAIL), which `aidc create` populates from the host's
# `git config --global user.{name,email}`. We write a minimal ~vscode/.gitconfig
# (NOT the host's whole gitconfig — that often carries credential helpers,
# signing keys, and includeIf paths we don't want bridged).
# Written by git itself (git config --file), which quotes and escapes each value: a name with a
# double quote or a backslash is stored as written, not as a config line git cannot read. Into a
# new file, renamed into place, so nothing already at that name is followed.
# write_git_identity <file> <name> <email>
write_git_identity() {
    local f="$1" tmp
    tmp=$(mktemp "${f}.XXXXXX") || return 1
    if GIT_CONFIG_NOSYSTEM=1 git config --file "$tmp" user.name "$2" \
        && GIT_CONFIG_NOSYSTEM=1 git config --file "$tmp" user.email "$3" \
        && GIT_CONFIG_NOSYSTEM=1 git config --file "$tmp" init.defaultBranch main \
        && chmod 0644 "$tmp" && mv -f "$tmp" "$f"; then
        return 0
    fi
    rm -f "$tmp"; return 1
}
if [ -n "${AIDC_GIT_USER_NAME:-}" ] && [ -n "${AIDC_GIT_USER_EMAIL:-}" ]; then
    log "writing /home/vscode/.gitconfig (user: ${AIDC_GIT_USER_NAME} <${AIDC_GIT_USER_EMAIL}>)"
    if write_git_identity /home/vscode/.gitconfig "$AIDC_GIT_USER_NAME" "$AIDC_GIT_USER_EMAIL"; then
        chown vscode:vscode /home/vscode/.gitconfig
    else
        log "WARN: could not write /home/vscode/.gitconfig (commits made here carry no identity)"
    fi
fi

# On Kubernetes the user's disk is shared with the git container, which tidies merged worktrees
# as a member of the session group: what a session writes there must be group-writable. The
# session's own processes inherit user-main.sh's umask; shells opened from outside (kubectl
# exec, aidc attach's shell windows, sudo) get the same here: login and interactive bash read
# the two files, and sudo would otherwise add its own 022 to whatever umask its caller had.
# Files written as root (a Docker build bind-mounting the disk) are still the session's to
# remove; gitctl tidy names them. umask_override also loosens a stricter umask a caller set
# (`umask 077; sudo ...` writes 002 files): accepted, in a single-user pod whose disk only the
# git container shares.
# group_write_shells <root>: writes them under <root> (/ in the container).
group_write_shells() {
    local r="${1%/}" tmp
    mkdir -p "${r}/etc/profile.d" "${r}/etc/sudoers.d" || return 1
    printf '# aidc (Kubernetes): files on the shared disk stay group-writable\numask 002\n' \
        > "${r}/etc/profile.d/aidc-umask.sh" && chmod 0644 "${r}/etc/profile.d/aidc-umask.sh" || return 1
    grep -qx 'umask 002  # aidc' "${r}/etc/bash.bashrc" 2>/dev/null \
        || printf '\numask 002  # aidc\n' >> "${r}/etc/bash.bashrc" || return 1
    tmp=$(mktemp "${r}/etc/sudoers.d/.aidc-umask.XXXXXX") || return 1
    printf 'Defaults umask=0002\nDefaults umask_override\n' > "$tmp" && chmod 0440 "$tmp" \
        && mv -f "$tmp" "${r}/etc/sudoers.d/aidc-umask" || { rm -f "$tmp"; return 1; }
}
if [ "${AIDC_BACKEND:-}" = kubernetes ]; then
    group_write_shells / && log "shells and sudo: umask 002 (the shared disk stays group-writable)" \
        || log "WARN: could not set umask 002 for shells and sudo (continuing)"
fi

# Claude Code's managed settings: aidc's hooks (MCP-46), and the host's shared plugins
# enabled when share_plugins is on (managed-settings.sh says why they go here).
#
# cmd-create.sh bind-mounts ~/.claude/plugins read-only, which lets Claude Code RESOLVE the
# plugins, but a resolved plugin still won't LOAD unless it's enabled. Not via
# ~/.claude/settings.json: that file is the session's copy of the host's, installed on first
# start, and enablement written there would be lost if the copy were ever re-seeded and would
# drift from the host's. The enable-list is every plugin the operator has installed, read from
# the mounted registry; share_plugins is opt-in, so enabling what they installed is expected.
# shellcheck source=managed-settings.sh
. /usr/local/bin/aidc-managed-settings.sh
PLUGIN_REGISTRY="/home/vscode/.claude/plugins/installed_plugins.json"
if aidc_install_managed_settings / "$PLUGIN_REGISTRY" "${AIDC_SHARE_PLUGINS:-false}"; then
    names=$(jq -r '.enabledPlugins // {} | keys | join(", ")' /etc/claude-code/managed-settings.json 2>/dev/null)
    log "claude managed settings: aidc's hooks installed${names:+; plugins enabled: ${names}}"
else
    log "ERROR: could not write Claude's managed settings, so Claude runs without aidc's hooks: aidc-mcp cannot tell when it is free and refuses prompts to this session (session_outdated). Recreating the session will not help until this write succeeds; see the line above."
fi

# If the mounted repo declares a Python version (.python-version, the pyenv
# convention), make sure pyenv has it installed. The image pre-bakes the
# latest 3.12 but anything older or different needs a one-time compile.
# This takes 2-5 minutes the first time per Python version per session;
# subsequent restarts no-op because pyenv install -s skips if installed.
if [ -n "${AIDC_REPO_PATH:-}" ] && [ -f "${AIDC_REPO_PATH}/.python-version" ]; then
    requested=$(head -1 "${AIDC_REPO_PATH}/.python-version" | tr -d '[:space:]')
    if [ -n "$requested" ]; then
        log "repo requests Python ${requested}; pyenv install -s (compiles if missing)..."
        if pyenv install -s "$requested" 2>&1 | tee -a /var/log/aidc/pyenv.log; then
            log "Python ${requested} ready"
        else
            log "WARN: pyenv install ${requested} failed; see /var/log/aidc/pyenv.log"
        fi
    fi
fi

# Claude Code's scratchpad root (/tmp/claude-<uid>) has to belong to vscode.
#
# When share_scratchpad bridges this repo's scratchpad dir, the bind mount is
# one level DOWN -- /tmp/claude-<uid>/<encoded-repo> -- and Docker materialises
# the parent it needs as root-owned 0755. Claude also writes siblings of the
# per-project dir directly in that root, so leaving it root-owned means those
# writes fail for reasons that look nothing like a mount problem. Claiming the
# root here fixes that without disturbing the bind mounted beneath it, and is
# equally correct unbridged, where the whole tree is container-local.
#
# 0700 matches the mode Claude Code creates this root as on a host.
# Non-fatal, like dockerd above: this is a convenience for Claude's working
# files, and nothing here is worth refusing to start the container over. The
# chown is deliberately NOT recursive -- a bridged scratchpad below this point
# is host-owned, and walking into it would rewrite the host's files.
if CLAUDE_TMP_ROOT="/tmp/claude-$(id -u vscode)" \
   && mkdir -p "$CLAUDE_TMP_ROOT" \
   && chown vscode:vscode "$CLAUDE_TMP_ROOT" \
   && chmod 0700 "$CLAUDE_TMP_ROOT"; then
    log "claude scratchpad root ready at ${CLAUDE_TMP_ROOT}"
else
    log "WARN: could not prepare the claude scratchpad root (continuing)"
fi

# The bridged memory and scratchpad dirs, when Docker made them: see
# aidc_claim_docker_made_dirs, and aidc_host_user_is_session_user for when that is
# safe. Non-fatal for the same reason as above; user-main.sh warns, and the CLI
# repeats it, if Claude still cannot write its transcripts.
# shellcheck source=claude-state-install.sh
. /usr/local/bin/aidc-claude-state-install.sh
if aidc_host_user_is_session_user "${AIDC_REPO_PATH:-/nonexistent}" "$(id -u vscode)"; then
    while IFS= read -r _line; do
        log "memory/scratchpad mount: ${_line}"
    done < <(aidc_claim_session_mounts vscode:vscode /home/vscode/.claude/projects \
                "${CLAUDE_TMP_ROOT:-/tmp/claude-$(id -u vscode)}" || true)
else
    log "memory/scratchpad mount: not claiming root-owned dirs: the host user does not appear here as vscode (repo owner uid $(stat -c %u "${AIDC_REPO_PATH:-/nonexistent}" 2>/dev/null || echo unknown))"
fi

# Drop privileges to vscode and exec the container's CMD (whatever was
# passed — compose's tmux+tail script, VS Code Dev Containers' keep-alive
# loop, or the Dockerfile's default of /usr/local/bin/aidc-user-main.sh
# when nothing else was specified).
#
# We use `sudo -u vscode -E` rather than `su` because sudo properly sets
# up the environment, forwards signals correctly via tini, and (unlike
# `su -c`) doesn't do another round of shell-quoting on the command
# string. HOME/USER/LOGNAME are explicitly set so vscode-as-vscode finds
# its own home (not root's).
#
# tini (declared as ENTRYPOINT in the Dockerfile) is PID 1; it reaps any
# zombies and forwards SIGTERM/SIGINT to this exec'd process tree.
if [ $# -eq 0 ]; then
    set -- /usr/local/bin/aidc-user-main.sh
fi
log "dropping to vscode and exec: $*"
exec sudo -E -u vscode \
    HOME=/home/vscode USER=vscode LOGNAME=vscode \
    "$@"
