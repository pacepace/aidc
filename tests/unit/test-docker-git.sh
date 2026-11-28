#!/usr/bin/env bash
# Unit tests for the git container on the Docker backend (scripts/docker/, `aidc git` and
# `aidc repo` there, the git agent as the session named git, and what sessions get).
#
# The git container holds the user's GitHub login, so how it is started is a security
# boundary: a route out other than its public-only proxy, a published port, a capability past
# the user switch sudo needs, or a mount of anything but the working copies the user added
# would let the login or the user's machine be reached. Status must never say "no" when docker
# or the container could not be asked. docker is a PATH stub; HOME holds the config.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/docker-git-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() {
    case "$3" in *"$2"*) pass "$1" ;;
        *) fail "$1 (no '$2' in:"; printf '%s\n' "$3" | tail -12 | sed 's/^/      /'; echo "    )" ;; esac
}
assert_not_has() {
    case "$3" in *"$2"*) fail "$1 ('$2' present in:"; printf '%s\n' "$3" | tail -12 | sed 's/^/      /'; echo "    )" ;;
        *) pass "$1" ;; esac
}

# docker stub: logs each call (one line, words as given) to $D_LOG.
#   D_DOWN=1          every call fails as an unreachable daemon does
#   D_STATE=running|stopped|absent|unknown   the git container (default running)
#   D_VOLS="a b"      volumes that exist (default: none, so setup creates them)
#   D_NET=0           the git networks do not exist yet (default 1: they do)
#   D_INTERNAL=false  aidc-git-net is not internal
#   D_GH=yes|no|unknown  gitctl status (default no); D_WAITING=n requests waiting (default 0)
#   D_COPIES/D_BUNDLES  bytes in the private copies / bundles (default 1 MiB / 0)
#   D_ADOPT_RC=1      gitctl adopt fails
#   D_PROXY_ENV       the proxy's environment (default AIDC_PUBLIC_ONLY=1)
#   D_TOKEN           AIDC_GIT_TOKEN in session s1's dev container
#   D_SESSIONS="s1"   sessions that exist (by label)
#   D_SEEN=dev:ino    the device and inode the git container sees at a mounted path (default: the host's)
#   D_REQERR=text     git-requests list fails in the status probe, with this reason
#   D_GITCT=false     the git container is not running (docker inspect of aidc-git-dev for kill/create)
#   D_NO_BASE=1       git-requests pr-base finds no base (origin has no default branch)
#   D_BROKER=running  the user's Claude account broker runs (default: there is none)
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$D_LOG"
[ "${D_DOWN:-}" = 1 ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; }
a="$*"
# The request holder's execs carry its own HOME; the patterns below name only the user.
a="${a//-u gitreq -e HOME=\/var\/lib\/gitctl\/gitreq/-u gitreq}"
case "$a" in
    info*) exit 0 ;;
    "image inspect "*) exit 0 ;;
    "volume inspect "*) case " ${D_VOLS:-} " in *" ${a##* } "*) exit 0 ;; esac; echo "Error: no such volume" >&2; exit 1 ;;
    "volume create "*) exit 0 ;;
    "network inspect -f {{.Internal}} aidc-git-net") echo "${D_INTERNAL:-true}"; exit 0 ;;
    "network inspect "*) [ "${D_NET:-1}" = 1 ] && exit 0; echo "Error: network not found" >&2; exit 1 ;;
    "network create "*|"network connect "*|"rm -f "*) exit 0 ;;
    "run --rm "*claude-refresh*) echo "claude-refresh: current"; exit 0 ;;
    "run --rm "*) echo seeded; exit 0 ;;
    "run -d "*) echo "c0ffee"; exit 0 ;;
    "inspect -f {{.State.Health.Status}} aidc-git-squid") echo healthy; exit 0 ;;
    "inspect -f {{.State.Running}} aidc-git-squid") echo true; exit 0 ;;
    "inspect -f {{range .Config.Env}}{{println .}}{{end}} aidc-git-squid") printf '%b\n' "${D_PROXY_ENV:-PATH=/bin\nAIDC_PUBLIC_ONLY=1}"; exit 0 ;;
    "inspect -f {{range .Config.Env}}{{println .}}{{end}} aidc-s1-dev") printf 'PATH=/bin\nAIDC_GIT_TOKEN=%s\n' "${D_TOKEN:-}"; exit 0 ;;
    "inspect -f {{.State.Running}} aidc-git-dev")
        case "${D_STATE:-running}" in
            running) echo true ;; stopped) echo false ;;
            absent) echo "Error: No such object: aidc-git-dev" >&2; exit 1 ;;
            *) echo "Error response from daemon: i/o timeout" >&2; exit 1 ;;
        esac; exit 0 ;;
    "ps -a --filter label=aidc.session="*) n="${a#*label=aidc.session=}"; n="${n%% *}"
        case " ${D_SESSIONS:-} git " in *" $n "*) echo abc123 ;; esac; exit 0 ;;
    'ps -a --filter label=aidc.role=dev --format {{.Label "aidc.session"}}') printf 'git\ns1\n'; exit 0 ;;
    "ps -a --filter label=aidc.role=dev --format "*) printf 'aidc-git-dev\tUp 2 minutes\naidc-s1-dev\tUp 1 hour\n'; exit 0 ;;
    "inspect aidc-"*"-dev --format"*"aidc.profile"*) case "$a" in *aidc-git-dev*) echo git-agent ;; *) echo multi ;; esac; exit 0 ;;
    "inspect aidc-"*"-dev --format"*) echo "2026-11-24T00:00:00Z"; exit 0 ;;
    "exec aidc-"*"-policy test -f /var/state/tainted") exit 1 ;;
    "exec -u git aidc-git-dev tmux has-session -t main") exit 0 ;;
    "inspect -f {{.State.Running}} aidc-claude-broker")
        [ "${D_BROKER:-}" = running ] && { echo true; exit 0; }
        echo "Error: No such object: aidc-claude-broker" >&2; exit 1 ;;
    "inspect -f {{range .Mounts}}"*) exit 0 ;;
    "exec aidc-claude-broker claude-broker session git") exit 0 ;;
    "exec -u git aidc-git-dev stat -c %d:%i -- "*) # what the container sees at a mounted path
        [ -n "${D_SEEN:-}" ] && { echo "$D_SEEN"; exit 0; }
        stat -c %d:%i -- "${a##* }"; exit 0 ;;
    "exec -u git aidc-git-dev sh -c "*)
        echo "github=${D_GH:-no}"
        if [ -n "${D_REQERR:-}" ]; then echo "requests-error=${D_REQERR}"; else echo "waiting=${D_WAITING:-0}"; fi
        echo "storage-copies ${D_COPIES:-1048576}"; echo "storage-bundles ${D_BUNDLES:-0}"; exit 0 ;;
    "exec -u git aidc-git-dev gitctl adopt "*) cp "$HOME/.config/aidc/git-added/repos" "$D_LOG.list" 2>/dev/null
        [ "${D_ADOPT_RC:-0}" = 0 ] && { echo "added o/r (${a##* })"; exit 0; }
        echo "gitctl: refused: cannot fetch https://github.com/o/r" >&2; exit 1 ;;
    "exec -u git aidc-git-dev gitctl protection "*|"exec -u gitreq aidc-git-dev gitctl protect "*)
        printf 'repo o/r\ndefault main\nforce-push blocked\ndeletion blocked\nmerge-commit allowed\nend\n'; exit 0 ;;
    "exec -u git aidc-git-dev gitctl tidy "*) printf 'deleted-remote feat\nunpushed 2 other\nend\n'; exit 0 ;;
    "exec -u gitreq aidc-git-dev gitctl push "*) echo "pushed ${a##* } 0123456789abcdef"; exit 0 ;;
    "exec -u git aidc-git-dev gitctl "*|"exec -u gitreq aidc-git-dev gitctl "*) exit 0 ;;
    "exec -u gitreq aidc-git-dev git-requests list") printf 'ID  RECEIVED\nabc\033[31m  x\n'; exit 0 ;;
    "exec -u gitreq aidc-git-dev git-requests first-use "*) exit 0 ;;
    "exec -u gitreq aidc-git-dev git-requests pr-base "*)
        [ "${D_NO_BASE:-}" = 1 ] && { echo "git-requests: no base branch given and origin has no default" >&2; exit 1; }
        set -- $a; [ $# = 8 ] && echo "$8" || echo main; exit 0 ;;
    "exec -u gitreq aidc-git-dev git-requests "*) echo "ok"; exit 0 ;;
    "exec -i -u gitreq aidc-git-dev git-requests mode "*) cat > "$D_STDIN"; echo "mode set"; exit 0 ;;
    "exec -i -u gitreq aidc-git-dev git-requests sync") cat > "$D_STDIN"; echo "sessions: 1 registered, 0 gone pruned"; exit 0 ;;
    "exec -i -u gitreq aidc-git-dev bash -c "*) cat > "$D_STDIN"; echo "https://github.com/o/r/pull/7"; exit 0 ;;
    "exec -it "*) exit 0 ;;
