#!/usr/bin/env bash
# Unit tests for the Claude account broker on the Docker backend (scripts/docker/broker.sh,
# scripts/docker/claude.sh; K8S-27, K8S-28): `aidc claude account|broker` reach the container
# aidc-claude-broker; it holds the accounts on a volume only it mounts and is started with nothing
# published and no capability; a session made while it runs gets its own folder of the
# aidc-claude-config volume as its Claude config dir (and no long-lived token), one made while it
# does not keeps today's way; aidc kill forgets the folder.
#
# docker is a PATH stub, and the test refuses to run unless `docker` is that stub: nothing here may
# reach this machine's daemon. HOME holds the config. Needs jq; yq for the compose and settings
# cases.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/docker-broker-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

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
#   D_DOWN=1           every call fails as an unreachable daemon does
#   D_BROKER=running|stopped|absent   the broker container (default absent)
#   D_VOLS="a b"       volumes that exist (default none)
#   D_EXEC_RC=1        claude-broker in the container fails
#   D_GITMOUNT=1       the git container running now has its folder of aidc-claude-config
#   D_ENGINE=25.0.3    the Docker Engine's version (default 29.8.0)
# `cp <dir> <ct>:<dest>` keeps the copied folder's config.json at $D_CFG.
cat > "$SCRATCH/bin/docker" <<'STUB_DOCKER_BROKER_q8'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$D_LOG"
[ "${D_DOWN:-}" = 1 ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; }
a="$*"
case "$a" in
    info*) exit 0 ;;
    "image inspect "*) exit 0 ;;
    "volume inspect "*) case " ${D_VOLS:-} " in *" ${a##* } "*) exit 0 ;; esac; echo "Error: no such volume" >&2; exit 1 ;;
    "volume create "*) exit 0 ;;
    "network inspect "*) echo "Error: network not found" >&2; exit 1 ;;
    "start aidc-claude-broker") : > "$D_LOG.started"; exit 0 ;;
    "network create "*|"rm -f "*|"create "*|"stop "*) exit 0 ;;
    "cp "*) set -- $a; cp "$2/config.json" "$D_CFG"; exit 0 ;;
    "inspect -f {{.State.Running}} aidc-claude-broker")
        [ -e "$D_LOG.started" ] && { echo true; exit 0; }
        case "${D_BROKER:-absent}" in
            running) echo true ;; stopped) echo false ;;
            *) echo "Error: No such object: aidc-claude-broker" >&2; exit 1 ;;
        esac; exit 0 ;;
    "inspect -f {{range .Mounts}}"*) [ "${D_GITMOUNT:-}" = 1 ] && echo "aidc-git-home|/home/git aidc-claude-config|/home/git/.claude "; exit 0 ;;
    "exec aidc-claude-broker claude-broker list"*) echo "* work  switch at 90%"; exit "${D_EXEC_RC:-0}" ;;
    "exec aidc-claude-broker claude-broker "*) exit "${D_EXEC_RC:-0}" ;;
    "exec -it "*) exit 0 ;;
    "logs "*) echo "a log line"; exit 0 ;;
    "version -f {{.Server.Version}}") echo "${D_ENGINE:-29.8.0}"; exit 0 ;;
    "run --rm "*) echo seeded; exit 0 ;;
esac
echo "docker stub: unexpected: $a" >&2
exit 1
STUB_DOCKER_BROKER_q8
chmod +x "$SCRATCH/bin/docker"

# kubectl answers nothing either: the cases that pick the kubernetes backend print its help only.
printf '#!/bin/sh\necho "kubectl stub: no cluster here" >&2\nexit 1\n' > "$SCRATCH/bin/kubectl"; chmod +x "$SCRATCH/bin/kubectl"
unset KUBECONFIG
export HOME="$SCRATCH/home" PATH="$SCRATCH/bin:$PATH" AIDC_VERSION_TAG=vtest
export D_LOG="$SCRATCH/docker.log" D_CFG="$SCRATCH/copied-config.json"
unset XDG_STATE_HOME AIDC_MCP_STATE_HOST AIDC_HOST_HOME AIDC_MCP_MOUNTS AIDC_BACKEND_FLAG
[ "$(command -v docker)" = "$SCRATCH/bin/docker" ] && [ "$(command -v kubectl)" = "$SCRATCH/bin/kubectl" ] \
    || { echo "FAIL: docker or kubectl is not the stub ($(command -v docker), $(command -v kubectl)); refusing to run"; exit 1; }
