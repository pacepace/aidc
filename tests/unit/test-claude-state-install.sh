#!/usr/bin/env bash
# Unit test for the container's first-start Claude state install
# (.devcontainer/claude-state-install.sh): the empty-placeholder sweep and the
# onboarding-seed install that user-main.sh runs before launching Claude.
#
# No Docker required: sources the exact functions user-main.sh runs inside the
# container. Scratch lives under tests/scratch/ (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../.devcontainer/claude-state-install.sh
. "$AIDC_ROOT/.devcontainer/claude-state-install.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/claude-state-install-unit-$$"
HOMEDIR="$SCRATCH/home"
CFG="$HOMEDIR/.claude"
PASS=0
FAIL=0
cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$CFG"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "        cmd: $cmd"; FAIL=$((FAIL + 1))
    fi
}

echo "[1/3] aidc_clear_mount_placeholders"
assert "nothing present is a silent no-op" \
    "[ -z \"\$(aidc_clear_mount_placeholders '$CFG' '$HOMEDIR')\" ]"
: > "$CFG/.credentials.json"
: > "$HOMEDIR/.claude.json"
# shellcheck disable=SC2034  # read inside the eval'd assert string below
OUT=$(aidc_clear_mount_placeholders "$CFG" "$HOMEDIR")
assert "both empty placeholders are removed" \
    "[ ! -e '$CFG/.credentials.json' ] && [ ! -e '$HOMEDIR/.claude.json' ]"
assert "each removal is reported by path" \
    "printf '%s' \"\$OUT\" | grep -q '.credentials.json' && printf '%s' \"\$OUT\" | grep -q '/.claude.json'"
printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$CFG/.credentials.json"
printf '{"hasCompletedOnboarding":true}' > "$HOMEDIR/.claude.json"
assert "files with content are never touched" \
    "[ -z \"\$(aidc_clear_mount_placeholders '$CFG' '$HOMEDIR')\" ] && [ -s '$CFG/.credentials.json' ] && [ -s '$HOMEDIR/.claude.json' ]"
rm -f "$CFG/.credentials.json" "$HOMEDIR/.claude.json"
echo

echo "[1b/3] aidc_install_claude_settings_seed"
SEEDS="$SCRATCH/seed"; mkdir -p "$SEEDS"
printf '{"theme":"dark","hooks":{}}' > "$SEEDS/settings.json"
assert "first start: the copy is installed" \
    "aidc_install_claude_settings_seed '$CFG' '$SEEDS/settings.json' && cmp -s '$SEEDS/settings.json' '$CFG/settings.json'"
assert "and is private to the user" \
    "[ \"\$(stat -c %a '$CFG/settings.json')\" = 600 ]"
printf '{"theme":"light"}' > "$CFG/settings.json"
assert "a later start never overwrites what the session changed" \
    "! aidc_install_claude_settings_seed '$CFG' '$SEEDS/settings.json' && grep -q light '$CFG/settings.json'"
rm -f "$CFG/settings.json"
assert "no seed: nothing installed, nothing created" \
    "! aidc_install_claude_settings_seed '$CFG' '$SEEDS/missing.json' && [ ! -e '$CFG/settings.json' ]"

echo "[2/3] aidc_install_claude_state_seed"
SEED="$SCRATCH/claude-state-seed.json"
assert "no seed file -> nothing to do (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED'; [ \$? -eq 1 ] && [ ! -e '$CFG/.claude.json' ]"
printf '{"hasCompletedOnboarding":true,"theme":"dark"}' > "$SEED"
assert "seed installs into an empty config dir (0)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && grep -q hasCompletedOnboarding '$CFG/.claude.json'"
assert "installed file is private (0600)" \
    "[ \"\$(stat -c %a '$CFG/.claude.json' 2>/dev/null || stat -f %Lp '$CFG/.claude.json')\" = 600 ]"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"me@example.com"}}' > "$CFG/.claude.json"
