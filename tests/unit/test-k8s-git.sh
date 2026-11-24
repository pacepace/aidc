#!/usr/bin/env bash
# Unit tests for the git container (k8s_render_git, `aidc git setup|attach|status`).
#
# The git container holds the user's SSH key and GitHub login, so its manifest is a security
# boundary: a privileged pod, an API token, cluster DNS or a route to private addresses would
# let a key be walked to the cluster; a recreated home claim would lose the user's login.
# Status must never say "no" when the cluster or the container could not be asked. kubectl is
# a PATH stub; HOME holds the config. Needs yq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-git-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not installed"
    exit 0
fi

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
    esac
}
assert_not_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' present in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

# kubectl stub: logs calls; apply appends stdin to $K_APPLIED.
#   K_DOWN=1         every call fails as an unreachable cluster does
#   K_NO_DISK=1      the user has no disk claim
#   K_NO_POD=1       no running git pod (the Deployment exists unless K_NO_DEP=1)
#   K_EXEC_FAIL=1    exec into the git pod fails (container not ready, exec refused)
#   K_GH=yes|stored|no   what gh says inside (default no)
#   K_WAITING=n      requests waiting for approval (default 0)
#   K_UNCHANGED=1    apply reports the Deployment unchanged
#   K_PROT="lines"   what gitctl protection reports before its end line (default: all on)
#   K_FAIL_STEP=requests  the request folder step's pod fails
#   K_NO_GIT_POLICY=1    the git-egress policy is missing
#   K_COPIES / K_BUNDLES bytes in gitrun's private copies / the agent's bundles (1 MiB / 0);
#   K_NO_STORAGE=1       gitctl storage printed nothing
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
[ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; exit 1; }
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) { echo ---; cat; } >> "$K_APPLIED"
        [ "${K_UNCHANGED:-}" = 1 ] && echo "deployment.apps/git unchanged" || echo "deployment.apps/git configured" ;;
    *"get pod repo-dir-"*"jsonpath"*)
        case "$*" in *"repo-dir-${K_FAIL_STEP:-none}-"*) printf Failed ;; *) printf Succeeded ;; esac ;;
    *"logs repo-dir-"*) echo "ready" ;;
    *"exec git-7d9f-abc -c git -- gitctl protection"*|*"exec git-7d9f-abc -c git -- gitctl protect "*)
        printf '%b' "${K_PROT:-repo o/r\ndefault main\nforce-push blocked\ndeletion blocked\nmerge-commit allowed\nsquash allowed\nrebase allowed\n}"; echo end ;;
    *"exec git-7d9f-abc -c git -- gitctl tidy"*) printf 'deleted-remote feat\nremoved-worktree /home/alice/r/wt\nunpushed 2 other\norphaned /home/alice/r/old\nend\n' ;;
    *"exec git-7d9f-abc -c git -- git-requests first-use"*) [ -n "${K_FIRST:-}" ] && printf '%b\nend\n' "$K_FIRST" ;;
    *"exec git-7d9f-abc -c git -- git-requests list"*) printf 'ID  RECEIVED\nabc\033[31m  x\n' ;;
    *"exec git-7d9f-abc -c git -- gitctl"*|*"exec -i git-7d9f-abc -c git -- bash -c"*|*"exec git-7d9f-abc -c git -- git-requests"*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'gitctl: refused: no GitHub login' >&2; exit 1; }
        cat >/dev/null 2>&1 || true; echo "ok: $*" | cut -c1-80 ;;
    *"rollout status"*) [ "${K_ROLLOUT_FAIL:-}" = 1 ] && { echo 'timed out' >&2; exit 1; } ;;
    *"get pvc disk"*)
        [ "${K_PVC_WARN:-}" = 1 ] && echo "Warning: client version skew" >&2
        [ "${K_NO_DISK:-}" = 1 ] || printf 'Bound' ;;
    *"get pod -l app=git"*)
        if [ "${K_NO_POD:-}" = 1 ]; then echo '{"items":[]}'
        else echo '{"items":[{"metadata":{"name":"git-old","deletionTimestamp":"2026-11-24T00:00:00Z"}},{"metadata":{"name":"git-7d9f-abc"}}]}'; fi ;;
    *"get deployment git"*) [ "${K_NO_DEP:-}" = 1 ] || echo "deployment.apps/git" ;;
    *"exec git-7d9f-abc -c git -- sh -c"*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection' >&2; exit 1; }
        echo "github=${K_GH:-no}"; echo "waiting=${K_WAITING:-0}"
        [ "${K_NO_STORAGE:-}" = 1 ] || { echo "storage-copies ${K_COPIES:-1048576}"; echo "storage-bundles ${K_BUNDLES:-0}"; } ;;
    *"get networkpolicy -o name"*)
        echo "networkpolicy.networking.k8s.io/default-deny"
        [ "${K_NO_GIT_POLICY:-}" = 1 ] || echo "networkpolicy.networking.k8s.io/git-egress" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" PATH="$SCRATCH/bin:$PATH" TERM=xterm-test
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
EOF
run() { : > "$K_APPLIED"; : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null; echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr '+' '_')

