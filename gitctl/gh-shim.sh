#!/bin/sh
# /opt/aidc/bin/gh in the git container, ahead of the real gh on PATH. The GitHub login is
# gitcred's, reached only through gitctl; a `gh auth login` run as the agent would keep a
# second login in the agent's own home, where the agent can read it. So plain gh says where to
# go instead of doing that.
echo "gh: not used directly in the git container; the GitHub login is reached through gitctl:" >&2
echo "  gitctl login | status | pr-create | pr-comment | pr-merge | pr-view | pr-list  (gitctl --help)" >&2
exit 1
