#!/usr/bin/env bash
# desc: Remove container-only-path overlay volumes (by session or by project).
#
# Usage:
#   aidc clean-env <session>             # remove overlay volumes for a (non-running) session
#   aidc clean-env --project <path>      # remove overlay volumes for a repo path, across all sessions
#   aidc clean-env --yes ...             # skip the y/N confirmation
#
# Overlay volumes are session-scoped (named aidc-sovl-<session>-<path-slug>)
# and are normally removed by `aidc kill`. This subcommand is for the edge
# case where a session died mid-create without cleanup, OR when you want to
# clear out stray volumes from many killed sessions of the same project.

set -euo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

MODE=""        # "session" or "project"
TARGET=""
YES=0

usage() {
    cat <<'EOF'
aidc clean-env <session>             - remove overlay volumes for a (non-running) session
aidc clean-env --project <path>      - remove overlay volumes for a repo path, across all sessions
aidc clean-env --yes ...             - skip the y/N confirmation

Overlay volumes hold container-only paths (venv, node_modules, etc.) per task-16.
They are session-scoped and normally cleaned up by 'aidc kill'. This subcommand
handles the edge cases.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --yes) YES=1; shift ;;
        --project)
            [ $# -ge 2 ] || die "--project requires a path"
            MODE="project"
            TARGET="$2"
            shift 2 ;;
        --project=*)
            MODE="project"
            TARGET="${1#--project=}"
            shift ;;
        --*) die "unknown flag: $1" ;;
        *)
            if [ -z "$MODE" ]; then
                MODE="session"
                TARGET="$1"
                shift
            else
                die "unexpected positional argument: $1"
            fi ;;
    esac
done

[ -z "$MODE" ] && { usage >&2; exit 2; }

require_docker

case "$MODE" in
    session)
        validate_session_name "$TARGET"
        if session_exists "$TARGET"; then
            die "session '$TARGET' is still running (use 'aidc kill $TARGET' to tear it down -- kill already removes overlay volumes)"
        fi
        # Match aidc-sovl-<session>-* but NOT aidc-sovl-<sessionx>-*
        # (the trailing - in the filter pattern is significant).
        vols=$(docker volume ls --filter "name=aidc-sovl-${TARGET}-" -q 2>/dev/null || true)
        SCOPE_DESC="session ${TARGET}"
        ;;
    project)
        # Project mode: the session-scoped volume names embed the session
        # but NOT the project path. We can't deduce volumes from project
        # path alone -- the volume name has the SESSION not the project.
        #
        # Instead: list all aidc-sovl-* volumes, then for each, look at
        # the container that's USING it (if any) and check whether that
        # container's compose project corresponds to the given repo path.
        # If no container is using it (stray volume), match purely by
        # name pattern with the repo's path-slug as a suffix.
        REPO_PATH=$(realpath_portable "$TARGET")
        [ -d "$REPO_PATH" ] || die "project path does not exist: $REPO_PATH"
        SCOPE_DESC="project ${REPO_PATH}"
        # Project mode is harder than session mode because we don't have a
        # direct mapping from project path to volume names. The safest
        # heuristic: for each aidc-sovl-* volume, inspect its in-container
        # mount target. If the target starts with the resolved repo path,
        # it belongs to this project. This works even for stray volumes
        # because docker stores the volume's mount metadata when it's
        # first attached.
        vols=""
        for v in $(docker volume ls --filter 'name=aidc-sovl-' -q 2>/dev/null); do
            # Find a container (running or stopped) that has this volume mounted.
            ct=$(docker ps -a --filter "volume=${v}" -q 2>/dev/null | head -1)
            if [ -z "$ct" ]; then
                # No container references it -- can't infer project. Skip.
                continue
            fi
            mount_target=$(docker inspect "$ct" --format "{{range .Mounts}}{{if eq .Name \"${v}\"}}{{.Destination}}{{end}}{{end}}" 2>/dev/null || true)
            case "$mount_target" in
                "${REPO_PATH}"|"${REPO_PATH}/"*)
                    vols="${vols}${v}
"
                    ;;
            esac
        done
        vols=$(printf '%s' "$vols" | awk 'NF')
        ;;
esac

if [ -z "$vols" ]; then
    printf 'no overlay volumes to remove for %s\n' "$SCOPE_DESC"
    exit 0
fi

# Refuse if any matched volume is currently in use by a running container.
# Docker would refuse the rm anyway; surface a clearer error upfront.
in_use=""
for v in $vols; do
    if docker ps --filter "volume=${v}" -q 2>/dev/null | grep -q .; then
        in_use="${in_use}${v}
"
    fi
done
if [ -n "$in_use" ]; then
    err "the following overlay volumes are in use by running containers; aidc kill the owning session first:"
    printf '%s\n' "$in_use" | sed 's/^/  /' >&2
    exit 1
fi

count=$(printf '%s\n' "$vols" | wc -l | tr -d ' ')
printf '\n' >&2
printf 'About to remove %s overlay volume(s) for %s:\n' "$count" "$SCOPE_DESC" >&2
printf '%s\n' "$vols" | sed 's/^/  /' >&2
printf '\n' >&2

if [ "$YES" -ne 1 ]; then
    printf 'Proceed? [y/N] ' >&2
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in
        y|Y) : ;;
        *) info "aborted"; exit 0 ;;
    esac
fi

printf '%s\n' "$vols" | xargs docker volume rm >/dev/null 2>&1 || \
    die "docker volume rm failed (one or more volumes may still be in use)"

info "removed ${count} overlay volume(s) for ${SCOPE_DESC}"