echo "=== aidc git setup: the manifest ==="
out=$(run git setup)
assert_has "setup reports the container ready" "the git container is ready" "$out"
assert_has "and exits 0" "exit=0" "$out"
assert_has "and points the user at adding their own GitHub login" "aidc git login" "$out"
assert_eq "it applies the egress policy, the home, login and private-copy claims and the Deployment, nothing else" \
    "NetworkPolicy/git-egress PersistentVolumeClaim/git-home PersistentVolumeClaim/git-cred PersistentVolumeClaim/git-run Deployment/git" \
    "$(yq -N e 'select(.kind != "Pod" and .kind != null) | [.kind, .metadata.name] | join("/")' "$K_APPLIED" | grep . | paste -sd' ' -)"
assert_eq "everything goes in the user's namespace" "aidc-u-alice" "$(q '.metadata.namespace' | sort -u | tr -d '"')"
assert_has "it waits for the Deployment to be ready" "rollout status deployment/git" "$(cat "$K_LOG")"
assert_eq "every volume mount in the git pod names a volume the pod declares" "" \
    "$(yq -N ea 'select(.kind == "Deployment" or .kind == "Pod" or .kind == "StatefulSet") | (.spec.template.spec // .spec) as $p | ([($p.containers[], $p.initContainers[]?) | .volumeMounts[]?.name] - [$p.volumes[]?.name]) | .[]' "$K_APPLIED" | sort -u | paste -sd' ' -)"
dep() { q "select(.kind == \"Deployment\") | $1" | tail -1; }
pod() { dep ".spec.template.spec | $1"; }
assert_eq "one replica, replaced not rolled (two would share one home and race on repos)" '[1,"Recreate"]' \
    "$(dep '[.spec.replicas, .spec.strategy.type]')"
assert_eq "no API token, no service links, Quad9 DNS only" '[false,false,"None",["9.9.9.9","149.112.112.112"]]' \
    "$(pod '[.automountServiceAccountToken, .enableServiceLinks, .dnsPolicy, .dnsConfig.nameservers]')"
# sudo (setuid) is how the wrapped git and gh reach the users that run the real ones; the
# capabilities are exactly a user switch's, so it can become those users and nothing more.
assert_eq "the git container runs as uid 2000, its own group, unprivileged, with only a user switch's capabilities" \
    '{"runAsUser":2000,"runAsGroup":2000,"runAsNonRoot":true,"privileged":false,"allowPrivilegeEscalation":true,"capabilities":{"drop":["ALL"],"add":["SETUID","SETGID","AUDIT_WRITE"]}}' \
    "$(pod '.containers[] | select(.name == "git") | .securityContext')"
assert_eq "the pod adds the session group (1000) and the runtime's seccomp profile" \
    '{"supplementalGroups":[1000],"seccompProfile":{"type":"RuntimeDefault"}}' "$(pod '.securityContext')"
assert_eq "no container or init container is privileged" "[]" \
    "$(pod '[(.containers[], .initContainers[]) | select(.securityContext.privileged == true)]')"
assert_eq "the root init step keeps only the capabilities a copy and chown need" \
    '{"runAsUser":0,"runAsGroup":0,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"],"add":["CHOWN","FOWNER","DAC_OVERRIDE"]}}' \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .securityContext')"
assert_has "a new home is seeded from the image only once, owned by the git user, private" \
    "[ -e /seed/.profile ] || cp -a /home/git/. /seed/; chown 2000:2000 /seed && chmod 0700 /seed" \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .command')"
assert_has "the login's home is gitcred's (2001), not listable by the git user" \
    "chown 2001:2001 /cred && chmod 0711 /cred" \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .command')"