esac
# D_LENIENT=1: any other call succeeds silently (aidc kill's many teardown steps).
[ "${D_LENIENT:-}" = 1 ] && exit 0
echo "docker stub: unexpected: $a" >&2
exit 1
STUB
chmod +x "$SCRATCH/bin/docker"

export HOME="$SCRATCH/home" PATH="$SCRATCH/bin:$PATH"
export D_LOG="$SCRATCH/docker.log" D_STDIN="$SCRATCH/stdin"
unset XDG_STATE_HOME AIDC_MCP_STATE_HOST AIDC_HOST_HOME AIDC_MCP_MOUNTS
HOMEP=$(cd "$HOME" && pwd -P)
run() { : > "$D_LOG"; "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null; }
calls() { cat "$D_LOG"; }
line() { grep -F -- "$1" "$D_LOG" | head -n1; }

# A working copy of the user's, under their home, with a GitHub origin.
WC="$HOMEP/src/proj"
mkdir -p "$WC"; git -C "$WC" init -q; git -C "$WC" remote add origin https://github.com/o/r.git

echo "=== which backend aidc git talks to ==="
out=$(run git status)
assert_has "no config: Docker" "git container: aidc-git-dev (Docker" "$out"
printf 'kubernetes:\n  user: alice\n  storage_class: x\nbackend: docker\n' > "$HOME/.config/aidc/config.yaml"
out=$(run git status)
assert_has "a kubernetes block with backend: docker: Docker" "git container: aidc-git-dev (Docker" "$out"
printf 'backend: kubernetes\n' > "$HOME/.config/aidc/config.yaml"
out=$(run git status --backend docker)
assert_has "--backend docker wins over the config" "git container: aidc-git-dev (Docker" "$out"
out=$(run git status --backend mars)
assert_has "an unknown backend is refused" "unknown backend: mars" "$out"
assert_eq "with an error" 2 "$(run git status --backend mars >/dev/null; echo $?)"
: > "$HOME/.config/aidc/config.yaml"

printf 'kubernetes:\n  user: alice\n  storage_class: x\n' > "$HOME/.config/aidc/config.yaml"
out=$(run git status)
assert_has "a kubernetes block alone (no backend: line) stays on Docker, as aidc create does" "git container: aidc-git-dev (Docker" "$out"
out=$(run repo list)
assert_not_has "aidc repo too" "kubectl" "$out"
cr=$(cat "$AIDC_ROOT/scripts/aidc")
assert_has "aidc create takes the same rule (one place: aidc_default_backend)" 'BACKEND=$(AIDC_BACKEND_FLAG="" aidc_default_backend)' "$cr"
: > "$HOME/.config/aidc/config.yaml"

echo "=== aidc git setup ==="
out=$(D_NET=0 run git setup)
assert_eq "setup succeeds" 0 "$(D_NET=0 run git setup >/dev/null; echo $?)"
for v in aidc-git-home aidc-git-cred aidc-git-run aidc-git-requests; do
    assert_has "the volume ${v} is created when missing" "volume create --label aidc.git=volume ${v}" "$(calls)"
done
seed=$(calls)
assert_has "the seed step runs as root with no network" "--network none --user 0:0 --cap-drop ALL" "$seed"
assert_has "holding only a copy's and a chown's capabilities" "--cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE --security-opt no-new-privileges" "$seed"
assert_has "it gives the request folder to the request holder (gitreq), setgid in the session group" "chown 2003:1000 /requests" "$seed"
assert_has "one the agent held is given to the holder, contents too, no symlink followed" "2000) chown -R -h 2003 /requests" "$seed"
assert_has "the login's volume is gitcred's (0711)" "chown 2001:2001 /cred && chmod 0711 /cred" "$seed"
assert_has "gitrun's store is its alone (0700)" "chown 2002:2002 /run-store && chmod 0700 /run-store" "$seed"
assert_has "a home made earlier gets the image's Claude, as the git user with no capabilities" \
    "run --rm --network none --user 2000:2000 --cap-drop ALL --security-opt no-new-privileges -v aidc-git-home:/seed --entrypoint /opt/aidc/lib/gitctl/claude-refresh.sh" "$(calls)"
assert_has "its network is internal: no route out" "network create --internal --label aidc.session=git aidc-git-net" "$(calls)"
proxy=$(line 'run -d --name aidc-git-squid')
assert_has "its proxy reaches public addresses only" "-e AIDC_PUBLIC_ONLY=1" "$proxy"
assert_has "from its own egress network" "--network aidc-git-egress" "$proxy"
assert_has "the proxy container resolves through Quad9 (squid itself: its entrypoint, test-squid-entrypoint.sh)" "--dns 9.9.9.9 --dns 149.112.112.112" "$proxy"
assert_has "and is the git container's aidc-proxy" "network connect --alias aidc-proxy aidc-git-net aidc-git-squid" "$(calls)"
git_run=$(line 'run -d --name aidc-git-dev')
assert_has "the git container is on the internal network only" "--network aidc-git-net " "$git_run"
assert_has "it holds only what sudo's user switch needs" "--cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add AUDIT_WRITE --label" "$git_run"
for bad in --privileged "-p " --publish docker.sock --pid --ipc "--network host" --cap-add=ALL "--cap-add SYS_ADMIN" "--cap-add DAC_OVERRIDE"; do
    assert_not_has "and nothing like ${bad}" "$bad" "$git_run"
done
assert_has "it is the dev container of the session named git (aidc list, attach and the MCP server find it)" \
    "--label aidc.session=git --label aidc.role=dev --label aidc.profile=git-agent" "$git_run"
assert_has "its request folder is the shared volume" "-e AIDC_GIT_REQUESTS=/var/aidc/git-requests" "$git_run"
assert_has "mounted at that path" "-v aidc-git-requests:/var/aidc/git-requests" "$git_run"
assert_not_has "the mode is not in its environment: the holder reads it from its read-only settings" "AIDC_GIT_MODE" "$git_run"
assert_has "the request watcher runs here, as gitreq (started through its sudo rule)" "-e AIDC_GIT_WATCH_HERE=1" "$git_run"
assert_has "the holder's settings are mounted read-only" "-v ${HOMEP}/.config/aidc/git-settings:/etc/aidc/git-settings:ro" "$git_run"
assert_eq "and name the request folder, the disk and the user's mode" "requests=/var/aidc/git-requests|disk=${HOMEP}|mode=ask" \
    "$(paste -sd'|' "$HOMEP/.config/aidc/git-settings/settings")"
assert_has "the user's disk is their home here" "-e AIDC_GIT_DISK=${HOMEP} " "$git_run"
assert_has "its Claude goes out through the proxy" "-e HTTPS_PROXY=http://aidc-proxy:3128" "$git_run"
assert_has "the agent's home, login and private copies are volumes" \
    "-v aidc-git-home:/home/git -v aidc-git-cred:/var/lib/gitctl/gitcred -v aidc-git-run:/var/lib/gitctl/gitrun" "$git_run"
assert_has "its transcript goes where the MCP server reads every session's" \
    "-v ${HOMEP}/.local/state/aidc-mcp/transcripts/git:/var/aidc/transcript-out:rw" "$git_run"
assert_has "that folder is given to the agent" "chown 2000:" "$(line '/transcripts/git:/t')"
assert_not_has "with no working copy added, none of the user's folders is mounted" "-v ${HOMEP}/src" "$git_run"
# gitctl takes "added" from this list alone: written here (aidc repo add|remove), read-only in
# the container, so neither the agent nor gitwc (the user's uid) can put a repo on it.
assert_has "the list of added repos is mounted read-only at the path gitctl reads" \
    "-v ${HOMEP}/.config/aidc/git-added:/etc/aidc/git-repos:ro " "$git_run"
assert_eq "it is mounted once, and only read-only" 1 "$(printf '%s\n' "$git_run" | grep -o -- ':/etc/aidc/git-repos[:a-z]*' | sort -u | wc -l | tr -d ' ')"
assert_eq "setup made the folder and an empty list (so Docker makes no root-owned folder in its place)" "yes 0" \
    "$([ -d "$HOMEP/.config/aidc/git-added" ] && echo yes) $(wc -c < "$HOMEP/.config/aidc/git-added/repos" | tr -d ' ')"
assert_has "it says what comes next" "aidc git login" "$out"
out=$(D_VOLS="aidc-git-home aidc-git-cred aidc-git-run aidc-git-requests" run git setup)
assert_not_has "run again, the volumes (the login, the private copies) are kept" "volume create" "$(calls)"
assert_not_has "and the networks" "network create" "$(calls)"
assert_has "the container is recreated on the current image" "rm -f aidc-git-dev" "$(calls)"
printf 'git:\n  mode: rules\n' > "$HOME/.config/aidc/config.yaml"
run git setup >/dev/null
assert_eq "git.mode reaches the request holder's settings" "mode=rules" "$(grep '^mode=' "$HOMEP/.config/aidc/git-settings/settings")"
printf 'git:\n  mode: yolo\n' > "$HOME/.config/aidc/config.yaml"
out=$(run git setup)
assert_has "a git.mode that is not ask or rules is refused" "git.mode 'yolo' is not ask or rules" "$out"
assert_not_has "before anything is started" "run -d" "$(calls)"
: > "$HOME/.config/aidc/config.yaml"
out=$(D_INTERNAL=false run git setup)
assert_has "an aidc-git-net that is not internal is refused, not used" "is not internal" "$out"
assert_not_has "and the container is not started on it" "--name aidc-git-dev" "$(calls)"

echo "=== aidc repo add|list|remove: the user's own working copies ==="
out=$(run repo add https://github.com/o/r)
assert_has "a URL is refused: the git container does not clone on Docker" "clone it yourself, then aidc repo add" "$out"
mkdir -p "$HOMEP/notarepo"
out=$(run repo add "$HOMEP/notarepo")
assert_has "a folder that is not a working copy is refused" "is not a working copy" "$out"
S="$HOMEP/src/sshy"; mkdir -p "$S"; git -C "$S" init -q; git -C "$S" remote add origin git@github.com:o/s.git
out=$(run repo add "$S")
assert_has "an SSH origin is refused, with how to keep pushing over SSH" "remote set-url --push origin" "$out"
mkdir -p "$SCRATCH/elsewhere"; git -C "$SCRATCH/elsewhere" init -q
out=$(run repo add "$SCRATCH/elsewhere")
assert_has "a working copy outside the user's home is refused" "below your home" "$out"
out=$(run repo add "$WC")
assert_eq "a GitHub working copy under the home is added" 0 "$(run repo add "$WC" >/dev/null; echo $?)"
assert_eq "it is recorded once" 1 "$(grep -cxF "$WC" "$HOME/.config/aidc/git-repos")"
: > "$D_LOG"; rm -f "$HOME/.config/aidc/git-repos" "$HOME/.config/aidc/git-added/repos" "$D_LOG.list"; out=$(run repo add "$WC")
assert_has "the git container is started again with it mounted at its own path" "-v ${WC}:${WC}:rw" "$(line 'run -d --name aidc-git-dev')"
assert_has "and gitctl adopts it (gitrun's private copy)" "exec -u git aidc-git-dev gitctl adopt ${WC}" "$(calls)"
ADDED="$HOMEP/.config/aidc/git-added/repos"
assert_eq "its GitHub repo is on the list of added repos" "o/r" "$(cat "$ADDED")"
assert_eq "written before the adopt (the list the adopt runs against already has it)" "o/r" "$(cat "$D_LOG.list" 2>/dev/null)"
out=$(D_ADOPT_RC=1 run repo add "$HOMEP/src/proj2" 2>&1)
mkdir -p "$HOMEP/src/proj2"; git -C "$HOMEP/src/proj2" init -q; git -C "$HOMEP/src/proj2" remote add origin https://github.com/o/r2
out=$(D_ADOPT_RC=1 run repo add "$HOMEP/src/proj2")
assert_has "when the git container cannot take it, it is forgotten again" "was not added" "$out"
assert_eq "and not recorded" 0 "$(grep -cxF "$HOMEP/src/proj2" "$HOME/.config/aidc/git-repos")"
assert_eq "and its repo is taken off the list again (o/r, added before, stays)" "o/r" "$(cat "$ADDED")"
out=$(D_ADOPT_RC=1 run repo add "$WC")
assert_eq "a working copy added before whose adopt fails now stays added (only what this run added is undone)" 1 \
    "$(grep -cxF "$WC" "$HOME/.config/aidc/git-repos")"
assert_eq "as does its repo on the list" "o/r" "$(cat "$ADDED")"
assert_not_has "and the container is not restarted for it" "run -d --name aidc-git-dev" "$(calls)"
out=$(run repo list)
assert_has "repo list shows it with its origin" "https://github.com/o/r.git" "$out"
mkdir -p "$HOMEP/gone"; printf '%s\n' "$HOMEP/gone" >> "$HOME/.config/aidc/git-repos"
out=$(run repo list)
assert_has "a working copy that went away is said so" "(gone: aidc repo remove ${HOMEP}/gone)" "$out"
run git setup >/dev/null
assert_not_has "and is not mounted (Docker would make an empty folder there)" "-v ${HOMEP}/gone:" "$(line 'run -d --name aidc-git-dev')"
# A session working on a workspace that holds an added working copy can replace it with a
# symlink to another folder of the user's; Docker's mount would follow it. Not mounted, with
# the warning, whether the symlink is the recorded folder itself or a folder on the way.
OTHER="$HOMEP/private/other"; mkdir -p "$OTHER/.git"
SW="$HOMEP/src/swapped"; ln -s "$OTHER" "$SW"; printf '%s\n' "$SW" >> "$HOME/.config/aidc/git-repos"
mkdir -p "$HOMEP/real-parent/inner/.git"; ln -s "$HOMEP/real-parent" "$HOMEP/linkparent"
printf '%s\n' "$HOMEP/linkparent/inner" >> "$HOME/.config/aidc/git-repos"
mkdir -p "$HOMEP/src/dotgit"; ln -s "$OTHER/.git" "$HOMEP/src/dotgit/.git"; printf '%s\n' "$HOMEP/src/dotgit" >> "$HOME/.config/aidc/git-repos"
out=$(run git setup)
for x in "$SW" "$HOMEP/linkparent/inner" "$HOMEP/src/dotgit"; do
    assert_not_has "a recorded working copy now reached through a symlink is not mounted: ${x#"$HOMEP"/}" "-v ${x}:" "$(line 'run -d --name aidc-git-dev')"
    assert_has "and the user is told" "warning: ${x} is gone, not a working copy, or reached through a symlink" "$out"
done
assert_not_has "nor is the folder the symlink points at" "$OTHER" "$(line 'run -d --name aidc-git-dev')"
assert_has "the working copy still as recorded is mounted" "-v ${WC}:${WC}:rw" "$(line 'run -d --name aidc-git-dev')"
assert_has "and checked from inside the container after the start" "exec -u git aidc-git-dev stat -c %d:%i -- ${WC}" "$(calls)"
assert_not_has "a start whose mounts match keeps the container" "rm -f aidc-git-dev" "$(sed -n '/run -d --name aidc-git-dev/,$p' "$D_LOG")"
# Swapped between the check and Docker's mount (and back): the container sees another folder.
out=$(D_SEEN="$(stat -c %d "$WC"):1" run git setup); rc=$?
assert_has "a working copy the container sees as another folder stops the start, named" "${WC} changed while the git container started" "$out"
assert_eq "it fails" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
assert_has "and the container is removed" "rm -f aidc-git-dev" "$(sed -n '/run -d --name aidc-git-dev/,$p' "$D_LOG")"
# An inode number is unique only within one filesystem: a folder on another filesystem with
# the same inode number is another folder.
out=$(D_SEEN="$(( $(stat -c %d "$WC") + 1 )):$(stat -c %i "$WC")" run git setup); rc=$?
assert_has "the same inode on another device stops the start too" "${WC} changed while the git container started" "$out"
assert_eq "it fails" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
assert_has "and the container is removed" "rm -f aidc-git-dev" "$(sed -n '/run -d --name aidc-git-dev/,$p' "$D_LOG")"
for x in "$SW" "$HOMEP/linkparent/inner" "$HOMEP/src/dotgit"; do
    { grep -vxF -- "$x" "$HOME/.config/aidc/git-repos" || true; } > "$SCRATCH/repos.tmp"; mv "$SCRATCH/repos.tmp" "$HOME/.config/aidc/git-repos"
done
out=$(run repo remove "$HOMEP/gone")
assert_has "a working copy that went away can still be forgotten" "if any, are left (aidc repo remove <owner/name>)" "$out"
assert_eq "and is" 0 "$(grep -cxF "$HOMEP/gone" "$HOME/.config/aidc/git-repos")"
out=$(run repo remove "$WC" --delete-working-copy)
assert_has "the user's working copy is never deleted" "never deletes it" "$out"
out=$(run repo remove "$WC")
assert_has "remove deletes gitrun's private copy" "exec -u git aidc-git-dev gitctl remove-copy o/r" "$(calls)"
assert_eq "and takes o/r off the list of added repos" "" "$(cat "$ADDED")"
assert_eq "and forgets the working copy" 0 "$(grep -cxF "$WC" "$HOME/.config/aidc/git-repos")"
assert_not_has "which is no longer mounted" "-v ${WC}:" "$(line 'run -d --name aidc-git-dev')"
assert_eq "and is left on disk" yes "$([ -d "$WC/.git" ] && echo yes)"
run repo add "$WC" >/dev/null
out=$(run repo remove o/r)
assert_has "remove by owner/name finds the working copies of that repo" "gitctl remove-copy o/r" "$(calls)"
assert_eq "and forgets them" 0 "$(grep -cxF "$WC" "$HOME/.config/aidc/git-repos")"
run repo add "$WC" >/dev/null

echo "=== push, pr, merge, tidy, protect: on a working copy the user added ==="
out=$(run git push "$HOMEP/notarepo" feat)
assert_has "a path that is not an added working copy is refused" "aidc repo add <working copy> first" "$out"
assert_not_has "before the git container is asked" "gitctl" "$(calls)"
out=$(run git push "$WC" feat)
assert_has "push runs gitctl push in the git container, as the request holder (the agent cannot)" \
    "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev gitctl push ${WC} feat" "$(calls)"
assert_has "and says what was pushed" "pushed feat" "$out"
mkdir -p "$WC/wt"
out=$(run git push "$WC/wt" feat)
assert_has "a worktree inside the working copy is taken as it is" "gitctl push ${WC}/wt feat" "$(calls)"
printf 'The body\n' > "$SCRATCH/body"
out=$(run git pr "$WC" feat --title "Add it" --body-file "$SCRATCH/body")
assert_has "pr pushes, then opens the pull request with the body on stdin" "https://github.com/o/r/pull/7" "$out"
assert_eq "the body went in on stdin" "The body" "$(cat "$D_STDIN")"
assert_has "the base is settled before the push" "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests pr-base ${WC}" "$(calls | grep -E 'pr-base|gitctl push' | head -n1)"
assert_has "and the pull request is opened as the holder" "exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev bash -c" "$(calls)"
assert_has "and handed to pr-create: origin's default" "bash ${WC} feat main Add it" "$(calls)"
: > "$D_LOG"
out=$(run git pr "$WC" feat --base release --title "Add it" --body-file "$SCRATCH/body")
assert_has "a --base given goes through the same check" "git-requests pr-base ${WC} release" "$(calls)"
assert_has "..." "bash ${WC} feat release Add it" "$(calls)"
: > "$D_LOG"
out=$(D_NO_BASE=1 run git pr "$WC" feat --title "Add it" --body-file "$SCRATCH/body"; echo "exit=$?")
assert_has "no base and no origin default: refused, saying nothing was pushed" "nothing pushed" "$out"
assert_has "..." "exit=1" "$out"
assert_not_has "and nothing is pushed" "gitctl push" "$(calls)"
assert_not_has "nor a pull request asked for" "bash -c" "$(calls)"
out=$(run git merge "$WC" 7)
assert_has "merge merges as the holder, then tidies" "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev gitctl pr-merge ${WC} 7" "$(calls)"
assert_has "and reports what is left" "unpushed: other (2 commit(s) on no GitHub branch)" "$out"
out=$(run git tidy)
assert_has "tidy with no repo tidies every working copy added" "gitctl tidy ${WC}" "$(calls)"
out=$(run git protect "$WC")
assert_has "protect shows the protections" "force pushes:   blocked" "$out"
out=$(run git requests)
assert_not_has "control characters from sessions never reach the terminal" $'\033' "$out"
out=$(run git approve 0123456789abcdef0123456789abcdef)
assert_has "approve runs git-requests approve as the request holder, from outside the container" \
    "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests approve 0123456789abcdef0123456789abcdef" "$(calls)"
out=$(run git deny 0123456789abcdef0123456789abcdef "not now")
assert_has "deny too" "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests deny 0123456789abcdef0123456789abcdef not now" "$(calls)"
out=$(run git logout)
assert_has "logout runs as the request holder (the agent cannot log the container out)" \
    "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev gitctl logout" "$(calls)"
out=$(run git approve nope)
assert_has "an id that is not one is refused" "not a request id" "$out"

echo "=== aidc git mode: a session's own mode, by its token ==="
out=$(D_SESSIONS=s1 D_TOKEN="$(printf 'a%.0s' $(seq 64))" run git mode s1 rules)
assert_has "the session's token is read from its dev container and handed over on stdin" "exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests mode s1 rules" "$(calls)"
assert_eq "the token itself, never on a command line" "$(printf 'a%.0s' $(seq 64))" "$(cat "$D_STDIN")"
assert_not_has "not in any docker argument" "$(printf 'a%.0s' $(seq 64))" "$(calls)"
out=$(D_SESSIONS=s1 D_TOKEN="" run git mode s1 rules)
assert_has "a session made before sessions had tokens is told to be made again" "create it again" "$out"
out=$(run git mode git rules)
assert_has "the git agent has no mode of its own: its requests always wait" "the git agent has no mode" "$out"
for m in ask default; do
    : > "$D_STDIN"
    out=$(D_SESSIONS=s1 D_TOKEN="$(printf 'a%.0s' $(seq 64))" run git mode s1 "$m")
    assert_has "${m}, too, is keyed on the session's token, on stdin" "exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests mode s1 ${m}" "$(calls)"
    assert_eq "..." "$(printf 'a%.0s' $(seq 64))" "$(cat "$D_STDIN")"
done
out=$(D_SESSIONS="" run git mode s9 ask)
assert_has "a session that does not exist is refused" "no session 's9'" "$out"

echo "=== setup registers every session's token; kill forgets the session ==="
: > "$D_STDIN"
out=$(D_TOKEN="$(printf 'c%.0s' $(seq 64))" run git setup)
assert_has "setup hands the git container every session's token (sync), on stdin" "exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests sync" "$(calls)"
assert_eq "the git agent's own container is not a session there" "s1 $(printf 'c%.0s' $(seq 64))" "$(cat "$D_STDIN")"
assert_not_has "no token on a command line" "$(printf 'c%.0s' $(seq 64))" "$(calls)"
out=$(D_LENIENT=1 D_SESSIONS=s1 run kill s1)
assert_has "aidc kill has the git container forget the session (its token and mode)" "exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests forget s1" "$(calls)"
out=$(D_LENIENT=1 D_SESSIONS=s1 D_STATE=absent run kill s1)
assert_not_has "with no git container running, kill asks nothing of it" "git-requests forget" "$(calls)"
cc=$(cat "$AIDC_ROOT/scripts/cmd-create.sh")
assert_has "aidc create registers the new session's token, on stdin" '| docker exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq "$DK_GIT_CT" git-requests register "$NAME"' "$cc"

echo "=== aidc git log ==="
out=$(run git log)
assert_has "log reads the git container's action log (gitctl log)" "exec -u git aidc-git-dev gitctl log 100" "$(calls)"
out=$(run git log 20)
assert_has "the last N lines" "gitctl log 20" "$(calls)"
out=$(run git log x)
assert_has "a count that is not one is refused" "not a number of lines" "$out"

echo "=== aidc git status ==="
out=$(D_GH=yes D_WAITING=3 run git status)
assert_has "running" "container: running" "$out"
assert_has "logged in" "github:    logged in" "$out"
assert_has "waiting requests are counted" "requests:  3 waiting for your approval (aidc git requests)" "$out"
assert_has "storage is reported" "storage:   1.0 MiB" "$out"
assert_has "egress enforced: internal network, public-only proxy" "egress:    enforced: internal network" "$out"
assert_has "and the working copies added" "repos:     1 working copy added" "$out"
out=$(D_PROXY_ENV='PATH=/bin' run git status)
assert_has "a proxy that is not public-only is NOT ENFORCED" "egress:    NOT ENFORCED" "$out"
out=$(D_INTERNAL=false run git status)
assert_has "nor is a network that is not internal" "egress:    NOT ENFORCED" "$out"
printf 'git:\n  storage_warn: 1Mi\n' > "$HOME/.config/aidc/config.yaml"
out=$(D_COPIES=2097152 run git status)
assert_has "storage above git.storage_warn is warned about" "WARNING: over git.storage_warn (1Mi)" "$out"
: > "$HOME/.config/aidc/config.yaml"
out=$(D_REQERR="git-requests: /var/aidc/git-requests is writable by others" run git status)
assert_has "a request folder the watcher refuses: status gives the watcher's own reason, not 'cannot be asked'" \
    "requests:  NOT TAKEN: the request watcher cannot use its request folder: /var/aidc/git-requests is writable by others" "$out"
out=$(D_STATE=absent run git status)
assert_has "no container: not set up, with the command" "container: not set up (run: aidc git setup)" "$out"
assert_has "and the login is unknown, never no" "github:    unknown" "$out"
out=$(D_STATE=unknown run git status)
assert_has "docker not answering is unknown" "container: unknown (docker did not answer)" "$out"
out=$(D_STATE=absent run git push "$WC" feat)
assert_has "a verb with no container says to set it up" "run \`aidc git setup\`" "$out"

echo "=== the git agent is the session named git ==="
out=$(run attach git)
assert_has "aidc attach git opens its tmux as the git user" "exec -it -u git -e TERM=" "$(calls)"
assert_has "..." "aidc-git-dev tmux attach -d -t main" "$(calls)"
out=$(run git attach)
assert_has "aidc git attach is the same" "aidc-git-dev tmux attach -d -t main" "$(calls)"
out=$(run git login)
assert_has "login runs gitctl login in its terminal" "aidc-git-dev gitctl login" "$(calls)"
for v in kill restart upgrade proxy network egress refresh; do
    out=$(run "$v" git)
    assert_has "aidc ${v} git is refused: aidc git setup manages it" "not a session aidc ${v} manages" "$out"
done
assert_eq "with an error" 2 "$(run kill git >/dev/null; echo $?)"
assert_eq "and no docker call" "" "$(D_LOG="$SCRATCH/kill.log"; : > "$D_LOG"; "$AIDC_ROOT/scripts/aidc" kill git >/dev/null 2>&1; cat "$D_LOG")"
out=$(run create git)
assert_has "aidc create git is refused (the name is the git agent's)" "'git' is the name of your git agent" "$out"
out=$(run status git)
assert_has "aidc status git is the git container's status" "git container: aidc-git-dev" "$out"
out=$(run list)
assert_has "aidc list shows it" "git" "$out"
assert_eq "as the git agent, with no taint column of its own (no sandbox proxy)" "git-agent -" \
    "$(printf '%s\n' "$out" | awk '$1 == "git" { print $(NF-2), $NF }')"
assert_not_has "and never asks a policy sidecar it does not have" "aidc-git-policy" "$(calls)"

echo "=== the git agent's Claude: the account broker's when it runs, its home's otherwise ==="
printf 'sk-ant-oat01-%s\n' "$(printf 'x%.0s' $(seq 40))" > "$HOME/.config/aidc/claude-oauth-token"
run git setup >/dev/null
git_run=$(line 'run -d --name aidc-git-dev')
assert_has "with no broker, the long-lived token is handed on as before" "-e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-" "$git_run"
assert_not_has "...and its Claude config dir stays its home's" "/home/git/.claude" "$git_run"
D_BROKER=running run git setup >/dev/null
git_run=$(line 'run -d --name aidc-git-dev')
assert_has "with the broker running, its Claude config dir is its folder of aidc-claude-config" \
    "--mount type=volume,src=aidc-claude-config,dst=/home/git/.claude,volume-subpath=git" "$git_run"
assert_has "...and no token is handed on (it would override the broker's credentials)" "-e CLAUDE_CODE_OAUTH_TOKEN= " "$git_run"
assert_has "the broker writes its credentials before it starts" "exec aidc-claude-broker claude-broker session git" "$(calls)"
rm -f "$HOME/.config/aidc/claude-oauth-token"

echo "=== sessions: their request folder and token ==="
render() {
    env SESSION=s1 PROFILE=multi REPO_PATH=/r WORKSPACE_PATH=/r AUDIT_DIR=/a HOST_CLAUDE_PROJECT_DIR=/p \
        ENCODED_REPO=-r AIDC_VERSION_TAG=v0 "$@" bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template"
}
if command -v yq >/dev/null 2>&1; then
    # The user's git identity, as compose reads it: a quote and a backslash survive the YAML (and
    # a $ is doubled, compose's literal $); a control character is not bridged.
    y=$(render GIT_USER_NAME="Alice \"Al\" O'Neil \\ Example" GIT_USER_EMAIL=alice@example.com)
    assert_eq "Docker: a git name with a double quote and a backslash reaches the session as written" \
        "Alice \"Al\" O'Neil \\ Example|alice@example.com" \
        "$(printf '%s' "$y" | yq '.services.dev.environment | .AIDC_GIT_USER_NAME + "|" + .AIDC_GIT_USER_EMAIL')"
    y=$(render GIT_USER_NAME='Cost $HOME' GIT_USER_EMAIL=alice@example.com)
    assert_eq "a \$ in it is compose's literal \$ (\$\$), not a variable" 'Cost $$HOME' "$(printf '%s' "$y" | yq '.services.dev.environment.AIDC_GIT_USER_NAME')"
    y=$(render GIT_USER_NAME=$'Two\nlines: x' GIT_USER_EMAIL=alice@example.com)
    assert_eq "a name with a control character is not bridged (it cannot add YAML of its own)" "|" \
        "$(printf '%s' "$y" | yq '.services.dev.environment | .AIDC_GIT_USER_NAME + "|" + .AIDC_GIT_USER_EMAIL')"
    y=$(render GIT_TOKEN=feed GIT_REQUESTS_PATH=/var/aidc/git-requests GIT_REQUESTS_MOUNT="- git-requests:/var/aidc/git-requests:rw" \
        GIT_REQUESTS_VOLUME_DECL=$'  git-requests:\n    name: aidc-git-requests\n    external: true')
    assert_eq "with the git container set up, the request folder is mounted at its path" "git-requests:/var/aidc/git-requests:rw" \
        "$(printf '%s' "$y" | yq '.services.dev.volumes[] | select(. == "git-requests:*")')"
    assert_eq "from the shared volume, external (aidc kill never removes it)" "aidc-git-requests true" \
        "$(printf '%s' "$y" | yq '.volumes["git-requests"] | .name + " " + (.external | tostring)')"
    assert_eq "and the session knows where it is, its backend and its token" "/var/aidc/git-requests docker feed" \
        "$(printf '%s' "$y" | yq '.services.dev.environment | .AIDC_GIT_REQUESTS + " " + .AIDC_BACKEND + " " + .AIDC_GIT_TOKEN')"
    y=$(render GIT_TOKEN=feed)
    assert_eq "without it, no request folder and no volume" "|null" \
        "$(printf '%s' "$y" | yq '.services.dev.environment.AIDC_GIT_REQUESTS')|$(printf '%s' "$y" | yq '.volumes["git-requests"]')"
    assert_eq "and the stand-in says no git container is set up (an empty folder is none)" "" \
        "$(printf '%s' "$y" | yq '.services.dev.environment.AIDC_GIT_REQUESTS')"
else
    echo "  SKIP: yq not installed (compose rendering)"
fi
cr=$(cat "$AIDC_ROOT/scripts/cmd-create.sh")
assert_has "every session gets a random 64-hex token" "GIT_TOKEN=\$(od -An -N32 -tx1 /dev/urandom" "$cr"
assert_has "the request folder only when the git container's volume exists" "if docker volume inspect aidc-git-requests" "$cr"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
