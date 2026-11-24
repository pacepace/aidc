# shellcheck shell=bash
# aidc kept audit trails: the Docker trails (one folder per session under the audit dir), ages
# and sizes, and the warning every aidc command gives when the kept trails grow past 100 MB
# (K8S-26). The Kubernetes trails (kept claims) are scripts/k8s/audit.sh.
#
# Sourced by the dispatcher on every command, so it must stay cheap to load and to run: it reads
# the audit dir from the global config with sed (no yq), and measures it with one `du`. It
# reports failures by printing and returning non-zero, never by calling a helper of another
# library.
#
# A trail row (aidc_audit_docker_rows, k8s/audit.sh rows) is one tab-separated line:
#   backend id session created killed tainted size state where
# created and killed are UTC ISO-8601 ("-" when unknown or not killed), tainted is yes, no or ?,
# size is bytes ("?" when unknown), and state is one of:
#   running   the session still exists: never trimmed
#   kept      killed with aidc kill
#   ended     the session is gone, but its trail was never closed (no killed_at)
#   released  Kubernetes: the claim is gone, its volume (and data) is not
#   unknown   Docker could not be asked whether the session still exists: never trimmed

# The warning's threshold, in bytes (K8S-26: 100 MB). AIDC_AUDIT_WARN_BYTES overrides it.
AIDC_AUDIT_WARN_DEFAULT=$((100 * 1024 * 1024))

# How long the Kubernetes size stays good (K8S-26: about a day). AIDC_AUDIT_CACHE_SECONDS
# overrides it.
AIDC_AUDIT_CACHE_DEFAULT=86400

aidc_audit_warn_bytes() { printf '%s' "${AIDC_AUDIT_WARN_BYTES:-$AIDC_AUDIT_WARN_DEFAULT}"; }

# The global config file, the host's home, path expansion and the aidc-mcp mounts.
# shellcheck source=config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# aidc_audit_host_dir: the audit dir as the host spells it: the global config's top-level
# audit_dir (a leading ~ is the host's home), else ~/aidc-audit. Read with sed so that the
# per-command warning costs no yq run; audit_dir is one plain scalar.
aidc_audit_host_dir() {
    local cfg v=""
    cfg=$(_aidc_global_config_file)
    if [ -n "$cfg" ]; then
        v=$(sed -n 's/^audit_dir:[[:space:]]*//p' "$cfg" 2>/dev/null | head -n1 \
            | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")
    fi
    if [ -n "$v" ]; then v=$(_aidc_expand_path "$v"); else v="$(aidc_host_home)/aidc-audit"; fi
    printf '%s' "${v%/}"
}

# aidc_audit_local_dir <host dir>: where this process reads that dir (aidc_local_path: the same
# path on the host, through its mount inside aidc-mcp). Prints nothing and returns 1 when this
# process cannot reach it or it does not exist.
aidc_audit_local_dir() {
    local l
    l=$(aidc_local_path "$1" 2>/dev/null) || return 1
    [ -d "$l" ] || return 1
    printf '%s' "$l"
}

# aidc_audit_parse_age <age>: seconds in <age>: N (days), Nd, Nh or Nw. Returns 1 otherwise.
aidc_audit_parse_age() {
    local a="${1:-}" n unit
    case "$a" in
        ''|*[!0-9dhw]*) return 1 ;;
    esac
    n="${a%[dhw]}"
    unit="${a#"$n"}"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    case "$unit" in
        ''|d) printf '%s' $((n * 86400)) ;;
        h)    printf '%s' $((n * 3600)) ;;
        w)    printf '%s' $((n * 604800)) ;;
        *)    return 1 ;;
    esac
}

# aidc_audit_epoch <UTC ISO-8601>: seconds since the epoch; nothing (return 1) when unreadable.
# GNU date reads it with -d, BSD date (macOS) with -j -f.
aidc_audit_epoch() {
    local t="${1:-}"
    case "$t" in ''|-|'?') return 1 ;; esac
    date -u -d "$t" +%s 2>/dev/null && return 0
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null
}

