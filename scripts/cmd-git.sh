#!/usr/bin/env bash
# desc: Your git container on the Kubernetes backend (holds your GitHub login).
#
# Usage: aidc git <setup|login|logout|attach|status|push|pr|merge|tidy|protect|requests|approve|deny|mode>
#
# Sessions in the cluster cannot push; one git container per user does (docs/design-12-kubernetes.md,
# "Git"). Each subcommand is scripts/k8s/git-<name>.sh.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc git <subcommand>

  setup    Start your git container in your namespace of the `kubernetes:` config (after
           `aidc user add`), and its request folder on your disk. It is the only thing that
           pushes, and it keeps your GitHub login where its agent cannot read it. Safe to run
           again; it restarts the container so it runs the image now in the registry.
  login    Log it in to GitHub as you: a one-time code you approve in your browser. Its
           commits then show as you (your GitHub name; your public email, else GitHub's
           noreply address for your account). logout removes both.
  attach   Open its terminal (tmux): its Claude, your git agent, and a shell. Detach with
           Ctrl-b d. The git agent is an aidc session named git: aidc list shows it, aidc
           attach git is the same as this, and aidc kill refuses it.
  status   Whether it is running and logged in, its git mode, waiting requests, its storage.
           Says "unknown" when the cluster or the container cannot be asked.

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
           Your git mode and the sessions given their own. With your mode ask, `rules` lets
           one session's requests run at once (it applies only to that session's own
           requests); `default` takes it back.

<repo> is a working copy's path, on your disk in the cluster or under your home here (as for
aidc repo). Sessions ask with `gh pr create` and `gh pr merge` (a stand-in that writes a request
for the git container); kubernetes.git_mode is ask (default: you approve each) or rules. In
ask mode your git agent asks you about each request with its question tool, so an
orchestrator driving it sees the question as it sees any session's; you can also answer here.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/git-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown git subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
