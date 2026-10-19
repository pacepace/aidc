#!/usr/bin/env bash
# The dev container's helpers for Claude's own state: its config dir, its project
# dirs, and the transcripts in them. Sourced inside the container (each function's
# comment names its caller and when it runs), by cmd-create.sh on the host for the
# project-dir name, and by tests/unit/test-claude-state-install.sh -- so the test
# exercises the exact code that ships (the transcript-mirror.sh pattern).
#
# The container owns its Claude config directory (CLAUDE_CONFIG_DIR on the
# dev-home volume; see cmd-create.sh "Authentication"). On the first start,
# before Claude is launched, user-main.sh:
#
#   1. Clears empty mount placeholders. A session created before v1.5.0
#      bind-mounted the host's login files at <config>/.credentials.json and
#      <home>/.claude.json; Docker materialises a bind-mount target as an empty
#      file, and that empty file outlives the mount in the volume once
#      `aidc upgrade` strips it. An empty credentials file is not a login and an
#      empty .claude.json is not state. Only EMPTY files are touched: anything
#      with content is Claude's own and must survive.
#   2. Installs the onboarding seed if the config dir has no .claude.json
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
# aidc_install_claude_settings_seed <config-dir> <seed>
# The host's settings.json, copied in at create and installed on the FIRST start
# only (a later start would overwrite what Claude changed in the session). It is
# not bind-mounted: that file carries `hooks`, which the HOST's Claude Code runs,
# so a session that could write it could run a command on the host (CTR-13).
# Returns 1 when there is nothing to do (already installed, or no seed).
aidc_install_claude_settings_seed() {
    local config_dir="$1" seed="$2"
    [ ! -e "${config_dir}/settings.json" ] && [ -s "$seed" ] || return 1
    mkdir -p "$config_dir" \
        && ( umask 0077; cp "$seed" "${config_dir}/settings.json" ) || return 2
}

aidc_install_claude_state_seed() {
    local config_dir="$1" seed="$2"
    [ ! -e "${config_dir}/.claude.json" ] && [ -s "$seed" ] || return 1
    mkdir -p "$config_dir" \
        && ( umask 0077; cp "$seed" "${config_dir}/.claude.json" ) || return 2
}

# The tag every line meaning "Claude cannot write this session's transcripts" starts
# with. wait_for_dev_ready (create, upgrade) and cmd-restart.sh repeat any log line
# carrying it to the operator, and match on the tag alone, so the wording after it is
# free to change. A session in that state looks healthy from outside: Claude says so
# only in its own status bar, and the orchestrator waits on replies the MCP cannot read
# from a transcript that is never written.
AIDC_TRANSCRIPT_UNWRITABLE_TAG="transcript-unwritable:"

# aidc_claude_project_name <path>
# The name Claude Code gives the dir under ~/.claude/projects/ that holds <path>'s
# conversations: every character that is not an ASCII letter or digit becomes "-"
# (read from Claude Code 2.1.303's own encoder). Replacing only "/" and "." put a repo
# whose path holds "_" or a space at a dir Claude never writes: no shared memory, no
# resume, and no transcript for the MCP to read. Not handled here: Claude shortens a
# name over 200 characters with a hash suffix, and counts a non-ASCII character per
# UTF-16 unit where this counts bytes ("é" is one "-" to Claude, two here).
aidc_claude_project_name() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g'
}

# aidc_host_user_is_session_user <repo-path> <session-uid>
# True when the host user, as this container sees them, is the session user. The repo
# is bind-mounted from the host and owned by the host user there, so its owner seen
# from inside is how that user appears here. This is the premise
# aidc_claim_docker_made_dirs rests on, checked rather than assumed: under rootless
# Docker the host user appears as root, so every dir they own reads as uid 0 here;
# and a host user whose uid is not the container's would have a Docker-made dir taken
# by whichever account holds the container's uid on the host.
aidc_host_user_is_session_user() {
    [ "$(stat -c %u "$1" 2>/dev/null)" = "$2" ]
}

