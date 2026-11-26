#!/usr/bin/env bash
# Unit test for when the dev image's aidc-claude wrapper resumes the project's
# conversation (--continue). The interactive agent resumes; a headless run
# (--print / -p, which is how session_invoke and session_invoke_async start Claude)
# never does. The orchestrator, 2026-10-22: every session_invoke resumed the resident agent's
# conversation, a huge context, and could act on its work, while the tool promised a
# fresh Claude.
#
# No Docker required: the wrapper's body is cut from .devcontainer/Dockerfile and
# run against a stub `claude` that records its arguments, with the resume check
# sourced from the repo's claude-state-install.sh instead of the image path.
# Scratch lives under tests/scratch/ (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/aidc-claude-resume-unit-$$"
PASS=0
FAIL=0
cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "        cmd: $cmd"; FAIL=$((FAIL + 1))
    fi
}

HOMEDIR="$SCRATCH/home"
PROJECT="$SCRATCH/repo"
mkdir -p "$HOMEDIR/.local/bin" "$PROJECT"
WRAPPER="$SCRATCH/aidc-claude"
# The heredoc body between `RUN cat > /usr/local/bin/aidc-claude <<'EOF'` and EOF.
awk '/^RUN cat > \/usr\/local\/bin\/aidc-claude <<.EOF./ {on = 1; getline; next}
     on && /^EOF$/ {exit} on {print}' "$AIDC_ROOT/.devcontainer/Dockerfile" \
    | sed -e "s#/usr/local/bin/aidc-claude-state-install.sh#$AIDC_ROOT/.devcontainer/claude-state-install.sh#" \
          -e "s#/usr/local/bin/aidc-claude-lease#$AIDC_ROOT/.devcontainer/claude-lease.sh#" \
    > "$WRAPPER"
assert "the wrapper body was found in the Dockerfile" "grep -q 'exec \"\${HOME}/.local/bin/claude\"' '$WRAPPER'"
SEEN="$SCRATCH/seen"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$SEEN" > "$HOMEDIR/.local/bin/claude"
chmod +x "$WRAPPER" "$HOMEDIR/.local/bin/claude"

# A conversation the project could resume.
CONV="$HOMEDIR/.claude/projects/$(printf '%s' "$PROJECT" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$CONV"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$CONV/s1.jsonl"

run() { (cd "$PROJECT" && HOME="$HOMEDIR" "$@" bash "$WRAPPER" "${ARGS[@]}") ; }

echo "[1/2] the interactive agent resumes"
ARGS=()
run env
assert "a bare launch with a conversation to resume gets --continue" "grep -qx -- --continue '$SEEN'"
run env AIDC_CLAUDE_RESUME=false
assert "AIDC_CLAUDE_RESUME=false turns it off" "! grep -qx -- --continue '$SEEN'"
echo

echo "[2/2] a headless run never resumes"
ARGS=(--print "what does f return?")
run env
assert "--print gets no --continue" "! grep -qx -- --continue '$SEEN'"
assert "and its prompt is passed through whole" "grep -qx 'what does f return?' '$SEEN'"
ARGS=(-p "x")
run env
assert "-p gets no --continue" "! grep -qx -- --continue '$SEEN'"
ARGS=(--print "x")
run env AIDC_CLAUDE_RESUME=true
assert "not even with AIDC_CLAUDE_RESUME=true" "! grep -qx -- --continue '$SEEN'"
echo

echo "[3/3] a cluster session resumes only its own conversation (the history folder is shared)"
OUT="$SCRATCH/transcript-out"; mkdir -p "$OUT"
printf '{"type":"user","message":{"role":"user","content":"theirs"}}\n' > "$CONV/other.jsonl"
touch -d '2 minutes ago' "$CONV/s1.jsonl"
ARGS=()
run env AIDC_BACKEND=kubernetes AIDC_TRANSCRIPT_OUT="$OUT"
assert "a new session (nothing of its own yet) starts a new conversation: no --continue, no --resume" \
    "! grep -qx -- --continue '$SEEN' && ! grep -qx -- --resume '$SEEN'"
echo s1.jsonl > "$OUT/own-transcripts"
run env AIDC_BACKEND=kubernetes AIDC_TRANSCRIPT_OUT="$OUT"
assert "its own newest conversation is resumed by id, though another session's is newer" \
    "grep -qx -- --resume '$SEEN' && grep -qx s1 '$SEEN' && ! grep -qx -- --continue '$SEEN'"
printf '{"cost":1}\n' > "$CONV/s2.jsonl"; echo s2.jsonl >> "$OUT/own-transcripts"
run env AIDC_BACKEND=kubernetes AIDC_TRANSCRIPT_OUT="$OUT"
assert "a newer one of its own with no message is skipped" "grep -qx s1 '$SEEN'"
printf '{"machine":"mac","until_s":%s}' "$(( $(date +%s) + 600 ))" > "$CONV/s1.aidc-lease"
run env AIDC_BACKEND=kubernetes AIDC_TRANSCRIPT_OUT="$OUT" AIDC_LEASE_MACHINE=cluster/s
assert "its own conversation open on another machine right now (its lease) is not resumed" "! grep -qx -- --resume '$SEEN'"
rm -f "$CONV/s1.aidc-lease"
ARGS=(--print x)
run env AIDC_BACKEND=kubernetes AIDC_TRANSCRIPT_OUT="$OUT"
assert "a headless run still resumes nothing" "! grep -qx -- --resume '$SEEN'"
echo

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
