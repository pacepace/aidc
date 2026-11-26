# aidc Claude account broker (aidc/broker): one per Kubernetes user, in the user's namespace
# (docs/design-12-kubernetes.md, "Claude: logins, account switching, history"; K8S-16, K8S-17).
#
# It holds the user's Claude accounts (each one's login, refresh token included, on a claim only
# this pod mounts) and writes the active account's credentials, without the refresh token, into
# each session's folder of the access claim. Every login and renewal is Claude Code's own, run
# here: the image carries Claude Code and claude-broker.sh, nothing else of aidc's.
#
# Same Ubuntu base as the dev and git images, so the node caches one base.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# jq for the credentials and the state, curl for Claude Code's installer and its own updates,
# tini to reap what Claude Code leaves.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        tini \
        procps \
    && rm -rf /var/lib/apt/lists/*

# The broker user, uid 1000 (the session user's uid): a session's Claude reads its own folder
# as that uid. Separation is by mount, not uid: only this pod mounts the accounts claim, and a
# session mounts only its own folder of claude-config.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 broker \
    && useradd -m -u 1000 -g 1000 -s /bin/bash broker

COPY claude-broker.sh /usr/local/bin/claude-broker
RUN chown root:root /usr/local/bin/claude-broker && chmod 0755 /usr/local/bin/claude-broker

# Claude Code from Anthropic's native installer, as the dev and git images install it.
# CLAUDE_CODE_REFRESH only busts the layer cache (`aidc k8s build --force` passes a fresh one).
ARG CLAUDE_CODE_REFRESH=0
ENV PATH="/home/broker/.local/bin:${PATH}"
USER broker
WORKDIR /home/broker
RUN echo "claude-code refresh: ${CLAUDE_CODE_REFRESH}" \
    && curl -fsSL https://claude.ai/install.sh | bash \
    && /home/broker/.local/bin/claude --version \
    && rm -rf /home/broker/.claude.json /home/broker/.claude

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/claude-broker", "serve"]
