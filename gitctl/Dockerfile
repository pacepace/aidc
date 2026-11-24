# aidc git container (aidc/gitctl): the one place a Kubernetes user's work leaves the cluster.
#
# One per user, in the user's namespace (docs/design-12-kubernetes.md, "Git"). It holds the
# user's GitHub login, which the user adds themselves by attaching to its tmux (gitctl login);
# the admin never handles it. Sessions cannot push; this container does.
#
# Same Ubuntu base as the dev image, so git behaves the same on both sides of the shared working
# copies, and one base image is cached on the node instead of two.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# git and ssh for the pushes, tmux for the user's terminal, tini to reap what tmux leaves.
# curl only for the downloads below and Claude Code's own updates. sudo is how gitctl switches
# to the users that hold the login; jq reads Claude Code's hook input and gh's JSON.
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
        sudo \
        jq \
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
# (1000). Its own primary group, not 1000, so what it keeps in its own home is not the
# sessions'; the working copies it shares with sessions get group 1000 from their setgid
# folders. Ubuntu's default `ubuntu` user holds 1000 and goes first.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 session \
    && groupadd -g 2000 git \
    && useradd -m -u 2000 -g 2000 -G session -s /bin/bash git

# The hard rules in code (docs/design-12-kubernetes.md, "Git", K8S-24), and the GitHub login
# out of the agent's reach. Three users:
#   git     (2000) the agent and the user's terminal; runs ordinary git as itself and holds no
#                  credential, so nothing it runs can reach GitHub;
#   gitrun  (2002) runs git for gitctl's fetch and push, only in its own private bare copies
#                  (/var/lib/gitctl/gitrun, the git-run claim, its alone), never in a working
#                  copy; commits reach it and leave it as bundles; holds no secret; its home is
#                  root's;
#   gitcred (2001) runs gh and git's credential helper; the only user that can read the
#                  GitHub login, in its home on the git-cred claim (/var/lib/gitctl/gitcred).
# git reaches the other two only through gitctl (gitctl/sudoers), a set of fixed verbs that
# build their own command lines. /opt/aidc/bin, first on PATH, holds gitctl and a gh that
# points there.
RUN groupadd -g 2001 gitcred \
    && useradd -M -u 2001 -g 2001 -d /var/lib/gitctl/gitcred -s /usr/sbin/nologin gitcred \
    && groupadd -g 2002 gitrun \
    && useradd -M -u 2002 -g 2002 -d /home/gitrun -s /usr/sbin/nologin gitrun \
    && install -d -o root -g root -m 0755 /home/gitrun /var/lib/gitctl \
    && install -d -o gitcred -g gitcred -m 0711 /var/lib/gitctl/gitcred \
    && install -d -o gitrun -g gitrun -m 0700 /var/lib/gitctl/gitrun
COPY gitctl-rules.sh gitctl.sh git-requests.sh gh-shim.sh cred-helper.sh claude-hook.sh /opt/aidc/lib/gitctl/
COPY gitconfig /etc/gitconfig
COPY sudoers /etc/sudoers.d/aidc-gitctl
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chown -R root:root /opt/aidc /etc/claude-code /etc/gitconfig /etc/sudoers.d/aidc-gitctl \
    && chmod 0755 /opt/aidc /opt/aidc/lib /opt/aidc/lib/gitctl /etc/claude-code \
    && chmod 0644 /opt/aidc/lib/gitctl/gitctl-rules.sh /etc/gitconfig /etc/claude-code/managed-settings.json \
    && chmod 0755 /opt/aidc/lib/gitctl/gitctl.sh /opt/aidc/lib/gitctl/git-requests.sh /opt/aidc/lib/gitctl/gh-shim.sh \
                  /opt/aidc/lib/gitctl/cred-helper.sh /opt/aidc/lib/gitctl/claude-hook.sh \
    && chmod 0440 /etc/sudoers.d/aidc-gitctl \
    && visudo -c -f /etc/sudoers.d/aidc-gitctl \
    && install -d -m 0755 /opt/aidc/bin \
    && ln -s /opt/aidc/lib/gitctl/gitctl.sh /opt/aidc/bin/gitctl \
    && ln -s /opt/aidc/lib/gitctl/gh-shim.sh /opt/aidc/bin/gh \
    && ln -s /opt/aidc/lib/gitctl/git-requests.sh /opt/aidc/bin/git-requests \
    && printf '%s\n' 'case ":$PATH:" in *:/opt/aidc/bin:*) ;; *) PATH="/opt/aidc/bin:$PATH" ;; esac' \
        > /etc/profile.d/aidc-gitctl.sh \
    # ~/.profile puts ~/.local/bin first; /opt/aidc/bin goes before it.
    && printf '\n%s\n' 'PATH="/opt/aidc/bin:$PATH"' >> /home/git/.profile

COPY gitctl-main.sh /usr/local/bin/gitctl-main.sh
RUN chmod 0755 /usr/local/bin/gitctl-main.sh

# Claude Code, installed as the dev image installs it: Anthropic's native installer, as the
# user, so it lands under ~/.local and can update itself. The home is a volume in the cluster
# (it keeps the user's secrets); the Deployment seeds a new one from this image's /home/git.
# CLAUDE_CODE_REFRESH only busts the layer cache (`aidc k8s build --force` passes a fresh one).
ARG CLAUDE_CODE_REFRESH=0
ENV PATH="/opt/aidc/bin:/home/git/.local/bin:${PATH}"
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
