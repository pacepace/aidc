#!/usr/bin/env bash
# desc: Rebuild all aidc/* images at the current VERSION. Does not touch any session.
#
# Usage: aidc rebuild
#
# Iterates the canonical image inventory and runs `docker build` for each.
# Running containers reference images by content digest, not tag, so this is
# non-disruptive to anything currently running. To swap a session onto a
# freshly-rebuilt image, use `aidc upgrade <session>` afterward.

set -euo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help)
            cat <<'EOF'
aidc rebuild

Rebuilds every aidc/* image at the current VERSION (squid, refresher,
policy, audit, forwarder, mcp, dev-base). Does not touch any running
session. To swap a session onto a freshly-rebuilt image afterward,
use `aidc upgrade <session>`.

No flags in v1; rebuild always builds all images.
EOF
            exit 0 ;;
        *) die "aidc rebuild takes no arguments (got: $1)" ;;
    esac
fi

require_docker   # also verifies `docker` is on PATH

info "rebuilding all aidc/* images at ${AIDC_VERSION_TAG}"

count=0
while IFS='|' read -r tag context dockerfile; do
    [ -z "$tag" ] && continue
    info "==> building ${tag}"
    # dev-base bakes Claude Code from Anthropic's installer; bust that one
    # layer so every rebuild fetches the current release (see Dockerfile).
    build_args=()
    case "$tag" in
        aidc/dev-base:*) build_args=(--build-arg "CLAUDE_CODE_REFRESH=$(date +%s)") ;;
    esac
    # ${arr[@]+"${arr[@]}"}: bash 3.2 (stock macOS) treats an empty array as
    # unbound under `set -u`; this idiom expands to nothing instead of dying.
    if ! docker build ${build_args[@]+"${build_args[@]}"} -t "$tag" -f "$dockerfile" "$context"; then
        die "build failed for ${tag}; aborting rebuild (other images unchanged)"
    fi
    count=$((count + 1))
done <<EOF
$(aidc_image_inventory)
EOF

info "rebuilt ${count} images at ${AIDC_VERSION_TAG}"
