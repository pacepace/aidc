#!/usr/bin/env bash
# Unit test for `aidc list` (scripts/cmd-list.sh).
#
# The case that motivated it: the listing asked `docker ps` for `{{json .}}`,
# which includes Size, and the daemon then summed each dev container's writable
# layer on disk. With two 70-80 GB sessions `aidc list` took over two minutes and
# the MCP's session_list gave up at 60s. The query must name only the columns the
# listing prints, and never Size.
#
# `docker` is a PATH stub that logs every call, so no daemon is needed.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/list-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin"

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# docker stub. `ps` prints $PS_OUT (name<TAB>status lines) for the label filter
# and nothing for the name fallback; `inspect` answers the profile label and the
# start time; `exec ... test -f /var/state/tainted` succeeds only for the policy
# container named in $TAINTED. Every call is appended to $DOCKER_LOG.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
    info) exit 0 ;;
    ps)
        case "$*" in *label=aidc.role=dev*) printf '%b' "$PS_OUT" ;; esac
        exit 0 ;;
    inspect)
        case "$*" in
            *aidc.profile*) echo "python" ;;
            *StartedAt*)    echo "2026-09-22T04:49:18Z" ;;
        esac
        exit 0 ;;
    exec)
        [ "$2" = "${TAINTED:-}" ] && exit 0
        exit 1 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"

run_list() {   # env assignments...
    : > "$SCRATCH/docker.log"
    env -i PATH="$SCRATCH/bin:/usr/bin:/bin" AIDC_SCRIPTS="$AIDC_ROOT/scripts" \
        DOCKER_LOG="$SCRATCH/docker.log" "$@" \
        bash "$AIDC_ROOT/scripts/cmd-list.sh"
}

echo "test: docker ps asks only for the columns it prints"
run_list PS_OUT='aidc-alpha-dev\tUp 6 days\n' >/dev/null
ps_calls=$(grep -c '^ps ' "$SCRATCH/docker.log")
assert_eq "docker ps was called" "yes" "$([ "$ps_calls" -ge 1 ] && echo yes || echo no)"
assert_eq "no ps query names Size" "0" "$(grep '^ps ' "$SCRATCH/docker.log" | grep -c 'Size')"
assert_eq "no ps query renders the whole record" "0" "$(grep '^ps ' "$SCRATCH/docker.log" | grep -c 'json')"
assert_eq "no ps query passes --size" "0" "$(grep '^ps ' "$SCRATCH/docker.log" | grep -cE -- '(^| )(-s|--size)( |$)')"

echo "test: rows carry session, status with spaces, profile, start time, taint"
out=$(run_list PS_OUT='aidc-alpha-dev\tUp 6 days\naidc-beta-dev\tExited (0) 2 hours ago\n' \
    TAINTED=aidc-beta-policy)
assert_eq "header first" "SESSION STATUS PROFILE STARTED TAINTED" \
    "$(printf '%s\n' "$out" | sed -n 1p | tr -s ' ')"
assert_eq "running session row" "alpha Up 6 days python 2026-09-22T04:49:18Z no" \
    "$(printf '%s\n' "$out" | sed -n 2p | tr -s ' ')"
assert_eq "exited, tainted session row" "beta Exited (0) 2 hours ago python 2026-09-22T04:49:18Z YES" \
    "$(printf '%s\n' "$out" | sed -n 3p | tr -s ' ')"

echo "test: no sessions"
out=$(run_list PS_OUT='')
assert_eq "empty message" "No active aidc sessions." "$out"
# An empty label query falls back to finding older sessions by container name;
# that query must stay just as narrow.
assert_eq "fallback name query ran" "1" "$(grep '^ps ' "$SCRATCH/docker.log" | grep -c 'name=')"
assert_eq "no ps query names Size or the whole record" "0" \
    "$(grep '^ps ' "$SCRATCH/docker.log" | grep -cE 'Size|json|(^| )(-s|--size)( |$)')"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
