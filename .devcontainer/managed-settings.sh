#!/usr/bin/env bash
# The session's Claude Code managed settings (/etc/claude-code/managed-settings.json).
# Sourced by entrypoint.sh, and by tests/unit/test-hook-event.sh on the host, so the test
# runs the code that ships.
#
# Managed settings are a container-local scope that merges on top of the session's own
# settings (its copy of the host's) and is never mounted from the host. They hold:
#   - aidc's hooks (MCP-46), always: SessionStart, Stop, Notification and UserPromptSubmit
#     each run aidc-hook-event, which writes the event where aidc-mcp reads it;
#   - the host's installed plugins, enabled, when share_plugins is on;
#   - in a cluster session, what its Claude tells the user's Claude account broker (K8S-17):
#     the status line through aidc-claude-usage (the weekly usage; the user's own status line
#     is still shown), and a StopFailure rate_limit hook; and the conversation lease
#     (aidc-claude-lease), since its Claude history is shared with the user's other machines;
#   - in a cluster session launched with bypass (claude_mode yolo or bypassPermissions),
#     skipDangerousModePermissionPrompt: the mode is the user's consent to bypass, and a
#     session made unattended never stops at a first-launch screen (owner ruling 2026-11-27).

AIDC_HOOK_EVENT_COMMAND="${AIDC_HOOK_EVENT_COMMAND:-/usr/local/bin/aidc-hook-event}"
AIDC_CLAUDE_USAGE_COMMAND="${AIDC_CLAUDE_USAGE_COMMAND:-/usr/local/bin/aidc-claude-usage}"
AIDC_CLAUDE_LEASE_COMMAND="${AIDC_CLAUDE_LEASE_COMMAND:-/usr/local/bin/aidc-claude-lease}"

# aidc_managed_settings <plugin-registry> <share-plugins true|false> [cluster [bypass]]
# Prints the managed settings JSON. The registry is Claude Code's installed_plugins.json;
# a missing or empty one enables nothing. With `cluster` (a Kubernetes session), the status
# line and the rate-limit hook the account broker reads; with `bypass` too (its Claude runs
# with bypassed permissions), the bypass-permissions warning skipped. Returns non-zero, saying why on
# stderr, when the JSON cannot be built (jq missing or failing).
aidc_managed_settings() {
    local registry="$1" share="$2" cluster="${3:-}" bypass="${4:-}" plugins='{}'
    if [ "$share" = "true" ] && [ -s "$registry" ]; then
        plugins=$(jq -c '(.plugins // {}) | keys | map({(.): true}) | add // {}' "$registry" 2>/dev/null) \
            || plugins='{}'
    fi
    jq -n -c --arg cmd "$AIDC_HOOK_EVENT_COMMAND" --arg usage "$AIDC_CLAUDE_USAGE_COMMAND" \
        --arg lease "$AIDC_CLAUDE_LEASE_COMMAND" \
        --argjson plugins "$plugins" --argjson cluster "$([ "$cluster" = cluster ] && echo true || echo false)" \
        --argjson bypass "$([ "$cluster" = cluster ] && [ "$bypass" = bypass ] && echo true || echo false)" '
        {hooks: ((["SessionStart", "Stop", "Notification", "UserPromptSubmit"]
                  | map({(.): [{hooks: [{type: "command", command: $cmd}]}]}) | add)
                 + (if $cluster then {StopFailure: [{matcher: "rate_limit",
                        hooks: [{type: "command", command: ($usage + " rate-limited")}]}]} else {} end)
                 | if $cluster then
                       reduce ("SessionStart", "PostToolUse", "Stop", "SessionEnd") as $e (.;
                           .[$e] = ((.[$e] // []) + [{hooks: [{type: "command", command: ($lease + " hook")}]}]))
                       # A prompt goes through the lease first, which hands it on to the event
                       # writer: an accepted one as itself (UserPromptSubmit), a refused one as
                       # a PromptRefused event naming the holder, which opens no turn
                       # (claude-lease.sh). The lease runs at the same events on a machine
                       # (scripts/lib/claude-sync.sh); tests/unit/test-claude-sync.sh holds
                       # the two lists equal.
                       | .UserPromptSubmit = [{hooks: [{type: "command", command: ($lease + " hook --then " + $cmd)}]}]
                   else . end)}
        + (if $cluster then {statusLine: {type: "command", command: ($usage + " statusline")}} else {} end)
        + (if $bypass then {skipDangerousModePermissionPrompt: true} else {} end)
        + (if ($plugins | length) > 0 then {enabledPlugins: $plugins} else {} end)' \
        || { echo "aidc_managed_settings: jq could not build the managed settings" >&2; return 1; }
}

# aidc_managed_bypass <claude-mode>: prints `bypass` when aidc-claude launches Claude with
# bypassed permissions in that mode (yolo, its default, is --dangerously-skip-permissions).
aidc_managed_bypass() {
    case "${1:-yolo}" in yolo|bypassPermissions) printf 'bypass' ;; esac
}

# aidc_install_managed_settings <root> <plugin-registry> <share-plugins> [cluster [bypass]]
# Writes <root>/etc/claude-code/managed-settings.json (mode 0644) by temp then rename.
# Returns non-zero, saying why on stderr, when it cannot.
aidc_install_managed_settings() {
    local root="$1" registry="$2" share="$3" json dir tmp
    json=$(aidc_managed_settings "$registry" "$share" "${4:-}" "${5:-}") || return 1
    dir="${root}/etc/claude-code"
    mkdir -p "$dir" || { echo "aidc_install_managed_settings: cannot create $dir" >&2; return 1; }
    tmp="${dir}/.managed-settings.json.$$"
    { printf '%s\n' "$json" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "${dir}/managed-settings.json"; } \
        || { rm -f "$tmp"; echo "aidc_install_managed_settings: cannot write ${dir}/managed-settings.json" >&2; return 1; }
}