assert_eq "it lands where sessions land, with their tolerations" \
    '[{"kubernetes.io/hostname":"n1"},[{"key":"role","operator":"Equal","value":"dev","effect":"NoSchedule"}]]' \
    "$(pod '[.nodeSelector, .tolerations]')"
assert_eq "its image is aidc's gitctl from the in-cluster registry, pulled every time" \
    "[\"localhost:5000/aidc/gitctl:${VERSION_TAG}\",\"Always\"]" \
    "$(pod '.containers[] | select(.name == "git") | [.image, .imagePullPolicy]')"
assert_eq "every aidc image in it is pulled every time" "[]" \
    "$(pod '[(.containers[], .initContainers[]) | select(.imagePullPolicy != "Always")]')"
assert_eq "the user's disk at /home/<user> (one path everywhere), its own home at /home/git, the login at gitcred's home, the private copies at gitrun's store" \
    '[{"name":"disk","mountPath":"/home/alice"},{"name":"home","mountPath":"/home/git"},{"name":"cred","mountPath":"/var/lib/gitctl/gitcred"},{"name":"run-store","mountPath":"/var/lib/gitctl/gitrun"}]' \
    "$(pod '.containers[] | select(.name == "git") | .volumeMounts')"
assert_eq "the volumes are the user's disk claim and the git-home, git-cred and git-run claims" \
    '[{"name":"disk","persistentVolumeClaim":{"claimName":"disk"}},{"name":"home","persistentVolumeClaim":{"claimName":"git-home"}},{"name":"cred","persistentVolumeClaim":{"claimName":"git-cred"}},{"name":"run-store","persistentVolumeClaim":{"claimName":"git-run"}}]' \
    "$(pod '.volumes')"
assert_eq "the home and login claims (the user's secrets) are on the user's retained class, not the session one" \
    '"shared-disk"' "$(q 'select(.kind == "PersistentVolumeClaim" and .metadata.name != "git-run") | .spec.storageClassName' | sort -u)"
assert_eq "the private copies (a cache of GitHub) are on the session class, 10Gi unless configured" '["scratch","10Gi"]' \
    "$(q 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "git-run") | [.spec.storageClassName, .spec.resources.requests.storage]')"
assert_has "gitrun's store is gitrun's alone (gitctl refuses one others can enter)" \
    "chown 2002:2002 /run-store && chmod 0700 /run-store" \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .command')"
assert_eq "it is ready only when its tmux session is up" '["tmux","has-session","-t","main"]' \
    "$(pod '.containers[] | select(.name == "git") | .readinessProbe.exec.command')"
assert_eq "the egress policy, exactly: no ingress; Quad9 DNS; public addresses only" \
    '{"podSelector":{"matchLabels":{"app":"git"}},"policyTypes":["Ingress","Egress"],"egress":[{"to":[{"ipBlock":{"cidr":"9.9.9.9/32"}},{"ipBlock":{"cidr":"149.112.112.112/32"}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]},{"to":[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","127.0.0.0/8"]}}]}]}' \
    "$(q 'select(.kind == "NetworkPolicy") | .spec')"
assert_eq "the policy selects exactly the pods the Deployment makes" '"git"' \
    "$(dep '.spec.template.metadata.labels.app')"
assert_has "every kubectl call uses the configured context" "--context lab apply" "$(cat "$K_LOG")"

assert_eq "the git container is told its request folder and git mode" \
    '[{"name":"AIDC_GIT_REQUESTS","value":"/home/alice/.aidc/git-requests"},{"name":"AIDC_GIT_MODE","value":"ask"}]' \
    "$(pod '[.containers[] | select(.name == "git") | .env[] | select(.name == "AIDC_GIT_REQUESTS" or .name == "AIDC_GIT_MODE")]')"
assert_eq "setup makes the request folder on the disk, by the root folder step, for the agent" \
    '["/home/alice/.aidc/git-requests","/home/alice","requests","2000"]' \
    "$(q 'select(.kind == "Pod") | .spec.containers[0].command[4:8]')"
assert_eq "a Deployment that applied changed rolls by itself: no restart" "" "$(grep 'rollout restart' "$K_LOG")"
out=$(K_UNCHANGED=1 run git setup)
assert_has "an unchanged Deployment (same tag, maybe a rebuilt image) is restarted, so the pod pulls the image again" \
    "rollout restart deployment/git" "$(cat "$K_LOG")"
