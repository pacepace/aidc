#!/usr/bin/env bash
# Unit test for where load_config reads the global config from
# (scripts/lib/config.sh).
#
# aidc-mcp runs this CLI for session_create inside its own container, where HOME is
# /root and the host's config is mounted at /aidc-config. Reading only
# ~/.config/aidc/config.yaml there meant every session the MCP created silently used
# the defaults instead of the host's settings.
#
# Pure function calls: no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/config-sources-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/host/.config/aidc" "$SCRATCH/mount" "$SCRATCH/empty" "$SCRATCH/container"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

printf 'profile: solo\ntaint_response: kill\n' > "$SCRATCH/host/.config/aidc/config.yaml"
printf 'profile: multi\ntaint_response: log\n' > "$SCRATCH/mount/config.yaml"

profile_with() {
    # $1 = HOME, $2 = AIDC_MCP_CONFIG_MOUNT
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$1" AIDC_MCP_CONFIG_MOUNT="$2" \
        AIDC_ROOT="$AIDC_ROOT" bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            load_config >/dev/null 2>&1
            printf "%s %s" "$AIDC_PROFILE" "$AIDC_TAINT_RESPONSE"'
}

echo "=== config sources ==="

eq "the host config wins when it is there" "solo kill" \
    "$(profile_with "$SCRATCH/host" "$SCRATCH/mount")"
eq "the mounted config is read when there is no host config (inside aidc-mcp)" \
    "multi log" "$(profile_with "$SCRATCH/empty" "$SCRATCH/mount")"
eq "neither present falls back to the defaults" "multi freeze" \
    "$(profile_with "$SCRATCH/empty" "$SCRATCH/empty")"

# Host paths must come from the host's HOME, not the container's: aidc-mcp runs this
# CLI with HOME=/root, and every path it hands docker is resolved on the host.
host_paths() {
    # $1 = HOME, $2 = AIDC_HOST_HOME ("" to leave it unset)
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$1" AIDC_HOST_HOME="$2" AIDC_ROOT="$AIDC_ROOT" \
        bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            [ -z "$AIDC_HOST_HOME" ] && unset AIDC_HOST_HOME
            aidc_config_defaults
            printf "%s %s" "$AIDC_AUDIT_DIR" "$(_aidc_expand_path "~/aidc-audit")"'
}

eq "without AIDC_HOST_HOME the paths follow HOME" \
    "$SCRATCH/container/aidc-audit $SCRATCH/container/aidc-audit" \
    "$(host_paths "$SCRATCH/container" "")"
eq "with it (inside aidc-mcp) they follow the host's home" \
    "$SCRATCH/host/aidc-audit $SCRATCH/host/aidc-audit" \
    "$(host_paths "$SCRATCH/container" "$SCRATCH/host")"

# `aidc mcp start` must pass it, or the fix above never reaches the container.
run_cmd=$(grep -A 20 'docker run -d' "$AIDC_ROOT/scripts/cmd-mcp.sh")
# shellcheck disable=SC2016  # matching the literal ${HOME} / ${AUDIT_DIR} in the script
case "$run_cmd" in
    *'AIDC_HOST_HOME=${HOME}'*) echo "  PASS: aidc mcp start passes the host home"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: aidc mcp start passes the host home"; FAIL=$((FAIL + 1)) ;;
esac
# shellcheck disable=SC2016  # as above
case "$run_cmd" in
    *'AIDC_MCP_STATE_HOST=${AUDIT_DIR}'*) echo "  PASS: and the host state dir"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: and the host state dir"; FAIL=$((FAIL + 1)) ;;
esac

# Inside aidc-mcp a host path is reachable only through its mount: writing the host
# spelling there makes a container-local directory the host never sees, and the session
# then binds a path nothing created.
local_path() {
    # $1 = host path, rest = env assignments
    # shellcheck disable=SC2016  # $1/$AIDC_ROOT expand in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" AIDC_ROOT="$AIDC_ROOT" HOME="$SCRATCH/container" \
        AIDC_HOST_HOME="${2:-}" AIDC_MCP_STATE_HOST="${3:-}" AIDC_MCP_STATE_MOUNT="${4:-}" \
        bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            [ -z "$AIDC_HOST_HOME" ] && unset AIDC_HOST_HOME
            [ -z "$AIDC_MCP_STATE_HOST" ] && unset AIDC_MCP_STATE_HOST
            if aidc_resolve_local "$1"; then printf "%s" "$AIDC_LOCAL_PATH"; else printf "unreachable"; fi' _ "$1"
}

eq "on the host a path is itself" "/home/pace/.local/state/aidc-mcp/transcripts/x" \
    "$(local_path /home/pace/.local/state/aidc-mcp/transcripts/x)"
eq "inside aidc-mcp it maps onto the mount" "/var/log/aidc-mcp/transcripts/x" \
    "$(local_path /home/pace/.local/state/aidc-mcp/transcripts/x /home/pace \
        /home/pace/.local/state/aidc-mcp /var/log/aidc-mcp)"
eq "a host path with no mount is unreachable there" "unreachable" \
    "$(local_path /home/pace/.claude/projects/x /home/pace \
        /home/pace/.local/state/aidc-mcp /var/log/aidc-mcp)"

# mcp.session_create: off by default, and what it adds to `docker run` when on.
create_args() {
    # $1 = config body
    printf '%s' "$1" > "$SCRATCH/host/.config/aidc/config.yaml"
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$SCRATCH/host" AIDC_ROOT="$AIDC_ROOT" bash -c '
        . "$AIDC_ROOT/scripts/lib/config.sh"
        mcp_load_settings
        printf "%s|" "$AIDC_MCP_SESSION_CREATE"
        mcp_session_create_args | tr "\n" " "'
}

eq "session_create is off when the key is absent" "false|" \
    "$(create_args 'mcp:
  port: 7878
')"
eq "off when it is false" "false|" \
    "$(create_args 'mcp:
  session_create: false
')"
eq "on it mounts the host home and sets the env" \
    "true|-v $SCRATCH/host:$SCRATCH/host:rw -e AIDC_MCP_SESSION_CREATE=true " \
    "$(create_args 'mcp:
  session_create: true
')"

echo
echo "config sources: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
