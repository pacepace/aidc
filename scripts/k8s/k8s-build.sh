#!/usr/bin/env bash
# aidc k8s build: build aidc's images inside the cluster and keep them in its registry.
#
# The same images and build contexts as `aidc rebuild` (aidc_image_inventory), built by
# Docker in a privileged builder pod (owner ruling 2026-11-24: the squid image's base needs
# UIDs no user namespace has), from this aidc install's own files streamed in as tar. Each image is tagged with this aidc version and pushed to the
# in-cluster registry; an image already there for this version is skipped unless --force.
# The builder pod is deleted when the build ends, whichever way it ends.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

FORCE=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<'EOF'
aidc k8s build [--force] [--only ROLE]

Builds aidc's images (squid, refresher, policy, audit, forwarder, mcp, dev-base) in the
cluster of the `kubernetes:` config and pushes them to the registry `aidc k8s setup` made.
Images already there for this aidc version are skipped; --force builds them again (and
fetches the current Claude Code release into dev-base, as `aidc rebuild` does). --only
builds one role.
EOF
            exit 0 ;;
        --force) FORCE=1; shift ;;
        --only) ONLY="${2:-}"; [ -n "$ONLY" ] || die "--only needs a role"; shift 2 ;;
        *) die "unknown argument: $1 (see aidc k8s build --help)" ;;
    esac
done

k8s_require || exit 1
ns=$(k8s_system_ns)
if ! ready=$(k8s_kubectl -n "$ns" get deployment registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null) \
        || [ "${ready:-0}" -lt 1 ]; then
    die "no ready registry in ${ns}: run \`aidc k8s setup\` first"
fi

BUILDER="builder-$(date +%s)-$$"
cleanup() { k8s_kubectl -n "$ns" delete pod "$BUILDER" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# bexec <args...>: run in the builder's docker container, with no stdin. `kubectl exec -i`
# reads all of its stdin whatever the command does with it, so inside the loop over images
# below it would swallow the remaining rows (it did: one image built, the rest silently
# skipped). bexec_in feeds stdin on purpose, for the build context.
bexec()    { k8s_kubectl -n "$ns" exec "$BUILDER" -c docker -- "$@" </dev/null; }
bexec_in() { k8s_kubectl -n "$ns" exec -i "$BUILDER" -c docker -- "$@"; }

# Each row is "<registry path>|<context dir>|<dockerfile>" for one role.
rows=$(aidc_image_inventory)
if [ -n "$ONLY" ]; then
    rows=$(printf '%s\n' "$rows" | grep -E "^aidc/${ONLY}:" || true)
    [ -n "$rows" ] || die "unknown role '${ONLY}' (one of: squid, refresher, policy, audit, forwarder, mcp, dev-base)"
fi

info "starting builder pod ${BUILDER} in ${ns}"
sel=$(k8s_node_selector) || exit 1
k8s_render_builder "$BUILDER" "$sel" | k8s_kubectl apply -f - >/dev/null
k8s_kubectl -n "$ns" wait --for=condition=Ready "pod/${BUILDER}" --timeout=300s >/dev/null \
    || die "builder pod did not start; see: kubectl -n ${ns} describe pod ${BUILDER}"
for _ in $(seq 60); do
    bexec docker info >/dev/null 2>&1 && break
    sleep 2
done
bexec docker info >/dev/null 2>&1 || die "Docker did not start in the builder pod"

built=0 skipped=0
while IFS='|' read -r tag context dockerfile; do
    [ -n "$tag" ] || continue
    ref="${AIDC_K8S_REGISTRY_PUSH}/${tag}"
    repo="${tag%%:*}" version="${tag##*:}"
    if [ "$FORCE" = 0 ] && bexec wget -q -O /dev/null \
            --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
            "http://${AIDC_K8S_REGISTRY_PUSH}/v2/${repo}/manifests/${version}" 2>/dev/null; then
        info "present: ${tag}"
        skipped=$((skipped + 1))
        continue
    fi
    info "==> building ${tag}"
    dir="/build/${repo#aidc/}"
    bexec sh -c "rm -rf '${dir}' && mkdir -p '${dir}'"
    # Local caches and virtualenvs are never part of an image (each .dockerignore drops them
    # too); leaving them out of the stream saves sending them.
    tar -C "$context" --exclude=.venv --exclude=__pycache__ --exclude=node_modules \
        --exclude=.pytest_cache --exclude=.mypy_cache --exclude=.ruff_cache -czf - . \
        | bexec_in tar -C "$dir" -xzf -
    build_args=()
    case "$tag" in
        aidc/dev-base:*) build_args=(--build-arg "CLAUDE_CODE_REFRESH=$(date +%s)") ;;
    esac
    bexec docker build ${build_args[@]+"${build_args[@]}"} -t "$ref" \
        -f "${dir}/${dockerfile#"$context"/}" "$dir" >&2 \
        || die "build failed for ${tag} (images already pushed are kept)"
    bexec docker push -q "$ref" >&2 || die "push failed for ${ref}"
    built=$((built + 1))
done <<EOF
$rows
EOF

want=$(printf '%s\n' "$rows" | grep -c . || true)
if [ $((built + skipped)) -ne "$want" ]; then
    die "accounted for $((built + skipped)) of ${want} images: the build loop ended early"
fi
info "built ${built}, already present ${skipped}, in ${AIDC_K8S_REGISTRY_PUSH} at ${AIDC_VERSION_TAG}"
