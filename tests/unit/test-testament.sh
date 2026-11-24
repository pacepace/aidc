#!/usr/bin/env bash
# Unit tests for testament in aidc sessions (scripts/lib/testament.sh, K8S-25 as amended).
#
# testament is optional while its repo is private: installed only when the user's config names
# the repo, fetched with the user's SSH key at its newest vX.Y.Z tag, built into a wheel here,
# and put into the dev image's build context and, on upgrade, into a running session. Three
# cases matter most: configured, unconfigured, and no access; the last two never fail a build.
#
# No network: ssh is a stub (GIT_SSH_COMMAND) that serves a local bare repo, or refuses like a
# key without access; uv is a stub that writes the wheel a build would. HOME is the test's.
#
# Hygiene: scratch under tests/scratch/ (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$AIDC_ROOT/tests/scratch/testament-$$"
PASS=0
FAIL=0
trap 'rm -rf "$S"' EXIT INT TERM
mkdir -p "$S/bin" "$S/home/.config/aidc" "$S/forge/team"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $(printf '%s' "$3" | tail -3))" ;; esac; }

export HOME="$S/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset XDG_CACHE_HOME GIT_SSH_COMMAND
G() { git -c user.name=Someone -c user.email=someone@example.com -c init.defaultBranch=main "$@"; }

# The release repo: tags v0.9.0, v0.10.0 (newer, though it sorts lower as text) and an rc.
SRC="$S/src"; G init -q "$SRC"
for v in 0.9.0 0.10.0 0.11.0-rc1; do
    printf '[project]\nname = "testament"\nversion = "%s"\n' "$v" > "$SRC/pyproject.toml"
    G -C "$SRC" add pyproject.toml; G -C "$SRC" commit -q -m "v$v"; G -C "$SRC" tag "v$v"
done
G clone -q --bare "$SRC" "$S/forge/team/testament.git"

# ssh stub: serves <forge>/<path> for any host, as GitHub's ssh would; SSH_DENY=1 refuses like a
# key without access.
cat > "$S/bin/fake-ssh" <<'STUB'
#!/bin/sh
[ "${SSH_DENY:-}" = 1 ] && { echo 'git@example.invalid: Permission denied (publickey).' >&2; exit 255; }
for a; do last="$a"; done
cd "$FORGE" || exit 1
exec sh -c "$last"
STUB
chmod +x "$S/bin/fake-ssh"
export FORGE="$S/forge" GIT_SSH_COMMAND="$S/bin/fake-ssh"

