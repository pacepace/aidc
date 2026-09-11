#!/usr/bin/env bash
# Unit test for the two in-place edits `aidc upgrade` makes to a session's
# create-time compose file (scripts/lib/common.sh):
#
#   aidc_strip_legacy_auth_mounts  -- a session created before v1.5.0 mounts the
#       host's login files where the new image reads its own; the mounts must go.
#   aidc_set_compose_dev_image     -- the file pins the dev image at the tag that
#       was current at create time; recreating from it unchanged brought the
#       container back on the OLD tag, so `upgrade` moved nothing across a
#       version bump (CLI-17).
#
# No Docker required. Scratch lives under tests/scratch/ (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/common.sh
. "$AIDC_ROOT/scripts/lib/common.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/upgrade-compose-unit-$$"
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

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

COMPOSE="$SCRATCH/aidc-old.yaml"
cat > "$COMPOSE" <<'EOF'
services:
  squid:
    image: aidc/squid:v1.4.1
  dev:
    image: aidc/dev-base:v1.4.1
    volumes:
      - /work/repo:/work/repo:rw
      - dev-home:/home/vscode:rw
      - /Users/me/aidc-audit/s/.claude-credentials.json:/home/vscode/.claude/.credentials.json:rw
      - /home/me/.claude/settings.json:/home/vscode/.claude/settings.json:rw
      - /home/me/.claude.json:/home/vscode/.claude.json:ro
      - /home/me/.claude/projects/-work-repo:/home/vscode/.claude/projects/-work-repo:rw
EOF
chmod 600 "$COMPOSE"

echo "[1/2] aidc_strip_legacy_auth_mounts"
assert "strip reports it removed something" "aidc_strip_legacy_auth_mounts '$COMPOSE'"
assert "the credentials mount is gone" "! grep -q '.credentials.json' '$COMPOSE'"
assert "the ~/.claude.json mount is gone" "! grep -q '/home/vscode/.claude.json:ro' '$COMPOSE'"
assert "settings, memory, repo and dev-home mounts survive" \
    "grep -q 'settings.json:rw' '$COMPOSE' && grep -q 'projects/-work-repo:rw' '$COMPOSE' && grep -q '/work/repo:rw' '$COMPOSE' && grep -q 'dev-home:/home/vscode:rw' '$COMPOSE'"
assert "the file keeps its 0600 mode" "[ \"\$(mode_of '$COMPOSE')\" = 600 ]"
assert "no temp file is left behind" "! ls '$SCRATCH'/aidc-old.yaml.strip.* >/dev/null 2>&1"
assert "a second strip finds nothing and returns 1" "! aidc_strip_legacy_auth_mounts '$COMPOSE'"
echo

echo "[2/2] aidc_set_compose_dev_image"
assert "rewrite succeeds" "aidc_set_compose_dev_image '$COMPOSE' aidc/dev-base:v1.5.0"
assert "the dev service now pins the new tag" "grep -q '^    image: aidc/dev-base:v1.5.0$' '$COMPOSE'"
assert "the old dev tag is gone" "! grep -q 'aidc/dev-base:v1.4.1' '$COMPOSE'"
assert "sidecar images are untouched (--no-deps never recreates them)" "grep -q '^    image: aidc/squid:v1.4.1$' '$COMPOSE'"
assert "the file keeps its 0600 mode" "[ \"\$(mode_of '$COMPOSE')\" = 600 ]"
assert "no temp file is left behind" "! ls '$SCRATCH'/aidc-old.yaml.image.* >/dev/null 2>&1"
assert "rewriting to the same tag is a no-op success" \
    "aidc_set_compose_dev_image '$COMPOSE' aidc/dev-base:v1.5.0 && grep -c 'aidc/dev-base:v1.5.0' '$COMPOSE' | grep -qx 1"
printf 'services:\n  dev:\n    image: something-else:1\n' > "$SCRATCH/odd.yaml"
assert "a file with no dev-base image line fails loudly" "! aidc_set_compose_dev_image '$SCRATCH/odd.yaml' aidc/dev-base:v1.5.0"
assert "and is left unchanged" "grep -q 'something-else:1' '$SCRATCH/odd.yaml'"
echo

echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