assert "an existing .claude.json (a login lives in it) is never overwritten (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED'; [ \$? -eq 1 ] && grep -q me@example.com '$CFG/.claude.json'"
rm -rf "$CFG"
assert "a missing config dir is created on the way (0)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && [ -s '$CFG/.claude.json' ]"
: > "$SCRATCH/empty-seed.json"
rm -f "$CFG/.claude.json"
assert "an empty seed is treated as absent (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SCRATCH/empty-seed.json'; [ \$? -eq 1 ] && [ ! -e '$CFG/.claude.json' ]"
echo

echo "[2b/3] aidc_claim_docker_made_dirs"
# Docker materialises a missing bind-mount source on the host as root 0755 at every
# container start, not just at create. The memory dir it made that way on 2026-10-19
# left Claude unable to save a single message for half an hour, and the MCP blind to
# every reply. A stub stat/chown pair stands in for root: dirs whose own name holds root-made are
# "owned by uid 0", and chown records what it was asked to do.
STUBS="$SCRATCH/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/stat" <<'STUB'
#!/bin/sh
eval "p=\${$#}"
case "${p##*/}" in *root-made*) echo 0 ;; *) echo 1000 ;; esac
STUB
cat > "$STUBS/chown" <<'STUB'
#!/bin/sh
[ -n "${CHOWN_FAIL:-}" ] && exit 1
printf '%s\n' "$*" >> "$CHOWNS"
STUB
chmod +x "$STUBS/stat" "$STUBS/chown"
CLAIM="$SCRATCH/claim"
mkdir -p "$CLAIM/projects-root-made/-repo-root-made/sub-root-made" "$CLAIM/projects-root-made/-other" \
    "$CLAIM/tmp/-repo-root-made"
export CHOWNS="$SCRATCH/chowns"
claim() { : > "$CHOWNS"; PATH="$STUBS:$PATH" aidc_claim_docker_made_dirs vscode:vscode - "$@"; }
# shellcheck disable=SC2034  # read inside the eval'd assert string below
OUT=$(claim "$CLAIM/projects-root-made" "$CLAIM/tmp")
assert "a root-owned parent and its root-owned children go to the session user" \
    "grep -qx 'vscode:vscode $CLAIM/projects-root-made' '$CHOWNS' && grep -qx 'vscode:vscode $CLAIM/projects-root-made/-repo-root-made' '$CHOWNS' && grep -qx 'vscode:vscode $CLAIM/tmp/-repo-root-made' '$CHOWNS'"
assert "a dir the host user owns is never re-owned" \
    "! grep -q -- '-other' '$CHOWNS' && ! grep -qx 'vscode:vscode $CLAIM/tmp' '$CHOWNS'"
assert "never recursive: what lives inside a bridged dir is the host's" \
    "! grep -q -- 'sub-root-made' '$CHOWNS' && ! grep -q -- '-R' '$CHOWNS'"
assert "each claim is reported by path" \
    "printf '%s' \"\$OUT\" | grep -qx 'claimed $CLAIM/tmp/-repo-root-made'"
assert "a parent that does not exist is skipped quietly" \
    "claim '$CLAIM/absent' && [ ! -s '$CHOWNS' ]"
# shellcheck disable=SC2034  # read inside the eval'd assert string below
OUT=$(CHOWN_FAIL=1 claim "$CLAIM/tmp"; echo "rc=$?")
assert "a chown that fails is reported and returns non-zero, so the caller can warn" \
    "printf '%s' \"\$OUT\" | grep -qx 'transcript-unwritable: could not claim $CLAIM/tmp/-repo-root-made' && printf '%s' \"\$OUT\" | grep -qx 'rc=1'"
