#!/usr/bin/env bash
# aidc refresher — container main process.
#
# Runs refresh.sh once on startup, then every AIDC_REFRESH_INTERVAL seconds
# (default 6h). MUST NOT exit on refresh failure — log and keep looping so
# the previous blocklist keeps serving (NET-11).

set -euo pipefail

REFRESH_INTERVAL="${AIDC_REFRESH_INTERVAL:-21600}"   # seconds; 6h default

echo "aidc-refresher: starting (interval=${REFRESH_INTERVAL}s)"

# Startup refresh — never exit on first refresh failure.
if /usr/local/bin/refresh.sh; then
    echo "aidc-refresher: startup refresh OK"
else
    echo "aidc-refresher: startup refresh FAILED (continuing with last-good list)"
fi

# Main loop. set -e is on, but `if` branches don't trigger it on non-zero.
while true; do
    sleep "$REFRESH_INTERVAL"
    if /usr/local/bin/refresh.sh; then
        echo "aidc-refresher: periodic refresh OK at $(date -u +%FT%TZ)"
    else
        echo "aidc-refresher: periodic refresh FAILED at $(date -u +%FT%TZ) (keeping last-good list)"
    fi
done
