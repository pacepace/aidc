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
    AIDC_AUDIT_DIR="$(aidc_host_home)/aidc-audit"
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
    AIDC_SHARE_SCRATCHPAD="true"  # mount host's /tmp/claude-<uid>/<repo>/ (scratchpad + tasks) into container
    AIDC_PORTS=""                 # declared host:container forwards (CLI-13); newline-separated
    AIDC_CONTAINER_ONLY_PATHS=""  # paths overlaid by session-scoped volumes (CLI-18); newline-separated
    AIDC_DNS_SERVERS=""           # per-session DNS override; newline-separated IPs; empty = Quad9 default
    AIDC_NETWORKS=""              # foreign docker bridges to attach (NET-13); newline-separated
    AIDC_EGRESS="proxied"         # proxied|direct -- internal session bridge vs NATed (NET-14)
    AIDC_EGRESS_TCP=""            # host:port TCP destinations relayed to the session (NET-15); newline-separated
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
share_scratchpad: true      # bridge host /tmp/claude-<uid>/<encoded>/ so a session's scratchpad
                            # and tasks survive moving between host and container

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

# TCP destinations the session may reach, host:port, without a route out: a
# database over ZeroTier, a VPN or the LAN. Each gets a relay that answers to the
# name inside the session and forwards to that one address and port, logging every
# connection to the audit dir. Resolved on this machine at create. Same as
# `aidc create --egress-tcp`. A repo's own .aidc/config.yaml cannot set this.
egress_tcp: []

notify_webhook: ""

# Only relevant if you use `aidc mcp` (the control plane for AI orchestrators).
mcp:
  bind_address: 127.0.0.1   # change to your ZeroTier / Tailscale interface IP for remote access
  port: 7878
  session_create: false     # offer the session_create tool. Creating a session reads a repo and
                            # writes Claude's per-project memory on the HOST, so turning this on
                            # mounts your home into the aidc-mcp container. Off, the tool is not
                            # offered at all.

# Only relevant if an orchestrator drives sessions over MCP (the key keeps its
# historical name): where session_invoke_async / session_send POST results back.
metallm:
  callback_url: ""           # base URL of the orchestrator's callback endpoint, e.g. https://orchestrator.example.com
  send_speaker: false        # add "speaker": "human"|"agent" to session_send replies. Leave off until
                             # the orchestrator records human turns instead of dropping them.
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
# The HOME of the person this aidc belongs to. Every path this CLI hands to docker
# (mounts, audit dir, the transcript mirror) is resolved by the daemon ON THE HOST, so
# it must be a host path. aidc-mcp runs this same CLI for session_create inside its own
# container, where HOME is /root: `aidc mcp start` passes the real one as
# AIDC_HOST_HOME, and every host path is derived from this.
aidc_host_home() {
    printf '%s' "${AIDC_HOST_HOME:-$HOME}"
}

