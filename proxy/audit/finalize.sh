#!/usr/bin/env bash
# Final audit sweep -- invoked by `aidc kill` before tearing down the stack.
#
# Performs one last sweep (reusing aggregate.sh --once) and stamps killed_at
# into meta.json so post-incident readers see the session is closed.
#
# Idempotent: safe to invoke multiple times. The last invocation wins for
# killed_at.

set -euo pipefail

META=/var/aidc/audit/meta.json

# One-shot sweep -- same logic as a single loop iteration of aggregate.sh.
/usr/local/bin/aggregate.sh --once

# Close meta.json with killed_at. The mktemp MUST live in $META's OWN directory
# so the mv is a same-filesystem atomic rename(). $META is a bind-mounted volume
# and the default $TMPDIR is the container's overlay fs, so a plain `mktemp` + `mv`
# is a cross-fs copy+unlink -- non-atomic. A reader (or a teardown) that catches
# it mid-copy sees a truncated, invalid-JSON meta.json (the CI-only smoke failure).
if [ -f "$META" ]; then
    TMP=$(mktemp "${META}.XXXXXX")
    if jq --arg ts "$(date -u +%FT%TZ)" '.killed_at = $ts' "$META" > "$TMP"; then
        # mktemp creates 0600; this runs as root in the sidecar, so without this
        # the finalized meta.json is root-owned 0600 and a non-root host reader
        # (e.g. a CI runner uid != 0) cannot read it — jq then fails on an
        # unreadable file. The audit record is non-secret and meant to be read
        # back on the host, so make it world-readable like the initial write.
        chmod 0644 "$TMP"
        mv "$TMP" "$META"
    else
        rm -f "$TMP"
        echo "[finalize] meta.json jq update failed" >&2
        exit 1
    fi
fi
