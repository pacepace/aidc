#!/usr/bin/env bash
# aidc config-loading library.
#
# Loads global config at ~/.config/aidc/config.yaml plus an optional
# per-project config at <repo>/.aidc/config.yaml. Merges them into env vars:
#
#   AIDC_PROFILE
#   AIDC_TAINT_RESPONSE
#   AIDC_TLD_TAINTS
#   AIDC_AUDIT_DIR
#   AIDC_STATE_ACTOR_TLDS       (newline-separated)
#   AIDC_BLOCKLIST_ADDITIONS    (newline-separated)
#   AIDC_NOTIFY_WEBHOOK
#
# Merge rules:
#   - Scalars: per-project overrides global, which overrides built-in defaults.
#   - Lists  : concatenate-and-dedupe (built-in + global + project).
#
# Parsing strategy:
#   - Prefer yq (`yq eval`) when available.
#   - Otherwise fall back to a minimal awk/sed parser that handles the flat
#     schema we ship (scalars + simple lists). This is intentionally narrow:
#     no anchors, no nested mappings, no flow-style. The shard says "don't
#     hand-roll a YAML parser unless absolutely necessary"; this fallback
#     exists so the CLI degrades gracefully when yq isn't installed.

# ---- defaults ----------------------------------------------------------------

aidc_config_defaults() {
    AIDC_PROFILE="multi"
    # Default to freeze: when Squid logs a malware-list hit, pause the dev
    # container immediately. Heavier hand than notify, but the right default
    # for a sandbox -- we'd rather stop a compromised agent mid-step than
    # let it keep running while a human gets paged.
    AIDC_TAINT_RESPONSE="freeze"
    AIDC_TLD_TAINTS="false"
    AIDC_AUDIT_DIR="${HOME}/aidc-audit"
    AIDC_STATE_ACTOR_TLDS=".ru
.cn
.by
.ir
.kp"
    AIDC_BLOCKLIST_ADDITIONS=""
    AIDC_NOTIFY_WEBHOOK=""
    AIDC_CLAUDE_MODE="yolo"       # yolo|safe|default|acceptEdits|auto|bypassPermissions|dontAsk|plan
    AIDC_CLAUDE_RESUME="true"     # auto-pass --continue to claude on launch
    AIDC_SHARE_MEMORY="true"      # mount host's ~/.claude/projects/<repo>/ into container
    AIDC_SHARE_PLUGINS="true"     # bridge host's ~/.claude/plugins/ (read-only) and enable them in-container
    AIDC_PORTS=""                 # declared host:container forwards (CLI-13); newline-separated
    AIDC_CONTAINER_ONLY_PATHS=""  # paths overlaid by session-scoped volumes (CLI-18); newline-separated
    AIDC_DNS_SERVERS=""           # per-session DNS override; newline-separated IPs; empty = Quad9 default
    AIDC_NETWORKS=""              # foreign docker bridges to attach (NET-13); newline-separated
    AIDC_EGRESS="proxied"         # proxied|direct -- internal session bridge vs NATed (NET-14)
}

# ---- default config template -------------------------------------------------

default_config_yaml() {
    cat <<'EOF'
# aidc config (~/.config/aidc/config.yaml or <repo>/.aidc/config.yaml).
# Per-project overrides global; list fields concatenate-and-dedupe.

profile: multi              # python | node | go | rust | multi
taint_response: freeze      # log | notify | freeze
                            #   freeze (default): docker-pause the dev container on
                            #     a malware-blocklist hit -- safest stance; agent
                            #     stops mid-step, you investigate before resuming.
                            #   notify: write taint flag + webhook; agent keeps running.
                            #   log:    write taint flag only.
tld_taints: false           # also taint on state-actor TLD hits
audit_dir: ~/aidc-audit

claude_mode: yolo           # yolo (--dangerously-skip-permissions) | safe (=default) |
                            # default|acceptEdits|auto|bypassPermissions|dontAsk|plan (--permission-mode).
                            # Non-yolo modes surface approve prompts the orchestrator answers over session_send.
claude_resume: true         # auto-pass --continue so claude picks up prior conversation
share_memory: true          # mount host's ~/.claude/projects/<encoded>/ into session
share_plugins: true         # bridge host ~/.claude/plugins (read-only) + enable them in-container

state_actor_tlds:
  - .ru
  - .cn
  - .by
  - .ir
  - .kp

blocklist_additions: []

# Foreign docker bridge networks to attach the dev container to, so the session
# can reach another stack's services (its postgres, NATS, redis) by container
# name on any port. Same as `aidc create --network <net>`; survives restart,
# upgrade, and recreate.
#
# This WIDENS THE SANDBOX: everything on an attached network is reachable from
# the session on every port, the traffic does not pass through squid, and taint
# detection never sees it. The attachment is bidirectional. List the narrowest
# networks that do the job -- never Docker's default `bridge`.
networks: []

notify_webhook: ""

# Only relevant if you use `aidc mcp` (the control plane for AI orchestrators).
mcp:
  bind_address: 127.0.0.1   # change to your ZeroTier / Tailscale interface IP for remote access
  port: 7878

# Only relevant if you use claude_invoke_async (async Claude Code callbacks via metallm).
metallm:
  callback_url: ""           # base URL of your metallm instance, e.g. https://metallm.example.com
                             # set this so aidc can POST async results back to Saoirse
EOF
}

