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
mkdir -p "$SCRATCH/host/.config/aidc" "$SCRATCH/mount" "$SCRATCH/empty" "$SCRATCH/container" \
         "$SCRATCH/bin"

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
# then binds a path nothing created. AIDC_MCP_MOUNTS is the one list `aidc mcp start`
# builds the -v flags from, so the two cannot disagree.
STATE_MOUNTS="/home/pace/.local/state/aidc-mcp|/var/log/aidc-mcp,/home/pace/aidc-audit|/var/aidc-audit"
HOME_MOUNTS="${STATE_MOUNTS},/home/pace|/home/pace"

local_path() {
    # $1 = host path, $2 = AIDC_MCP_MOUNTS ("" for a host run)
    # shellcheck disable=SC2016  # $1/$AIDC_ROOT expand in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" AIDC_ROOT="$AIDC_ROOT" HOME="$SCRATCH/container" \
        AIDC_HOST_HOME="${3:-}" AIDC_MCP_MOUNTS="${2:-}" \
        bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            [ -z "$AIDC_HOST_HOME" ] && unset AIDC_HOST_HOME
            if aidc_resolve_local "$1"; then printf "%s" "$AIDC_LOCAL_PATH"; else printf "unreachable"; fi' _ "$1"
}

eq "on the host a path is itself" "/home/pace/.local/state/aidc-mcp/transcripts/x" \
    "$(local_path /home/pace/.local/state/aidc-mcp/transcripts/x)"
eq "inside aidc-mcp it maps onto the mount" "/var/log/aidc-mcp/transcripts/x" \
    "$(local_path /home/pace/.local/state/aidc-mcp/transcripts/x "$STATE_MOUNTS" /home/pace)"
eq "a host path with no mount is unreachable there" "unreachable" \
    "$(local_path /srv/somewhere-else "$STATE_MOUNTS" /home/pace)"
# The defect three reviewers found in the first cut: the operator turned the home mount
# on and Claude's per-project memory was still reported as unreachable.
eq "with the home mount, the memory dir is reachable at its own path" \
    "/home/pace/.claude/projects/x" \
    "$(local_path /home/pace/.claude/projects/x "$HOME_MOUNTS" /home/pace)"
eq "and without it, it is not" "unreachable" \
    "$(local_path /home/pace/.claude/projects/x "$STATE_MOUNTS" /home/pace)"

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
eq "on it sets the env that makes the tool exist" \
    "true|-e AIDC_MCP_SESSION_CREATE=true " \
    "$(create_args 'mcp:
  session_create: true
')"

# The mount itself comes from the same list as every other one, so the -v flags and the
# reachability table cannot disagree.
mount_args() {
    printf '%s' "$1" > "$SCRATCH/host/.config/aidc/config.yaml"
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$SCRATCH/host" AIDC_ROOT="$AIDC_ROOT" bash -c '
        . "$AIDC_ROOT/scripts/lib/config.sh"
        load_config >/dev/null 2>&1
        mcp_load_settings
        mcp_mount_args | tr "\n" " "'
}
case "$(mount_args 'mcp:
  session_create: true
')" in
    *"-v $SCRATCH/host:$SCRATCH/host:rw"*) echo "  PASS: the -v flags carry the home when enabled"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: the -v flags carry the home when enabled"; FAIL=$((FAIL + 1)) ;;
esac
case "$(mount_args 'mcp:
  session_create: false
')" in
    *"-v $SCRATCH/host:$SCRATCH/host:rw"*) echo "  FAIL: and not when it is off"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: and not when it is off (-v)"; PASS=$((PASS + 1)) ;;
esac

# The mount list `aidc mcp start` passes as AIDC_MCP_MOUNTS: mcp_mount_args builds the
# -v flags from this same function, so a mount cannot be granted without being reachable.
mounts_env() {
    printf '%s' "$1" > "$SCRATCH/host/.config/aidc/config.yaml"
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$SCRATCH/host" AIDC_ROOT="$AIDC_ROOT" bash -c '
        . "$AIDC_ROOT/scripts/lib/config.sh"
        load_config >/dev/null 2>&1
        mcp_load_settings
        mcp_mounts_env'
}

contains_home=$(mounts_env 'mcp:
  session_create: true
')
case "$contains_home" in
    *"$SCRATCH/host|$SCRATCH/host"*) echo "  PASS: the mount list carries the home when enabled"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: the mount list carries the home when enabled (got: $contains_home)"; FAIL=$((FAIL + 1)) ;;
esac
contains_home=$(mounts_env 'mcp:
  session_create: false
')
case "$contains_home" in
    *"$SCRATCH/host|$SCRATCH/host"*) echo "  FAIL: the mount list must not carry the home when off"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: and not when it is off"; PASS=$((PASS + 1)) ;;
esac

# aidc_mkdir_host: what it creates, and who it hands it to. A directory left owned by
# the creating process is one the session's own mirror cannot write, which is the silent
# no-reply-ever failure this whole path exists to prevent — so the handoff is pinned, and
# a chown that cannot happen must be loud.
mkdir_host() {
    # $1 = host path, $2 = mounts, $3 = host home, $4 = "fail" to make chown fail
    # shellcheck disable=SC2016  # expansions are for the inner shell, on purpose
    env -i PATH="$SCRATCH/bin:/usr/bin:/bin" AIDC_ROOT="$AIDC_ROOT" HOME="$SCRATCH/container" \
        AIDC_HOST_HOME="$3" AIDC_MCP_MOUNTS="$2" CHOWN_FAIL="${4:-}" STUB_STATE="$STUB_STATE" \
        bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            if aidc_mkdir_host "$1"; then printf "%s owner=%s" "$AIDC_LOCAL_PATH" "$AIDC_HOST_OWNER"; else printf "refused"; fi' _ "$1"
}

# Fake stat/chown/id so the test does not need root or a real mount: the mount root
# "belongs to" 4242:4242, and chown records what it was asked to do.
cat > "$SCRATCH/bin/stat" <<'STUB'
#!/bin/sh
printf '4242:4242
'
STUB
cat > "$SCRATCH/bin/chown" <<'STUB'
#!/bin/sh
[ -n "${CHOWN_FAIL:-}" ] && exit 1
shift  # -R
printf '%s
' "$*" >> "$STUB_STATE/chowns"
exit 0
STUB
chmod +x "$SCRATCH/bin/stat" "$SCRATCH/bin/chown"
export STUB_STATE="$SCRATCH/state"
mkdir -p "$STUB_STATE"

mkdir -p "$SCRATCH/mnt"
: > "$STUB_STATE/chowns"
out=$(mkdir_host "/host/state/transcripts/sess" \
    "/host/state|$SCRATCH/mnt" /home/pace)
eq "it creates the path through the mount" "$SCRATCH/mnt/transcripts/sess owner=4242:4242" "$out"
eq "and hands over the topmost dir it created, not just the leaf" \
    "4242:4242 $SCRATCH/mnt/transcripts" "$(head -1 "$STUB_STATE/chowns")"
eq "the directory exists" "yes" \
    "$([ -d "$SCRATCH/mnt/transcripts/sess" ] && echo yes || echo no)"

out=$(mkdir_host "/host/state/other" "/host/state|$SCRATCH/mnt" \
    /home/pace fail 2>/dev/null)
eq "a chown it cannot do stops the create instead of leaving it unwritable" "refused" "$out"

out=$(mkdir_host "/elsewhere/x" "/host/state|$SCRATCH/mnt" /home/pace)
eq "a path outside every mount is refused" "refused" "$out"

echo
echo "config sources: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
