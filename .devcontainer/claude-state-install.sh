#!/usr/bin/env bash
# First-start install of the dev container's own Claude state. Sourced by
# user-main.sh INSIDE the container, and by tests/unit/test-claude-state-install.sh
# on the host -- one function, two callers, so the test exercises the exact code
# that ships (the transcript-mirror.sh pattern).
#
# The container owns its Claude config directory (CLAUDE_CONFIG_DIR on the
# dev-home volume; see cmd-create.sh "Authentication"). Two things happen once,
# before Claude is launched:
#
#   1. Empty mount placeholders are cleared. A session created before v1.5.0
#      bind-mounted the host's login files at <config>/.credentials.json and
#      <home>/.claude.json; Docker materialises a bind-mount target as an empty
#      file, and that empty file outlives the mount in the volume once
#      `aidc upgrade` strips it. An empty credentials file is not a login and an
#      empty .claude.json is not state. Only EMPTY files are touched: anything
#      with content is Claude's own and must survive.
#   2. The onboarding seed is installed if the config dir has no .claude.json
#      yet. `aidc create` writes the seed (host onboarding state, no account) into
#      the audit dir; once Claude has written its own .claude.json -- the account
#      you logged in with, settings you changed -- the seed is never reapplied,
#      or a restart/upgrade would undo the login.

# aidc_clear_mount_placeholders <config-dir> <home>
# Emits one line per removed file on stdout (the caller logs it); returns 0.
aidc_clear_mount_placeholders() {
    local config_dir="$1" home="$2" f
    for f in "${config_dir}/.credentials.json" "${home}/.claude.json"; do
        if [ -f "$f" ] && [ ! -s "$f" ]; then
            rm -f "$f" && printf '%s\n' "$f"
        fi
    done
    return 0
}

# aidc_install_claude_state_seed <config-dir> <seed-file>
# Returns 0 when the seed was installed, 1 when there was nothing to do (a
# .claude.json already exists, or there is no seed), 2 when the install failed.
aidc_install_claude_state_seed() {
    local config_dir="$1" seed="$2"
    [ ! -e "${config_dir}/.claude.json" ] && [ -s "$seed" ] || return 1
    mkdir -p "$config_dir" \
        && ( umask 0077; cp "$seed" "${config_dir}/.claude.json" ) || return 2
}
