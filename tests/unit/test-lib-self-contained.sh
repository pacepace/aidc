#!/usr/bin/env bash
# Every sourced library under scripts/ loads what it calls.
#
# A library that calls a helper (die, err, info, k8s_kubectl, ...) defined in another library
# depends on its caller having sourced that one first. When one has not, `cmd || die ...` is a
# command-not-found that the || swallows, and the failure it was meant to stop passes silently
# (aidc_mkdir_host's chown, 2026-09-17; .claude/rules/learnings/shell-libraries.md). So each
# library defines what it calls or loads it itself (`declare -F f >/dev/null || . lib`, also
# inside the function that needs it), and this test holds every one to that:
#
#   - the libraries are the files under scripts/ that a `.` or `source` line in scripts/ names;
#   - each is sourced alone in a clean `bash --noprofile --norc` (HOME a scratch folder, docker
#     and kubectl stubs first on PATH), which must succeed with no "command not found";
#   - the command words of its own functions (tests/unit/lib/shell-calls.py reads bash's
#     listing of them) that name a function defined anywhere under scripts/ must be among what
#     that sourcing defined, or what a library it names in a `.` line defines. External commands
#     are not functions under scripts/, so they need no allowlist;
#   - HOOKS below are the exception: functions a library's caller supplies by contract, each of
#     which the library's own header must name.
#
# Hygiene: sources the libraries in scratch subshells; nothing they define runs.

set -uo pipefail
export LC_ALL=C   # one sort order for sort, comm and the scanner's sorted output
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/lib-self-contained-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/home"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/bin"

# <library>:<function> its callers supply (the library's header names each).
HOOKS="
lib/claude-front.sh:cf_require
lib/claude-front.sh:cf_state
lib/claude-front.sh:cf_status_label
lib/claude-front.sh:cf_exec
lib/claude-front.sh:cf_exec_tty
lib/claude-front.sh:cf_start
lib/claude-front.sh:cf_stop
lib/claude-front.sh:cf_logs
"

# libraries <scripts-dir>: the paths (lib/x.sh, k8s/y.sh, ...) a source line under it names.
libraries() {
    ( cd "$1" && grep -rhoE '^[[:space:]]*(declare -F [A-Za-z0-9_]+ >/dev/null \|\| )?(\.|source)[[:space:]]+"[^"]*"' . \
        | grep -oE '(lib|k8s|docker|git)/[a-z0-9-]+\.sh' | sort -u \
        | while read -r l; do [ -f "$l" ] && printf '%s\n' "$l"; done )
}

# known_functions <scripts-dir>: every function defined in a file under it.
known_functions() {
    grep -rhoE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$1" \
        | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//' | sort -u
}

# load <scripts-dir> <lib> <out-dir>: sources <lib> alone; writes <out>/rc, <out>/err,
# <out>/loaded (every function defined then) and <out>/code (the listing of its own functions).
load() {
    local dir="$1" lib="$2" out="$3"
    mkdir -p "$out"
    ( cd "$SCRATCH" && env -i HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" \
        XDG_STATE_HOME="$SCRATCH/home/.local/state" PATH="$PATH" \
        AIDC_SCRIPTS="$dir" AIDC_ROOT="$(dirname "$dir")" \
        bash --noprofile --norc -c '
            f=$1 out=$2
            . "$f" </dev/null >/dev/null 2>"$out/err"
            echo "$?" > "$out/rc"
            shopt -s extdebug
            : > "$out/code"
            for fn in $(declare -F | awk "{print \$3}"); do
                echo "$fn"
                set -- $(declare -F "$fn")
                [ "${3:-}" = "$f" ] && declare -f "$fn" >> "$out/code"
            done | sort -u > "$out/loaded"
        ' _ "$dir/$lib" "$out" ) 2>>"$out/err"
}

# check <scripts-dir> <label>: one PASS or FAIL per library under it.
check() {
    local dir="$1" label="$2" work="$SCRATCH/$2" lib key t missing
    mkdir -p "$work"
    known_functions "$dir" > "$work/known"
    libraries "$dir" > "$work/libs"
    while read -r lib; do
        key=$(printf '%s' "$lib" | tr '/.' '__')
        load "$dir" "$lib" "$work/$key"
    done < "$work/libs"
    while read -r lib; do
        key=$(printf '%s' "$lib" | tr '/.' '__')
        if [ "$(cat "$work/$key/rc")" != 0 ] || grep -q 'command not found' "$work/$key/err"; then
            fail "${label}${lib} does not source alone: $(tr '\n' ' ' < "$work/$key/err")"
            continue
        fi
        # What it may call: what sourcing it defined, plus what each library it names defines.
        cp "$work/$key/loaded" "$work/$key/may"
        # A path without its folder (". \"${lib}/x.sh\"", "$(dirname ...)/x.sh") is in the library's own.
        for t in $(grep -vE '^[[:space:]]*#' "$dir/$lib" | grep -E '(^|[[:space:];|&])(\.|source)[[:space:]]+"' \
                | grep -oE '[A-Za-z0-9_}]*/[a-z0-9-]+\.sh' | sort -u); do
            case "${t%%/*}" in lib|k8s|docker|git) ;; *) t="${lib%%/*}/${t##*/}" ;; esac
            t=$(printf '%s' "$t" | tr '/.' '__')
            [ -f "$work/$t/loaded" ] && cat "$work/$t/loaded" >> "$work/$key/may"
        done
        printf '%s\n' "$HOOKS" | sed -n "s|^${lib}:||p" >> "$work/$key/may"
        sort -u -o "$work/$key/may" "$work/$key/may"
        missing=$(python3 "$SCRIPT_DIR/lib/shell-calls.py" < "$work/$key/code" \
            | comm -12 - "$work/known" | comm -23 - "$work/$key/may" | tr '\n' ' ')
        if [ -z "$missing" ]; then pass "${label}${lib}"
        else fail "${label}${lib} calls what it neither defines nor loads: ${missing}"; fi
    done < "$work/libs"
}

