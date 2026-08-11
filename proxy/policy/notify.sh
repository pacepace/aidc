#!/usr/bin/env bash
# notify.sh: receives a JSON taint event on stdin and fans out notifications.
# Called by policy.sh exactly once per session (idempotency enforced by caller).
set -euo pipefail

JSON=$(cat)
EVENT_TIME=$(printf '%s' "$JSON" | sed -n 's/.*"tainted_at":"\([^"]*\)".*/\1/p')
DOMAIN=$(printf '%s' "$JSON" | sed -n 's/.*"domain":"\([^"]*\)".*/\1/p')
TRIGGER=$(printf '%s' "$JSON" | sed -n 's/.*"trigger":"\([^"]*\)".*/\1/p')

# Always: log to events file (append-only, host-visible).
mkdir -p /var/log/aidc
printf '%s\n' "$JSON" >> /var/log/aidc/policy-events.log

# Always: write to host-visible FIFO or fallback file under audit_dir.
FIFO=/var/aidc/audit/taint-events
if [ -p "$FIFO" ]; then
    # Non-blocking write: if no reader, drop rather than wedge the sidecar.
    printf '%s\n' "$JSON" > "$FIFO" || true
else
    mkdir -p "$(dirname "$FIFO")"
    printf '%s\n' "$JSON" >> "${FIFO}.log"
fi

# Conditional: webhook POST.
if [ -n "${AIDC_NOTIFY_WEBHOOK:-}" ]; then
    curl -fsS -X POST \
        -H 'Content-Type: application/json' \
        --max-time 10 \
        -d "$JSON" \
        "$AIDC_NOTIFY_WEBHOOK" >/dev/null || true
fi

# stderr breadcrumb (visible via docker logs)
printf '[notify] taint dispatched: time=%s domain=%s trigger=%s\n' \
    "$EVENT_TIME" "$DOMAIN" "$TRIGGER" >&2
