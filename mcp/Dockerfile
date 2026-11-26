# aidc-mcp: the MCP control plane server.
#
# One image for both backends (TRS-23): the Docker server, one per host, and the per-user
# server in the cluster (K8S-07). It wraps the aidc CLI and exposes it as MCP tools +
# resources over streamable HTTP, bearer-token authenticated.
#
# Build it through aidc (aidc rebuild, aidc k8s build): its context is this folder with the
# CLI staged beside it as aidc/ (scripts/lib/common.sh, aidc_build_context), so a bare
# `docker build mcp/` has no CLI to copy.
FROM python:3.14-alpine

# Runtime deps: aidc CLI is bash; we shell out to docker as well, and to kubectl and yq in
# the cluster (MCP-13 as amended). gettext is for envsubst, which `aidc create` requires to
# render a session's compose file: session_create runs the CLI in here, and without it the
# tool failed at the door with "required commands missing: envsubst".
# tests/unit/test-mcp-image-deps.sh keeps this list in step with what the CLI requires.
RUN apk add --no-cache \
        bash \
        coreutils \
        curl \
        docker-cli \
        docker-cli-compose \
        gettext \
        jq \
        kubectl \
        yq-go \
        ca-certificates

# uv provides reproducible, lockfile-pinned installs. Pinned to the version the
# committed uv.lock was produced with so the build is deterministic.
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /uvx /usr/local/bin/

# Use the base image's Python (never download a managed one), copy-link into the
# venv (bind mounts across filesystems can't hardlink), and put the venv on PATH.
ENV UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/aidc-mcp/.venv \
    PATH="/opt/aidc-mcp/.venv/bin:$PATH"

WORKDIR /opt/aidc-mcp

# Install EXACTLY what the committed uv.lock pins (not floating pip installs), so
# the control-plane image is reproducible. --frozen fails the build if pyproject
# and uv.lock have drifted. --no-dev skips the test/lint tooling. The runtime does
# NOT bake the aidc CLI in; it's mounted at /aidc/ so host CLI updates take effect
# on the next mcp-server restart without rebuilding.
#
# The 3tears packages are git sources pinned to one commit (mcp/pyproject.toml), and uv
# fetches a git source with the git CLI over https. git is installed for the sync only and
# removed in the same layer, so the running server has no git.
COPY pyproject.toml uv.lock ./
COPY src/ ./src/
RUN apk add --no-cache --virtual .uv-git-sources git \
    && uv sync --frozen --no-dev --python python3.14 \
    && apk del .uv-git-sources \
    && python -c "import mcp; print('mcp SDK version:', getattr(mcp, '__version__', 'unknown'))" \
    && python -c "import threetears.mcp, threetears.tool_contract.mcp_face; print('3tears-mcp', threetears.mcp.__version__)"

# The aidc CLI, baked in for the cluster, where nothing mounts it (MCP-13 as amended). The
# Docker server mounts the host's CLI over it (cmd-mcp.sh), so a host CLI update still takes
# effect on its next restart without a rebuild.
COPY aidc/ /aidc/

# Default expectations (overridable via env at runtime):
#   AIDC_CLI            -> /aidc/scripts/aidc
#   AIDC_MCP_PORT       -> 7878
#   AIDC_MCP_TOKEN_FILE -> /aidc-config/mcp-token
#   AIDC_MCP_AUDIT_LOG  -> /var/log/aidc-mcp/access.log
ENV AIDC_CLI=/aidc/scripts/aidc \
    AIDC_MCP_PORT=7878 \
    AIDC_MCP_TOKEN_FILE=/aidc-config/mcp-token \
    AIDC_MCP_AUDIT_LOG=/var/log/aidc-mcp/access.log

EXPOSE 7878

CMD ["python", "-m", "aidc_mcp"]
