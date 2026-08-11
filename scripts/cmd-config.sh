#!/usr/bin/env bash
# desc: Show or edit aidc configuration.
#
# Usage:
#   aidc config                  # show merged (global + cwd-project) config
#   aidc config global           # show ~/.config/aidc/config.yaml
#   aidc config <session>        # show session's frozen config-snapshot.yaml
#   aidc config edit             # $EDITOR on cwd-project config (created if missing)
#   aidc config global edit      # $EDITOR on global config (created if missing)

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"

GLOBAL_CFG="${HOME}/.config/aidc/config.yaml"
PROJECT_CFG=".aidc/config.yaml"

editor_open() {
    local target="$1"
    local dir
    dir=$(dirname "$target")
    mkdir -p "$dir"
    if [ ! -f "$target" ]; then
        default_config_yaml > "$target"
        info "created $target from template"
    fi
    exec "${EDITOR:-vim}" "$target"
}

# ---- arg dispatch ------------------------------------------------------------

ARG="${1:-}"
ARG2="${2:-}"

case "$ARG" in
    -h|--help)
        cat <<'EOF'
aidc config                  Show merged config (global + cwd-project).
aidc config global           Show global config file (~/.config/aidc/config.yaml).
aidc config <session>        Show a session's frozen config-snapshot.yaml.
aidc config edit             Edit per-project config (creates if missing).
aidc config global edit      Edit global config (creates if missing).
EOF
        exit 0 ;;
    "")
        load_config "$(pwd -P)"
        emit_loaded_config_yaml
        ;;
    global)
        if [ "$ARG2" = "edit" ]; then
            editor_open "$GLOBAL_CFG"
        elif [ -f "$GLOBAL_CFG" ]; then
            cat "$GLOBAL_CFG"
        else
            info "$GLOBAL_CFG does not exist; defaults:"
            default_config_yaml
        fi
        ;;
    edit)
        # Per-project edit. We need a repo root with .aidc/ -- use cwd.
        editor_open "$(pwd -P)/$PROJECT_CFG"
        ;;
    *)
        # Treat as a session name. Validate, then look up its frozen snapshot.
        validate_session_name "$ARG"
        require_docker
        if ! session_exists "$ARG"; then
            die "no such session: $ARG"
        fi
        AUDIT_CT="$(container_name "$ARG" audit)"
        # The audit container mounts the host audit dir at /var/aidc/audit;
        # `docker inspect` recovers the host path.
        host_audit=$(docker inspect "$AUDIT_CT" \
            --format '{{range .Mounts}}{{if eq .Destination "/var/aidc/audit"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null || printf '')
        snap=""
        if [ -n "$host_audit" ] && [ -f "${host_audit}/config-snapshot.yaml" ]; then
            snap="${host_audit}/config-snapshot.yaml"
        fi
        if [ -n "$snap" ]; then
            cat "$snap"
        else
            die "could not locate config-snapshot.yaml for session $ARG"
        fi
        ;;
esac
