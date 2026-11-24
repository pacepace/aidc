#!/usr/bin/env bash
# aidc system pre-push hook (GIT-05): blocks all push attempts inside the
# dev container. There is no environment toggle to bypass this from inside
# the container. On the Kubernetes backend the user's git container pushes
# (AIDC_GIT_REQUESTS is its request folder): gh asks it.
echo "aidc: git push is disabled inside the dev container." >&2
if [ -n "${AIDC_GIT_REQUESTS:-}" ]; then
    echo "aidc: ask the user's git container instead: \`gh pr create\` pushes this branch and opens" >&2
    echo "aidc: the pull request; \`gh aidc push\` only pushes. In ask mode the user approves first." >&2
else
    echo "aidc: review and push from the host machine." >&2
fi
exit 1
