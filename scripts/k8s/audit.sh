#!/usr/bin/env bash
# The kept audit trails in the cluster (K8S-26), for `aidc audit` and the size warning.
#
#   audit.sh rows          one row per trail (format: scripts/lib/audit.sh), on stdout
#   audit.sh trim <id>...  remove these trails (claim names, or released volume names)
#   audit.sh refresh       recount the kept trails' total into the size cache
#
# A trail is a claim labelled aidc/kept=audit in the user's namespace, named
# <session>-audit-<UTC time>. `aidc kill` keeps it and records on it, as annotations, the
# trail's size after the final sweep (aidc/size-bytes), when it was killed (aidc/killed-at) and
# whether the session was tainted (aidc/tainted): a killed trail no longer grows, so nothing
# has to mount it again to measure it.
#
# Removing a claim on a Retain class leaves its volume and the data on the storage backend
# behind. So trim first sets the claim's volume to Delete, then deletes the claim: the
# provisioner then deletes the volume and its data. A volume left Released by a claim removed
# some other way is listed (state released) and trimmed the same way, so nothing piles up.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../lib/audit.sh
. "$AIDC_SCRIPTS/lib/audit.sh"

k8s_require || exit 1
NS=$(k8s_user_ns "$AIDC_K8S_USER")
# How long trim waits for the provisioner to delete a volume.
WAIT="${AIDC_AUDIT_K8S_WAIT:-120s}"

