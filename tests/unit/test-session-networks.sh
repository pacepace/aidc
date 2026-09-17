#!/usr/bin/env bash
# Unit test for removing a session's networks (remove_session_networks in
# scripts/lib/common.sh) and for the order `aidc kill` does it in.
#
# Why it matters: aidc-mcp identifies a session by the id of aidc-<s>-net.
# `docker compose down` leaves a network in place, printing "Resource is still in
# use" and exiting 0 (measured on Docker 29.8 / Compose 5.5), while a container
# outside the project is attached: an `aidc proxy` forwarder, or another session
# joined with `aidc network`. `aidc kill` used to remove the forwarders only after
# the down, so a killed session's network survived: the MCP kept treating the
# session as alive, and a session created again under the name reused the network,
# id and all, inheriting the old one's queued prompts.
#
# `docker` is a PATH stub that keeps network state in files, so no daemon is needed.
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/session-networks-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/state" "$SCRATCH/home"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# A network exists while state/net-<name> exists; the file lists attached containers.
# `network rm` refuses while anything is attached, unless STUCK names the network,
# which refuses always. Every call is appended to state/calls.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/usr/bin/env bash
S="$STUB_STATE"
echo "$*" >> "$S/calls"
case "$1 $2" in
    "network inspect")
        [ -f "$S/net-$3" ] || { echo "Error response from daemon: network $3 not found" >&2; exit 1; }
        [ "${4:-}" = "--format" ] && tr '\n' ' ' < "$S/net-$3"
        exit 0 ;;
    "network disconnect")
        f="$S/net-$4"; grep -vx "$5" "$f" > "$f.new"; mv "$f.new" "$f"; exit 0 ;;
    "network rm")
        [ "${STUCK:-}" = "$3" ] && exit 1
        [ -s "$S/net-$3" ] && { echo "Error: network $3 has active endpoints" >&2; exit 1; }
        rm -f "$S/net-$3"; exit 0 ;;
    "ps -a")
        case "$*" in *fwd*) echo fwd-id ;; *label=aidc.session*) echo dev-id ;; esac
        exit 0 ;;
    "rm -f")
        # A forwarder removed is detached from every network.
        for f in "$S"/net-*; do [ -f "$f" ] || continue
            grep -vx "aidc-killme-fwd-8002" "$f" > "$f.new"; mv "$f.new" "$f"; done
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"

reset_state() {
    rm -f "$SCRATCH"/state/*
    : > "$SCRATCH/state/calls"
}

run_helper() {
    # shellcheck disable=SC2016  # $1 expands in the inner shell, on purpose
    env PATH="$SCRATCH/bin:/usr/bin:/bin" STUB_STATE="$SCRATCH/state" STUCK="${STUCK:-}" \
        bash -c '. "$1"; remove_session_networks killme' _ "$AIDC_ROOT/scripts/lib/common.sh"
}

echo "=== session networks ==="

# 1. A network with an outside container still attached is detached and removed.
reset_state
printf 'aidc-killme-fwd-8002\n' > "$SCRATCH/state/net-aidc-killme-net"
: > "$SCRATCH/state/net-aidc-killme-egress"
run_helper 2>/dev/null; rc=$?
eq "returns success" 0 "$rc"
eq "the session network is gone" "no" "$([ -f "$SCRATCH/state/net-aidc-killme-net" ] && echo yes || echo no)"
eq "the egress network is gone" "no" "$([ -f "$SCRATCH/state/net-aidc-killme-egress" ] && echo yes || echo no)"
eq "the attached container was disconnected first" \
    "network disconnect -f aidc-killme-net aidc-killme-fwd-8002" \
    "$(grep -m1 'network disconnect' "$SCRATCH/state/calls")"

# 2. No networks: nothing to do, no error.
reset_state
run_helper 2>/dev/null; rc=$?
eq "no networks is success" 0 "$rc"
eq "and removes nothing" "0" "$(grep -c 'network rm' "$SCRATCH/state/calls")"

# 3. A network that will not go is reported, loudly.
reset_state
: > "$SCRATCH/state/net-aidc-killme-net"
err=$(STUCK=aidc-killme-net run_helper 2>&1 >/dev/null); rc=$?
eq "a stuck network fails" 1 "$rc"
eq "and names it" "[aidc] error: could not remove network(s) of session 'killme': aidc-killme-net" "$err"

# 4. `aidc kill` removes forwarders before `compose down`, and leaves no network.
reset_state
printf 'aidc-killme-fwd-8002\n' > "$SCRATCH/state/net-aidc-killme-net"
: > "$SCRATCH/state/net-aidc-killme-egress"
env PATH="$SCRATCH/bin:/usr/bin:/bin" STUB_STATE="$SCRATCH/state" HOME="$SCRATCH/home" \
    AIDC_SCRIPTS="$AIDC_ROOT/scripts" bash "$AIDC_ROOT/scripts/cmd-kill.sh" killme >/dev/null 2>&1
rc=$?
eq "kill succeeds" 0 "$rc"
fwd_line=$(grep -n '^rm -f fwd-id' "$SCRATCH/state/calls" | head -1 | cut -d: -f1)
down_line=$(grep -n '^compose .*down' "$SCRATCH/state/calls" | head -1 | cut -d: -f1)
eq "forwarders go before compose down" "yes" \
    "$([ -n "$fwd_line" ] && [ -n "$down_line" ] && [ "$fwd_line" -lt "$down_line" ] && echo yes || echo no)"
eq "kill leaves no session network" "no" \
    "$(ls "$SCRATCH"/state/net-* >/dev/null 2>&1 && echo yes || echo no)"

# 5. A network that survives makes kill fail loudly instead of reporting success.
reset_state
: > "$SCRATCH/state/net-aidc-killme-net"
out=$(env PATH="$SCRATCH/bin:/usr/bin:/bin" STUB_STATE="$SCRATCH/state" HOME="$SCRATCH/home" \
    STUCK=aidc-killme-net AIDC_SCRIPTS="$AIDC_ROOT/scripts" \
    bash "$AIDC_ROOT/scripts/cmd-kill.sh" killme 2>&1)
rc=$?
eq "kill with a stuck network fails" 1 "$rc"
case "$out" in
    *"still treats it as a live session"*) echo "  PASS: and says why"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: and says why (got: $out)"; FAIL=$((FAIL + 1)) ;;
esac

echo
echo "session networks: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