CFG="$HOME/.config/aidc/config.yaml"
run() { : > "$D_LOG"; rm -f "$D_LOG.started"; "$AIDC_ROOT/scripts/aidc" claude "$@" 2>&1 </dev/null; echo "exit=$?"; }
calls() { cat "$D_LOG"; }
line() { grep -F -- "$1" "$D_LOG" | head -n1; }

echo "=== which backend aidc claude talks to (aidc's one rule) ==="
out=$(run help)
assert_has "no config: Docker's broker" "aidc-claude-broker" "$out"
out=$(run help --backend kubernetes)
assert_has "--backend kubernetes: the cluster's" "a broker pod in" "$out"
printf 'backend: kubernetes\n' > "$CFG"
out=$(run help --backend docker)
assert_has "--backend docker wins over the config" "aidc-claude-broker" "$out"
out=$(run help)
assert_has "the config's backend line otherwise" "a broker pod in" "$out"
: > "$CFG"

echo "=== with no broker ==="
out=$(run account list)
assert_has "account list says how to start one" "aidc claude account add <name> starts it" "$out"
assert_has "...exit 0" "exit=0" "$out"
out=$(run account use work)
assert_has "account use refuses, saying how" "aidc claude broker start" "$out"
assert_not_has "...asking the broker nothing" "exec" "$(calls)"
out=$(D_DOWN=1 run account add work)
assert_has "a docker that does not answer stops add" "docker daemon not reachable" "$out"
assert_not_has "...starting nothing" "create --name" "$(calls)"
out=$(run broker status)
assert_has "broker status says it is not running" "claude-broker (docker, aidc-claude-broker): NOT RUNNING" "$out"

echo "=== --help on every verb is help, never an account name ==="
for v in "account use" "account remove" "account add" "account list" "broker start" "broker stop" "broker logs"; do
    # shellcheck disable=SC2086  # the verb's two words
    out=$(D_BROKER=running run $v --help)
    assert_has "aidc claude ${v} --help prints the help" "account use <name>" "$out"
    assert_not_has "...and runs nothing in the broker" "claude-broker" "$(calls)"
done

echo "=== account add starts the broker, then Claude's own login in it ==="
if command -v yq >/dev/null 2>&1; then
    printf 'claude_accounts:\n  - {name: work, switch_at: 80}\n  - {name: personal}\nclaude_account_switch: wait\n' > "$CFG"
fi
out=$(run account add work)
assert_has "it succeeds" "exit=0" "$out"
for v in aidc-claude-accounts aidc-claude-config; do
    assert_has "the volume ${v} is made when missing" "volume create --label aidc.claude=volume ${v}" "$(calls)"
done
seed=$(line 'run --rm')
assert_has "the volumes' step runs as root with no network and a chown's capabilities only" \
    "run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --security-opt no-new-privileges" "$seed"
assert_has "...giving both to the broker's user, closed to others" "chown 1000:1000 /accounts /config && chmod 0700 /accounts /config" "$(calls)"
mk=$(line 'create --name aidc-claude-broker')
assert_has "the broker is its own container, on its own network, resolving through Quad9" \
    "--network aidc-claude-broker-net --dns 9.9.9.9 --dns 149.112.112.112" "$mk"
assert_has "with no capability and no privilege gain" "--cap-drop ALL --security-opt no-new-privileges" "$mk"
for bad in --privileged "-p " --publish docker.sock "--network host" --cap-add "aidc-git" "/home/" ".config/aidc"; do
    assert_not_has "...and nothing like ${bad}" "$bad" "$mk"
done
assert_has "the accounts' volume is its alone, at the cluster's path" "-v aidc-claude-accounts:/var/lib/claude-broker" "$mk"
assert_has "the sessions' folders' volume whole" "-v aidc-claude-config:/var/aidc/claude-config" "$mk"
assert_has "the program is told where they are, as in a cluster" \
    "-e BROKER_HOME=/var/lib/claude-broker -e BROKER_ACCESS=/var/aidc/claude-config -e BROKER_CONFIG=/etc/claude-broker/config.json" "$mk"