# uv stub: `uv build ... --out-dir D SRC` writes the wheel of SRC's version; logs each build.
cat > "$S/bin/uv" <<'STUB'
#!/bin/sh
[ "$1" = build ] || exit 1
out="" src=""
while [ $# -gt 0 ]; do case "$1" in --out-dir) out="$2"; shift 2 ;; -*|build) shift ;; *) src="$1"; shift ;; esac; done
v=$(sed -n 's/^version = "\(.*\)"/\1/p' "$src/pyproject.toml")
mkdir -p "$out" && echo wheel > "$out/testament-${v}-py3-none-any.whl"
echo "$v" >> "$UV_LOG"
STUB
chmod +x "$S/bin/uv"
export UV_LOG="$S/uv.log" PATH="$S/bin:$PATH"
: > "$UV_LOG"

# shellcheck source=../../scripts/lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=../../scripts/lib/testament.sh
. "$AIDC_SCRIPTS/lib/testament.sh"

CFG="$HOME/.config/aidc/config.yaml"
wheel() { OUT=$(aidc_testament_wheel 2>"$S/err"); RC=$?; ERR=$(cat "$S/err"); }

echo "=== unconfigured ==="
: > "$CFG"
wheel
assert_eq "no testament.repo: no wheel" "1 " "$RC $OUT"
assert_has "and one line says so and that it goes on" "testament: not configured" "$ERR"
assert_eq "one line only" 1 "$(printf '%s\n' "$ERR" | grep -c .)"

echo "=== configured ==="
printf 'testament:\n  repo: git@example.invalid:team/testament.git\n' > "$CFG"
assert_eq "the repo is read from the config (block style)" "git@example.invalid:team/testament.git" "$(aidc_testament_repo)"
if command -v yq >/dev/null 2>&1; then
    printf 'testament: {repo: "git@example.invalid:team/testament.git"}\n' > "$CFG"
    assert_eq "and flow style" "git@example.invalid:team/testament.git" "$(aidc_testament_repo)"
fi
assert_eq "the newest vX.Y.Z tag, in number order (v0.10.0 over v0.9.0; no pre-release)" "v0.10.0" \
    "$(aidc_testament_newest_tag git@example.invalid:team/testament.git)"
wheel
assert_eq "the wheel of that release, cached per tag" "0 $HOME/.cache/aidc/testament/v0.10.0/testament-0.10.0-py3-none-any.whl" "$RC $OUT"
assert_eq "built once" "0.10.0" "$(cat "$UV_LOG")"
wheel
assert_eq "a second call takes the cached wheel" "0 $HOME/.cache/aidc/testament/v0.10.0/testament-0.10.0-py3-none-any.whl" "$RC $OUT"
assert_eq "without building again" 1 "$(grep -c . "$UV_LOG")"
assert_eq "its version" "0.10.0" "$(aidc_testament_version "$OUT")"
printf '[project]\nname = "testament"\nversion = "0.12.0"\n' > "$SRC/pyproject.toml"
G -C "$SRC" commit -q -am "v0.12.0"; G -C "$SRC" tag v0.12.0; G -C "$SRC" push -q "$S/forge/team/testament.git" v0.12.0 2>/dev/null
wheel
assert_eq "a new release is picked up (latest, not pinned)" "0 testament-0.12.0-py3-none-any.whl" "$RC ${OUT##*/}"
assert_eq "no build folder is left behind" "" "$(find "$HOME/.cache/aidc/testament" -maxdepth 1 -name '.build.*')"

echo "=== no access, or not something to fetch with an SSH key ==="
rm -rf "$HOME/.cache/aidc/testament"
OUT=$(SSH_DENY=1 aidc_testament_wheel 2>"$S/err"); RC=$?; ERR=$(cat "$S/err")
assert_eq "no access: no wheel" "1 " "$RC $OUT"
assert_has "and one line says so and that it goes on" "cannot read its release tags with your SSH key (no access?); going on without it" "$ERR"
for url in https://github.com/team/testament.git "-oProxyCommand=x:y" "/srv/testament.git"; do
    printf 'testament:\n  repo: "%s"\n' "$url" > "$CFG"
    wheel
    assert_eq "not an ssh URL ($url): no wheel, nothing fetched" "1 " "$RC $OUT"
done
printf 'testament:\n  repo: git@example.invalid:team/testament.git\n' > "$CFG"
mv "$S/bin/uv" "$S/bin/uv.off"
P_NO_UV=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/uv" ] || printf '%s:' "$d"; done)
OUT=$(PATH="$P_NO_UV" aidc_testament_wheel 2>"$S/err"); RC=$?; ERR=$(cat "$S/err")
assert_eq "no uv here: no wheel" "1 " "$RC $OUT"
assert_has "and it says why" "uv is not installed here" "$ERR"
mv "$S/bin/uv.off" "$S/bin/uv"

echo "=== the dev image's build context ==="
CTX="$S/ctx"; mkdir -p "$CTX/testament"; printf 'FROM scratch\n' > "$CTX/Dockerfile"; : > "$CTX/testament/.gitkeep"
echo stray > "$CTX/testament/testament-0.0.1-py3-none-any.whl"
aidc_testament_stage "$CTX" "$S/stage1" 2>"$S/err"
assert_eq "configured: the staged context has the newest wheel, and only it" "testament-0.12.0-py3-none-any.whl" \
    "$(cd "$S/stage1/testament" && ls -- *.whl | paste -sd' ' -)"
assert_eq "and the rest of the context" yes "$([ -f "$S/stage1/Dockerfile" ] && echo yes)"
assert_has "it says what goes in" "testament: 0.12.0 goes into the image" "$(cat "$S/err")"
: > "$CFG"
aidc_testament_stage "$CTX" "$S/stage2" 2>"$S/err"; RC=$?
assert_eq "unconfigured: the build goes on, with an empty testament folder" "0 " "$RC $(cd "$S/stage2/testament" && ls -- *.whl 2>/dev/null)"
printf 'testament:\n  repo: git@example.invalid:team/testament.git\n' > "$CFG"
rm -rf "$HOME/.cache/aidc/testament"
SSH_DENY=1 aidc_testament_stage "$CTX" "$S/stage3" 2>"$S/err"; RC=$?
assert_eq "no access: the build goes on, with an empty testament folder" "0 " "$RC $(cd "$S/stage3/testament" && ls -- *.whl 2>/dev/null)"
assert_eq "the source context is never changed" "testament-0.0.1-py3-none-any.whl" "$(cd "$CTX/testament" && ls -- *.whl)"
assert_eq "aidc's dev context has the folder the Dockerfile copies (empty but for its marker)" ".gitkeep" \
    "$(find "$AIDC_ROOT/.devcontainer/testament" -mindepth 1 -maxdepth 1 ! -name '*.whl' -printf '%f\n')"
DF="$AIDC_ROOT/.devcontainer/Dockerfile"
assert_has "the Dockerfile copies it" "COPY testament/ /opt/aidc/testament/" "$(cat "$DF")"
assert_has "and a failed install does not fail the image build" 'did not install; the image goes on without it' "$(cat "$DF")"

echo "=== a running session (aidc upgrade) ==="
SESSION_V=""
# The backend's two functions, as stubs: the session reports SESSION_V; a copy is logged; an
# install sets SESSION_V from the wheel unless INSTALL_FAILS.
tcopy() { printf 'copy %s %s\n' "${1##*/}" "$2" >> "$S/session.log"; [ "${COPY_FAILS:-}" != 1 ]; }
texec() {
    case "$*" in
        *"testament --version"*) [ -n "$SESSION_V" ] && echo "testament ${SESSION_V}" ;;
        *"uv tool install"*) printf 'install %s\n' "${*: -1}" >> "$S/session.log"
            [ "${INSTALL_FAILS:-}" = 1 ] && return 1
            SESSION_V=$(aidc_testament_version "${*: -1}") ;;
    esac
    return 0
}
: > "$S/session.log"
aidc_testament_install tcopy texec 2>"$S/err"
assert_has "a session without it gets the newest release, in its user's home" "install /tmp/testament-0.12.0-py3-none-any.whl" "$(cat "$S/session.log")"
assert_has "copied in first" "copy testament-0.12.0-py3-none-any.whl /tmp/testament-0.12.0-py3-none-any.whl" "$(cat "$S/session.log")"
assert_has "and says so" "0.12.0 installed in the session (was none)" "$(cat "$S/err")"
: > "$S/session.log"
aidc_testament_install tcopy texec 2>"$S/err"
assert_eq "a session that has it already is left alone" "" "$(cat "$S/session.log")"
assert_has "saying so" "0.12.0 is already in the session" "$(cat "$S/err")"
SESSION_V=0.10.0
INSTALL_FAILS=1 aidc_testament_install tcopy texec 2>"$S/err"; RC=$?
assert_eq "a failed install does not fail the upgrade" 0 "$RC"
assert_has "it says the session keeps what it had" "did not install in the session; it keeps 0.10.0" "$(cat "$S/err")"
COPY_FAILS=1 aidc_testament_install tcopy texec 2>"$S/err"
assert_has "a failed copy the same" "cannot copy 0.12.0 into the session; it keeps 0.10.0" "$(cat "$S/err")"
: > "$CFG"; : > "$S/session.log"
aidc_testament_install tcopy texec 2>"$S/err"; RC=$?
assert_eq "unconfigured: nothing goes into the session, the upgrade goes on" "0 " "$RC $(cat "$S/session.log")"
assert_has "with the one line" "testament: not configured" "$(cat "$S/err")"

