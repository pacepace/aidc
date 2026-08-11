# aidc-mcp: the MCP control plane server.
#
# Single global container per host. Wraps the aidc CLI (mounted in at
# /aidc/) and exposes it as MCP tools + resources over streamable HTTP.
# Bearer-token authenticated.
FROM python:3.14-alpine

# Runtime deps: aidc CLI is bash; we shell out to docker as well.
RUN apk add --no-cache \
        bash \
        coreutils \
        curl \
        docker-cli \
        jq \
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
COPY pyproject.toml uv.lock ./
COPY src/ ./src/
RUN uv sync --frozen --no-dev --python python3.14 \
    && python -c "import mcp; print('mcp SDK version:', getattr(mcp, '__version__', 'unknown'))"

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
