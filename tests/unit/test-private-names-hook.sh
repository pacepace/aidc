#!/usr/bin/env bash
# Unit test for scripts/hooks/pre-commit: a staged change naming something on the maintainer's
# private-names list (kept outside the repo) is refused, the list never printed; with no list
# the commit goes through, said.
#
# Hygiene: scratch lives under tests/scratch/ (gitignored); a throwaway git repo there.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/private-names-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

assert_eq() {
    if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1 (want '$2', got '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_has() {
    case "$3" in *"$2"*) echo "  PASS: $1"; PASS=$((PASS + 1)) ;; *) echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL + 1)) ;; esac
}

R="$SCRATCH/repo"
git init -q "$R"
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name t
HOOK="$AIDC_ROOT/scripts/hooks/pre-commit"
LIST="$SCRATCH/private-names"
printf '# mine\n\nsecretcorp\nhost-[0-9]+\\.lan\n' > "$LIST"
run() { (cd "$R" && AIDC_PRIVATE_NAMES="$LIST" bash "$HOOK" 2>&1; echo "|$?"); }

echo "== a clean change goes through"
echo "nothing here" > "$R/a.txt"; git -C "$R" add a.txt
assert_eq "exit 0" "|0" "$(run | tail -1)"

echo "== a change naming a listed name is refused"
echo "deploy to SecretCorp now" > "$R/b.txt"; git -C "$R" add b.txt
out=$(run)
assert_eq "exit 1" "|1" "$(printf '%s' "$out" | tail -1)"
assert_has "it shows the matching line" "deploy to SecretCorp now" "$out"
assert_eq "it never prints the list" "0" "$(printf '%s' "$out" | grep -c 'host-\[0-9\]')"
git -C "$R" rm -q --cached b.txt

echo "== a pattern, a file name"
echo "x" > "$R/host-12.lan.md"; git -C "$R" add host-12.lan.md
assert_eq "a file named for one is refused" "|1" "$(run | tail -1)"
git -C "$R" rm -q --cached host-12.lan.md

echo "== only what the commit adds"
git -C "$R" commit -q -m one --no-verify
echo "secretcorp" > "$R/old.txt"; git -C "$R" add old.txt; git -C "$R" commit -q -m two --no-verify
printf 'secretcorp\nmore\n' > "$R/old.txt"; git -C "$R" add old.txt
assert_eq "a line already there is not this commit's" "|0" "$(run | tail -1)"

echo "== with no list"
out=$(cd "$R" && AIDC_PRIVATE_NAMES="$SCRATCH/none" bash "$HOOK" 2>&1; echo "|$?")
assert_eq "it lets the commit through" "|0" "$(printf '%s' "$out" | tail -1)"
assert_has "and says names were not checked" "names not checked" "$out"

echo
echo "private-names hook: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
