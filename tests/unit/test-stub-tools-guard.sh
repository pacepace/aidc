#!/usr/bin/env bash
# Holds every unit test to the stub rule (.claude/rules/learnings/core.md, "Tests and the real
# host"): a tests/unit script that runs the aidc CLI, sources or runs a script under scripts/, or
# writes a docker or kubectl stub, must use tests/unit/lib/stub-tools.sh (source it and call
# stub_tools), which puts docker and kubectl stubs first on PATH and refuses to run unless
# `command -v` finds them. The rule had no check, and a test whose stub came first on PATH only
# by luck built images and started containers on the owner's host once the code it ran did real
# work (2026-11-28).
#
# Also checks the helper itself: it refuses when docker or kubectl is not its stub.
#
# Reads files and runs the helper in a scratch folder; runs no docker, kubectl or aidc.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/stub-tools-guard-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Pending: files another change is editing now, to be moved onto the helper once it lands.
# Each must still need the helper (an entry that no longer does is a failure, so this list
# cannot outlive its reason).
PENDING=""

# What puts a test in scope, read from its lines outside comments:
#  - a docker or kubectl stub written: a redirect into a path ending in /docker or /kubectl,
#    or a bin/docker / bin/kubectl path;
#  - the aidc CLI or a script under scripts/ sourced or run: `.`, source, bash, sh or exec of a
#    path under scripts/ ($AIDC_SCRIPTS/..., $AIDC_ROOT/scripts/..., also inside bash -c '...'),
#    or scripts/aidc or a scripts/cmd-*.sh run as a command.
RE_STUB='(>|>>)[[:space:]]*"?[^[:space:]"]*/(docker|kubectl)"?([[:space:]]|$)|bin[0-9]*/(docker|kubectl)([^A-Za-z0-9_.-]|$)'
RE_RUN='(^|[[:space:];&|(`'"'"'"])(\.|source|bash|sh|exec)[[:space:]]+\\?"?\$\{?[A-Za-z0-9_]+\}?/((scripts|aidc/scripts)/)?(aidc"|aidc[[:space:]]|cmd-|lib/|docker/|k8s/|git/)|(^|[[:space:];&|(`]|\$\()[[:space:]]*"?\$\{?[A-Za-z0-9_]+\}?/scripts/(aidc|cmd-[a-z0-9-]+\.sh)"?[[:space:]]+[A-Za-z-]'

# in_scope <file>: 0 when the test needs the helper. The last grep of each pipe reads all of its
# input (no -q): one that stops at its first match leaves the grep before it writing to a closed
# pipe, and under pipefail that SIGPIPE fails the pipe now and then (seen under a parallel run).
in_scope() {
    grep -vE '^[[:space:]]*#' "$1" | grep -E "$RE_STUB|$RE_RUN" >/dev/null
}
# uses_helper <file>: 0 when it sources the helper and calls stub_tools.
uses_helper() {
    grep -vE '^[[:space:]]*#' "$1" | grep -E '^[[:space:]]*(\.|source)[[:space:]]+"?\$\{?SCRIPT_DIR\}?/lib/stub-tools\.sh"?' >/dev/null \
        && grep -vE '^[[:space:]]*#' "$1" | grep -E '(^|[[:space:];&|])stub_tools[[:space:]]+[^[:space:]]' >/dev/null
}

echo "=== the guard sees what it must (it is not vacuous) ==="
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SCRATCH/$1"; }
mk run-cli.sh 'out=$("$AIDC_ROOT/scripts/aidc" claude help 2>&1)'
mk run-cmd.sh 'bash "$AIDC_SCRIPTS/cmd-rebuild.sh" --all'
mk source-lib.sh '. "$AIDC_ROOT/scripts/docker/lib.sh"'
mk source-in-bash-c.sh "staged=\$(bash -c '. \"\$1/scripts/lib/common.sh\" && x' _ \"\$AIDC_ROOT\")"
mk stub-docker.sh 'printf "#!/bin/sh\nexit 0\n" > "$SCRATCH/bin/docker"'
mk stub-kubectl.sh 'cat > "$S/kubectl" <<EOF_X'
mk reads-only.sh 'grep -c "x" "$AIDC_ROOT/scripts/cmd-create.sh"
cmp "$a" "$AIDC_ROOT/scripts/lib/claude-state.sh"
# bash "$AIDC_ROOT/scripts/aidc" in a comment'
mk compliant.sh '. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/bin"
bash "$AIDC_SCRIPTS/cmd-rebuild.sh"'
for f in run-cli run-cmd source-lib source-in-bash-c stub-docker stub-kubectl; do
    if in_scope "$SCRATCH/$f.sh" && ! uses_helper "$SCRATCH/$f.sh"; then pass "a test that does ${f} is caught"
    else fail "a test that does ${f} is not caught"; fi
