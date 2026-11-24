#!/usr/bin/env bash
# desc: Your git container (holds your GitHub login; pushes and opens PRs for sessions).
#
# Usage: aidc git <setup|login|logout|attach|status|log|push|pr|merge|tidy|protect|requests|approve|deny|mode>
#
# Sessions cannot push; one git container per user does, on either backend, with one design
# (docs/design-12-kubernetes.md, "Git"). Each subcommand is one script, scripts/git/git-<name>.sh,
# for both backends: it reaches the git container through its backend's small interface (the
# gb_* functions of scripts/docker/lib.sh and scripts/k8s/lib.sh). Only setup, which makes the
# container, is per backend (scripts/<backend>/git-setup.sh). The backend is the one every
# command defaults to (lib/git-common.sh, aidc_default_backend: --backend, the config's
# top-level backend:, else Docker).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc git <subcommand>

  setup    Start your git container: in a cluster, in your namespace of the `kubernetes:`
           config (after `aidc user add`); on Docker, beside your sessions (container
           aidc-git-dev, behind its own proxy that reaches public addresses only). Also its
           request folder, which sessions hand requests to. It is the only thing that
           pushes, and it keeps your GitHub login where its agent cannot read it. Safe to run
           again; it restarts the container so it runs the current image.
  login    Log it in to GitHub as you: a one-time code you approve in your browser. Its
           commits then show as you (your GitHub name; your public email, else GitHub's
           noreply address for your account). logout removes both.
  attach   Open its terminal (tmux): its Claude, your git agent, and a shell. Detach with
           Ctrl-b d. The git agent is an aidc session named git: aidc list shows it, aidc
           attach git is the same as this, and aidc kill refuses it.
  status   Whether it is running and logged in, its git mode, waiting requests, its storage.
           Says "unknown" when the cluster or the container cannot be asked, and why the
           request watcher cannot take requests when it cannot.
  log [<lines>]
           What the git container changed on GitHub (pushes, pull requests opened, merged and
           commented on, branches deleted, protections added): time, repo, branch or PR,
           commit, and who asked (a session's request id, or direct). Kept by the users that
           hold the login, where its agent cannot change it; capped, the oldest dropped.

  push <repo> <branch>
           Push a branch of a working copy on your disk (fast-forward only; never main,
           master or develop; commits with AI attribution refused).
  pr <repo> <branch> [--base B] --title T --body-file F
           Push the branch and open a pull request (base: origin's default branch).
  merge <repo> <pr-number>
           Merge a pull request, always with a merge commit, then tidy the repo.
  tidy [<repo>]
           Delete merged branches (on GitHub and here) and their clean worktrees; list
           every leftover (unmerged, unpushed, uncommitted, orphaned folders) for you.
  protect <repo>
           Show GitHub's protections of the default branch; with your yes, turn missing
           ones on (no force pushes, no deletion, merge commits allowed). Never turns any off.

  requests [<id>]   Sessions' requests waiting for your approval (git mode ask), or one of them.
  approve <id>      Run a waiting request.
  deny <id> [why]   Refuse it; the session is told why.
  mode [<session> <rules|ask|default>]
           Your git mode and the sessions given their own, both ways: with your mode ask,
           `rules` lets one session's requests run at once; with your mode rules, `ask` holds
           one session's requests for your approval; `default` gives it your mode again. It is
           keyed on the session's own token (made by aidc create), so it applies to that
           session's requests only; a request without its session's token always waits for
           you. aidc kill drops a session's mode; a session made again starts at yours.

<repo> is a working copy's path, on your disk in the cluster or under your home here (as for
aidc repo; on Docker, one you added with aidc repo add, or a worktree inside it). Sessions ask
with `gh pr create` and `gh pr merge` (a stand-in that writes a request for the git container);
the mode (kubernetes.git_mode in a cluster, git.mode on Docker) is ask (default: you approve
each) or rules. In
ask mode your git agent asks you about each request with its question tool, so an
orchestrator driving it sees the question as it sees any session's; you can also answer here.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
# shellcheck source=lib/git-common.sh
. "$AIDC_SCRIPTS/lib/git-common.sh"
BACKEND_DIR=k8s
AIDC_GIT_BACKEND=$(aidc_default_backend) || exit 2
case "$AIDC_GIT_BACKEND" in
    kubernetes) ;;
    docker) BACKEND_DIR=docker ;;
esac
export AIDC_GIT_BACKEND
case "$SUB" in
    setup) SCRIPT="$AIDC_SCRIPTS/${BACKEND_DIR}/git-setup.sh" ;;
    *[!a-z]*|"") SCRIPT="" ;;
    *) SCRIPT="$AIDC_SCRIPTS/git/git-${SUB}.sh" ;;
esac
if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown git subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