# Where THIS process must write to land in a host directory.
#
# On the host the two are the same. Inside aidc-mcp, which runs this CLI for
# session_create, a host path like /home/you/.local/state/aidc-mcp is reachable only
# through the mount it was given (/var/log/aidc-mcp), and creating the host spelling
# there just makes a container-local directory the host never sees: the session's
# compose file then binds a host path nothing created, docker makes it root-owned, and
# the mirror that must write into it (running as vscode) silently writes nothing, so no
# reply from that session is ever delivered. Prints the path to use, or nothing when
# this process cannot reach it at all — which the caller must treat as fatal.
# Sets AIDC_LOCAL_PATH (where to write) and AIDC_LOCAL_MOUNT (the mount it came
# through, "" on the host). Returns 1 when this process cannot reach the path.
# aidc_local_path is the same lookup for callers that just want the path.
aidc_resolve_local() {
    local p="${1:-}" pair host mount mounts
    mounts="${AIDC_MCP_MOUNTS:-}"
    if [ -z "$mounts" ] && [ -n "${AIDC_MCP_STATE_HOST:-}" ]; then
        # A container started before this list existed: /aidc is a read-only mount, so a
        # CLI update lands inside a RUNNING aidc-mcp whose env predates it. Fall back to
        # the two mounts that server was given, rather than declaring every host path
        # unreachable and failing a create with a message naming the wrong cause.
        mounts="${AIDC_MCP_STATE_HOST}|/var/log/aidc-mcp"
        [ -n "${AIDC_AUDIT_HOST:-}" ] && mounts="${mounts},${AIDC_AUDIT_HOST}|/var/aidc-audit"
    fi
    for pair in $(printf '%s' "$mounts" | tr ',' ' '); do
        host="${pair%%|*}"
        mount="${pair##*|}"
        if [ -z "$host" ] || [ -z "$mount" ]; then
            continue
        fi
        case "$p" in
            "$host"|"$host"/*)
                # The mount root is who this tree belongs to on the host: see
                # aidc_mkdir_host.
                AIDC_LOCAL_MOUNT="$mount"
                AIDC_LOCAL_PATH="${mount}${p#"$host"}"
                export AIDC_LOCAL_MOUNT AIDC_LOCAL_PATH
                return 0 ;;
        esac
    done
    # No mapping needed on the host. Inside aidc-mcp (AIDC_HOST_HOME set) an unmapped
    # host path is unreachable: say so rather than writing where nobody looks.
    AIDC_LOCAL_MOUNT=""
    AIDC_LOCAL_PATH="$p"
    export AIDC_LOCAL_MOUNT AIDC_LOCAL_PATH
    [ -n "${AIDC_HOST_HOME:-}" ] && return 1
    return 0
}

aidc_local_path() {
    aidc_resolve_local "${1:-}" || return 1
    printf '%s' "$AIDC_LOCAL_PATH"
}

# Create a HOST directory and set AIDC_LOCAL_PATH to the path THIS process writes to (see
# aidc_local_path). Inside aidc-mcp the process is root, so a directory it makes
# through a mount lands root-owned on the host — and the session's own processes, which
# run as the container user, then cannot write into it: the transcript mirror fails
# silently and no reply is ever delivered. So it is given the owner of the tree it was
# made in, which is what creating it on the host would have done. Sets
# AIDC_HOST_OWNER (uid:gid) when it applied one, for files written afterwards. It sets
# rather than prints both, because a command substitution would run it in a subshell
# and lose them. Returns 1 when this process cannot reach the path at all.
aidc_mkdir_host() {
    local host="${1:-}" write owner
    # Resolve in THIS shell: a command substitution would lose AIDC_LOCAL_MOUNT.
    aidc_resolve_local "$host" || return 1
    write="$AIDC_LOCAL_PATH"
    # The topmost directory this call creates: everything from there down is ours to
    # hand to the host owner, not just the leaf.
    local top="$write"
    while [ ! -e "$top" ] && [ "$(dirname "$top")" != "$top" ] \
            && [ ! -e "$(dirname "$top")" ]; do
        top=$(dirname "$top")
    done
    # Never step outside the mount this path resolved into: an operator config with a
    # `..` in it (audit_dir: ~/aidc-audit/../..) would otherwise hand the chown below a
    # tree nobody meant to touch.
    case "$(cd "$(dirname "$write")" 2>/dev/null && pwd -P || printf '%s' "$(dirname "$write")")" in
        "$AIDC_LOCAL_MOUNT"|"$AIDC_LOCAL_MOUNT"/*|"") ;;
        *) if [ -n "${AIDC_LOCAL_MOUNT:-}" ]; then
               printf '[aidc] error: refusing to create %s: it resolves outside %s\n' \
                   "$write" "$AIDC_LOCAL_MOUNT" >&2
               return 1
           fi ;;
    esac
    mkdir -p "$write" || return 1
    AIDC_HOST_OWNER=""
    if [ -n "${AIDC_HOST_HOME:-}" ] && [ -n "${AIDC_LOCAL_MOUNT:-}" ]; then
        # The mount root carries the host owner of this whole tree — not the deepest
        # existing directory, which may itself be a root-owned leftover from a create
        # that ran before this fix.
        owner=$(stat -c '%u:%g' "$AIDC_LOCAL_MOUNT" 2>/dev/null || true)
        if [ -n "$owner" ] && [ "$owner" != "$(id -u):$(id -g)" ]; then
            # Loud on failure: a directory left owned by this process is one the
            # session's own mirror cannot write, and nothing downstream would say so.
            # printf, not die/err: this library is sourced on its own by tests and by
            # callers that have not sourced common.sh, where `die` would be a
            # command-not-found that the || swallowed — exactly the silent pass this
            # check exists to prevent.
            if ! chown -R "$owner" "$top" 2>/dev/null; then
                printf '[aidc] error: could not give %s to %s: a session created here could not write its transcripts\n' \
                    "$top" "$owner" >&2
                return 1
            fi
            AIDC_HOST_OWNER="$owner"
        fi
    fi
    export AIDC_HOST_OWNER
}

# Give files written into a host dir the owner of the tree that dir belongs to. The
# owner is read for THIS path, not carried from whatever aidc_mkdir_host was called last:
# the audit dir and the state dir are different mounts and can have different owners.
aidc_fix_host_owner() {
    local path="${1:-}" owner
    [ -n "${AIDC_HOST_HOME:-}" ] || return 0
    aidc_resolve_local "$path" >/dev/null 2>&1 || return 0
    [ -n "${AIDC_LOCAL_MOUNT:-}" ] || return 0
    owner=$(stat -c '%u:%g' "$AIDC_LOCAL_MOUNT" 2>/dev/null || true)
    [ -n "$owner" ] && [ "$owner" != "$(id -u):$(id -g)" ] || return 0
    if ! chown -R "$owner" "$path" 2>/dev/null; then
        printf '[aidc] error: could not give %s to %s; files there may be unreadable to you\n' \
            "$path" "$owner" >&2
        return 1
    fi
}

# Expand a leading ~ or $HOME so audit_dir/foo and ~/foo both resolve.

_aidc_expand_path() {
    local p="${1:-}"
    # SC2088: the quoted '~' below is a case *pattern* (a literal tilde to
    # match), not a path we want the shell to tilde-expand -- expansion is done
    # explicitly via ${HOME} in the branch body.
    # shellcheck disable=SC2088
    case "$p" in
        '~'|'~/'*) printf '%s' "$(aidc_host_home)${p#\~}" ;;
        *)         printf '%s' "$p" ;;
    esac
}

# ---- repo-config trust (SEC-09) ---------------------------------------------

# How hard a taint response bites, for "a repo may only make it stricter".
# Unknown values rank lowest, so they never count as a tightening.
_aidc_taint_rank() {
    case "$1" in
        freeze) printf '3' ;;
        notify) printf '2' ;;
        log)    printf '1' ;;
        *)      printf '0' ;;
    esac
}

# Record a setting a workspace/repo config asked for and did not get.
_aidc_repo_request() {
    AIDC_REPO_REQUESTED="${AIDC_REPO_REQUESTED}${1}: ${2}
"
}

# The same, for each entry of a list (newline-separated $3) under key $2.
_aidc_repo_request_list() {
    local item
    while IFS= read -r item; do
        if [ -n "$item" ]; then
            _aidc_repo_request "$1" "$2: $item"
        fi
    done <<EOF_REQ
$3
EOF_REQ
    return 0
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
    # The host's ~/.config/aidc/config.yaml, or the copy mounted into the aidc-mcp
    # container, which runs this same CLI for session_create. Without the mount the
    # MCP created every session on the defaults, ignoring the profile, taint
    # response and audit dir the host is configured with. Paths in that config are
    # host paths, which is what they must be: the container drives the host's docker.
    local global_cfg
    global_cfg=$(_aidc_global_config_file)
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

    # Which files were actually read, for `aidc create` to report: a session created
    # on the defaults because no config was found looks identical otherwise.
    AIDC_CONFIG_SOURCES=""
    export AIDC_CONFIG_SOURCES
    AIDC_REPO_REQUESTED=""

    local f val
    for f in "$global_cfg" "$workspace_cfg" "$project_cfg"; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || continue

        AIDC_CONFIG_SOURCES="${AIDC_CONFIG_SOURCES:+${AIDC_CONFIG_SOURCES} }${f}"

        # A config file in the workspace or the repo is writable from inside the
        # session, so an agent can edit it and the next `aidc create` would read it.
        # From there (SEC-09) only settings that cannot widen the sandbox apply:
        # anything that opens a path out, mounts a host directory, moves where aidc
        # writes on the host, or softens the response to a taint is set aside in
        # AIDC_REPO_REQUESTED for `aidc create` to show, and applies only with
        # --trust-repo-config. A request that tightens (freeze over log, sharing
        # turned off, proxied egress) always applies: refusing it helps no one.
        local trusted=false
        if [ "$f" = "$global_cfg" ] || [ "${AIDC_TRUST_REPO_CONFIG:-false}" = "true" ]; then
            trusted=true
        fi

        # Scalars: each non-empty value overrides.
        val=$(_aidc_yaml_scalar "$f" "profile");         [ -n "$val" ] && AIDC_PROFILE="$val"
        val=$(_aidc_yaml_scalar "$f" "claude_mode");     [ -n "$val" ] && AIDC_CLAUDE_MODE="$val"
        val=$(_aidc_yaml_scalar "$f" "claude_resume");   [ -n "$val" ] && AIDC_CLAUDE_RESUME="$val"

        val=$(_aidc_yaml_scalar "$f" "taint_response")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || \
               [ "$(_aidc_taint_rank "$val")" -ge "$(_aidc_taint_rank "$AIDC_TAINT_RESPONSE")" ]; then
                AIDC_TAINT_RESPONSE="$val"
            else
                _aidc_repo_request "$f" "taint_response: $val"
            fi
        fi
        val=$(_aidc_yaml_scalar "$f" "tld_taints")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || [ "$val" = "true" ]; then
                AIDC_TLD_TAINTS="$val"
            else
                _aidc_repo_request "$f" "tld_taints: $val"
            fi
        fi
        val=$(_aidc_yaml_scalar "$f" "share_memory")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || [ "$val" = "false" ]; then AIDC_SHARE_MEMORY="$val"
            else _aidc_repo_request "$f" "share_memory: $val"; fi
        fi
        val=$(_aidc_yaml_scalar "$f" "share_plugins")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || [ "$val" = "false" ]; then AIDC_SHARE_PLUGINS="$val"
            else _aidc_repo_request "$f" "share_plugins: $val"; fi
        fi
        val=$(_aidc_yaml_scalar "$f" "share_scratchpad")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || [ "$val" = "false" ]; then AIDC_SHARE_SCRATCHPAD="$val"
            else _aidc_repo_request "$f" "share_scratchpad: $val"; fi
        fi
        val=$(_aidc_yaml_scalar "$f" "egress")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ] || [ "$val" = "proxied" ]; then AIDC_EGRESS="$val"
            else _aidc_repo_request "$f" "egress: $val"; fi
        fi
        val=$(_aidc_yaml_scalar "$f" "audit_dir")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ]; then AIDC_AUDIT_DIR=$(_aidc_expand_path "$val")
            else _aidc_repo_request "$f" "audit_dir: $val"; fi
        fi
        val=$(_aidc_yaml_scalar "$f" "notify_webhook")
        if [ -n "$val" ]; then
            if [ "$trusted" = true ]; then AIDC_NOTIFY_WEBHOOK="$val"
            else _aidc_repo_request "$f" "notify_webhook: $val"; fi
        fi

        # Lists: append to running aggregate, dedupe at the end. The first three
        # only ever add blocking or hiding; the rest open paths, so they are
        # operator-only like the scalars above.
        local tlds adds cops ports dnss nets etcp
        tlds=$(_aidc_yaml_list "$f" "state_actor_tlds" || true)
        adds=$(_aidc_yaml_list "$f" "blocklist_additions" || true)
        cops=$(_aidc_yaml_list "$f" "container_only_paths" || true)
        ports=$(_aidc_yaml_list "$f" "ports" || true)
        dnss=$(_aidc_yaml_list "$f" "dns_servers" || true)
        nets=$(_aidc_yaml_list "$f" "networks" || true)
        etcp=$(_aidc_yaml_list "$f" "egress_tcp" || true)
        if [ -n "$tlds" ]; then
            AIDC_STATE_ACTOR_TLDS=$(printf '%s\n%s' "$AIDC_STATE_ACTOR_TLDS" "$tlds" | _aidc_dedupe_lines)
        fi
        if [ -n "$adds" ]; then
            AIDC_BLOCKLIST_ADDITIONS=$(printf '%s\n%s' "$AIDC_BLOCKLIST_ADDITIONS" "$adds" | _aidc_dedupe_lines)
        fi
        if [ -n "$cops" ]; then
            AIDC_CONTAINER_ONLY_PATHS=$(printf '%s\n%s' "$AIDC_CONTAINER_ONLY_PATHS" "$cops" | _aidc_dedupe_lines)
        fi
        if [ "$trusted" = true ]; then
            if [ -n "$ports" ]; then
                AIDC_PORTS=$(printf '%s\n%s' "$AIDC_PORTS" "$ports" | _aidc_dedupe_lines)
            fi
            if [ -n "$dnss" ]; then
                AIDC_DNS_SERVERS=$(printf '%s\n%s' "$AIDC_DNS_SERVERS" "$dnss" | _aidc_dedupe_lines)
            fi
            if [ -n "$nets" ]; then
                AIDC_NETWORKS=$(printf '%s\n%s' "$AIDC_NETWORKS" "$nets" | _aidc_dedupe_lines)
            fi
            if [ -n "$etcp" ]; then
                AIDC_EGRESS_TCP=$(printf '%s\n%s' "$AIDC_EGRESS_TCP" "$etcp" | _aidc_dedupe_lines)
            fi
        else
            _aidc_repo_request_list "$f" ports "$ports"
            _aidc_repo_request_list "$f" dns_servers "$dnss"
            _aidc_repo_request_list "$f" networks "$nets"
            _aidc_repo_request_list "$f" egress_tcp "$etcp"
        fi
    done

    # Final dedupe pass on defaults-only paths too (idempotent under -e).
    AIDC_STATE_ACTOR_TLDS=$(printf '%s\n' "$AIDC_STATE_ACTOR_TLDS" | _aidc_dedupe_lines)
    AIDC_BLOCKLIST_ADDITIONS=$(printf '%s\n' "$AIDC_BLOCKLIST_ADDITIONS" | _aidc_dedupe_lines)
    AIDC_CONTAINER_ONLY_PATHS=$(printf '%s\n' "$AIDC_CONTAINER_ONLY_PATHS" | _aidc_dedupe_lines)
    AIDC_PORTS=$(printf '%s\n' "$AIDC_PORTS" | _aidc_dedupe_lines)
    AIDC_DNS_SERVERS=$(printf '%s\n' "$AIDC_DNS_SERVERS" | _aidc_dedupe_lines)
    AIDC_NETWORKS=$(printf '%s\n' "$AIDC_NETWORKS" | _aidc_dedupe_lines)
    AIDC_EGRESS_TCP=$(printf '%s\n' "$AIDC_EGRESS_TCP" | _aidc_dedupe_lines)

    export AIDC_PROFILE AIDC_TAINT_RESPONSE AIDC_TLD_TAINTS AIDC_AUDIT_DIR \
           AIDC_STATE_ACTOR_TLDS AIDC_BLOCKLIST_ADDITIONS AIDC_NOTIFY_WEBHOOK \
           AIDC_CLAUDE_MODE AIDC_CLAUDE_RESUME AIDC_SHARE_MEMORY \
           AIDC_SHARE_PLUGINS AIDC_SHARE_SCRATCHPAD \
           AIDC_PORTS AIDC_CONTAINER_ONLY_PATHS AIDC_DNS_SERVERS AIDC_NETWORKS \
           AIDC_EGRESS AIDC_EGRESS_TCP AIDC_REPO_REQUESTED
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
    printf 'share_scratchpad: %s\n' "$AIDC_SHARE_SCRATCHPAD"
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
    printf 'egress_tcp:\n'
    if [ -n "$AIDC_EGRESS_TCP" ]; then
        printf '%s\n' "$AIDC_EGRESS_TCP" | awk 'NF { printf "  - \"%s\"\n", $0 }'
    else
        printf '  []\n'
    fi
    if [ -n "${AIDC_REPO_REQUESTED:-}" ]; then
        printf '# Asked for by a workspace/repo config and NOT applied (SEC-09);\n'
        printf '# aidc create --trust-repo-config applies them:\n'
        printf '%s' "$AIDC_REPO_REQUESTED" | awk 'NF { printf "#   %s\n", $0 }'
    fi
}

# Tell the person creating a session what a workspace/repo config asked for and
# did not get, and how to grant it. Silent when there is nothing to say.
aidc_report_repo_requests() {
    [ -n "${AIDC_REPO_REQUESTED:-}" ] || return 0
    printf 'aidc: a workspace/repo config asked to widen the sandbox; NOT applied:\n' >&2
    printf '%s' "$AIDC_REPO_REQUESTED" | awk 'NF { printf "aidc:   %s\n", $0 }' >&2
    printf 'aidc: that file is writable from inside a session. If you wrote it and want it,\n' >&2
    printf 'aidc: recreate with --trust-repo-config, or move the settings to your own config.\n' >&2
}

# Read a single child key of a top-level YAML mapping.
# Args: file parent-key child-key
# Echoes the value (stripped of quotes / comments / surrounding whitespace) or
# nothing if absent. Handles the flat-block schema aidc uses; not a general YAML
# parser.
_aidc_yaml_nested() {
    local file="$1" parent="$2" child="$3"
    [ -f "$file" ] || return 0
    awk -v parent="$parent" -v child="$child" '
        BEGIN { in_block=0 }
        $0 ~ "^"parent":" { in_block=1; next }
        /^[A-Za-z]/      { in_block=0 }
        in_block && $0 ~ "^[[:space:]]+"child":" {
            v=$0
            sub("^[[:space:]]+"child":[[:space:]]*", "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            sub(/^["'\'']/, "", v); sub(/["'\'']$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$file"
}

# The global config file readable from here: the host's ~/.config/aidc, or, inside
# the aidc-mcp container (which runs `aidc create` for session_create, with HOME
# /root), the /aidc-config mount. Echoes nothing when neither exists.
_aidc_global_config_file() {
    local host_cfg="${HOME}/.config/aidc/config.yaml"
    local mcp_cfg="${AIDC_MCP_CONFIG_MOUNT:-/aidc-config}/config.yaml"
    if [ -f "$host_cfg" ]; then
        printf '%s' "$host_cfg"
    elif [ -f "$mcp_cfg" ]; then
        printf '%s' "$mcp_cfg"
    fi
}

mcp_load_settings() {
    # Read mcp.bind_address and mcp.port from global config into
    # AIDC_MCP_BIND_ADDRESS / AIDC_MCP_PORT (defaults 127.0.0.1 / 7878).
    # Prefer yq when present, otherwise use the nested-aware awk parser.
    local cfg
    cfg=$(_aidc_global_config_file)
    AIDC_MCP_BIND_ADDRESS="127.0.0.1"
    AIDC_MCP_PORT="7878"
    AIDC_MCP_SESSION_CREATE="false"
    export AIDC_MCP_BIND_ADDRESS AIDC_MCP_PORT AIDC_MCP_SESSION_CREATE
    [ -n "$cfg" ] || return 0

    local b="" p="" c=""
    if command -v yq >/dev/null 2>&1; then
        b=$(yq eval '.mcp.bind_address // ""' "$cfg" 2>/dev/null || printf '')
        p=$(yq eval '.mcp.port // ""' "$cfg" 2>/dev/null || printf '')
        c=$(yq eval '.mcp.session_create // ""' "$cfg" 2>/dev/null || printf '')
        [ "$b" = "null" ] && b=""
        [ "$p" = "null" ] && p=""
        [ "$c" = "null" ] && c=""
    fi
    if [ -z "$b" ]; then b=$(_aidc_yaml_nested "$cfg" "mcp" "bind_address"); fi
    if [ -z "$p" ]; then p=$(_aidc_yaml_nested "$cfg" "mcp" "port"); fi
    if [ -z "$c" ]; then c=$(_aidc_yaml_nested "$cfg" "mcp" "session_create"); fi
    [ -n "$b" ] && AIDC_MCP_BIND_ADDRESS="$b"
    [ -n "$p" ] && AIDC_MCP_PORT="$p"
    [ "$c" = "true" ] && AIDC_MCP_SESSION_CREATE="true"
    export AIDC_MCP_BIND_ADDRESS AIDC_MCP_PORT AIDC_MCP_SESSION_CREATE
}

# The host directories aidc-mcp is given, as `<host>|<mount>` pairs, one per line.
#
# ONE list with two consumers, because they were written twice and drifted: the
# `docker run -v` flags in `aidc mcp start`, and the table aidc_resolve_local uses to
# decide which host paths the CLI can reach from inside that container. When the home
# mount arrived in the first and not the second, the operator opted into sharing Claude's
# per-project memory and got "memory: NOT shared" anyway. `aidc mcp start` passes this
# list to the container as AIDC_MCP_MOUNTS, and aidc_resolve_local reads only that.
aidc_mcp_mount_pairs() {
    printf '%s|/var/log/aidc-mcp\n' "${AIDC_MCP_STATE_DIR:-$(aidc_host_home)/.local/state/aidc-mcp}"
    printf '%s|/var/aidc-audit\n' "${AIDC_AUDIT_DIR:-$(aidc_host_home)/aidc-audit}"
    # The operator's home, at the same path it has on the host, so a repo and Claude's
    # per-project memory are reachable. Only with mcp.session_create (see below).
    if [ "${AIDC_MCP_SESSION_CREATE:-}" = "true" ]; then
        printf '%s|%s\n' "$(aidc_host_home)" "$(aidc_host_home)"
    fi
}

# The `-v host:mount:rw` flags for the pairs above, one per line — the same list
# aidc_resolve_local is given, so a mount cannot be granted without being reachable.
mcp_mount_args() {
    local pair
    aidc_mcp_mount_pairs | while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        printf -- '-v\n%s:%s:rw\n' "${pair%%|*}" "${pair##*|}"
    done
}

# The extra `docker run` arguments `aidc mcp start` needs when mcp.session_create is on.
#
# Creating a session means reading a repo and writing Claude's per-project memory on the
# HOST, so the server needs the operator's home at the same path it has on the host.
# That is a real widening — the container can then read and write everything under it —
# so it is opt-in, and with it off the MCP does not offer session_create at all rather
# than offering one that cannot work. (The container already has the docker socket,
# which is root-equivalent on the host, so this grants no power it lacked; it makes the
# paths line up.) Prints nothing when the setting is off.
# The home mount itself comes from mcp_mount_args, like every other; this adds only the
# env that makes the tool exist.
mcp_session_create_args() {
    [ "${AIDC_MCP_SESSION_CREATE:-}" = "true" ] || return 0
    printf -- '-e\nAIDC_MCP_SESSION_CREATE=true\n'
}

# AIDC_MCP_MOUNTS for the container: the same pairs, comma-separated.
mcp_mounts_env() {
    aidc_mcp_mount_pairs | paste -sd, -
}

# aidc_mcp_deny_target: "addr:port" of the aidc-mcp server that sessions must not
# reach (MCP-12), for the session's squid. The running aidc-mcp container's
# published binding is what is actually listening, so it wins; without one, the
# configured bind address and port (what `aidc mcp start` would use). The same
# answer holds on the host and inside the aidc-mcp container, which reaches the
# host docker daemon through its socket.
aidc_mcp_deny_target() {
    local bound
    bound=$(docker inspect aidc-mcp \
        --format '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' \
        2>/dev/null | awk 'NF { print; exit }') || bound=""
    case "$bound" in
        :*) bound="0.0.0.0${bound}" ;;   # empty HostIp: published on every interface
    esac
    if [ -n "$bound" ]; then
        printf '%s' "$bound"
        return 0
    fi
    mcp_load_settings
    printf '%s:%s' "$AIDC_MCP_BIND_ADDRESS" "$AIDC_MCP_PORT"
}
