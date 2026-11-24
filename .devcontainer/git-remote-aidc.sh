#!/bin/sh
# git-remote-aidc: where `git push` to GitHub goes in an aidc session. The image's system git
# config rewrites GitHub push URLs to aidc::<url> (url.<base>.pushInsteadOf), so git runs this
# helper instead of contacting GitHub, which would fail asking for a login before the pre-push
# hook (GIT-05) could say anything. It pushes nothing; it says what to do instead. Fetches are
# not rewritten.
echo "aidc: git push is disabled inside the dev container." >&2
if [ -n "${AIDC_GIT_REQUESTS:-}" ]; then
    echo "aidc: ask the user's git container instead: \`gh pr create\` pushes this branch and opens" >&2
    echo "aidc: the pull request; \`gh aidc push\` only pushes. In ask mode the user approves first." >&2
else
    echo "aidc: review and push from the host machine." >&2
fi
exit 1
