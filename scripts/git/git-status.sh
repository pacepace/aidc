#!/usr/bin/env bash
# aidc git status (also aidc status git): the git container, its GitHub login, git mode, waiting
# requests (or why its request watcher cannot take any), its storage (gitrun's private copies and
# the bundles, with a warning above the storage_warn setting, so nothing fills the disk
# unnoticed) and its egress; on Docker also the working copies added.
#
# Every answer is one of yes, no or unknown: a daemon, cluster or container that cannot be asked
# is "unknown", never "no", because a user told "not logged in" logs in again when the truth was
# only that nothing answered.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 0 ] || die "aidc git status takes no arguments (got: $*)"
gb_require
gb_settings
GB_UP=0
gb_status_head
W="${GB_STATUS_W:-11}"
row() { printf '%-*s%s\n' "$W" "$1:" "$2"; }

github="unknown (the container cannot be asked)"
waiting="unknown (the container cannot be asked)"
storage="unknown (the container cannot be asked)"
out=""
if [ "$GB_UP" = 1 ]; then
    # One exec for every answer. Only a line the script printed counts: an exec that fails before
    # running it leaves them unknown. `gitctl status` asks gh, as the login's user, whether
    # GitHub accepts the login: yes, no, or unknown when GitHub could not confirm it. A request
    # list that fails says why (the watcher's own reason: its request folder is missing, not
    # its own, open to others' writes...).
    # shellcheck disable=SC2016  # expanded by the container's shell
    out=$(gb_exec sh -c '
        case "$(gitctl status 2>/dev/null)" in
            yes) echo "github=yes" ;; no) echo "github=no" ;; unknown) echo "github=stored" ;;
        esac
        # Only a list that printed its header counts; grep -c exits 1 on zero rows.
        if l=$(git-requests list 2>&1); then echo "waiting=$(printf "%s\n" "$l" | tail -n +2 | grep -c . || true)"
        else echo "requests-error=$(printf "%s\n" "$l" | grep -v "^$" | tail -n1)"; fi
        gitctl storage 2>/dev/null | sed "s/^/storage-/"' 2>/dev/null | aidc_printable || true)
    case "$(printf '%s\n' "$out" | sed -n 's/^github=//p')" in
        yes) github="logged in" ;;
        no) github="not logged in (aidc git login)" ;;
        stored) github="unknown (GitHub did not confirm the login)" ;;
    esac
    n=$(printf '%s\n' "$out" | sed -n 's/^waiting=//p')
    why=$(printf '%s\n' "$out" | sed -n 's/^requests-error=//p' | head -n1)
    case "$n" in
        0) waiting="none" ;;
        [1-9]*) waiting="${n} waiting for your approval (aidc git requests)" ;;
        *) [ -z "$why" ] || waiting="NOT TAKEN: the request watcher cannot use its request folder: ${why#git-requests: } (aidc git setup makes it again)" ;;
    esac
fi
copies=$(printf '%s\n' "$out" | sed -n 's/^storage-copies //p')
bundles=$(printf '%s\n' "$out" | sed -n 's/^storage-bundles //p')
if [ "$GB_UP" = 1 ] && printf '%s' "$copies" | grep -Eq '^[0-9]+$'; then
    total=$(( copies + ${bundles:-0} ))
    human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
    storage="$(human "$total") (private copies $(human "$copies"), bundles $(human "${bundles:-0}"))"
    if limit=$(aidc_bytes "$GB_STORAGE_WARN") && [ "$total" -gt "$limit" ]; then
        storage="${storage}; WARNING: over ${GB_STORAGE_KEY} (${GB_STORAGE_WARN}): aidc repo remove what you no longer work on"
    fi
fi
row github "$github"
row mode "${GB_MODE} (${GB_MODE_KEY}: ask approves each session request, rules lets gitctl decide; aidc git mode for one session)"
row requests "$waiting"
row storage "$storage"
gb_status_tail
