# aidc audit aggregator sidecar
#
# Minimal alpine image whose sole job is to mirror forensic artefacts from the
# running session (Squid access log, policy events, refresher log, dev shell
# history, optional Claude transcript) into a host-visible audit directory.
#
# All source mounts arrive read-only at runtime (enforced by compose). The
# container's only writable mount is /var/aidc/audit/.

FROM alpine:3.24

RUN apk add --no-cache bash coreutils jq

COPY aggregate.sh /usr/local/bin/aggregate.sh
COPY finalize.sh  /usr/local/bin/finalize.sh
RUN chmod +x /usr/local/bin/aggregate.sh /usr/local/bin/finalize.sh

# meta.json lives in /var/aidc/audit/, which is bind-mounted from the host by
# compose. The audit container does NOT create the per-session directory --
# that's `aidc create`'s job.

CMD ["/usr/local/bin/aggregate.sh"]
