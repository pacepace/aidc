# shellcheck shell=bash
# Sourced by every scripts/git/git-<verb>.sh: the backend's library, which defines the small
# interface each verb reaches the git container through (gb_require, gb_target, gb_exec,
# gb_exec_in, gb_exec_tty, gb_repo_arg, gb_repos, gb_repo_ok, gb_settings, gb_session_token,
# gb_sessions, gb_status_head, gb_status_tail; scripts/docker/lib.sh and scripts/k8s/lib.sh).
# The backend is AIDC_GIT_BACKEND (cmd-git.sh sets it), else the default every command uses.

# shellcheck source=../lib/git-common.sh
. "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}/lib/git-common.sh"
if [ -z "${AIDC_GIT_BACKEND:-}" ]; then AIDC_GIT_BACKEND=$(aidc_default_backend) || exit 2; fi
if [ "$AIDC_GIT_BACKEND" = docker ]; then
    # shellcheck source=../docker/lib.sh
    . "$AIDC_SCRIPTS/docker/lib.sh"
elif [ "$AIDC_GIT_BACKEND" = kubernetes ]; then
    # shellcheck source=../k8s/lib.sh
    . "$AIDC_SCRIPTS/k8s/lib.sh"
else
    printf '[aidc] error: unknown backend: %s; the backends are docker and kubernetes\n' "$AIDC_GIT_BACKEND" >&2; exit 2
fi
# --help on any verb: the one help text.
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
