# aidc dev container base image.
#
# Pinning policy (CTR-01): the base image is tag-pinned to an LTS major
# (ubuntu:26.04, codename "resolute"). Tag-pinning satisfies CTR-01;
# digest-pinning is a P2 future hardening we have NOT adopted for v1 -- it keeps
# maintenance simple. Add Renovate later if we want a holdback window before tag
# bumps land.
#
# 26.04 over the previous 24.04 pin: it carries materially newer versions of the
# apt-sourced tooling we depend on (pip 25.1 vs 24.0, pipx 1.8 vs 1.4,
# docker-buildx 0.30 vs 0.23), which is the whole point of this image. Note that
# 26.04 still ships a default `ubuntu` user at UID 1000, so the userdel dance
# further down remains necessary.
FROM ubuntu:26.04

# Avoid prompts from apt during image build.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Minimal base toolchain plus docker.io (provides the inner Docker daemon
# for DinD — DKR-01). docker.io is Ubuntu's packaged Docker; using it
# instead of Docker's upstream repo keeps the Dockerfile simple. iptables
# is required by dockerd for its NAT/bridge rules.
#
# Explicitly NOT installed (anti-patterns):
#   - gh (GitHub CLI) -- GIT-03 forbids it
#   - openssh-client / sshpass -- no SSH outbound from container
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tmux \
        git \
        curl \
        ca-certificates \
        gnupg \
        vim \
        less \
        jq \
        ripgrep \
        tree \
        procps \
        sudo \
        bash \
        locales \
        docker.io \
        docker-compose-v2 \
        docker-buildx \
        iptables \
        uidmap \
        fuse-overlayfs \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Node + npm (for JS-based tooling that profiles may need).
# Uses NodeSource's distribution so we get the current ACTIVE LTS (24.x, the
# "Krypton" line) on Ubuntu without waiting for Ubuntu's package to lag.
#
# Why 24 and not 20/22: Node 20 bundles npm 10.x and Node 22 bundles npm 10.9.x
# -- both below the npm 11.10+ floor this image guarantees. Node 24 ships npm
# 11.17+, and we then move to npm@latest (12.x) on top; npm 12 requires
# node ^22.22 || ^24.15 || >=26, which 24.x satisfies. The `npm_major` check
# below is a build-time tripwire: if a future NodeSource/npm combination ever
# lands us back under 11, the image fails to build instead of shipping quietly.
#
# Note: Claude Code is NOT installed here. We use Anthropic's native installer
# instead (further down, as the vscode user). The native installer puts claude
# under the user's home (~/.local/share/claude/), which is the same place a
# regular host install of Claude Code lives -- and crucially, claude can
# auto-update itself because it owns its own install dir. The previous
# `npm install -g @anthropic-ai/claude-code` approach put claude under
# /usr/lib/node_modules/ (root-owned), making in-session auto-update fail
# with EACCES -- "Auto-update failed - Try claude doctor or npm i -g ...".
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set update-notifier false \
    && npm install -g npm@latest \
    && node --version \
    && npm --version \
    && npm_major="$(npm --version | cut -d. -f1)" \
    && if [ "$npm_major" -lt 11 ]; then \
           echo "FATAL: npm $(npm --version) is below the npm 11.10+ floor" >&2; exit 1; \
       fi