# _rows: the rows, from four reads of the cluster. A cluster that does not answer is an error,
# never "no trails". Volumes are cluster-wide objects a user may not be allowed to read; then
# released volumes are left out of the list, with a note.
_rows() {
    local tmp running
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/aidc-audit.XXXXXX")
    # shellcheck disable=SC2064  # expand now: the trap must remove this run's directory
    trap "rm -rf '$tmp'" EXIT
    k8s_kubectl -n "$NS" get pvc -l aidc/kept=audit -o json --request-timeout=10s > "$tmp/pvcs" \
        || die "the cluster did not answer; its audit trails are unknown (${NS})"
    # A trail is running when a session's StatefulSet names it, or any pod mounts it.
    running=$(k8s_kubectl -n "$NS" get statefulset --request-timeout=10s \
        -o jsonpath='{range .items[*]}{.metadata.annotations.aidc/audit}{"\n"}{end}') \
        || die "the cluster did not answer; which sessions are running is unknown (${NS})"
    running="${running}
$(k8s_kubectl -n "$NS" get pod --request-timeout=10s \
        -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}{end}')" \
        || die "the cluster did not answer; which sessions are running is unknown (${NS})"
    if ! k8s_kubectl get pv -o json --request-timeout=10s > "$tmp/pvs" 2>/dev/null; then
        info "could not read the cluster's volumes: released audit volumes are not listed"
        printf '{"items":[]}' > "$tmp/pvs"
    fi
    jq -rn --arg ns "$NS" --arg running "$running" --slurpfile pvcs "$tmp/pvcs" \
        --slurpfile pvs "$tmp/pvs" '
        ($pvcs[0]) as $pvcs | ($pvs[0]) as $pvs
        | ($running | split("\n") | map(select(. != ""))) as $running
        | ($pvs.items | map({key: .metadata.name, value: .}) | from_entries) as $pv
        | ([$pvcs.items[].metadata.name]) as $claims
        | ($pvcs.items[] | . as $c
            | ($c.metadata.annotations // {}) as $a
            | ($pv[$c.spec.volumeName // ""] // null) as $v
            | ["kubernetes", $c.metadata.name,
               ($c.metadata.labels["aidc/session"] // ($c.metadata.name | sub("-audit-[0-9]+$"; ""))),
               $c.metadata.creationTimestamp,
               ($a["aidc/killed-at"] // "-"),
               ($a["aidc/tainted"] // "?"),
               ($a["aidc/size-bytes"] // "?"),
               # A claim no session uses is kept: only aidc kill leaves one behind (a claim
               # killed before aidc recorded the kill shows no kill time).
               (if ($running | index($c.metadata.name)) then "running" else "kept" end),
               ("claim " + $ns + "/" + $c.metadata.name
                 + (if $c.spec.volumeName then ", volume " + $c.spec.volumeName
                      + (if $v then " (" + $v.spec.persistentVolumeReclaimPolicy + ")" else "" end)
                    else "" end))]),
          ($pvs.items[]
            | select(.spec.claimRef.namespace == $ns
                and ((.spec.claimRef.name // "") | test("-audit-[0-9]{14}$"))
                and (.status.phase == "Released" or .status.phase == "Failed")
                and (.spec.claimRef.name as $cn | $claims | index($cn) | not))
            | ["kubernetes", .metadata.name, (.spec.claimRef.name | sub("-audit-[0-9]+$"; "")),
               .metadata.creationTimestamp, "-", "?", "?", "released",
               ("volume " + .metadata.name + " (claim " + .spec.claimRef.name + " gone, "
                 + .spec.persistentVolumeReclaimPolicy + ", " + .status.phase + ")")])
        | @tsv'
}

# _set_delete <pv>: make sure the volume goes with its data once it has no claim. Set to
# Delete, the provisioner removes it and the data behind it.
_set_delete() {
    local pv="$1" policy
    policy=$(k8s_kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' --request-timeout=10s) \
        || { err "cannot read volume ${pv}"; return 1; }
    [ "$policy" = Delete ] && return 0
    k8s_kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null \
        || { err "cannot set volume ${pv} to Delete (it is ${policy}); nothing removed"; return 1; }
}

# _wait_gone <pv> <what>: wait for the provisioner to delete the volume, and say what happened.
_wait_gone() {
    local pv="$1" what="$2" phase prov
    if k8s_kubectl wait --for=delete "pv/${pv}" --timeout="$WAIT" >/dev/null 2>&1; then
        printf 'removed %s: volume %s and its data are deleted\n' "$what" "$pv"
        return 0
    fi
    phase=$(k8s_kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || printf '?')
    prov=$(k8s_kubectl get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || printf '')
    err "${what}: volume ${pv} is still there (${phase:-?}) after ${WAIT}: its provisioner${prov:+ (${prov})} has not deleted it, so its data is still on the storage backend. Check 'kubectl describe pv ${pv}'; aidc audit trim tries again"
    return 1
}

_trim() {
    local rows id row state where pv rc=0
    [ $# -gt 0 ] || die "audit.sh trim: name the trails"
    rows=$(_rows)
    for id in "$@"; do
        row=$(printf '%s\n' "$rows" | awk -F'\t' -v id="$id" '$2 == id' | head -n1)
        if [ -z "$row" ]; then
            err "no audit trail ${id} in ${NS}"; rc=1; continue
        fi
        state=$(printf '%s' "$row" | cut -f8)
        where=$(printf '%s' "$row" | cut -f9)
        case "$state" in
            running|unknown)
                err "${id} belongs to a session that is still running; not removed"; rc=1; continue ;;
            released)
                _set_delete "$id" || { rc=1; continue; }
                _wait_gone "$id" "released volume" || rc=1 ;;
            *)
                pv=$(k8s_kubectl -n "$NS" get pvc "$id" -o jsonpath='{.spec.volumeName}' --request-timeout=10s) \
                    || { err "cannot read claim ${id}; not removed"; rc=1; continue; }
                if [ -n "$pv" ]; then _set_delete "$pv" || { rc=1; continue; }; fi
                k8s_kubectl -n "$NS" delete pvc "$id" --wait=true --timeout="$WAIT" >/dev/null \
                    || { err "claim ${id} was not deleted (${where})"; rc=1; continue; }
                if [ -n "$pv" ]; then
                    _wait_gone "$pv" "claim ${id}" || rc=1
                else
                    printf 'removed claim %s (it had no volume)\n' "$id"
                fi ;;
        esac
    done
    aidc_audit_k8s_cache_clear
    return "$rc"
}

# _refresh: one claim list. The total counts the trails aidc kill measured; the rest (running,
# or killed without a final sweep) are counted as of unknown size.
_refresh() {
    local pvcs sums
    pvcs=$(k8s_kubectl -n "$NS" get pvc -l aidc/kept=audit -o json --request-timeout=5s) || return 1
    sums=$(printf '%s' "$pvcs" | jq -r '[.items[].metadata.annotations["aidc/size-bytes"] // empty
        | tonumber? // empty] as $s | "\($s | add // 0) \((.items | length) - ($s | length))"') || return 1
    # shellcheck disable=SC2086  # "<total> <unknown>"
    aidc_audit_k8s_cache_write "$NS" $sums
}

case "${1:-}" in
    rows)
        # The list has just read every claim: it refreshes the cached total as it goes.
        out=$(_rows)
        [ -z "$out" ] || printf '%s\n' "$out"
        # shellcheck disable=SC2046  # "<total> <unknown>"
        aidc_audit_k8s_cache_write "$NS" $(printf '%s\n' "$out" | awk -F'\t' '
            $8 == "released" { next }
            { if ($7 ~ /^[0-9]+$/) t += $7; else if ($2 != "") u++ } END { printf "%d %d", t, u }') || true ;;
    trim) shift; _trim "$@" ;;
    refresh) _refresh ;;
    *) die "usage: audit.sh rows | trim <id>... | refresh" ;;
esac
