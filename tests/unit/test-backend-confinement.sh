#!/usr/bin/env bash
# Docker is called only where the Docker backend lives.
#
# aidc gains a second place for sessions to run (Kubernetes, docs/design-12-kubernetes.md).
# Its switch point on the CLI side is the dispatcher, scripts/aidc, which runs one
# scripts/cmd-<verb>.sh per verb; the Kubernetes verbs go beside these. A `docker` call
# that creeps into the dispatcher or a shared library would run under the Kubernetes
# backend too, and talk to a daemon that holds none of its sessions. So:
#   - the per-verb scripts and the Docker network libraries may call docker;
#   - in common.sh and config.sh only the named Docker helper functions may;
#   - the dispatcher and every other shared library may not.
# The Kubernetes backend's mirror image: kubectl only in scripts/k8s/, and docker never there.
# scripts/docker/ (the git container on Docker) is the Docker backend's, so kubectl never there.
#
# Hygiene: reads files only.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

# Files that implement the Docker backend outright.
DOCKER_FILES="lib/network.sh lib/egress.sh"
# Shared libraries' Docker helpers: file:function.
DOCKER_FUNCS="
common.sh:session_exists
common.sh:require_docker
common.sh:ensure_image
common.sh:aidc_session_audit_dir
common.sh:list_adhoc_forwards
common.sh:remove_adhoc_forwards
common.sh:remove_session_networks
common.sh:wait_for_dev_ready
config.sh:aidc_mcp_deny_target
"

# docker_calls <file>: "<line>:<function>" for each line that runs docker as a command
# (a command word after a separator, a keyword such as `if` or `while`, `exec`, `xargs`,
# `env`, `timeout N`, `!`, `$(` or `command -v`), outside comments. <function> is the
# enclosing shell function, or "-" at top level; a one-line function ends on its own line.
docker_calls() {
    awk '
        /^[[:space:]]*#/ { next }
        /^(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{/ ||
        /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)/ {
            fn = $0
            sub(/^function[[:space:]]+/, "", fn)
            sub(/[[:space:]]*(\(\))?[[:space:]]*\{.*$/, "", fn)
            sub(/[[:space:]]*\(\).*$/, "", fn)
            oneline = ($0 ~ /\}[[:space:]]*$/)
        }
        /(^|[;&|({`]|\$\(|(^|[^a-zA-Z0-9_])(then|else|do|if|elif|while|until|exec|xargs|env|time)|timeout[[:space:]]+[0-9]+[a-z]?|!|command -v)[[:space:]]*docker([[:space:]]|$)/ {
            print NR ":" (fn == "" ? "-" : fn)
        }
        /^}/ || oneline { fn = ""; oneline = 0 }
    ' "$1"
}

check() {
    local desc="$1" got="$2"
    if [ -z "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; printf '%s\n' "$got" | sed 's/^/      /'; FAIL=$((FAIL + 1))
    fi
}

# leaks <path-under-scripts>: the calls in that file that are not allowed.
leaks() {
    local rel="$1" base hit fn
    base="$(basename "$rel")"
    case "$rel" in cmd-*.sh) return 0 ;; esac
    case " $DOCKER_FILES " in *" $rel "*) return 0 ;; esac
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        fn="${hit#*:}"
        if printf '%s\n' "$DOCKER_FUNCS" | grep -qx "${base}:${fn}"; then continue; fi
        printf '%s:%s\n' "scripts/$rel" "$hit"
    done < <(docker_calls "$AIDC_ROOT/scripts/$rel")
}

echo "=== the leak finder sees each form of a docker call ==="
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<'EOF'
# docker ps   (a comment: not a call)
top() { docker ps; }
f() {
    x=$(docker inspect a)
    if docker info; then :; fi
    timeout 5 docker ps
    if ! docker info >/dev/null; then :; fi
    printf '%s\n' "$ids" | xargs docker rm -f
    command -v docker >/dev/null
    echo "docker not found"
}
docker version
function g { docker ps; }
EOF
found=$(docker_calls "$probe" | tr '\n' ' ')
want="2:top 4:f 5:f 6:f 7:f 8:f 9:f 12:- 13:g "
if [ "$found" = "$want" ]; then
    echo "  PASS: finds a call in each position, and skips comments and messages"; PASS=$((PASS + 1))
else
    echo "  FAIL: leak finder found '$found' (want '$want')"; FAIL=$((FAIL + 1))
fi

echo "=== docker stays in the Docker backend ==="
check "the dispatcher (scripts/aidc) does not call docker" "$(
    docker_calls "$AIDC_ROOT/scripts/aidc" | sed 's|^|scripts/aidc:|')"
for f in "$AIDC_ROOT"/scripts/lib/*.sh; do
    rel="lib/$(basename "$f")"
    check "scripts/$rel calls docker only where allowed" "$(leaks "$rel")"
done

echo "=== kubectl stays in the Kubernetes backend, and docker out of it ==="
# kubectl_calls <file>: like docker_calls, for kubectl.
kubectl_calls() {
    awk '
        /^[[:space:]]*#/ { next }
        /(^|[;&|({`]|\$\(|(^|[^a-zA-Z0-9_])(then|else|do|if|elif|while|until|exec|xargs|env|time)|!|command -v)[[:space:]]*kubectl([[:space:]]|$)/ {
            print NR
        }
    ' "$1"
}
outside=""
for f in "$AIDC_ROOT"/scripts/aidc "$AIDC_ROOT"/scripts/cmd-*.sh "$AIDC_ROOT"/scripts/lib/*.sh "$AIDC_ROOT"/scripts/docker/*.sh; do
    for n in $(kubectl_calls "$f"); do outside="${outside}${f#"$AIDC_ROOT"/}:${n} "; done
done
check "no kubectl outside scripts/k8s/" "$outside"
inside=""
for f in "$AIDC_ROOT"/scripts/k8s/*.sh; do
    [ -f "$f" ] || continue
    for hit in $(docker_calls "$f"); do inside="${inside}${f#"$AIDC_ROOT"/}:${hit} "; done
done
check "no docker in scripts/k8s/" "$inside"

echo "=== every allowed helper still exists ==="
missing=""
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    grep -qE "^${entry#*:}[[:space:]]*\(\)" "$AIDC_ROOT/scripts/lib/${entry%%:*}" \
        || missing="${missing}${entry} "
done <<< "$DOCKER_FUNCS"
check "the allowlist names only helpers that exist (a stale entry would hide a leak)" "$missing"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