assert_has "the image is the cluster's broker image, at this version" "aidc/broker:$(tr -d '[:space:]' < "$AIDC_ROOT/VERSION")" "$mk"
assert_has "it comes back after a reboot until stopped" "--restart unless-stopped" "$mk"
assert_has "its settings are copied in before it starts" "cp " "$(calls)"
if command -v yq >/dev/null 2>&1; then
    assert_eq "the settings are the user's claude_accounts and claude_account_switch" \
        '{"accounts":[{"name":"work","switch_at":80},{"name":"personal","switch_at":90}],"switch":"wait"}' "$(jq -c . "$D_CFG")"
else
    echo "  SKIP: yq not installed (settings)"
fi
assert_has "then Claude's own login runs in it, on this terminal" "exec -it -e TERM=" "$(line 'claude-broker login work')"
: > "$CFG"

echo "=== with the broker running ==="
out=$(D_BROKER=running run account use work)
assert_has "account use reaches the broker" "exec aidc-claude-broker claude-broker use work" "$(calls)"
out=$(D_BROKER=running run account remove work)
assert_has "account remove too" "exec aidc-claude-broker claude-broker remove work" "$(calls)"
out=$(D_BROKER=running run account list --json)
assert_has "account list passes --json on" "exec aidc-claude-broker claude-broker list --json" "$(calls)"
out=$(D_BROKER=running run broker status)
assert_has "broker status: running, with the accounts" "claude-broker (docker, aidc-claude-broker): RUNNING" "$out"
assert_has "...the list indented" "  * work" "$out"
out=$(D_BROKER=running run broker stop)
assert_has "broker stop stops the container (volumes and container kept)" "stop aidc-claude-broker" "$(calls)"
assert_not_has "...removing nothing" "volume rm" "$(calls)"
out=$(D_BROKER=running run broker logs --follow)
assert_has "broker logs --follow follows its log" "logs -f aidc-claude-broker" "$(calls)"
out=$(D_DOWN=1 run account list)
assert_has "a docker that does not answer is said, never 'not running'" "docker daemon not reachable" "$out"

echo "=== a new session: the broker's folder when it runs, today's way otherwise ==="
ready() {
    ( : > "$D_LOG"; rm -f "$D_LOG.started"
      AIDC_SCRIPTS="$AIDC_ROOT/scripts"
      # shellcheck source=../../scripts/docker/broker.sh
      . "$AIDC_ROOT/scripts/docker/broker.sh"
      dk_claude_session_ready s1 2>"$SCRATCH/ready.err"
      printf '%s|%s|%s|%s\n' "$DK_CLAUDE_VIA" "$CLAUDE_BROKER" "$CLAUDE_CONFIG_MOUNT" "$(printf '%s' "$CLAUDE_CONFIG_VOLUME_DECL" | paste -sd'~' -)" )
}
got=$(D_BROKER=running ready)
assert_eq "with the broker running, the session uses it" "broker|1" "$(printf '%s' "$got" | cut -d'|' -f1-2)"
assert_has "its folder is readied and given the active account's credentials before it starts" \
    "exec aidc-claude-broker claude-broker session s1" "$(calls)"
assert_has "its Claude config dir is its own folder of the volume, at the path CLAUDE_CONFIG_DIR names" \
    "{type: volume, source: claude-config, target: /home/vscode/.claude, volume: {subpath: s1}}" "$got"
assert_has "the volume is declared external (aidc kill never removes it with the session)" \
    "  claude-config:~    name: aidc-claude-config~    external: true" "$got"
assert_eq "with none running, today's way (its own login, or the token)" "none|||" "$(D_BROKER=absent ready)"
assert_eq "...stopped too" "none|||" "$(D_BROKER=stopped ready)"
assert_eq "a broker that does not answer for it leaves it on today's way (no folder to mount)" "none|||" "$(D_BROKER=running D_EXEC_RC=1 ready)"
assert_has "...saying so" "did not answer for s1" "$(cat "$SCRATCH/ready.err")"
assert_eq "a docker that does not answer: today's way" "none|||" "$(D_DOWN=1 ready)"
assert_eq "an engine older than 26 (no volume subpath) leaves it on today's way" "none|||" "$(D_BROKER=running D_ENGINE=25.0.3 ready)"
assert_has "...saying why" "needs 26 or later" "$(cat "$SCRATCH/ready.err")"
assert_not_has "...without making its folder" "claude-broker session" "$(calls)"

