# aidc Squid forward proxy
#
# Canonical's ubuntu/squid (no _stable channel; _edge is the current release
# channel). Version-tag pinned, not digest-pinned, for v1 simplicity.
#
# 7.x is a rockcraft-built "Rock", which differs from the classic 6.6-24.04
# image in three ways that shape everything below:
#   1. Chiselled rootfs -- no bash, sed, chmod, chown, mkdir, or id. Build-time
#      file modes/ownership therefore come from COPY flags, not RUN steps, and
#      the healthcheck/entrypoint scripts are perl+dash (see those files).
#   2. Runs as UID 584792, not root, and there is no `proxy` user. Files squid
#      must read (and squid.conf, which the entrypoint rewrites for the DNS
#      override) are COPY'd with that numeric owner.
#   3. Its ENTRYPOINT is `pebble enter`. We replace it -- compose already
#      supervises this container via restart policy + healthcheck, so pebble's
#      service management is redundant -- and chain to the Rock's own
#      entrypoint.sh, which is what pebble would have invoked.
FROM ubuntu/squid:7.2-26.04_edge

# Configuration and ACL data files.
# blocklist.txt ships empty so Squid can start before the refresher writes
# anything (NET-11 fallback). The compose stack mounts a named volume over
# the directory at runtime; the in-image copy is the fallback.
#
# Owned by the runtime UID because /etc/squid is root-owned 0755 in the base and
# the entrypoint rewrites squid.conf in place when AIDC_DNS_SERVERS is set. The
# named volume compose mounts here inherits this ownership on first init.
COPY --chown=584792:584792 --chmod=0644 squid.conf           /etc/squid/squid.conf
COPY --chown=584792:584792 --chmod=0644 state-actor-tlds.txt /etc/squid/state-actor-tlds.txt
COPY --chown=584792:584792 --chmod=0644 blocklist.txt        /etc/squid/blocklist.txt

# Healthcheck script — used by docker-compose healthcheck.
COPY --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck.sh

# Entrypoint wrapper: applies per-session DNS override (AIDC_DNS_SERVERS env)
# to squid.conf before chaining to the base image's entrypoint.
COPY --chmod=0755 aidc-entrypoint.sh /usr/local/bin/aidc-entrypoint.sh

# NOTE: no `RUN mkdir -p /var/log/squid && chown ...` here anymore. The Rock
# already ships /var/log/squid and /var/spool/squid owned by 584792 (the runtime
# UID), and the chiselled base has neither mkdir nor chown to run it with.

# Container-side port. NOT bound to the host in compose — the proxy is
# only reachable from inside the per-session Docker network.
EXPOSE 3128

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Wrapper entrypoint (DNS override) chains to the base image's entrypoint.sh.
#
# CMD deliberately no longer carries `-f /etc/squid/squid.conf`. The entrypoint
# supplies `-f` itself, because a DNS-override session has to start squid from a
# derived config in a writable path (see aidc-entrypoint.sh) -- keeping the flag
# here would mean two `-f` args disagreeing about which config is live.
ENTRYPOINT ["/usr/local/bin/aidc-entrypoint.sh"]
CMD ["-NYC"]