mkdir -p "$CLAIM/scratch/-repo-root-made"; chmod 0755 "$CLAIM/scratch/-repo-root-made"
: > "$CHOWNS"
PATH="$STUBS:$PATH" aidc_claim_docker_made_dirs vscode:vscode 0700 "$CLAIM/scratch" >/dev/null
assert "a claimed scratchpad dir gets the mode it was asked for (0700, not Docker's 0755)" \
    "[ \"\$(stat -c %a '$CLAIM/scratch/-repo-root-made')\" = 700 ]"
assert "while '-' leaves the mode alone" \
    "[ \"\$(stat -c %a '$CLAIM/tmp/-repo-root-made')\" != 700 ]"
# The entrypoint's pass, under set -e as entrypoint.sh runs it: a chown that fails on
# the memory side must not stop the scratchpad side being claimed.
cat > "$STUBS/chown-fail-projects" <<'STUB'
#!/bin/sh
case "$2" in *projects*) exit 1 ;; esac
printf '%s\n' "$*" >> "$CHOWNS"
STUB
chmod +x "$STUBS/chown-fail-projects"
mkdir -p "$STUBS/failproj"; cp "$STUBS/stat" "$STUBS/failproj/stat"; cp "$STUBS/chown-fail-projects" "$STUBS/failproj/chown"
mkdir -p "$CLAIM/scratch2/-repo-root-made"
: > "$CHOWNS"
# shellcheck disable=SC2034  # read inside the eval'd assert string below
OUT=$(set -e; PATH="$STUBS/failproj:$PATH" aidc_claim_session_mounts vscode:vscode "$CLAIM/projects-root-made" "$CLAIM/scratch2"; echo "rc=$?")
assert "a failed memory-side claim still lets the scratchpad side be claimed, and is reported" \
    "grep -qx 'vscode:vscode $CLAIM/scratch2/-repo-root-made' '$CHOWNS' && printf '%s' \"\$OUT\" | grep -q 'could not claim $CLAIM/projects-root-made'"
assert "and the pass returns non-zero" \
    "! (PATH='$STUBS/failproj':\$PATH aidc_claim_session_mounts vscode:vscode '$CLAIM/projects-root-made' '$CLAIM/scratch2' >/dev/null)"
echo

echo "[2c/3] aidc_has_resumable_conversation"
# aidc-claude passes --continue when this says yes, and `claude --continue` with
# nothing to continue exits with "No conversation found to continue" instead of
# opening a session. A transcript holding only bookkeeping (cost, mode, a
# file-history snapshot) is what a Claude that could not write all session leaves
# behind on exit once the dir becomes writable — the 2026-10-19 handmcp stub.
CONV="$SCRATCH/conv"; mkdir -p "$CONV"
assert "an empty project dir has nothing to resume" \
    "! aidc_has_resumable_conversation '$CONV'"
assert "nor does a project dir that does not exist" \
    "! aidc_has_resumable_conversation '$SCRATCH/no-such-dir'"