cleanup() {
    ( : > "$D_LOG"; rm -f "$D_LOG.started"
      AIDC_SCRIPTS="$AIDC_ROOT/scripts"
      # shellcheck source=../../scripts/docker/broker.sh
      . "$AIDC_ROOT/scripts/docker/broker.sh"
      DK_CLAUDE_VIA="$1"
      dk_claude_create_cleanup s1 "$2" "$3" 2>/dev/null )
}
D_VOLS=aidc-claude-config D_BROKER=running cleanup broker 1 0
assert_has "a create that failed before compose started forgets the folder the broker made" "claude-broker forget s1" "$(calls)"
D_VOLS=aidc-claude-config D_BROKER=running cleanup broker 1 1
assert_eq "...not once compose was asked (its containers may hold it: aidc kill's)" "" "$(calls)"
D_VOLS=aidc-claude-config D_BROKER=running cleanup broker 0 1
assert_eq "...nor a create that succeeded" "" "$(calls)"
D_VOLS=aidc-claude-config D_BROKER=running cleanup none 1 0
assert_eq "...nor a session the broker does not manage" "" "$(calls)"
assert_has "aidc create sets the trap after readying, and marks compose started before asking it" \
    "trap 'dk_claude_create_cleanup \"\$NAME\" \"\$?\" \"\$AIDC_COMPOSE_STARTED\"' EXIT" "$(cat "$AIDC_ROOT/scripts/cmd-create.sh")"
assert_eq "...in that order" "yes" "$(awk '/^trap .dk_claude_create_cleanup/{t=NR} /^AIDC_COMPOSE_STARTED=1/{c=NR} /compose -p "\$PROJECT" -f "\$COMPOSE_OUT" up -d/{u=NR} END{print (t && c && u && t < c && c < u) ? "yes" : "no"}' "$AIDC_ROOT/scripts/cmd-create.sh")"

if command -v yq >/dev/null 2>&1; then
    render() {
        env SESSION=s1 PROFILE=multi REPO_PATH=/r WORKSPACE_PATH=/r AUDIT_DIR=/a HOST_CLAUDE_PROJECT_DIR=/p \
            ENCODED_REPO=-r AIDC_VERSION_TAG=v0 "$@" bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template"
    }
    y=$(render CLAUDE_BROKER=1 CLAUDE_CONFIG_MOUNT="- {type: volume, source: claude-config, target: /home/vscode/.claude, volume: {subpath: s1}}" \
        CLAUDE_CONFIG_VOLUME_DECL=$'  claude-config:\n    name: aidc-claude-config\n    external: true')
    assert_eq "compose: the dev container mounts the session's folder at /home/vscode/.claude" "claude-config /home/vscode/.claude s1" \
        "$(printf '%s' "$y" | yq '.services.dev.volumes[] | select(type == "!!map") | .source + " " + .target + " " + .volume.subpath')"
    assert_eq "...over dev-home, which stays the home" "1" "$(printf '%s' "$y" | yq '[.services.dev.volumes[] | select(. == "dev-home:/home/vscode:rw")] | length')"
    assert_eq "...from the external volume" "aidc-claude-config true" "$(printf '%s' "$y" | yq '.volumes["claude-config"] | .name + " " + (.external | tostring)')"
    assert_eq "...and tells the entrypoint the broker manages it" "1" "$(printf '%s' "$y" | yq '.services.dev.environment.AIDC_CLAUDE_BROKER')"
    assert_eq "no other service mounts it" "0" "$(printf '%s' "$y" | yq '[.services | to_entries[] | select(.key != "dev") | .value.volumes[]? | select(type == "!!map")] | length')"
    y=$(render)
    assert_eq "without the broker: no folder, no volume, AIDC_CLAUDE_BROKER empty" "0|null|" \
        "$(printf '%s' "$y" | yq '[.services.dev.volumes[] | select(type == "!!map")] | length')|$(printf '%s' "$y" | yq '.volumes["claude-config"]')|$(printf '%s' "$y" | yq '.services.dev.environment.AIDC_CLAUDE_BROKER')"
else
    echo "  SKIP: yq not installed (compose rendering)"
fi
cr=$(cat "$AIDC_ROOT/scripts/cmd-create.sh")
assert_has "aidc create asks the broker before choosing a way in" 'dk_claude_session_ready "$NAME"' "$cr"
assert_has "...and hands no long-lived token on to a session the broker manages (it would override its credentials)" \
    'if [ "$DK_CLAUDE_VIA" = broker ]; then
    if [ -f "$AIDC_CLAUDE_TOKEN_FILE" ]; then
        info "auth: your long-lived token is not handed on' "$cr"

