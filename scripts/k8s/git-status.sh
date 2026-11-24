#!/usr/bin/env bash
# aidc git status: the git container's pod, GitHub login, git mode, waiting requests, its storage (gitrun's
# private copies and the agent's bundles, with a warning above kubernetes.git_storage_warn, so
# nothing fills its disk unnoticed) and its egress policy.
#
# Every answer is one of yes, no or unknown: a cluster or container that cannot be asked is
# "unknown", never "no", because a user told "not logged in" logs in again when the truth was
# only that nothing answered.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git status takes no arguments (got: $*)"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
printf 'git container: %s (namespace %s)\n' "$AIDC_K8S_USER" "$ns"

rc=0
pod=$(k8s_git_pod "$ns") || rc=$?
case "$rc" in
    0) printf 'pod:      %s, running\n' "$pod" ;;
    1)
        # No running pod: say whether there is a git container at all.
        if dep=$(k8s_kubectl -n "$ns" get deployment git --ignore-not-found -o name --request-timeout=10s 2>/dev/null); then
            if [ -n "$dep" ]; then printf 'pod:      not running (see: kubectl -n %s describe pod -l app=git)\n' "$ns"
            else printf 'pod:      not set up (run: aidc git setup)\n'; fi
        else
            printf 'pod:      unknown (the cluster did not answer)\n'
        fi ;;
    *) printf 'pod:      %s\n' "$pod" ;;
esac

github="unknown (the container cannot be asked)"
waiting="unknown (the container cannot be asked)"
storage="unknown (the container cannot be asked)"
if [ "$rc" = 0 ]; then
    # One exec for both answers. Only a line the script printed counts: an exec that fails
    # before running it leaves both unknown. `gitctl status` asks gh, as the login's user,
    # whether GitHub accepts the login: yes, no, or unknown when GitHub could not confirm it
    # (it may only have been unreachable).
    # shellcheck disable=SC2016  # expanded by the container's shell, not this one
    out=$(k8s_kubectl -n "$ns" exec "$pod" -c git -- sh -c '
        case "$(gitctl status 2>/dev/null)" in
            yes) echo "github=yes" ;; no) echo "github=no" ;; unknown) echo "github=stored" ;;
        esac
        n=$(git-requests list 2>/dev/null | tail -n +2 | grep -c .) && echo "waiting=${n}"
        gitctl storage 2>/dev/null | sed "s/^/storage-/"' </dev/null 2>/dev/null || true)
    case "$(printf '%s\n' "$out" | sed -n 's/^github=//p')" in
        yes) github="logged in" ;;
        no) github="not logged in (aidc git attach, then: gitctl login)" ;;
        stored) github="unknown (GitHub did not confirm the login)" ;;
    esac
    n=$(printf '%s\n' "$out" | sed -n 's/^waiting=//p')
    case "$n" in
        0) waiting="none" ;;
        [1-9]*) waiting="${n} waiting for your approval (aidc git requests)" ;;
    esac
fi
copies=$(printf '%s\n' "${out:-}" | sed -n 's/^storage-copies //p')
bundles=$(printf '%s\n' "${out:-}" | sed -n 's/^storage-bundles //p')
if [ "$rc" = 0 ] && printf '%s' "$copies" | grep -Eq '^[0-9]+$'; then
    total=$(( copies + ${bundles:-0} ))
    human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
    storage="$(human "$total") (private copies $(human "$copies"), bundles $(human "${bundles:-0}"))"
    if limit=$(k8s_bytes "$AIDC_K8S_GIT_STORAGE_WARN") && [ "$total" -gt "$limit" ]; then
        storage="${storage}; WARNING: over kubernetes.git_storage_warn (${AIDC_K8S_GIT_STORAGE_WARN}): aidc repo remove what you no longer work on"
    fi
fi
printf 'github:   %s\n' "$github"
printf 'mode:     %s (kubernetes.git_mode: ask approves each session request, rules lets gitctl decide)\n' "$AIDC_K8S_GIT_MODE"
printf 'requests: %s\n' "$waiting"
printf 'storage:  %s\n' "$storage"

if have=$(k8s_kubectl -n "$ns" get networkpolicy -o name --request-timeout=10s 2>/dev/null); then
    missing=""
    for p in default-deny git-egress; do
        printf '%s\n' "$have" | grep -qx "networkpolicy.networking.k8s.io/${p}" || missing="${missing} ${p}"
    done
    if [ -z "$missing" ]; then
        printf 'egress:   enforced: NetworkPolicy, public addresses and Quad9 DNS only; no connections in\n'
    else
        printf 'egress:   NOT ENFORCED: NetworkPolicy missing:%s\n' "$missing"
    fi
else
    printf 'egress:   unknown (the cluster did not answer)\n'
fi