# ---- Python ecosystem -------------------------------------------------------
# Includes everything aidc users need to run tests: pyenv (version mgmt),
# uv (Astral, modern), poetry, pipenv, pipx, plus:
#   - build deps for pyenv to compile any Python version
#   - native libs for common wheel builds (psycopg2, lxml, Pillow, python-ldap)
#   - postgresql-client (psql + pg_dump for tests that need to verify DB state)
# Explicitly NOT included: mysql/mariadb anything. Use postgres.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3-pip python3-venv python3-dev pipx \
        build-essential pkg-config cmake \
        libssl-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
        liblzma-dev zlib1g-dev libncurses-dev tk-dev xz-utils \
        libpq-dev postgresql-client \
        libxml2-dev libxslt1-dev \
        libjpeg-dev libpng-dev libtiff-dev libwebp-dev \
        libldap2-dev libsasl2-dev \
    && rm -rf /var/lib/apt/lists/*

# pyenv: system-wide install at /usr/local/pyenv. PATH+init wiring via
# /etc/profile.d so it's picked up by every shell (bash, sh) for every user.
ENV PYENV_ROOT=/usr/local/pyenv
ENV PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
RUN git clone --depth=1 https://github.com/pyenv/pyenv.git "${PYENV_ROOT}" \
    && git clone --depth=1 https://github.com/pyenv/pyenv-virtualenv.git "${PYENV_ROOT}/plugins/pyenv-virtualenv" \
    && cat > /etc/profile.d/pyenv.sh <<'EOF'
export PYENV_ROOT=/usr/local/pyenv
export PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
if command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)" 2>/dev/null || true
fi
EOF

# Pre-install the most recent Python minors via pyenv so the common cases start
# instantly. Projects requesting any other version are handled by the entrypoint
# (it reads .python-version and `pyenv install --skip-existing` if needed).
#
# Cross-session persistence: /usr/local/pyenv/versions/ is mounted as a shared
# named volume by compose. On first ever session, Docker copies the image's
# baked versions into the empty volume; from then on the volume is the source
# of truth and ALL installed versions (including ones added on-demand at runtime)
# persist across aidc kill + create.
#
# How many to bake is the single biggest cost in this image: each one is a full
# CPython source build, and the image is already >5GB. It was 3; it is now 2.
# The third bought little -- because of the shared volume above, "instant start"
# only ever applies to the FIRST session on a machine, and a project asking for
# an unbaked version compiles it once and then keeps it forever. Meanwhile every
# CI rebuild on a cold cache paid for all three, which is what exhausted the
# runner's disk on the v0.6.0 smoke run.
#
# Tune with `--build-arg PYTHON_BAKE_COUNT=N` (3 restores the old behavior, 1 is
# the cheapest useful image) rather than editing the pipeline below.
ARG PYTHON_BAKE_COUNT=2
# Discover the N most recent Python minor versions pyenv knows about (skipping
# `t` free-threaded variants), then bake the latest patch of each. When pyenv
# learns about 3.15 / 3.16 / etc., a rebuild auto-picks them up — no Dockerfile
# edit required. The shared aidc-pyenv-versions volume lets the same logic
# install older versions on-demand when projects ask via .python-version.
RUN LATEST_MINORS=$(pyenv install --list \
            | grep -E '^ +3\.[0-9]+\.[0-9]+$' \
            | sed 's/^ *//' \
            | awk -F. '{print $1"."$2}' \
            | sort -uV \
            | tail -"${PYTHON_BAKE_COUNT}") \
    && for minor in $LATEST_MINORS; do \
        ver=$(pyenv install --list | awk -v m="$minor" '$0 ~ "^ +"m"\\.[0-9]+$" {v=$1} END {print v}'); \
        echo "==> baking Python $ver (latest $minor)" && pyenv install -s "$ver"; \
    done \
    && LATEST=$(pyenv versions --bare | grep -v 't$' | sort -V | tail -1) \
    && pyenv global "$LATEST" \
    && python --version \
    && echo "pyenv versions:" && pyenv versions --bare

# uv: download the Astral installer to a system location so vscode user
# inherits it without per-user setup.
RUN curl -fsSL https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    && uv --version

# poetry: official installer to a system location, then symlink onto PATH.
# (Ubuntu 24.04's pipx doesn't support --global; using POETRY_HOME instead.)
ENV POETRY_HOME=/opt/poetry
RUN curl -sSL https://install.python-poetry.org | python3 - --yes \
    && ln -s ${POETRY_HOME}/bin/poetry /usr/local/bin/poetry \
    && poetry config virtualenvs.in-project true \
    && poetry --version

