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
# (a command word after a separator, `exec`, `xargs`, `!`, `$(` or `command -v`), outside
# comments. <function> is the enclosing shell function, or "-" at top level.
docker_calls() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)/ { fn = $1; sub(/\(\).*/, "", fn) }
        /^}/ { fn = "" }
        /(^|[;&|({`]|\$\(|then|else|do|exec|xargs|!|command -v)[[:space:]]*docker([[:space:]]|$)/ {
            print NR ":" (fn == "" ? "-" : fn)
        }
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
    if ! docker info >/dev/null; then :; fi
    printf '%s\n' "$ids" | xargs docker rm -f
    command -v docker >/dev/null
    echo "docker not found"
}
EOF
found=$(docker_calls "$probe" | tr '\n' ' ')
if [ "$found" = "2:top 4:f 5:f 6:f 7:f " ]; then
    echo "  PASS: finds a call in each position, and skips comments and messages"; PASS=$((PASS + 1))
else
    echo "  FAIL: leak finder found '$found' (want '2:top 4:f 5:f 6:f 7:f ')"; FAIL=$((FAIL + 1))
fi

echo "=== docker stays in the Docker backend ==="
check "the dispatcher (scripts/aidc) does not call docker" "$(
    docker_calls "$AIDC_ROOT/scripts/aidc" | sed 's|^|scripts/aidc:|')"
for f in "$AIDC_ROOT"/scripts/lib/*.sh; do
    rel="lib/$(basename "$f")"
    check "scripts/$rel calls docker only where allowed" "$(leaks "$rel")"
done

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
