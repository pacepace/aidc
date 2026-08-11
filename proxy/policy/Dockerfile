FROM alpine:3.24

# bash:       policy/notify scripts (parameter expansion, arrays, traps)
# coreutils:  GNU tail -F semantics for rotation survival
# grep:       fast membership test against the on-disk blocklist file
# curl:       webhook fan-out
# docker-cli: docker pause on the sibling dev container (freeze mode)
RUN apk add --no-cache \
        bash \
        coreutils \
        grep \
        curl \
        docker-cli

COPY policy.sh /usr/local/bin/policy.sh
COPY notify.sh /usr/local/bin/notify.sh
RUN chmod +x /usr/local/bin/policy.sh /usr/local/bin/notify.sh

CMD ["/usr/local/bin/policy.sh"]