assert_eq "restarted before setup waits for it" yes \
    "$([ "$(grep -n 'rollout restart' "$K_LOG" | cut -d: -f1)" -lt "$(grep -n 'rollout status' "$K_LOG" | cut -d: -f1)" ] && echo yes || echo no)"
out=$(K_FAIL_STEP=requests run git setup)
assert_has "a request folder that cannot be made fails setup, saying so" "its request folder /home/alice/.aidc/git-requests could not be made" "$out"
cp "$HOME/.config/aidc/config.yaml" "$SCRATCH/config.bak"
printf '  git_mode: rules\n' >> "$HOME/.config/aidc/config.yaml"
out=$(run git setup)
assert_has "kubernetes.git_mode reaches the git container" '{"name":"AIDC_GIT_MODE","value":"rules"}' "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[]')"
cp "$SCRATCH/config.bak" "$HOME/.config/aidc/config.yaml"
printf '  git_mode: yolo\n' >> "$HOME/.config/aidc/config.yaml"
out=$(run git setup)
assert_has "a git_mode that is not ask or rules is refused" "is not ask or rules" "$out"
cp "$SCRATCH/config.bak" "$HOME/.config/aidc/config.yaml"
out=$(run git setup)

echo "=== aidc git setup: run again ==="
nopod() { yq -N e 'select(.kind != "Pod")' "$K_APPLIED"; }
first=$(nopod)
out=$(run git setup)
assert_has "a second setup succeeds" "exit=0" "$out"
assert_eq "it applies the same manifests (apply leaves what is right alone)" "$first" "$(nopod)"
assert_not_has "and deletes nothing but its own one-shot folder pod (the home claim holds the user's secrets)" " delete " \
    "$(grep -v ' delete pod repo-dir-requests-' "$K_LOG")"

echo "=== aidc git setup: failures ==="
out=$(K_NO_DISK=1 run git setup)
assert_has "no disk: says to add the user first" "run \`aidc user add alice\` first" "$out"
assert_has "and exits 1" "exit=1" "$out"
assert_not_has "and applies nothing" "apply" "$(cat "$K_LOG")"
out=$(K_DOWN=1 run git setup)
assert_has "a cluster that does not answer is said so, not 'no disk'" "the cluster did not answer" "$out"
assert_not_has "and is not reported as a missing user" "aidc user add" "$out"
out=$(K_PVC_WARN=1 run git setup)
assert_has "a kubectl warning on a disk read that worked is not 'no disk'" "exit=0" "$out"
assert_not_has "and does not send the user to add a disk" "aidc user add" "$out"
out=$(K_ROLLOUT_FAIL=1 run git setup)
assert_has "a container that never gets ready is reported with where to look" "did not become ready" "$out"
assert_has "and exits 1" "exit=1" "$out"
out=$(run git setup extra)
assert_has "setup takes no arguments" "takes no arguments" "$out"
out=$("$AIDC_ROOT/scripts/aidc" git frobnicate 2>&1 </dev/null); rc=$?
assert_eq "an unknown subcommand exits 2" "2" "$rc"

echo "=== aidc git attach ==="
out=$(run git attach)
assert_has "attach opens the running pod's tmux as the container's own user, with the caller's terminal" \
    "--context lab -n aidc-u-alice exec -it git-7d9f-abc -c git -- env TERM=xterm-test tmux attach -d -t main" "$(cat "$K_LOG")"
assert_not_has "it never attaches to a pod that is being replaced" "git-old" "$(grep ' exec ' "$K_LOG")"
out=$(K_NO_POD=1 run git attach)
assert_has "no running container: says to set it up" "run \`aidc git setup\`" "$out"
assert_has "and exits 1" "exit=1" "$out"
out=$(K_DOWN=1 run git attach)
assert_has "a cluster that does not answer is said so" "the cluster did not answer" "$out"

echo "=== aidc git status ==="
out=$(K_GH=yes run git status)
assert_has "the running pod is named" "pod:      git-7d9f-abc, running" "$out"
assert_has "a confirmed GitHub login is yes" "github:   logged in" "$out"
assert_not_has "no SSH key row (the login is gh over https)" "ssh key" "$out"
assert_has "the git mode is shown (ask by default)" "mode:     ask" "$out"
assert_has "no waiting requests is none" "requests: none" "$out"
out=$(K_WAITING=3 run git status)
assert_has "waiting requests are counted, with where to see them" "requests: 3 waiting for your approval (aidc git requests)" "$out"
assert_has "the egress policy is reported enforced" "egress:   enforced" "$out"
out=$(run git status)
assert_has "no login is no, with what to do" "github:   not logged in (aidc git attach" "$out"
out=$(K_GH=stored run git status)
assert_has "a stored login GitHub did not confirm is unknown, not no" \
    "github:   unknown (GitHub did not confirm the login)" "$out"