# aidc_audit_human <bytes>: "395 MB", "12 KB", "?" for unknown.
aidc_audit_human() {
    local b="${1:-}"
    case "$b" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
    if [ "$b" -ge 1073741824 ]; then
        awk -v b="$b" 'BEGIN { printf "%.1f GB", b / 1073741824 }'
    elif [ "$b" -ge 1048576 ]; then
        printf '%s MB' $((b / 1048576))
    elif [ "$b" -ge 1024 ]; then
        printf '%s KB' $((b / 1024))
    else
        printf '%s B' "$b"
    fi
}

# aidc_audit_du_bytes <dir>: bytes under <dir> (du -sk; what cannot be read is left out).
aidc_audit_du_bytes() {
    local k
    k=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
    case "$k" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' $((k * 1024)) ;; esac
}

# _aidc_audit_docker_mounts: the basenames of every host folder an aidc container mounts, one
# per line; returns 1 when Docker cannot be asked. A trail mounted by any of them belongs to a
# session that still exists (running, paused or stopped): its audit sidecar, or a forwarder
# that logs into it. A trail's folder name is its session and creation second, so the basename
# names it.
_aidc_audit_docker_mounts() {
    local ids
    command -v docker >/dev/null 2>&1 || return 1
    ids=$(docker ps -aq --filter 'name=^aidc-' 2>/dev/null) || return 1
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086  # one id per word
    docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' $ids 2>/dev/null \
        | sed -n 's|.*/||p' | sort -u
}

# aidc_audit_docker_rows: one row per folder in the audit dir. Prints nothing when there is no
# audit dir here.
aidc_audit_docker_rows() {
    local host local_dir mounts docker_ok=1 d id meta fields session created killed tainted_at
    local tainted size state
    host=$(aidc_audit_host_dir)
    local_dir=$(aidc_audit_local_dir "$host") || return 0
    mounts=$(_aidc_audit_docker_mounts) || docker_ok=0
    for d in "$local_dir"/*/; do
        [ -d "$d" ] || continue
        id=$(basename "$d")
        meta="${d}meta.json"
        session="" created="" killed="" tainted_at=""
        if [ -f "$meta" ] && fields=$(jq -r '[.session // "", .created_at // "", .killed_at // "",
                .tainted_at // ""] | @tsv' "$meta" 2>/dev/null); then
            IFS="$(printf '\t')" read -r session created killed tainted_at <<<"$fields"
        fi
        # A folder aidc did not make (no meta.json) still counts: aidc names its folders
        # <session>-<UTC timestamp>.
        [ -n "$session" ] || session="${id%-*}"
        if [ -z "$created" ]; then
            created=$(printf '%s' "${id##*-}" \
                | sed -n 's/^\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z$/\1-\2-\3T\4:\5:\6Z/p')
        fi
        if [ -n "$tainted_at" ] || [ -e "${d}tainted" ]; then tainted=yes; else tainted=no; fi
        size=$(aidc_audit_du_bytes "$d")
        if [ "$docker_ok" = 1 ]; then
            if printf '%s\n' "$mounts" | grep -qxF -- "$id"; then state=running
            elif [ -n "$killed" ]; then state=kept
            else state=ended
            fi
        elif [ -n "$killed" ]; then
            state=kept
        else
            state=unknown
        fi
        printf 'docker\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$session" "${created:--}" \
            "${killed:--}" "$tainted" "$size" "$state" "${host}/${id}"
    done
}

# aidc_audit_docker_remove <id>: remove one trail folder. Files the audit sidecar wrote as root
# can stop a plain rm in a folder made by aidc-mcp; then a throwaway container of aidc's own
# audit image (already built for sessions, no network) removes it. Returns 1 if it stays.
aidc_audit_docker_remove() {
    local id="$1" host local_dir
    host=$(aidc_audit_host_dir)
    local_dir=$(aidc_audit_local_dir "$host") || return 1
    case "$id" in ''|.|..|*/*) return 1 ;; esac
    [ -d "${local_dir}/${id}" ] || return 0
    rm -rf -- "${local_dir:?}/${id}" 2>/dev/null
    [ -e "${local_dir}/${id}" ] || return 0
    command -v docker >/dev/null 2>&1 || return 1
    docker run --rm --network none --entrypoint rm -v "${host}:/trails" \
        "aidc/audit:${AIDC_VERSION_TAG:-latest}" -rf -- "/trails/${id}" >/dev/null 2>&1 || true
    [ ! -e "${local_dir}/${id}" ]
}

