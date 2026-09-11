#!/usr/bin/env bash
# Unit test for the ~/.claude.json seed filter (scripts/lib/claude-state.sh).
#
# The dev container owns its Claude config directory and logs in on its own.
# The only thing it takes from the host's ~/.claude.json is onboarding state
# plus this project's trust entry -- never the host's account and never another
# project's state. This test pins that boundary against the shipped filter.
#
# No Docker required. Hygiene: scratch lives under tests/scratch/ (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/claude-state.sh
. "$AIDC_ROOT/scripts/lib/claude-state.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/claude-state-unit-$$"
PASS=0
FAIL=0
cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$SCRATCH"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "        cmd: $cmd"; FAIL=$((FAIL + 1))
    fi
}

HOST="$SCRATCH/claude.json"
cat > "$HOST" <<'EOF'
{
  "hasCompletedOnboarding": true,
  "theme": "dark",
  "editorMode": "vim",
  "numStartups": 42,
  "oauthAccount": {"emailAddress": "someone@example.com", "organizationUuid": "org-1"},
  "projects": {
    "/code/org/app": {"hasTrustDialogAccepted": true, "allowedTools": ["Bash"]},
    "/code/org/lib": {"hasTrustDialogAccepted": true},
    "/code/org/app/sub": {"hasTrustDialogAccepted": true},
    "/code/other": {"hasTrustDialogAccepted": true, "history": [{"display": "secret prompt"}]},
    "/code/org": {"hasTrustDialogAccepted": true}
  }
}
EOF

echo "[1/3] single-repo session (workspace == repo)"
OUT="$SCRATCH/single.json"
aidc_claude_state_seed "$HOST" /code/org/app /code/org/app > "$OUT"
assert "output is valid JSON" "jq -e . '$OUT'"
assert "onboarding state is kept" "jq -e '.hasCompletedOnboarding == true and .theme == \"dark\" and .editorMode == \"vim\"' '$OUT'"
assert "host account is dropped" "jq -e 'has(\"oauthAccount\") | not' '$OUT'"
assert "this repo's project entry is kept" "jq -e '.projects[\"/code/org/app\"].hasTrustDialogAccepted == true' '$OUT'"
assert "a subdirectory of the repo is kept" "jq -e '.projects | has(\"/code/org/app/sub\")' '$OUT'"
assert "a sibling project is dropped" "jq -e '.projects | has(\"/code/org/lib\") | not' '$OUT'"
assert "an unrelated project (with history) is dropped" "jq -e '.projects | has(\"/code/other\") | not' '$OUT'"
assert "the parent directory is dropped" "jq -e '.projects | has(\"/code/org\") | not' '$OUT'"
echo

echo "[2/3] workspace session (siblings mounted)"
OUT="$SCRATCH/ws.json"
aidc_claude_state_seed "$HOST" /code/org/app /code/org > "$OUT"
assert "repo, siblings and the workspace root are kept" \
    "jq -e '(.projects | keys | sort) == [\"/code/org\",\"/code/org/app\",\"/code/org/app/sub\",\"/code/org/lib\"]' '$OUT'"
assert "unrelated project still dropped" "jq -e '.projects | has(\"/code/other\") | not' '$OUT'"
assert "host account still dropped" "jq -e 'has(\"oauthAccount\") | not' '$OUT'"
echo

echo "[3/3] edge cases"
printf '{"hasCompletedOnboarding": true}' > "$SCRATCH/noprojects.json"
assert "a file with no projects key yields an empty projects map" \
    "aidc_claude_state_seed '$SCRATCH/noprojects.json' /r /r | jq -e '.projects == {}'"
printf 'not json' > "$SCRATCH/bad.json"
assert "unparseable input fails (caller falls back to in-container onboarding)" \
    "! aidc_claude_state_seed '$SCRATCH/bad.json' /r /r"
echo

echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
