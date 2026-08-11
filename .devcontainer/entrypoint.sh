#!/usr/bin/env bash
# aidc dev container entrypoint.
#
# Starts the inner Docker daemon (DinD) before handing off to the container's
# CMD (tmux + tail). The compose template runs this container with
# `privileged: true`, which is what dockerd needs to set up its bridge,
# manage iptables, and use overlay2 storage.
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
if [ -n "${AIDC_GIT_USER_NAME:-}" ] && [ -n "${AIDC_GIT_USER_EMAIL:-}" ]; then
    log "writing /home/vscode/.gitconfig (user: ${AIDC_GIT_USER_NAME} <${AIDC_GIT_USER_EMAIL}>)"
    cat > /home/vscode/.gitconfig <<GITCONFIG
[user]
    name = ${AIDC_GIT_USER_NAME}
    email = ${AIDC_GIT_USER_EMAIL}
[init]
    defaultBranch = main
GITCONFIG
    chown vscode:vscode /home/vscode/.gitconfig
    chmod 0644 /home/vscode/.gitconfig
fi

# Enable the host's shared plugins inside the container (share_plugins).
#
# cmd-create.sh bind-mounts ~/.claude/plugins read-only, which lets Claude
# Code RESOLVE the plugins — but a resolved plugin still won't LOAD unless it's
# enabled. We can't enable via ~/.claude/settings.json: that file is bridged
# read-write from the host, so writing enabledPlugins there would leak this
# container's enablement back onto the host. Instead we write
# /etc/claude-code/managed-settings.json — a container-local settings scope that
# merges on top of the bridged user settings and is never mounted from the host.
#
# The enable-list is every plugin the operator has installed, read from the
# mounted registry. share_plugins is opt-in, so enabling what they installed is
# the expected behavior. Empty/missing registry -> nothing written.
PLUGIN_REGISTRY="/home/vscode/.claude/plugins/installed_plugins.json"
if [ "${AIDC_SHARE_PLUGINS:-false}" = "true" ] && [ -s "$PLUGIN_REGISTRY" ]; then
    enabled_json=$(jq -c '{enabledPlugins: ((.plugins // {}) | keys | map({(.): true}) | add // {})}' "$PLUGIN_REGISTRY" 2>/dev/null || true)
    if [ -n "$enabled_json" ] && [ "$enabled_json" != '{"enabledPlugins":{}}' ]; then
        mkdir -p /etc/claude-code
        printf '%s\n' "$enabled_json" > /etc/claude-code/managed-settings.json
        chmod 0644 /etc/claude-code/managed-settings.json
        names=$(printf '%s' "$enabled_json" | jq -r '.enabledPlugins | keys | join(", ")')
        log "plugins: enabled in-container via managed-settings.json (${names})"
    else
        log "plugins: share_plugins=true but no installed plugins in registry; none enabled"
    fi
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
