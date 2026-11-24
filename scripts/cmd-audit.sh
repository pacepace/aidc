#!/usr/bin/env bash
# desc: List kept audit trails, or remove old or named ones (Docker and Kubernetes).
#
# Usage: aidc audit list | aidc audit trim [--older-than <age>] [<name>...] [--yes] [--dry-run]
#
# Every session leaves an audit trail that outlives it: a folder under the audit dir on Docker,
# a kept claim on Kubernetes (K8S-26). Audit is evidence, so trails go only when asked, and never
# a running session's. Rows come from lib/audit.sh (Docker) and k8s/audit.sh (Kubernetes).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/audit.sh
. "$AIDC_SCRIPTS/lib/audit.sh"

usage() {
    cat <<'USAGE'
aidc audit <subcommand>

  list   Every kept audit trail: Docker (folders under the audit dir) and Kubernetes (kept
         claims in your namespace), with session, created, killed, tainted, size and state.
  trim [--older-than <age>] [<name>...] [--yes] [--dry-run]
         Removes trails created more than <age> ago (30d, 12h, 2w; a bare number is days)
         and/or the named ones (a session name: all its trails; or one trail's name, as
         list shows it). Lists exactly what will go and asks first, unless --yes. Never
         removes a running session's trail. --dry-run lists and removes nothing.

  --backend docker|kubernetes   only that backend's trails (default: both, where present)

States: running (the session still exists: never trimmed), kept (killed with aidc kill),
ended (the session went without aidc kill), released (Kubernetes: the claim is gone but its
volume is not; trim removes the volume and its data), unknown (Docker could not be asked:
never trimmed).

Every aidc command warns when the kept trails total more than 100 MB. On Kubernetes, trim
sets the claim's volume to Delete before deleting the claim, so a Retain storage class does
not keep the volume and its data behind.
USAGE
}

SUB="${1:-}"
case "$SUB" in
    ""|-h|--help|help) usage; exit 0 ;;
    list|trim) shift ;;
    *) err "unknown subcommand: aidc audit ${SUB} (list or trim)"; exit 2 ;;
esac

OLDER="" YES=0 DRY=0 NAMES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --older-than) OLDER="${2:-}"; shift 2 || die "--older-than needs an age (30d, 12h, 2w)" ;;
        --older-than=*) OLDER="${1#--older-than=}"; shift ;;
        --yes|-y) YES=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) NAMES+=("$1"); shift ;;
    esac
done
if [ "$SUB" = list ] && { [ -n "$OLDER" ] || [ "${#NAMES[@]}" -gt 0 ] || [ "$YES" = 1 ] || [ "$DRY" = 1 ]; }; then
    die "aidc audit list takes no arguments"
fi

# Which backends: the flag, else Docker always and the cluster when one is configured.
WANT_DOCKER=1 WANT_K8S=0
case "${AIDC_BACKEND_FLAG:-}" in
    "") bash "$AIDC_SCRIPTS/k8s/session-where.sh" --configured && WANT_K8S=1 ;;
    docker) ;;
    kubernetes|k8s) WANT_DOCKER=0 WANT_K8S=1 ;;
    *) die "unknown backend: ${AIDC_BACKEND_FLAG}; the backends are docker and kubernetes" ;;
esac

# Gather every row. A backend that cannot be read is said, and for trim stops everything: a
# trail on it could be one a name or an age meant.
ROWS="" FAILED=""
if [ "$WANT_DOCKER" = 1 ]; then
    ROWS=$(aidc_audit_docker_rows)
fi
if [ "$WANT_K8S" = 1 ]; then
    if k8s_rows=$(bash "$AIDC_SCRIPTS/k8s/audit.sh" rows); then
        ROWS="${ROWS:+${ROWS}
}${k8s_rows}"
    else
        FAILED="kubernetes"
    fi
fi
ROWS=$(printf '%s\n' "$ROWS" | sed '/^$/d')

TAB="$(printf '\t')"
FMT='%-34s %-16s %-20s %-20s %-7s %-8s %-8s %s\n'
day() { [ "$1" = - ] && { printf -- '-'; return; }; printf '%s' "$1" | sed 's/T/ /; s/:[0-9][0-9]Z$//; s/Z$//'; }