# pipenv: another popular Python project tool. Installed via pipx into a
# system path so it's available to vscode user.
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install pipenv \
    && pipenv --version

# ---- Go ---------------------------------------------------------------------
# NOT `apt-get install golang-go`. On the old 24.04 base that package was Go
# 1.22 -- outside upstream's support window (Go patches only the two most recent
# majors), which is what prompted this switch. On 26.04 it is a much healthier
# 1.26, so the gap is small TODAY; the reason to keep the tarball is that a
# distro package is frozen for the life of the release, so it drifts back out of
# support as 1.27/1.28 ship while this pin auto-tracks. Resolving "latest stable"
# from go.dev at build time means a rebuild picks up new Go releases with no
# Dockerfile edit -- same spirit as the pyenv block above.
#
# Unlike the apt package (which lands in /usr/bin, always on PATH), the tarball
# installs to /usr/local/go, so PATH is wired two ways: ENV for non-login shells
# and docker exec, /etc/profile.d for login shells (tmux panes) that reset PATH.
ENV PATH="/usr/local/go/bin:${PATH}"
RUN GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
    && ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz \
    && printf 'export PATH="/usr/local/go/bin:${PATH}"\n' > /etc/profile.d/go.sh \
    && chmod 0644 /etc/profile.d/go.sh \
    && go version

# ---- Rust -------------------------------------------------------------------
# rustup-managed, stable channel, system-wide so vscode picks it up.
#
# The /etc/profile.d entry is NOT redundant with the ENV above. entrypoint.sh
# drops privileges with `exec sudo -E -u vscode`, and sudo replaces PATH with
# its own `secure_path` -- which strips /usr/local/cargo/bin. Anything that
# survives that has to be re-exported by /etc/profile.d when the login shell
# starts, which is how pyenv and go already do it. Without this file, `rustc`
# and `cargo` are simply missing from every tmux pane in a real aidc session
# (the image ENV only covers `docker exec`, which bypasses the entrypoint).
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH="${CARGO_HOME}/bin:${PATH}"
RUN curl -fsSL https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
    && chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}" \
    && printf 'export RUSTUP_HOME=/usr/local/rustup\nexport CARGO_HOME=/usr/local/cargo\nexport PATH="/usr/local/cargo/bin:${PATH}"\n' \
        > /etc/profile.d/cargo.sh \
    && chmod 0644 /etc/profile.d/cargo.sh \
    && rustc --version \
    && cargo --version

# Claude wrapper. Dispatches on env vars set by compose from aidc config:
#   AIDC_CLAUDE_MODE    permission mode. Default `yolo` (--dangerously-skip-permissions).
#                       `safe` is an alias for the native `default` mode; the rest map
#                       to `--permission-mode`: default, acceptEdits, auto,
#                       bypassPermissions, dontAsk, plan.
#   AIDC_CLAUDE_RESUME  true (default) -> --continue (resume previous convo)
#                       false          -> start fresh every time
# Per-session memory is bind-mounted from the host, so --continue picks up
# wherever the previous container left off. Only passed when conversation
# transcripts exist for the current directory — avoids a hard error on first run.
#
# Human-in-the-loop tools are denied because an aidc session is driven by an
# external orchestrator that pastes text into the tmux pane (no human at the
# terminal). AskUserQuestion renders a keyboard-navigated widget paste+Enter can't
# answer, and a turn that stops on it never reaches end_turn — the session
# deadlocks, unseen by the orchestrator; it is denied in EVERY mode. The plan-mode
# tools (EnterPlanMode / ExitPlanMode) are denied too — with no human to approve a
# plan the agent would otherwise strand read-only — EXCEPT when the session's mode
# IS `plan`, which is built on them (its approve prompt is answered by the orchestrator
# over the existing session_send loop, like any other turn). The deny removes the
# tools from the model's context (holds even under --dangerously-skip-permissions).
# The transcript watcher's interactive-block detection remains as a safety net.
RUN cat > /usr/local/bin/aidc-claude <<'EOF' \
 && chmod 0755 /usr/local/bin/aidc-claude