# ---- yq vs fallback ----------------------------------------------------------

_aidc_has_yq() { command -v yq >/dev/null 2>&1; }

# ---- scalar getter -----------------------------------------------------------
#
# Read a top-level scalar from a YAML file. Returns the empty string if the
# key is absent. Strips surrounding quotes and trailing comments.

_aidc_yaml_scalar() {
    local file="$1" key="$2"
    [ -f "$file" ] || { printf ''; return 0; }
    if _aidc_has_yq; then
        # yq prints 'null' for missing keys; normalize to empty.
        local v
        v=$(yq eval ".${key} // \"\"" "$file" 2>/dev/null || printf '')
        [ "$v" = "null" ] && v=""
        printf '%s' "$v"
        return 0
    fi
    # Fallback: line-based. Look for `key: value` at column 0.
    awk -v k="$key" '
        BEGIN { FS=":" }
        /^[[:space:]]*#/ { next }
        $0 ~ "^"k"[[:space:]]*:" {
            sub("^"k"[[:space:]]*:[[:space:]]*", "", $0)
            sub("[[:space:]]*#.*$", "", $0)            # strip inline comment
            sub("^[\"'\'']", "", $0); sub("[\"'\'']$", "", $0)  # strip quotes
            sub("[[:space:]]+$", "", $0)
            print $0
            exit
        }
    ' "$file"
}

# ---- list getter -------------------------------------------------------------
#
# Read a top-level YAML list as one item per line. Supports flow `[a, b]` and
# block `- a\n- b` styles. Empty list -> empty output.

_aidc_yaml_list() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    if _aidc_has_yq; then
        # `.x[]` over a missing or null key prints nothing; the `// []` guard
        # keeps yq quiet about traversing null.
        yq eval ".${key} // [] | .[]" "$file" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
        return 0
    fi
    # Fallback: detect `key:` line, then either read inline [..] or following
    # `  - item` lines until a non-indented / non-list line.
    awk -v k="$key" '
        BEGIN { in_block=0 }
        /^[[:space:]]*#/ { next }
        in_block == 1 {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                v = $0
                sub(/^[[:space:]]*-[[:space:]]*/, "", v)
                sub(/[[:space:]]*#.*$/, "", v)
                sub(/^["'\'']/, "", v); sub(/["'\'']$/, "", v)
                sub(/[[:space:]]+$/, "", v)
                if (v != "") print v
                next
            } else if ($0 ~ /^[[:space:]]*$/) {
                next
            } else {
                in_block=0
            }
        }
        $0 ~ "^"k"[[:space:]]*:" {
            rest = $0
            sub("^"k"[[:space:]]*:[[:space:]]*", "", rest)
            sub(/[[:space:]]*#.*$/, "", rest)
            if (rest ~ /^\[.*\]$/) {
                sub(/^\[/, "", rest); sub(/\]$/, "", rest)
                n = split(rest, parts, ",")
                for (i=1; i<=n; i++) {
                    p = parts[i]
                    sub(/^[[:space:]]+/, "", p); sub(/[[:space:]]+$/, "", p)
                    sub(/^["'\'']/, "", p); sub(/["'\'']$/, "", p)
                    if (p != "") print p
                }
            } else if (rest == "" || rest == "[]") {
                in_block=1
            }
        }
    ' "$file"
}

# ---- list-dedupe helper ------------------------------------------------------
#
# Dedupe lines, preserving first-occurrence order. Empty lines dropped.

_aidc_dedupe_lines() {
    awk 'NF && !seen[$0]++'
}

# ---- expansion helper --------------------------------------------------------
#
# Expand a leading ~ or $HOME so audit_dir/foo and ~/foo both resolve.

_aidc_expand_path() {
    local p="${1:-}"
    # SC2088: the quoted '~' below is a case *pattern* (a literal tilde to
    # match), not a path we want the shell to tilde-expand -- expansion is done
    # explicitly via ${HOME} in the branch body.
    # shellcheck disable=SC2088
    case "$p" in
        '~'|'~/'*) printf '%s' "${HOME}${p#\~}" ;;
        *)         printf '%s' "$p" ;;
    esac
}

