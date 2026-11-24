# aidc git container (aidc/gitctl): the one place a Kubernetes user's work leaves the cluster.
#
# One per user, in the user's namespace (docs/design-12-kubernetes.md, "Git"). It holds the
# user's SSH key and GitHub login, which the user adds themselves by attaching to its tmux; the
# admin never handles them. Sessions cannot push; this container does.
#
# Same Ubuntu base as the dev image, so git behaves the same on both sides of the shared repo
# (the repo lock in design-12 was measured with that git), and one base image is cached on the
# node instead of two.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# git and ssh for the pushes, tmux for the user's terminal, tini to reap what tmux leaves.
# curl only for the downloads below and Claude Code's own updates.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        openssh-client \
        tmux \
        tini \
        curl \
        ca-certificates \
        less \
        vim-tiny \
        procps \
    && rm -rf /var/lib/apt/lists/*

# GitHub's gh CLI, pinned and checksum-verified: it holds the user's GitHub token, so the build
# never takes whatever was published last. The version is older than the 14-day cooldown
# (REL-09) when pinned; bump deliberately, with both checksums from the release's
# gh_<version>_checksums.txt.
ARG GH_VERSION=2.103.3
ARG GH_SHA256_AMD64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG GH_SHA256_ARM64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
           amd64) SUM="$GH_SHA256_AMD64" ;; \
           arm64) SUM="$GH_SHA256_ARM64" ;; \
           *) echo "no pinned gh checksum for $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
        -o /tmp/gh.tar.gz \
    && echo "${SUM}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar -C /tmp -xzf /tmp/gh.tar.gz \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${ARCH}" \
    && gh --version

# The git user, uid 2000, its own primary group (2000) and a member of the session group
# (1000). Its own primary group, not 1000: the files it creates to lock a repo (.git/config,
# hooks/) must not be group-writable by sessions, and core.sharedRepository=group makes the
# files git writes writable by their group. The shared parts of a repo get group 1000 from
# their setgid folders instead. Ubuntu's default `ubuntu` user holds 1000 and goes first.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 session \
    && groupadd -g 2000 git \
    && useradd -m -u 2000 -g 2000 -G session -s /bin/bash git

COPY gitctl-main.sh /usr/local/bin/gitctl-main.sh
RUN chmod 0755 /usr/local/bin/gitctl-main.sh

# Claude Code, installed as the dev image installs it: Anthropic's native installer, as the
# user, so it lands under ~/.local and can update itself. The home is a volume in the cluster
# (it keeps the user's secrets); the Deployment seeds a new one from this image's /home/git.
# CLAUDE_CODE_REFRESH only busts the layer cache (`aidc k8s build --force` passes a fresh one).
ARG CLAUDE_CODE_REFRESH=0
ENV PATH="/home/git/.local/bin:${PATH}"
USER git
WORKDIR /home/git
RUN echo "claude-code refresh: ${CLAUDE_CODE_REFRESH}" \
    && curl -fsSL https://claude.ai/install.sh | bash \
    && /home/git/.local/bin/claude --version \
    # The version check writes first-run state; ship the home without it.
    && rm -rf /home/git/.claude.json /home/git/.claude/backups /home/git/.claude/sessions \
              /home/git/.claude/downloads

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/gitctl-main.sh"]
