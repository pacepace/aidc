#!/bin/sh
# aidc squid entrypoint wrapper.
#
# If AIDC_DNS_SERVERS is set (space-separated IP list from `aidc create
# --dns ...` or the dns_servers config list), rewrite the dns_nameservers
# line in squid.conf before starting squid. This lets per-session DNS
# override (e.g. ZeroTier-managed DNS for sessions that need to resolve
# overlay-network names) apply to the PROXIED traffic path -- squid does
# its own resolution; the dev container's `dns:` setting only covers
# direct lookups.
#
# /etc/squid is a per-session named volume (initialized from this image's
# files on first use), so the rewrite is scoped to this session and does
# not affect the image or other sessions.
#
# Default (AIDC_DNS_SERVERS empty/unset): squid.conf keeps its baked-in
# Quad9 pair. NET-03's threat-intel DNS layer stays intact unless a
# session explicitly overrides.

set -eu

# Config squid is actually started from. Overridden below when a DNS override
# is active; the Dockerfile's CMD no longer carries `-f` so that this single
# variable is the only thing that decides it.
CONF=/etc/squid/squid.conf

if [ -n "${AIDC_DNS_SERVERS:-}" ]; then
    # IMPORTANT: we do NOT write the override list into dns_nameservers.
    # Squid's internal resolver only fails over to the next server on
    # TIMEOUT -- a server answering REFUSED (e.g. a split-horizon dnsmasq
    # that serves its own domains to everyone but refuses public-name
    # recursion from this source) is treated as a definitive answer and
    # kills the lookup. With such a server first in dns_nameservers, every
    # public name dies on the fast REFUSED.
    #
    # Docker's embedded DNS (127.0.0.11) DOES fail over on REFUSED. So for
    # override sessions, we REMOVE the dns_nameservers directive entirely;
    # squid then falls back to resolv.conf, which inside the container
    # points at 127.0.0.11. The compose template gives the squid service
    # the same dns: list as the dev container, so the embedded DNS forwards
    # to the override servers with correct failover semantics.
    echo "[aidc-squid] DNS override active (${AIDC_DNS_SERVERS}); removing dns_nameservers so squid resolves via Docker embedded DNS (failover-correct)" >&2

    # Derive to a writable path instead of editing in place. Under the 7.x Rock
    # squid runs as UID 584792 while /etc/squid (and the named volume that
    # inherits its ownership) is root-owned, so an in-place edit there fails
    # with "Cannot make temp name: Permission denied" -- and squid then starts
    # happily from the UNMODIFIED config, reporting healthy while resolving via
    # the wrong nameservers. That silent-success mode is the thing to avoid, so
    # everything below is written to fail loudly instead.
    #
    # ACL file references inside squid.conf are absolute (/etc/squid/*.txt), so
    # they still resolve from the derived copy, and the refresher's SIGHUP
    # reload re-reads this same path.
    DERIVED=/tmp/aidc-squid.conf
    perl -ne 'print unless /^dns_nameservers /' "$CONF" > "$DERIVED" || {
        echo "[aidc-squid] FATAL: could not derive DNS-override config from ${CONF}" >&2
        exit 1
    }
    # Verify the edit actually took. Without this the failure above is invisible
    # and the session silently runs on the baked-in Quad9 pair.
    if grep -q '^dns_nameservers ' "$DERIVED"; then
        echo "[aidc-squid] FATAL: dns_nameservers still present in ${DERIVED} after rewrite" >&2
        exit 1
    fi
    # Non-empty sanity check: a truncated config would let squid fall back to
    # defaults, i.e. an open proxy with no blocklist.
    if [ ! -s "$DERIVED" ]; then
        echo "[aidc-squid] FATAL: derived config ${DERIVED} is empty" >&2
        exit 1
    fi
    CONF="$DERIVED"
fi

# Chain to the base image's entrypoint, passing the effective config path.
#
# NB: the 7.x Rock's own ENTRYPOINT is `pebble enter`, which we deliberately
# replace -- aidc supervises the container with compose (restart policy +
# healthcheck), so pebble's service management is redundant. entrypoint.sh is
# still shipped in the Rock and is what pebble itself would invoke: it tails the
# squid logs to stdout, pre-creates cache dirs, then execs squid. Calling it by
# absolute path since our PATH assumptions shouldn't depend on the base's.
#
# `-f` is supplied here rather than in CMD so the DNS-override branch can steer
# it; CMD carries only the run-mode flags.
exec /usr/local/bin/entrypoint.sh -f "$CONF" "$@"