cat > "$CONV/63a2068f-d255-4bb9-948d-7ba694cbf4e8.jsonl" <<'JSONL'
{"type":"cost-state","sessionId":"63a2068f-d255-4bb9-948d-7ba694cbf4e8","totalCostUSD":0,"modelUsage":{}}
{"type":"file-history-snapshot","messageId":"4df7ecbf-87a1-4d2e-8207-5fea5dd7b404","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}
{"type":"last-prompt","leafUuid":"fbd792b9-5cca-4084-b65e-2c3f3a1b1c1d","sessionId":"63a2068f-d255-4bb9-948d-7ba694cbf4e8"}
{"type":"mode","mode":"normal","sessionId":"63a2068f-d255-4bb9-948d-7ba694cbf4e8"}
{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"63a2068f-d255-4bb9-948d-7ba694cbf4e8"}
JSONL
assert "a transcript with no message in it has nothing to resume" \
    "! aidc_has_resumable_conversation '$CONV'"
printf '%s\n' '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"uuid":"95d55add-d011-4358-92b7-29faa304e432","sessionId":"d3e1fb58-39fc-4fe6-8eb9-138ca204933b"}' \
    > "$CONV/d3e1fb58-39fc-4fe6-8eb9-138ca204933b.jsonl"
assert "one transcript with a message beside the stub is enough" \
    "aidc_has_resumable_conversation '$CONV'"
echo

echo "[2d/3] aidc_host_user_is_session_user"
# The claim above is only safe when the host user is the session user. Under rootless
# Docker the host user appears as root inside, so their own memory dir reads as uid 0
# and the claim would take it from them; a host user whose uid differs would lose a
# Docker-made dir to whoever holds the container's uid on the host.
assert "the repo's owner seen from inside is the session uid: safe to claim" \
    "PATH='$STUBS':\$PATH aidc_host_user_is_session_user '$CLAIM/tmp' 1000"
assert "the repo reads as root (rootless Docker): not safe" \
    "! PATH='$STUBS':\$PATH aidc_host_user_is_session_user '$CLAIM/projects-root-made' 1000"
assert "the repo is owned by another uid: not safe" \
    "! PATH='$STUBS':\$PATH aidc_host_user_is_session_user '$CLAIM/tmp' 1001"
assert "a repo path that cannot be read is not safe either" \
    "! aidc_host_user_is_session_user '$SCRATCH/no-such-repo' \$(id -u)"
echo

echo "[2e/3] aidc_transcript_dir_warning"
# The line user-main.sh logs, and the CLI repeats, when Claude cannot write the
# project dir. The CLI matches on the tag alone (relay_transcript_warnings), so the
# tag is the contract and the test pins it.
WARNDIR="$SCRATCH/warn"; mkdir -p "$WARNDIR"
assert "a writable project dir says nothing" \
    "[ -z \"\$(aidc_transcript_dir_warning '$WARNDIR')\" ]"
assert "nor does one that does not exist yet (Claude creates it)" \
    "[ -z \"\$(aidc_transcript_dir_warning '$SCRATCH/not-yet')\" ]"
chmod 0555 "$WARNDIR"
if [ -w "$WARNDIR" ]; then
    echo "  SKIP: running as root, a 0555 dir is still writable"
else
    assert "an unwritable one gets one line, starting with the tag, naming the dir" \
        "aidc_transcript_dir_warning '$WARNDIR' | grep -qx '$AIDC_TRANSCRIPT_UNWRITABLE_TAG $WARNDIR is not writable by .*'"
fi
chmod 0755 "$WARNDIR"
assert "the tag is the one the CLI matches on" \
    "[ '$AIDC_TRANSCRIPT_UNWRITABLE_TAG' = transcript-unwritable: ] && grep -qF \"grep -F 'transcript-unwritable:'\" '$AIDC_ROOT/scripts/lib/common.sh'"
echo

echo "[2f/3] aidc_claude_project_name"
# Must match Claude Code's own encoder (every non-alphanumeric becomes "-"), or the
# memory mount, the resume check and the transcript mirror all point at a dir Claude
# never writes.
assert "slashes and dots, as before" \
    "[ \"\$(aidc_claude_project_name /home/pace/crypt/pub/dev-wsl/vscode/3tears/handmcp)\" = -home-pace-crypt-pub-dev-wsl-vscode-3tears-handmcp ]"
assert "an underscore, a space and other punctuation too" \
    "[ \"\$(aidc_claude_project_name '/work/my_repo/a b+c@1.2')\" = -work-my-repo-a-b-c-1-2 ]"
echo

echo "[3/3] the order user-main.sh runs them in"
: > "$HOMEDIR/.claude.json"
: > "$CFG/.credentials.json"
aidc_clear_mount_placeholders "$CFG" "$HOMEDIR" >/dev/null
assert "after a legacy upgrade: placeholders gone, then the seed lands" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && [ -s '$CFG/.claude.json' ] && [ ! -e '$CFG/.credentials.json' ] && [ ! -e '$HOMEDIR/.claude.json' ]"
echo

echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