# aidc_claim_docker_made_dirs <owner> <mode|-> <parent>...
# Gives <owner> each <parent>, and each directory directly inside it, that is owned by
# root, and sets <mode> on each one claimed ("-" leaves Docker's 0755). The scratchpad
# passes 0700, the mode Claude Code and `aidc create` give it, so a claimed one is not
# left listable by other host users. Run by entrypoint.sh as root on every start
# (through aidc_claim_session_mounts), before privileges drop, and only when
# aidc_host_user_is_session_user holds. Docker materialises a missing bind-mount source
# on the HOST as root 0755 whenever it starts the container -- an `aidc restart`, an
# upgrade, a /tmp wiped by a host reboot -- and a memory dir made that way leaves
# Claude unable to save the conversation and the MCP's transcript mirror with nothing
# to read. With the host user being the session user, a root-owned dir here is
# root-owned on the host too: nobody meant a dir under their own ~/.claude to belong to
# root, and giving it to the session user gives it back to them. A dir already owned by
# anyone else is left alone. Never recursive, because what lives inside a bridged dir
# is the host's. What this cannot reach: when Docker also had to make the bridged dir's
# PARENT on the host (the host's /tmp/claude-<uid> after a reboot cleared /tmp), that
# parent stays root-owned there, because the container's /tmp/claude-<uid> is its own
# and not a mount.
# Emits "claimed <dir>", or the unwritable tag and "could not claim <dir>", per dir on
# stdout (the caller logs it); returns 1 when any claim failed.
aidc_claim_docker_made_dirs() {
    local owner="$1" mode="$2" parent d rc=0
    shift 2
    for parent in "$@"; do
        [ -d "$parent" ] || continue
        for d in "$parent" "$parent"/*/; do
            d="${d%/}"
            [ -d "$d" ] && [ ! -L "$d" ] || continue
            [ "$(stat -c %u "$d" 2>/dev/null)" = 0 ] || continue
            if chown "$owner" "$d" 2>/dev/null \
                    && { [ "$mode" = - ] || chmod "$mode" "$d" 2>/dev/null; }; then
                printf 'claimed %s\n' "$d"
            else
                printf '%s could not claim %s\n' "$AIDC_TRANSCRIPT_UNWRITABLE_TAG" "$d"
                rc=1
            fi
        done
    done
    return "$rc"
}

# aidc_claim_session_mounts <owner> <projects-dir> <scratchpad-root>
# The entrypoint's claim over both bridged mounts: the memory dirs under <projects-dir>
# keep their mode, the scratchpad dirs under <scratchpad-root> get 0700. Each is
# attempted whatever the other returned, because the entrypoint runs under `set -e`,
# which would otherwise end the pass at the first failed chown and leave the rest
# unclaimed and unreported. Returns 1 when either failed.
aidc_claim_session_mounts() {
    local rc=0
    aidc_claim_docker_made_dirs "$1" - "$2" || rc=1
    aidc_claim_docker_made_dirs "$1" 0700 "$3" || rc=1
    return "$rc"
}

# aidc_transcript_dir_warning <project-dir>
# Prints one tagged line when <project-dir> exists and this process cannot write it,
# and nothing otherwise. user-main.sh runs it as the session user on every start,
# after entrypoint.sh's claim, so it reports whatever the claim could not or would not
# fix. A dir that does not exist yet is fine: Claude creates it.
aidc_transcript_dir_warning() {
    local dir="$1"
    [ -d "$dir" ] && [ ! -w "$dir" ] || return 0
    printf '%s %s is not writable by %s (owner %s): Claude cannot save this conversation and the MCP will not see its replies\n' \
        "$AIDC_TRANSCRIPT_UNWRITABLE_TAG" "$dir" "$(id -un)" "$(stat -c %U:%G "$dir" 2>/dev/null)"
}

# aidc_has_resumable_conversation <project-dir>
# True when some transcript in <project-dir> holds a message. The aidc-claude wrapper
# asks on every launch and passes --continue on that answer, and `claude --continue` with nothing to continue exits
# ("No conversation found to continue") rather than opening a session. A transcript
# file alone is not a conversation: a Claude that could not write all session leaves
# one holding only bookkeeping (cost, mode, a file-history snapshot) when it exits.
# Any transcript will do, not only the newest: `claude --continue` skips a newer
# bookkeeping-only one and resumes the conversation before it (Claude Code 2.1.303).
aidc_has_resumable_conversation() {
    local dir="$1"
    compgen -G "${dir}/*.jsonl" >/dev/null || return 1
    grep -qsE '"type":"(user|assistant)"' "${dir}"/*.jsonl
}