# ---- main entry --------------------------------------------------------------
#
# load_config [project_dir] [workspace_dir]
#
# Reads global + (if --workspace was given) workspace + (if present)
# <project_dir>/.aidc/config.yaml and sets the AIDC_* env vars. Resolution
# order is global -> workspace -> project (later wins for scalars; lists
# are aggregated-and-deduped). Idempotent: safe to call repeatedly.

load_config() {
    local project_dir="${1:-}"
    local workspace_dir="${2:-}"
    local global_cfg="${HOME}/.config/aidc/config.yaml"
    local workspace_cfg=""
    local project_cfg=""
    if [ -n "$workspace_dir" ] && [ -f "${workspace_dir}/.aidc/config.yaml" ]; then
        workspace_cfg="${workspace_dir}/.aidc/config.yaml"
    fi
    if [ -n "$project_dir" ] && [ -f "${project_dir}/.aidc/config.yaml" ]; then
        # Don't double-read if workspace == project (i.e. --workspace pointed
        # at the same dir as --repo).
        if [ "$project_dir" != "$workspace_dir" ]; then
            project_cfg="${project_dir}/.aidc/config.yaml"
        fi
    fi

    # If yq isn't available we still use the awk fallback. The shard prefers
    # yq; we degrade rather than die, because the schema is flat enough that
    # the fallback covers it.
    aidc_config_defaults

    local f val
    for f in "$global_cfg" "$workspace_cfg" "$project_cfg"; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || continue

        # Scalars: each non-empty value overrides.
        val=$(_aidc_yaml_scalar "$f" "profile");         [ -n "$val" ] && AIDC_PROFILE="$val"
        val=$(_aidc_yaml_scalar "$f" "taint_response");  [ -n "$val" ] && AIDC_TAINT_RESPONSE="$val"
        val=$(_aidc_yaml_scalar "$f" "tld_taints");      [ -n "$val" ] && AIDC_TLD_TAINTS="$val"
        val=$(_aidc_yaml_scalar "$f" "audit_dir");       [ -n "$val" ] && AIDC_AUDIT_DIR=$(_aidc_expand_path "$val")
        val=$(_aidc_yaml_scalar "$f" "notify_webhook");  [ -n "$val" ] && AIDC_NOTIFY_WEBHOOK="$val"
        val=$(_aidc_yaml_scalar "$f" "claude_mode");     [ -n "$val" ] && AIDC_CLAUDE_MODE="$val"
        val=$(_aidc_yaml_scalar "$f" "claude_resume");   [ -n "$val" ] && AIDC_CLAUDE_RESUME="$val"
        val=$(_aidc_yaml_scalar "$f" "share_memory");    [ -n "$val" ] && AIDC_SHARE_MEMORY="$val"
        val=$(_aidc_yaml_scalar "$f" "share_plugins");   [ -n "$val" ] && AIDC_SHARE_PLUGINS="$val"
        val=$(_aidc_yaml_scalar "$f" "egress");          [ -n "$val" ] && AIDC_EGRESS="$val"

        # Lists: append to running aggregate, dedupe at the end.
        local tlds adds ports cops dnss nets
        tlds=$(_aidc_yaml_list "$f" "state_actor_tlds" || true)
        adds=$(_aidc_yaml_list "$f" "blocklist_additions" || true)
        ports=$(_aidc_yaml_list "$f" "ports" || true)
        cops=$(_aidc_yaml_list "$f" "container_only_paths" || true)
        dnss=$(_aidc_yaml_list "$f" "dns_servers" || true)
        nets=$(_aidc_yaml_list "$f" "networks" || true)
        if [ -n "$tlds" ]; then
            AIDC_STATE_ACTOR_TLDS=$(printf '%s\n%s' "$AIDC_STATE_ACTOR_TLDS" "$tlds" | _aidc_dedupe_lines)
        fi
        if [ -n "$adds" ]; then
            AIDC_BLOCKLIST_ADDITIONS=$(printf '%s\n%s' "$AIDC_BLOCKLIST_ADDITIONS" "$adds" | _aidc_dedupe_lines)
        fi
        if [ -n "$ports" ]; then
            AIDC_PORTS=$(printf '%s\n%s' "$AIDC_PORTS" "$ports" | _aidc_dedupe_lines)
        fi
        if [ -n "$cops" ]; then
            AIDC_CONTAINER_ONLY_PATHS=$(printf '%s\n%s' "$AIDC_CONTAINER_ONLY_PATHS" "$cops" | _aidc_dedupe_lines)
        fi
        if [ -n "$dnss" ]; then
            AIDC_DNS_SERVERS=$(printf '%s\n%s' "$AIDC_DNS_SERVERS" "$dnss" | _aidc_dedupe_lines)
        fi
        if [ -n "$nets" ]; then
            AIDC_NETWORKS=$(printf '%s\n%s' "$AIDC_NETWORKS" "$nets" | _aidc_dedupe_lines)
        fi
    done

    # Final dedupe pass on defaults-only paths too (idempotent under -e).
    AIDC_STATE_ACTOR_TLDS=$(printf '%s\n' "$AIDC_STATE_ACTOR_TLDS" | _aidc_dedupe_lines)
    AIDC_BLOCKLIST_ADDITIONS=$(printf '%s\n' "$AIDC_BLOCKLIST_ADDITIONS" | _aidc_dedupe_lines)
    AIDC_CONTAINER_ONLY_PATHS=$(printf '%s\n' "$AIDC_CONTAINER_ONLY_PATHS" | _aidc_dedupe_lines)
    AIDC_PORTS=$(printf '%s\n' "$AIDC_PORTS" | _aidc_dedupe_lines)
    AIDC_DNS_SERVERS=$(printf '%s\n' "$AIDC_DNS_SERVERS" | _aidc_dedupe_lines)
    AIDC_NETWORKS=$(printf '%s\n' "$AIDC_NETWORKS" | _aidc_dedupe_lines)

    export AIDC_PROFILE AIDC_TAINT_RESPONSE AIDC_TLD_TAINTS AIDC_AUDIT_DIR \
           AIDC_STATE_ACTOR_TLDS AIDC_BLOCKLIST_ADDITIONS AIDC_NOTIFY_WEBHOOK \
           AIDC_CLAUDE_MODE AIDC_CLAUDE_RESUME AIDC_SHARE_MEMORY \
           AIDC_SHARE_PLUGINS \
           AIDC_PORTS AIDC_CONTAINER_ONLY_PATHS AIDC_DNS_SERVERS AIDC_NETWORKS \
           AIDC_EGRESS
}