done
if in_scope "$SCRATCH/reads-only.sh"; then fail "a test that only reads scripts/ files is held to it"
else pass "a test that only reads scripts/ files (grep, cmp, a comment) is not"; fi
if in_scope "$SCRATCH/compliant.sh" && uses_helper "$SCRATCH/compliant.sh"; then pass "a test that sources and calls the helper passes"
else fail "a test that sources and calls the helper does not pass"; fi

echo "=== every unit test that runs aidc, scripts or stubs uses the helper ==="
for f in "$SCRIPT_DIR"/test-*.sh; do
    name=$(basename "$f")
    [ "$name" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
    in_scope "$f" || continue
    case " $PENDING " in
        *" $name "*)
            if uses_helper "$f"; then fail "${name} is on the pending list but uses the helper now: take it off"
            else echo "  PENDING: ${name} (being edited elsewhere; moves onto the helper when that lands)"; fi
            continue ;;
    esac
    if uses_helper "$f"; then pass "$name"
    else fail "${name} runs aidc or scripts/, or stubs docker or kubectl, without tests/unit/lib/stub-tools.sh"; fi
done
for p in $PENDING; do
    [ -f "$SCRIPT_DIR/$p" ] && in_scope "$SCRIPT_DIR/$p" || fail "pending ${p} no longer needs the helper (or is gone): take it off the list"
done

echo "=== the helper refuses a docker or kubectl that is not its stub ==="
# shellcheck source=lib/stub-tools.sh
out=$(PATH="/usr/bin:/bin" bash -c '. "$1/lib/stub-tools.sh"; stub_tools "$2/ok"; command -v docker; command -v kubectl; docker ps; echo "rc=$?"' _ "$SCRIPT_DIR" "$SCRATCH" 2>&1)
case "$out" in *"$SCRATCH/ok/docker"*"$SCRATCH/ok/kubectl"*"not expected here: ps"*"rc=1"*) pass "stub_tools puts failing stubs first on PATH" ;;
    *) fail "stub_tools puts failing stubs first on PATH (got: $out)" ;; esac
mkdir -p "$SCRATCH/own" "$SCRATCH/real"
printf '#!/bin/sh\necho own\n' > "$SCRATCH/own/docker"; chmod +x "$SCRATCH/own/docker"
out=$(PATH="/usr/bin:/bin" bash -c '. "$1/lib/stub-tools.sh"; stub_tools "$2/own"; docker' _ "$SCRIPT_DIR" "$SCRATCH" 2>&1)
[ "$out" = own ] && pass "a stub the test wrote itself is kept" || fail "a stub the test wrote itself is kept (got: $out)"
printf '#!/bin/sh\necho REAL\n' > "$SCRATCH/real/docker"; chmod +x "$SCRATCH/real/docker"
chmod -x "$SCRATCH/own/docker"
out=$(PATH="$SCRATCH/real:/usr/bin:/bin" bash -c '. "$1/lib/stub-tools.sh"; stub_tools "$2/own"; echo ran' _ "$SCRIPT_DIR" "$SCRATCH" 2>&1); rc=$?
case "$rc|$out" in 1*"docker is not the test's stub"*"refusing to run"*) pass "a stub that cannot run (another docker would) refuses the test" ;;
    *) fail "a stub that cannot run refuses the test (rc=$rc: $out)" ;; esac
chmod +x "$SCRATCH/own/docker"
out=$(PATH="/usr/bin:/bin" bash -c '. "$1/lib/stub-tools.sh"; stub_tools "$2/own"; PATH="$2/real:$PATH"; stub_tools_check; echo ran' _ "$SCRIPT_DIR" "$SCRATCH" 2>&1); rc=$?
case "$rc|$out" in 1*"docker is not the test's stub"*) pass "stub_tools_check refuses once another docker comes first" ;;
    *) fail "stub_tools_check refuses once another docker comes first (rc=$rc: $out)" ;; esac

echo
echo "stub-tools guard: passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