#!/usr/bin/env bash
# aidc-claude: wraps `claude` with the session's configured flags.
mode="${AIDC_CLAUDE_MODE:-yolo}"
args=()
# Human-in-the-loop deny (see image comment). AskUserQuestion is denied in every
# mode; the plan-mode tools are denied in every mode EXCEPT `plan`, which needs
# them. --disallowedTools is variadic and repeating it appends; a mode/permission
# flag is ALWAYS appended below right after the deny, so the variadic is terminated
# and — with "$@" exec'd before args — never swallows a user prompt. (A literal
# "--" in the wrapper args would end option parsing; no aidc caller passes one —
# bare interactive / headless `--print <prompt>`.)
args+=(--disallowedTools AskUserQuestion)
if [ "$mode" != "plan" ]; then
    args+=(--disallowedTools ExitPlanMode --disallowedTools EnterPlanMode)
fi
# Permission mode. `yolo` keeps the strong --dangerously-skip-permissions flag;
# `safe` aliases the native `default` mode; the rest pass straight to
# --permission-mode (claude validates the value against its own choices).
case "$mode" in
    yolo)          args+=(--dangerously-skip-permissions) ;;
    safe|default)  args+=(--permission-mode default) ;;
    acceptEdits|auto|bypassPermissions|dontAsk|plan)
                   args+=(--permission-mode "$mode") ;;
    *)
        printf 'aidc-claude: unknown AIDC_CLAUDE_MODE=%s (expected yolo|safe|default|acceptEdits|auto|bypassPermissions|dontAsk|plan)\n' \
            "$mode" >&2
        exit 2
        ;;
