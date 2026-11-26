#!/usr/bin/env bash
# The session's Claude Code managed settings (/etc/claude-code/managed-settings.json).
# Sourced by entrypoint.sh, and by tests/unit/test-hook-event.sh on the host, so the test
# runs the code that ships.
#
# Managed settings are a container-local scope that merges on top of the session's own
# settings (its copy of the host's) and is never mounted from the host. They hold:
#   - aidc's hooks (MCP-46), always: Stop, Notification and UserPromptSubmit each run
#     aidc-hook-event, which writes the event where aidc-mcp reads it;
#   - the host's installed plugins, enabled, when share_plugins is on.

AIDC_HOOK_EVENT_COMMAND="${AIDC_HOOK_EVENT_COMMAND:-/usr/local/bin/aidc-hook-event}"

# aidc_managed_settings <plugin-registry> <share-plugins true|false>
# Prints the managed settings JSON. The registry is Claude Code's installed_plugins.json;
# a missing or empty one enables nothing. Returns non-zero, saying why on stderr, when the
# JSON cannot be built (jq missing or failing).
aidc_managed_settings() {
    local registry="$1" share="$2" plugins='{}'
    if [ "$share" = "true" ] && [ -s "$registry" ]; then
        plugins=$(jq -c '(.plugins // {}) | keys | map({(.): true}) | add // {}' "$registry" 2>/dev/null) \
            || plugins='{}'
    fi
    jq -n -c --arg cmd "$AIDC_HOOK_EVENT_COMMAND" --argjson plugins "$plugins" '
        {hooks: (["Stop", "Notification", "UserPromptSubmit"]
                 | map({(.): [{hooks: [{type: "command", command: $cmd}]}]}) | add)}
        + (if ($plugins | length) > 0 then {enabledPlugins: $plugins} else {} end)' \
        || { echo "aidc_managed_settings: jq could not build the managed settings" >&2; return 1; }
}

# aidc_install_managed_settings <root> <plugin-registry> <share-plugins>
# Writes <root>/etc/claude-code/managed-settings.json (mode 0644) by temp then rename.
# Returns non-zero, saying why on stderr, when it cannot.
aidc_install_managed_settings() {
    local root="$1" registry="$2" share="$3" json dir tmp
    json=$(aidc_managed_settings "$registry" "$share") || return 1
    dir="${root}/etc/claude-code"
    mkdir -p "$dir" || { echo "aidc_install_managed_settings: cannot create $dir" >&2; return 1; }
    tmp="${dir}/.managed-settings.json.$$"
    { printf '%s\n' "$json" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "${dir}/managed-settings.json"; } \
        || { rm -f "$tmp"; echo "aidc_install_managed_settings: cannot write ${dir}/managed-settings.json" >&2; return 1; }
}
