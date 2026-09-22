# aidc refresher sidecar
#
# Keeps /etc/squid/blocklist.txt fresh by pulling URLhaus, ThreatFox, and
# HaGeZi-TIF feeds. Squid needs no signal: its blocklist helper follows the file (NET-16).
#
# Network egress for this container is direct (NOT through Squid) — see
# task-04 implementation notes.

FROM alpine:3.24

# curl    — feed fetching
# bash    — refresh.sh / loop.sh use bash features (pipefail, etc.)
# coreutils — GNU sort/mv/date semantics (busybox is mostly fine but be explicit)
# gawk    — busybox awk is too limited for some CSV parses
# ca-certificates — needed for HTTPS feed fetches via curl
RUN apk add --no-cache \
        bash \
        ca-certificates \
        coreutils \
        curl \
        gawk

COPY refresh.sh /usr/local/bin/refresh.sh
COPY loop.sh    /usr/local/bin/loop.sh
RUN chmod +x /usr/local/bin/refresh.sh /usr/local/bin/loop.sh

CMD ["/usr/local/bin/loop.sh"]