esac
if [ "${AIDC_CLAUDE_RESUME:-true}" = "true" ]; then
    _proj_enc="$(pwd | tr '/.' '-')"
    _proj_dir="${HOME}/.claude/projects/${_proj_enc}"
    _sessions=("${_proj_dir}"/*.jsonl)
    if [ -e "${_sessions[0]}" ]; then
        args+=(--continue)
    fi
fi
exec "${HOME}/.local/bin/claude" "$@" "${args[@]}"
EOF

# Create the unprivileged `vscode` user. Originally provided by the
# common-utils Dev Container Feature, but features only apply via the
# devcontainer CLI — under our `aidc create` (plain docker compose) path
# they don't run. Bake the user into the image so behavior is identical
# regardless of how the container is launched.
#
# Ubuntu 24.04 ships with a default `ubuntu` user at UID 1000. We delete
# it first to free UID 1000 for vscode (matches the Linux default first-
# user UID, which keeps host/container ownership semantics clean).
#
# Adds vscode to the docker group so it can talk to the inner DinD socket
# without sudo.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 vscode \
    && useradd -m -u 1000 -g 1000 -s /bin/bash vscode \
    && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode \
    && usermod -aG docker vscode \
    && mkdir -p /home/vscode/.claude \
    && chown -R vscode:vscode /home/vscode \
    && chown -R vscode:vscode /usr/local/pyenv /usr/local/rustup /usr/local/cargo /opt/poetry /opt/pipx 2>/dev/null || true

# User-owned npm global prefix. Without this, `npm install -g <anything>` as the
# `vscode` user targets root-owned /usr/lib/node_modules and dies with EACCES --
# the exact trap that broke Claude Code auto-update and got the npm-global
# install removed from post-create.sh. Anything a project installs globally now
# lands in vscode's own home instead.
#
# PATH is set via ENV (not just profile.d) because aidc drives the container
# with `docker exec`, which gets a non-login shell that never sources
# /etc/profile.d. That does put a vscode-writable dir on root's PATH too;
# irrelevant here, since vscode already holds NOPASSWD:ALL sudo above -- there
# is no privilege boundary between the two accounts to protect.
ENV PATH="/home/vscode/.npm-global/bin:${PATH}"
RUN mkdir -p /home/vscode/.npm-global \
    && chown -R vscode:vscode /home/vscode/.npm-global \
    && printf 'export PATH="${HOME}/.npm-global/bin:${PATH}"\n' > /etc/profile.d/npm-global.sh \
    && chmod 0644 /etc/profile.d/npm-global.sh \
    && su vscode -c 'npm config set prefix "${HOME}/.npm-global"'

# Claude Code via Anthropic's native installer.
# Runs AS the vscode user so the install lands at /home/vscode/.local/share/claude/
# with everything vscode-owned. The binary symlink lands at /home/vscode/.local/bin/claude
# which is on vscode's PATH by default (Ubuntu default). Auto-update works because the
# install dir is user-owned -- no EACCES against /usr/lib/node_modules/ like the prior
# npm-global approach.
#
# The bake provides the floor version; auto-update within the running session moves
# forward from there (mirroring what a host install does).
USER vscode
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/vscode/.local/bin/claude --version
USER root

# System-level git hooks directory (GIT-05). The pre-push hook lives here
# and is activated by `git config --system core.hooksPath /etc/git-hooks`
# at IMAGE BUILD TIME so the policy applies whether the container is started
# via `aidc create` (plain docker compose) OR via VS Code Dev Containers.
# (Originally this lived in post-create.sh — but post-create is a Dev
# Container lifecycle hook that doesn't run for the compose-driven path.)
RUN mkdir -p /etc/git-hooks
COPY pre-push-hook.sh /etc/git-hooks/pre-push
RUN chmod 0755 /etc/git-hooks/pre-push \
    && chown root:root /etc/git-hooks/pre-push \
    && git config --system core.hooksPath /etc/git-hooks \
    && git config --system --add safe.directory '*'

# The workspace repo is bind-mounted from the host, so inside the container it is
# owned by the host's uid, not `vscode`. Modern git then refuses every command
# with "detected dubious ownership" — breaking `git status` / commit / the
# pre-push policy hook. Trust all directories at the system level: the container
# is single-purpose and isolated, so git's cross-user-ownership guard adds no
# security here (it protects multi-user hosts), and without it the intended
# git-asymmetry (local works, push blocked) can't function at all.

# Helper scripts. Copied here, executed by postCreateCommand and by the
# tmux entrypoint. The `vscode` user is created by the common-utils
# Dev Container Feature, not here.
COPY post-create.sh        /usr/local/bin/aidc-post-create.sh
COPY tmux-start.sh         /usr/local/bin/aidc-tmux-start.sh
COPY entrypoint.sh         /usr/local/bin/aidc-entrypoint.sh
COPY user-main.sh          /usr/local/bin/aidc-user-main.sh
COPY transcript-mirror.sh  /usr/local/bin/aidc-transcript-mirror.sh
COPY dockerd-start.sh      /usr/local/bin/aidc-dockerd-start.sh
RUN chmod 0755 /usr/local/bin/aidc-post-create.sh \
                /usr/local/bin/aidc-tmux-start.sh \
                /usr/local/bin/aidc-entrypoint.sh \
                /usr/local/bin/aidc-user-main.sh \
                /usr/local/bin/aidc-transcript-mirror.sh \
                /usr/local/bin/aidc-dockerd-start.sh

# tini is PID 1 — it reaps zombies (which a plain shell as PID 1 wouldn't)
# and properly forwards SIGTERM/SIGINT through.
#
# entrypoint.sh starts dockerd + writes gitconfig + handles per-repo Python
# install (all as root), then drops privileges and `exec $@`. The CMD below
# is the default when nothing else is passed (`docker run` with no command,
# or VS Code without overrideCommand). aidc's compose template overrides
# CMD with its own tmux+tail invocation; VS Code with overrideCommand:true
# overrides with its keep-alive loop. Either way the entrypoint just runs it.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/aidc-entrypoint.sh"]
CMD ["/usr/local/bin/aidc-user-main.sh"]