trails() { if [ "$1" = 1 ]; then printf '1 trail'; else printf '%s trails' "$1"; fi; }

# total <rows>: the sum of the known sizes, and how many are unknown.
total() {
    awk -F'\t' '{ if ($7 ~ /^[0-9]+$/) t += $7; else u++ } END { printf "%d %d", t, u }'
}

if [ "$SUB" = list ]; then
    if [ -z "$ROWS" ]; then
        printf 'No kept audit trails.\n'
    else
        # shellcheck disable=SC2059  # FMT is this script's own format
        printf "$FMT" TRAIL SESSION CREATED KILLED TAINTED SIZE STATE BACKEND
        while IFS="$TAB" read -r backend id session created killed tainted size state _where; do
            # shellcheck disable=SC2059
            printf "$FMT" "$id" "$session" "$(day "$created")" "$(day "$killed")" "$tainted" \
                "$(aidc_audit_human "$size")" "$state" "$backend"
        done <<<"$ROWS"
        for b in docker kubernetes; do
            sub=$(printf '%s\n' "$ROWS" | awk -F'\t' -v b="$b" '$1 == b')
            [ -n "$sub" ] || continue
            read -r t u <<<"$(printf '%s\n' "$sub" | total)"
            n=$(printf '%s\n' "$sub" | wc -l | tr -d ' ')
            case "$b" in
                docker) where="in $(aidc_audit_host_dir)" ;;
                kubernetes) where="in the cluster" ;;
            esac
            printf '%s: %s, %s %s%s\n' "$b" "$(trails "$n")" "$(aidc_audit_human "$t")" "$where" \
                "$([ "$u" -gt 0 ] && printf ' (%s of unknown size: running, or killed before its size was recorded)' "$u")"
        done
    fi
    if [ -n "$FAILED" ]; then
        err "the ${FAILED} trails could not be read (above)"
        exit 1
    fi
    exit 0
fi

# ---- trim -------------------------------------------------------------------

[ -n "$OLDER" ] || [ "${#NAMES[@]}" -gt 0 ] \
    || die "say which trails: --older-than <age> and/or names (aidc audit list shows them); nothing removed"
AGE=""
if [ -n "$OLDER" ]; then
    AGE=$(aidc_audit_parse_age "$OLDER") || die "--older-than ${OLDER}: an age is a number of days (30 or 30d), hours (12h) or weeks (2w)"
fi
[ -z "$FAILED" ] || die "the ${FAILED} trails could not be read, so what a trim would remove is unknown; nothing removed (--backend docker trims only the Docker trails)"

# Every named trail or session must exist: a typo never turns into "nothing to do".
for n in ${NAMES[@]+"${NAMES[@]}"}; do
    printf '%s\n' "$ROWS" | awk -F'\t' -v n="$n" '$2 == n || $3 == n { f = 1 } END { exit !f }' \
        || die "no audit trail or session named '${n}' (aidc audit list shows them); nothing removed"
done

NOW=$(date +%s)
SELECTED="" REFUSED=""
while IFS="$TAB" read -r backend id session created killed tainted size state where; do
    [ -n "$id" ] || continue
    if [ "${#NAMES[@]}" -gt 0 ]; then
        hit=0
        for n in "${NAMES[@]}"; do
            if [ "$n" = "$id" ] || [ "$n" = "$session" ]; then hit=1; fi
        done
        [ "$hit" = 1 ] || continue
    fi
    if [ -n "$AGE" ]; then
        if ! e=$(aidc_audit_epoch "$created"); then
            info "${id}: its creation time is unknown, so its age is too; not removed"
            continue
        fi
        [ $((NOW - e)) -ge "$AGE" ] || continue
    fi
    line="${backend}${TAB}${id}${TAB}${session}${TAB}${created}${TAB}${killed}${TAB}${tainted}${TAB}${size}${TAB}${state}${TAB}${where}"
    case "$state" in
        running|unknown) REFUSED="${REFUSED}${line}