echo "=== the check sees what it must (it is not vacuous) ==="
F="$SCRATCH/fake/scripts"
mkdir -p "$F/lib" "$F/k8s"
cat > "$F/lib/common.sh" <<'EOF_FAKE_COMMON'
err() { printf 'error: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
EOF_FAKE_COMMON
cat > "$F/lib/bad.sh" <<'EOF_FAKE_BAD'
bad_run() { false || die "it failed"; }
EOF_FAKE_BAD
cat > "$F/lib/subst.sh" <<'EOF_FAKE_SUBST'
subst_run() { local x; x="$(err "in a substitution")"; case "$1" in die) : ;; esac; echo "die here"; }
EOF_FAKE_SUBST
cat > "$F/lib/good.sh" <<'EOF_FAKE_GOOD'
declare -F die >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
good_run() { false || die "it failed"; printf 'err die\n'; }
EOF_FAKE_GOOD
cat > "$F/lib/lazy.sh" <<'EOF_FAKE_LAZY'
lazy_run() { declare -F die >/dev/null || . "$AIDC_SCRIPTS/lib/common.sh"; die "x"; }
EOF_FAKE_LAZY
cat > "$F/k8s/main.sh" <<'EOF_FAKE_MAIN'
. "$AIDC_SCRIPTS/lib/common.sh"
. "$AIDC_SCRIPTS/lib/bad.sh"
. "$AIDC_SCRIPTS/lib/subst.sh"
. "$AIDC_SCRIPTS/lib/good.sh"
. "$AIDC_SCRIPTS/lib/lazy.sh"
EOF_FAKE_MAIN
fake=$(PASS=0 FAIL=0; check "$F" fake/ ; echo "counts $PASS $FAIL")
case "$fake" in *"FAIL: fake/lib/bad.sh calls what it neither defines nor loads: die "*) pass "a library calling die without loading common.sh is caught" ;;
    *) fail "a library calling die without loading common.sh is caught (got: $fake)" ;; esac
case "$fake" in *"FAIL: fake/lib/subst.sh calls what it neither defines nor loads: err "*) pass "a call inside \$(...) in a string is caught, a case pattern and a message are not" ;;
    *) fail "a call inside \$(...) is caught, a pattern and a message are not (got: $fake)" ;; esac
case "$fake" in *"PASS: fake/lib/good.sh"*) pass "a library that loads common.sh itself passes" ;;
    *) fail "a library that loads common.sh itself passes (got: $fake)" ;; esac
case "$fake" in *"PASS: fake/lib/lazy.sh"*) pass "a library that loads it inside the function passes" ;;
    *) fail "a library that loads it inside the function passes (got: $fake)" ;; esac

echo "=== every hook is named in its library's header ==="
for h in $HOOKS; do
    lib=${h%%:*} fn=${h#*:}
    if awk '!/^#/ && NR > 1 { exit } { print }' "$AIDC_ROOT/scripts/$lib" | grep -qw -- "$fn"; then pass "${lib} names ${fn}"
    else fail "${lib} does not name its hook ${fn} in its header (take it off HOOKS, or document it)"; fi
done

echo "=== every sourced library under scripts/ loads what it calls ==="
libs=$(libraries "$AIDC_ROOT/scripts")
for want in lib/common.sh lib/claude-front.sh k8s/lib.sh k8s/manifests.sh docker/lib.sh; do
    printf '%s\n' "$libs" | grep -qx "$want" || fail "the library list misses ${want} (got: $(printf '%s' "$libs" | tr '\n' ' '))"
done
check "$AIDC_ROOT/scripts" ""

echo
echo "libraries: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
