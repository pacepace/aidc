#!/usr/bin/env bash
# aidc git status (Docker), also `aidc status git`: the git container, its GitHub login, git
# mode, waiting requests, its storage (gitrun's private copies and the bundles, with a warning
# above git.storage_warn, so nothing fills the disk unnoticed), its egress and the working
# copies it works on.
#
# Every answer is one of yes, no or unknown: a daemon or container that cannot be asked is
# "unknown", never "no", because a user told "not logged in" logs in again when the truth was
# only that nothing answered.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git status takes no arguments (got: $*)"
require_docker
dk_git_settings
printf 'git container: %s (Docker; the git agent, session git)\n' "$DK_GIT_CT"
state=$(dk_git_state)
case "$state" in
    running) printf 'container: running\n' ;;
    stopped) printf 'container: not running (aidc git setup; docker logs %s)\n' "$DK_GIT_CT" ;;
    absent) printf 'container: not set up (run: aidc git setup)\n' ;;
    *) printf 'container: unknown (docker did not answer)\n' ;;
esac

github="unknown (the container cannot be asked)"
waiting="unknown (the container cannot be asked)"
storage="unknown (the container cannot be asked)"
out=""
if [ "$state" = running ]; then
    # One exec for all answers; only lines the script printed count.
    # shellcheck disable=SC2016  # expanded by the container's shell
    out=$(dk_git_exec sh -c '
        case "$(gitctl status 2>/dev/null)" in
            yes) echo "github=yes" ;; no) echo "github=no" ;; unknown) echo "github=stored" ;;
        esac
        if l=$(git-requests list 2>/dev/null); then echo "waiting=$(printf "%s\n" "$l" | tail -n +2 | grep -c . || true)"; fi
        gitctl storage 2>/dev/null | sed "s/^/storage-/"' 2>/dev/null || true)
    case "$(printf '%s\n' "$out" | sed -n 's/^github=//p')" in
        yes) github="logged in" ;;
        no) github="not logged in (aidc git login)" ;;
        stored) github="unknown (GitHub did not confirm the login)" ;;
    esac
    n=$(printf '%s\n' "$out" | sed -n 's/^waiting=//p')
    case "$n" in
        0) waiting="none" ;;
        [1-9]*) waiting="${n} waiting for your approval (aidc git requests)" ;;
    esac
fi
copies=$(printf '%s\n' "$out" | sed -n 's/^storage-copies //p')
bundles=$(printf '%s\n' "$out" | sed -n 's/^storage-bundles //p')
if [ "$state" = running ] && printf '%s' "$copies" | grep -Eq '^[0-9]+$'; then
    total=$(( copies + ${bundles:-0} ))
    human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
    storage="$(human "$total") (private copies $(human "$copies"), bundles $(human "${bundles:-0}"))"
    if limit=$(aidc_bytes "$AIDC_DK_GIT_STORAGE_WARN") && [ "$total" -gt "$limit" ]; then
        storage="${storage}; WARNING: over git.storage_warn (${AIDC_DK_GIT_STORAGE_WARN}): aidc repo remove what you no longer work on"
    fi
fi
printf 'github:    %s\n' "$github"
printf 'mode:      %s (git.mode: ask approves each session request, rules lets gitctl decide)\n' "$AIDC_DK_GIT_MODE"
printf 'requests:  %s\n' "$waiting"
printf 'storage:   %s\n' "$storage"

# Egress: an internal network (no route out) and the proxy on it that refuses every address
# that is not public. Anything else is reported, never assumed.
internal=$(docker network inspect -f '{{.Internal}}' "$DK_GIT_NET" 2>/dev/null || true)
proxy_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DK_GIT_PROXY" 2>/dev/null || true)
proxy_up=$(docker inspect -f '{{.State.Running}}' "$DK_GIT_PROXY" 2>/dev/null || true)
if [ "$internal" = true ] && printf '%s\n' "$proxy_env" | grep -qx 'AIDC_PUBLIC_ONLY=1' && [ "$proxy_up" = true ]; then
    printf 'egress:    enforced: internal network, out only through its proxy to public addresses (Quad9 DNS); no connections in\n'
elif [ -z "$internal" ] && [ "$state" = absent ]; then
    printf 'egress:    not set up\n'
else
    printf 'egress:    NOT ENFORCED: network internal=%s, proxy running=%s, public-only=%s\n' "${internal:-?}" "${proxy_up:-?}" \
        "$(printf '%s\n' "$proxy_env" | grep -qx 'AIDC_PUBLIC_ONLY=1' && echo yes || echo no)"
fi
n=$(dk_git_repos | grep -c . || true)
printf 'repos:     %s working cop%s added (aidc repo list)\n' "$n" "$([ "$n" = 1 ] && echo y || echo ies)"
