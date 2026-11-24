#!/usr/bin/env bash
# aidc git status: the git container's pod, GitHub login and SSH key, and its egress policy.
#
# Every answer is one of yes, no or unknown: a cluster or container that cannot be asked is
# "unknown", never "no", because a user told "not logged in" logs in again, and one told
# "no key" makes a second key, when the truth was only that nothing answered.

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
ssh="unknown (the container cannot be asked)"
if [ "$rc" = 0 ]; then
    # One exec for both answers. Only a line the script printed counts: an exec that fails
    # before running it leaves both unknown. `gh auth status` asks GitHub; when it fails but a
    # login is stored, GitHub may only have been unreachable, so that is unknown too.
    # shellcheck disable=SC2016  # expanded by the container's shell, not this one
    out=$(k8s_kubectl -n "$ns" exec "$pod" -c git -- sh -c '
        if gh auth status >/dev/null 2>&1; then echo "github=yes"
        elif gh auth token >/dev/null 2>&1; then echo "github=stored"
        else echo "github=no"; fi
        keys=$(ls "$HOME"/.ssh/id_* 2>/dev/null | grep -v "\.pub$" | xargs -r -n1 basename | paste -sd" " -)
        echo "ssh=${keys:-none}"' </dev/null 2>/dev/null || true)
    case "$(printf '%s\n' "$out" | sed -n 's/^github=//p')" in
        yes) github="logged in" ;;
        no) github="not logged in (aidc git attach, then: gh auth login)" ;;
        stored) github="unknown (a login is stored, but GitHub did not confirm it)" ;;
    esac
    keys=$(printf '%s\n' "$out" | sed -n 's/^ssh=//p')
    case "$keys" in
        "") ;;
        none) ssh="none (aidc git attach, then add one to ~/.ssh)" ;;
        *) ssh="yes (${keys})" ;;
    esac
fi
printf 'github:   %s\n' "$github"
printf 'ssh key:  %s\n' "$ssh"

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