" ;;
        *) SELECTED="${SELECTED}${line}
" ;;
    esac
done <<<"$ROWS"
SELECTED=$(printf '%s' "$SELECTED" | sed '/^$/d')
REFUSED=$(printf '%s' "$REFUSED" | sed '/^$/d')

rc=0
if [ -n "$REFUSED" ]; then
    printf 'Kept, because the session still exists (or Docker could not say it does not):\n'
    while IFS="$TAB" read -r backend id _ _ _ _ _ state _; do
        printf '  %s (%s, %s)\n' "$id" "$backend" "$state"
    done <<<"$REFUSED"
    # A trail asked for by name and refused is a failed request.
    if [ "${#NAMES[@]}" -gt 0 ]; then rc=1; fi
fi
if [ -z "$SELECTED" ]; then
    printf 'Nothing to remove.\n'
    exit "$rc"
fi

read -r T U <<<"$(printf '%s\n' "$SELECTED" | total)"
N=$(printf '%s\n' "$SELECTED" | wc -l | tr -d ' ')
printf 'To remove: %s (%s%s):\n' "$(trails "$N")" "$(aidc_audit_human "$T")" \
    "$([ "$U" -gt 0 ] && printf ', and %s of unknown size' "$U")"
while IFS="$TAB" read -r backend id session created killed tainted size state where; do
    printf '  %-34s %-8s created %-17s %-8s %s\n' "$id" "$(aidc_audit_human "$size")" "$(day "$created")" "$state" "$where"
done <<<"$SELECTED"
if printf '%s\n' "$SELECTED" | awk -F'\t' '$1 == "kubernetes" { f = 1 } END { exit !f }'; then
    printf 'On Kubernetes each claim'\''s volume is set to Delete first, so the volume and its data on the\nstorage backend go too, whatever the storage class keeps by default.\n'
fi
if [ "$DRY" = 1 ]; then
    printf 'Dry run: nothing removed.\n'
    exit "$rc"
fi
if [ "$YES" != 1 ]; then
    printf 'Remove them? This cannot be undone. [y/N] ' >&2
    ans=""
    read -r ans || true
    case "$ans" in
        y|Y|yes|YES) ;;
        *) printf 'Nothing removed%s.\n' "$([ -n "$ans" ] || [ -t 0 ] || printf ' (no answer: use --yes to remove without asking)')"; exit 1 ;;
    esac
fi

# Docker: ask again just before each removal whether a container mounts the trail, since a
# session could have been made with it in between (an upgrade or restart keeps its trail).
docker_ids=$(printf '%s\n' "$SELECTED" | awk -F'\t' '$1 == "docker" { print $2 }')
if [ -n "$docker_ids" ]; then
    if mounts=$(_aidc_audit_docker_mounts); then docker_ok=1; else docker_ok=0; fi
    while read -r id; do
        state=$(printf '%s\n' "$SELECTED" | awk -F'\t' -v id="$id" '$1 == "docker" && $2 == id { print $8 }')
        if [ "$docker_ok" = 1 ] && printf '%s\n' "$mounts" | grep -qxF -- "$id"; then
            err "${id} is now mounted by a session; not removed"; rc=1; continue
        fi
        if [ "$docker_ok" = 0 ] && [ "$state" != kept ]; then
            err "${id}: Docker cannot say whether its session still exists; not removed"; rc=1; continue
        fi
        if aidc_audit_docker_remove "$id"; then
            printf 'removed %s/%s\n' "$(aidc_audit_host_dir)" "$id"
        else
            err "${id}: could not remove $(aidc_audit_host_dir)/${id} (files owned by root? sudo rm -rf it)"; rc=1
        fi
    done <<<"$docker_ids"
fi

k8s_ids=$(printf '%s\n' "$SELECTED" | awk -F'\t' '$1 == "kubernetes" { print $2 }')
if [ -n "$k8s_ids" ]; then
    # shellcheck disable=SC2086  # one id per word; ids are claim and volume names
    bash "$AIDC_SCRIPTS/k8s/audit.sh" trim $k8s_ids || rc=1
fi
exit "$rc"