echo "=== aidc kill forgets the session's folder ==="
forget() {
    ( : > "$D_LOG"; rm -f "$D_LOG.started"
      AIDC_SCRIPTS="$AIDC_ROOT/scripts"
      # shellcheck source=../../scripts/docker/broker.sh
      . "$AIDC_ROOT/scripts/docker/broker.sh"
      dk_claude_session_forget s1 2>/dev/null; echo "rc=$?" )
}
out=$(forget)
assert_eq "with no broker volume, nothing is asked past it" "volume inspect aidc-claude-config" "$(calls)"
out=$(D_VOLS=aidc-claude-config D_BROKER=running forget)
assert_has "a running broker forgets it, under its lock" "exec aidc-claude-broker claude-broker forget s1" "$(calls)"
assert_not_has "...nothing else needed" "run --rm" "$(calls)"
out=$(D_VOLS=aidc-claude-config D_BROKER=absent forget)
rm_line=$(line 'run --rm')
assert_has "with none running, a one-shot root container with no network removes it" \
    "run --rm --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges -v aidc-claude-config:/config" "$rm_line"
assert_has "...that folder only" "--entrypoint /bin/rm aidc/broker:vtest -rf -- /config/s1" "$rm_line"
out=$(D_VOLS=aidc-claude-config D_BROKER=running D_EXEC_RC=1 forget)
assert_has "what the broker cannot remove, the one-shot does" "-rf -- /config/s1" "$(calls)"
assert_has "a failure never fails the kill" "rc=0" "$out"
kl=$(cat "$AIDC_ROOT/scripts/cmd-kill.sh")
assert_has "aidc kill calls it" 'dk_claude_session_forget "$NAME"' "$kl"

echo "=== the git agent ==="
uses() {
    ( AIDC_SCRIPTS="$AIDC_ROOT/scripts"
      # shellcheck source=../../scripts/docker/broker.sh
      . "$AIDC_ROOT/scripts/docker/broker.sh"
      dk_git_uses_broker && echo yes || echo no )
}
assert_eq "it moves to the broker when the broker runs" "yes" "$(D_BROKER=running uses)"
assert_eq "it stays moved while the broker is stopped (its history is in its folder)" "yes" "$(D_BROKER=stopped D_GITMOUNT=1 uses)"
assert_eq "it keeps its home's Claude otherwise" "no" "$(D_BROKER=absent uses)"
assert_eq "...and on an engine older than 26" "no" "$(D_BROKER=running D_ENGINE=24.0.7 uses)"
ready_git() {
    ( : > "$D_LOG"; rm -f "$D_LOG.started"
      AIDC_SCRIPTS="$AIDC_ROOT/scripts"
      # shellcheck source=../../scripts/docker/broker.sh
      . "$AIDC_ROOT/scripts/docker/broker.sh"
      dk_git_claude_ready 2>/dev/null; echo "rc=$?" )
}
out=$(D_BROKER=running ready_git)
assert_has "its folder is made as root with no network, given to the agent with the broker's group, 0770" \
    "chown 2000:1000 \"\$d\" && chmod 0770 \"\$d\"" "$(calls)"
assert_has "...filled once as the agent, with no capabilities, from its home's Claude config (read-only)" \
    "run --rm --network none --user 2000:2000 --cap-drop ALL --security-opt no-new-privileges -v aidc-git-home:/seed:ro --mount type=volume,src=aidc-claude-config,dst=/claude-config-own,volume-subpath=git" "$(calls)"
assert_has "...its history included, once" ".aidc-seeded" "$(calls)"
assert_has "...then the broker writes its credentials" "exec aidc-claude-broker claude-broker session git" "$(calls)"
lib=$(cat "$AIDC_ROOT/scripts/docker/lib.sh")
assert_has "the git container mounts that folder as its Claude config dir" \
    'claude=(--mount "type=volume,src=${DK_CLAUDE_CONFIG_VOLUME},dst=/home/git/.claude,volume-subpath=${DK_BROKER_GIT_FOLDER}")' "$lib"
assert_has "...and is handed no long-lived token then" 'if dk_git_uses_broker; then' "$lib"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