# Emit the loaded config as YAML, for `aidc config` printing.
emit_loaded_config_yaml() {
    printf 'profile: %s\n' "$AIDC_PROFILE"
    printf 'taint_response: %s\n' "$AIDC_TAINT_RESPONSE"
    printf 'tld_taints: %s\n' "$AIDC_TLD_TAINTS"
    printf 'audit_dir: %s\n' "$AIDC_AUDIT_DIR"
    printf 'claude_mode: %s\n' "$AIDC_CLAUDE_MODE"
    printf 'claude_resume: %s\n' "$AIDC_CLAUDE_RESUME"
    printf 'share_memory: %s\n' "$AIDC_SHARE_MEMORY"
    printf 'share_plugins: %s\n' "$AIDC_SHARE_PLUGINS"
    printf 'egress: %s\n' "$AIDC_EGRESS"
    printf 'notify_webhook: "%s"\n' "$AIDC_NOTIFY_WEBHOOK"
    printf 'state_actor_tlds:\n'
    if [ -n "$AIDC_STATE_ACTOR_TLDS" ]; then
        printf '%s\n' "$AIDC_STATE_ACTOR_TLDS" | awk 'NF { printf "  - %s\n", $0 }'
    else
        printf '  []\n'
    fi
    printf 'blocklist_additions:\n'
    if [ -n "$AIDC_BLOCKLIST_ADDITIONS" ]; then
        printf '%s\n' "$AIDC_BLOCKLIST_ADDITIONS" | awk 'NF { printf "  - %s\n", $0 }'
    else
        printf '  []\n'
    fi
    printf 'ports:\n'
    if [ -n "$AIDC_PORTS" ]; then
        printf '%s\n' "$AIDC_PORTS" | awk 'NF { printf "  - \"%s\"\n", $0 }'
    else
        printf '  []\n'
    fi
    printf 'container_only_paths:\n'
    if [ -n "$AIDC_CONTAINER_ONLY_PATHS" ]; then
        printf '%s\n' "$AIDC_CONTAINER_ONLY_PATHS" | awk 'NF { printf "  - \"%s\"\n", $0 }'
    else
        printf '  []\n'
    fi
    printf 'dns_servers:\n'
    if [ -n "$AIDC_DNS_SERVERS" ]; then
        printf '%s\n' "$AIDC_DNS_SERVERS" | awk 'NF { printf "  - %s\n", $0 }'
    else
        printf '  []  # default: Quad9 (9.9.9.9, 149.112.112.112)\n'
    fi
    printf 'networks:\n'
    if [ -n "$AIDC_NETWORKS" ]; then
        printf '%s\n' "$AIDC_NETWORKS" | awk 'NF { printf "  - %s\n", $0 }'
    else
        printf '  []\n'
    fi
}
