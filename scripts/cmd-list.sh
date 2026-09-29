#!/usr/bin/env bash
# desc: List active aidc sessions.
#
# Usage: aidc list
#
# Columns: SESSION, STATUS, PROFILE, STARTED, TAINTED

set -euo pipefail

# Tolerate piped consumers (grep -q, head, less) that close stdin early.
# Without this, set -e + pipefail would surface a SIGPIPE-induced 141 as
# a spurious failure.
trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

require_docker

# We discover sessions by their dev container. Two possibilities:
#   - The labels were applied at create time (aidc.role=dev, aidc.session=X);
#     prefer this when present.
#   - Fall back to name pattern aidc-*-dev for older sessions.

#
# Ask `docker ps` for exactly the columns used. `{{json .}}` includes Size, and
# filling that in makes the daemon sum every container's writable layer on disk:
# about a minute per 70 GB dev container, which pushed `aidc list` past the MCP
# server's 60s timeout.
PS_FORMAT='{{.Names}}\t{{.Status}}'
PRIMARY=$(docker ps -a --filter 'label=aidc.role=dev' --format "$PS_FORMAT" 2>/dev/null || printf '')
if [ -z "$PRIMARY" ]; then
    PRIMARY=$(docker ps -a --filter 'name=^aidc-.*-dev$' --format "$PS_FORMAT" 2>/dev/null || printf '')
fi

if [ -z "$PRIMARY" ]; then
    printf 'No active aidc sessions.\n'
    exit 0
fi

# From here we're producing tabular output that callers commonly pipe
# through grep / head / awk. Relax -e and pipefail so a consumer closing
# stdin mid-stream doesn't bubble up as a spurious failure.
set +e
set +o pipefail

printf '%-20s %-15s %-10s %-25s %s\n' "SESSION" "STATUS" "PROFILE" "STARTED" "TAINTED"

# Each line is "<name><TAB><status>". Read line-by-line (bash 3.2 has no mapfile).
while IFS="$(printf '\t')" read -r ct_name status; do
    [ -z "$ct_name" ] && continue
    # Strip aidc- prefix and -dev suffix to recover the session name.
    session=${ct_name#aidc-}
    session=${session%-dev}

    # Read labels and started-at from `docker inspect` rather than relying on
    # the ps format; some platforms don't surface labels in `ps`.
    profile=$(docker inspect "$ct_name" --format '{{ index .Config.Labels "aidc.profile"}}' 2>/dev/null || printf '')
    [ -z "$profile" ] && profile=$(docker inspect "$ct_name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^AIDC_PROFILE=//p' | head -1)
    [ -z "$profile" ] && profile="?"

    started=$(docker inspect "$ct_name" --format '{{.State.StartedAt}}' 2>/dev/null || printf '?')

    # Taint marker lives at /var/state/tainted inside the policy sidecar's
    # state volume. Probe via the policy container.
    policy_ct="aidc-${session}-policy"
    tainted="no"
    if docker exec "$policy_ct" test -f /var/state/tainted >/dev/null 2>&1; then
        tainted="YES"
    fi

    printf '%-20s %-15s %-10s %-25s %s\n' "$session" "$status" "$profile" "$started" "$tainted"
done <<EOF
$PRIMARY
EOF