out=$(K_EXEC_FAIL=1 run git status)
assert_has "a container that cannot be asked: login unknown" "github:   unknown" "$out"
assert_has "a container that cannot be asked: requests unknown" "requests: unknown" "$out"
assert_not_has "and never 'not logged in'" "not logged in" "$out"
out=$(K_DOWN=1 run git status)
assert_has "a cluster that does not answer: pod unknown" "pod:      unknown" "$out"
assert_has "login unknown" "github:   unknown" "$out"
assert_has "egress unknown, not 'not enforced'" "egress:   unknown" "$out"
assert_not_has "never 'not set up'" "not set up" "$out"
out=$(K_NO_POD=1 run git status)
assert_has "a Deployment with no running pod says not running" "pod:      not running" "$out"
out=$(K_NO_POD=1 K_NO_DEP=1 run git status)
assert_has "no Deployment says not set up, with the command" "pod:      not set up (run: aidc git setup)" "$out"
out=$(run git status)
assert_has "storage: what the private copies and bundles take" "storage:  1.0 MiB (private copies 1.0 MiB, bundles 0 B)" "$out"
assert_not_has "under the threshold, no warning" "WARNING" "$out"
out=$(K_COPIES=1073741824 K_BUNDLES=1048576 run git status)
assert_has "above kubernetes.git_storage_warn (default 1Gi) it warns, saying what to do" \
    "WARNING: over kubernetes.git_storage_warn (1Gi): aidc repo remove what you no longer work on" "$out"
cp "$HOME/.config/aidc/config.yaml" "$SCRATCH/config.bak"
printf '  git_storage_warn: 4Gi\n' >> "$HOME/.config/aidc/config.yaml"
out=$(K_COPIES=2147483648 run git status)
assert_not_has "the threshold is the config's" "WARNING" "$out"
cp "$SCRATCH/config.bak" "$HOME/.config/aidc/config.yaml"
out=$(K_NO_STORAGE=1 run git status)
assert_has "storage gitctl did not report is unknown" "storage:  unknown" "$out"
out=$(K_EXEC_FAIL=1 run git status)
assert_has "a container that cannot be asked: storage unknown" "storage:  unknown" "$out"
out=$(K_NO_GIT_POLICY=1 run git status)
assert_has "a missing egress policy is reported loudly" "NOT ENFORCED: NetworkPolicy missing: git-egress" "$out"