# ---- the size warning --------------------------------------------------------

# _aidc_audit_say <total bytes> <where>: the warning, on stderr.
_aidc_audit_say() {
    printf '[aidc] warning: kept audit trails take %s (more than %s) %s. See them with '\''aidc audit list'\''; remove old ones with '\''aidc audit trim --older-than 30d'\''.\n' \
        "$(aidc_audit_human "$1")" "$(aidc_audit_human "$(aidc_audit_warn_bytes)")" "$2" >&2
}

# aidc_audit_warn_docker: warn when the Docker audit dir is over the threshold. One du of one
# folder: cheap enough for every command. Quiet when there is no audit dir here.
aidc_audit_warn_docker() {
    local host local_dir b
    host=$(aidc_audit_host_dir)
    local_dir=$(aidc_audit_local_dir "$host") || return 0
    b=$(aidc_audit_du_bytes "$local_dir")
    case "$b" in ''|*[!0-9]*) return 0 ;; esac
    [ "$b" -gt "$(aidc_audit_warn_bytes)" ] || return 0
    _aidc_audit_say "$b" "in ${host}"
}

# aidc_audit_k8s_cache_file: where the Kubernetes total is kept between cluster commands.
aidc_audit_k8s_cache_file() {
    printf '%s/aidc/audit-k8s-size' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

# aidc_audit_k8s_cache_fresh: 0 when the cache exists, is younger than a day, and is newer
# than the global config (a changed cluster or user makes it stale).
aidc_audit_k8s_cache_fresh() {
    local f cfg ts now
    f=$(aidc_audit_k8s_cache_file)
    [ -f "$f" ] || return 1
    ts=$(awk 'NR==1 {print $1}' "$f" 2>/dev/null)
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    [ $((now - ts)) -lt "${AIDC_AUDIT_CACHE_SECONDS:-$AIDC_AUDIT_CACHE_DEFAULT}" ] || return 1
    cfg=$(_aidc_global_config_file)
    if [ -n "$cfg" ] && [ "$cfg" -nt "$f" ]; then return 1; fi
    return 0
}

# aidc_audit_k8s_cache_write <namespace> <total bytes> <count of unknown size>
aidc_audit_k8s_cache_write() {
    local f tmp
    f=$(aidc_audit_k8s_cache_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 1
    printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" > "$tmp" && mv -f "$tmp" "$f"
}

# aidc_audit_k8s_cache_clear: after a kill or a trim the total has changed.
aidc_audit_k8s_cache_clear() { rm -f "$(aidc_audit_k8s_cache_file)" 2>/dev/null || true; }

# aidc_audit_warn_k8s: during a cluster command, warn when the cluster's kept trails are over
# the threshold. Reads the cached total; only when it is missing or older than a day does it
# ask the cluster (one claim list, scripts/k8s/audit.sh refresh, at most a few seconds). A
# cluster that does not answer leaves the warning out: the command itself will say so.
aidc_audit_warn_k8s() {
    local f ts ns total
    if ! aidc_audit_k8s_cache_fresh; then
        bash "${AIDC_SCRIPTS:?}/k8s/audit.sh" refresh >/dev/null 2>&1 || return 0
    fi
    f=$(aidc_audit_k8s_cache_file)
    read -r ts ns total _ < "$f" 2>/dev/null || return 0
    case "$total" in ''|*[!0-9]*) return 0 ;; esac
    [ "$total" -gt "$(aidc_audit_warn_bytes)" ] || return 0
    _aidc_audit_say "$total" "in the cluster (namespace ${ns}, measured $(date -u -d "@${ts}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
        || date -u -r "$ts" '+%Y-%m-%d %H:%M UTC' 2>/dev/null))"
}
