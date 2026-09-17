#!/usr/bin/env bash
# Unit test for how `aidc create` finds the aidc-mcp address its squid must deny
# (MCP-12): aidc_mcp_deny_target in scripts/lib/config.sh, and that the value
# reaches the squid service's environment through compose rendering.
#
# The case that motivated it: the live aidc-mcp runs `aidc create` inside its own
# container for session_create, where HOME is /root and the config is mounted at
# /aidc-config. Reading only ~/.config/aidc there silently fell back to 127.0.0.1,
# leaving the real MCP reachable from every session the orchestrator created.
#
# `docker` is a PATH stub, so no daemon is needed.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/mcp-deny-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin"

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# docker stub: prints $DOCKER_BINDING for `docker inspect aidc-mcp`, or fails
# like a missing container when it is unset.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
if [ "$1" = "inspect" ] && [ -n "${DOCKER_BINDING+set}" ]; then
    printf '%b' "$DOCKER_BINDING"
    exit 0
fi
echo "Error: no such object: aidc-mcp" >&2
exit 1
STUB
chmod +x "$SCRATCH/bin/docker"

target() {   # env assignments..., runs aidc_mcp_deny_target in a clean shell
    # Under the same shell options cmd-create.sh runs with, so a failing docker
    # lookup cannot abort the resolution.
    env -i PATH="$SCRATCH/bin:/usr/bin:/bin" "$@" bash -c '
        set -euo pipefail
        shopt -s inherit_errexit
        die() { echo "die: $*" >&2; exit 1; }
        . "'"$AIDC_ROOT"'/scripts/lib/config.sh"
        aidc_mcp_deny_target'
}

write_cfg() {   # dir addr port
    mkdir -p "$1"
    printf 'mcp:\n  bind_address: %s   # comment\n  port: %s\n' "$2" "$3" > "$1/config.yaml"
}

echo "== the running aidc-mcp container's binding wins"
write_cfg "$SCRATCH/home1/.config/aidc" 10.9.9.9 1111
assert_eq "published binding" "10.23.68.16:7878" \
    "$(target HOME="$SCRATCH/home1" DOCKER_BINDING='10.23.68.16:7878\n')"
assert_eq "empty HostIp means every interface" "0.0.0.0:7878" \
    "$(target HOME="$SCRATCH/home1" DOCKER_BINDING=':7878\n')"

echo "== no running server: the host's config"
assert_eq "host ~/.config/aidc" "10.9.9.9:1111" "$(target HOME="$SCRATCH/home1")"

echo "== no running server, inside the aidc-mcp container: the /aidc-config mount"
write_cfg "$SCRATCH/aidc-config" 10.23.68.16 7878
assert_eq "config mount used when HOME has none" "10.23.68.16:7878" \
    "$(target HOME="$SCRATCH/emptyhome" AIDC_MCP_CONFIG_MOUNT="$SCRATCH/aidc-config")"

echo "== nothing configured: aidc mcp's defaults"
assert_eq "defaults" "127.0.0.1:7878" \
    "$(target HOME="$SCRATCH/emptyhome" AIDC_MCP_CONFIG_MOUNT="$SCRATCH/none")"

echo "== the value reaches the squid service through compose rendering"
render() {
    AIDC_VERSION_TAG=test-tag SESSION=probe PROFILE=python \
    REPO_PATH=/home/someone/work/myrepo WORKSPACE_PATH=/home/someone/work/myrepo \
    AUDIT_DIR=/home/someone/aidc-audit/probe \
    HOST_CLAUDE_PROJECT_DIR=/home/someone/.claude/projects/x ENCODED_REPO=x \
    env "$@" bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template"
}
render MCP_DENY=10.23.68.16:7878 > "$SCRATCH/rendered.yaml" 2>/dev/null
squid_env=$(awk '/^  squid:/ { s=1; next } s && /^  [a-z]/ { s=0 } s' "$SCRATCH/rendered.yaml")
assert_eq "AIDC_MCP_DENY set on the squid service" "1" \
    "$(printf '%s\n' "$squid_env" | grep -c 'AIDC_MCP_DENY: "10.23.68.16:7878"')"
assert_eq "no literal placeholder left" "0" "$(grep -c 'MCP_DENY}' "$SCRATCH/rendered.yaml")"
assert_eq "cmd-create derives MCP_DENY from aidc_mcp_deny_target" "1" \
    "$(grep -c '^MCP_DENY=\$(aidc_mcp_deny_target)$' "$AIDC_ROOT/scripts/cmd-create.sh")"

echo "== aidc create refuses a malformed address or port with a message naming the key"
validate() {   # MCP_DENY value -> runs cmd-create.sh's validation block
    env -i PATH="/usr/bin:/bin" MCP_DENY="$1" bash -c '
        set -euo pipefail
        die() { echo "die: $*"; exit 1; }
        eval "$(awk "/^MCP_DENY=\\\$\\(aidc_mcp_deny_target\\)\$/{f=1; next} f && /^export MCP_DENY\$/{exit} f" "'"$AIDC_ROOT"'/scripts/cmd-create.sh")"
        echo ok'
}
assert_eq "valid address:port passes" "ok" "$(validate 10.23.68.16:7878)"
assert_eq "hostname rejected" "die: mcp.bind_address 'mcp.example.org' is not an IP address (needed to keep sessions away from aidc-mcp)" \
    "$(validate mcp.example.org:7878)"
assert_eq "non-numeric port rejected" "die: mcp.port '78x8' is not a port number (needed to keep sessions away from aidc-mcp)" \
    "$(validate 10.23.68.16:78x8)"

echo
echo "mcp deny target: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