echo "=== push, pr, merge, tidy, protect, requests, login ==="
mkdir -p "$HOME/r"
xl() { grep ' exec ' "$K_LOG" | sed 's/^--context lab -n aidc-u-alice //'; }
out=$(run git push "$HOME/r" feat)
assert_has "push: gitctl push in the git container, the path mapped onto the disk" "exec git-7d9f-abc -c git -- gitctl push /home/alice/r feat" "$(xl)"
assert_has "then the first-use protection check" "git-requests first-use /home/alice/r" "$(xl)"
assert_has "exit 0" "exit=0" "$out"
out=$(K_FIRST='repo o/r\ndefault main\nforce-push allowed\ndeletion allowed\nmerge-commit allowed' run git push "$HOME/r" feat)
assert_has "a first push to an unprotected repo shows the protections" "force pushes:   allowed" "$out"
assert_has "and offers aidc git protect" "aidc git protect" "$out"
out=$(K_EXEC_FAIL=1 run git push "$HOME/r" feat)
assert_has "a push the git container refused fails" "exit=1" "$out"
out=$(run git push /etc feat)
assert_has "a path off the disk is refused before anything runs" "must be under your home directory" "$out"
assert_eq "..." "" "$(xl)"
printf 'The body.\n' > "$SCRATCH/body.md"
out=$(run git pr "$HOME/r" feat --title "Add it" --body-file "$SCRATCH/body.md")
assert_has "pr: pushes first" "gitctl push /home/alice/r feat" "$(xl)"
assert_has "then opens the PR with the body on stdin and the title as an argument" "exec -i git-7d9f-abc -c git -- bash -c" "$(xl)"
assert_has "..." "gitctl pr-create" "$(cat "$K_LOG")"
assert_has "exit 0" "exit=0" "$out"
out=$(run git pr "$HOME/r" feat --title "Add it")
assert_has "pr needs a body file" "usage: aidc git pr" "$out"
out=$(run git merge "$HOME/r" 12)
assert_has "merge: gitctl pr-merge, then tidy" "gitctl pr-merge /home/alice/r 12" "$(xl)"
assert_has "..." "gitctl tidy /home/alice/r" "$(xl)"
assert_has "and the tidy report names what went and what is left" "deleted on GitHub: feat" "$out"
assert_has "..." "unpushed: other (2 commit(s) on no GitHub branch)" "$out"
assert_has "..." "orphaned worktree folder (its record is gone): /home/alice/r/old" "$out"
out=$(run git merge "$HOME/r" "12;x")
assert_has "a PR number that is not one is refused" "not a pull request number" "$out"
out=$(run git tidy "$HOME/r")
assert_has "tidy one repo" "== /home/alice/r" "$out"
assert_has "..." "left for you:" "$out"
out=$(run git protect "$HOME/r")
assert_has "protect: nothing missing, nothing asked, nothing changed" "nothing to turn on" "$out"
assert_not_has "..." "gitctl protect " "$(xl)"
: > "$K_LOG"
out=$(K_PROT='repo o/r\ndefault main\nforce-push allowed\ndeletion allowed\nmerge-commit allowed\n' bash -c '"$0/scripts/aidc" git protect "$1" 2>&1 <<<"no"; echo "exit=$?"' "$AIDC_ROOT" "$HOME/r")
assert_has "missing protections are offered; anything but yes leaves them" "left as it is" "$out"
assert_not_has "..." "gitctl protect " "$(xl)"
: > "$K_LOG"
out=$(K_PROT='repo o/r\ndefault main\nforce-push allowed\ndeletion allowed\nmerge-commit allowed\n' bash -c '"$0/scripts/aidc" git protect "$1" 2>&1 <<<"yes"; echo "exit=$?"' "$AIDC_ROOT" "$HOME/r")
assert_has "the user's yes applies them, through gitctl protect" "gitctl protect /home/alice/r" "$(xl)"
out=$(run git requests)
assert_has "requests lists the waiting ones from the git container" "git-requests list" "$(xl)"
assert_not_has "with control characters a session wrote stripped" $'\033' "$out"
id=0123456789abcdef0123456789abcdef
out=$(run git approve "$id"); assert_has "approve <id>" "git-requests approve $id" "$(xl)"
out=$(run git deny "$id" "not now"); assert_has "deny <id> <why>" "git-requests deny $id not now" "$(xl)"
out=$(run git approve "../x"); assert_has "an id that is not one is refused" "not a request id" "$out"
out=$(run git login)
assert_has "login runs gitctl login interactively in the git container" "exec -it git-7d9f-abc -c git -- env TERM=xterm-test gitctl login" "$(xl)"
out=$(run git logout); assert_has "logout" "gitctl logout" "$(xl)"
out=$(K_NO_POD=1 run git push "$HOME/r" feat)
assert_has "with no git container: says to set it up" "run \`aidc git setup\`" "$out"

echo "=== aidc user add offers it ==="
out=$(run user add bob)
assert_has "user add ends with the git setup hint" "runs \`aidc git setup\`" "$out"

echo "=== the image ==="
inv=$(AIDC_ROOT="$AIDC_ROOT" AIDC_VERSION_TAG=vtest bash -c '. "$AIDC_ROOT/scripts/lib/common.sh"; aidc_image_inventory')
assert_has "gitctl is in the image inventory, so aidc k8s build builds it" \
    "aidc/gitctl:vtest|$AIDC_ROOT/gitctl|$AIDC_ROOT/gitctl/Dockerfile" "$inv"
df="$AIDC_ROOT/gitctl/Dockerfile"
assert_eq "the gh download is checked against a pinned checksum" "1" "$(grep -c 'sha256sum -c' "$df")"
assert_eq "gh is pinned to a version, not latest" "1" "$(grep -cE '^ARG GH_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df")"
assert_has "the git user is uid 2000, own group, in the session group" \
    "useradd -m -u 2000 -g 2000 -G session" "$(cat "$df")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
