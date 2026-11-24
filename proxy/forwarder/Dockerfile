# aidc forwarder: a minimal socat sidecar used by `aidc proxy` to publish
# adhoc host->container port forwards. One instance per active forward,
# lifecycle-managed by scripts/cmd-proxy.sh. The TCP egress relays (NET-15)
# run it too, and on Kubernetes it is also a session's names responder
# (dnsmasq, scripts/k8s/manifests.sh), the dev pod's only nameserver.
#
# Built lazily on first `aidc proxy add` so sessions that don't use port
# forwarding never pay the cost.
FROM alpine:3.24

# socat is the reason this image exists; dnsmasq answers a Kubernetes
# session's relay names. The apk versions are current enough; no need to pin
# a specific version of a tool with a stable CLI.
RUN apk add --no-cache socat dnsmasq

# Default args come from the caller's `docker run ... aidc/forwarder:<ver>
# TCP-LISTEN:... TCP:...` invocation. No baked-in defaults — every use is
# explicit.
ENTRYPOINT ["socat"]