echo "=== aidc upgrade (Docker) carries it into the session ==="
# The session is already on the current image (nothing to swap): the testament step still runs,
# through docker cp and docker exec as the session user. docker is a stub that logs.
printf 'testament:\n  repo: git@example.invalid:team/testament.git\n' > "$CFG"
mkdir -p "$HOME/.local/state/aidc/sessions"; printf 'services: {}\n' > "$HOME/.local/state/aidc/sessions/demo.yaml"
cat > "$S/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$D_LOG"
case "$*" in
    info*) exit 0 ;;
    "ps -a --filter label=aidc.session=demo -q") echo 0123456789ab ;;
    "image inspect aidc/dev-base:"*) echo sha256:same ;;
    "inspect aidc-demo-dev --format {{.Image}}") echo sha256:same ;;
    *"testament --version"*) : ;;
esac
exit 0
STUB
chmod +x "$S/bin/docker"
export D_LOG="$S/docker.log"; : > "$D_LOG"
out=$(AIDC_ROOT="$AIDC_ROOT" AIDC_VERSION_TAG=vtest bash "$AIDC_SCRIPTS/cmd-upgrade.sh" demo --yes 2>&1); rc=$?
assert_eq "the upgrade succeeds" 0 "$rc"
assert_has "the newest wheel is copied into the dev container" "cp $HOME/.cache/aidc/testament/v0.12.0/testament-0.12.0-py3-none-any.whl aidc-demo-dev:/tmp/testament-0.12.0-py3-none-any.whl" "$(cat "$D_LOG")"
assert_has "handed to the session user" "exec -u root aidc-demo-dev chown 1000:1000 /tmp/testament-0.12.0-py3-none-any.whl" "$(cat "$D_LOG")"
assert_has "and installed as the session user, in its home" "exec -i -u vscode -e HOME=/home/vscode aidc-demo-dev sh -c uv tool install" "$(cat "$D_LOG")"
assert_has "it says so" "testament: 0.12.0 installed in the session" "$out"
rm -rf "$HOME/.cache/aidc/testament"; : > "$D_LOG"
out=$(SSH_DENY=1 AIDC_ROOT="$AIDC_ROOT" AIDC_VERSION_TAG=vtest bash "$AIDC_SCRIPTS/cmd-upgrade.sh" demo --yes 2>&1); rc=$?
assert_eq "no access: the upgrade still succeeds" 0 "$rc"
assert_has "with the one line" "testament: cannot read its release tags with your SSH key" "$out"
assert_eq "and nothing is copied in" "" "$(grep '^cp ' "$D_LOG")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
