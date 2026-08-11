#!/usr/bin/env bash
# aidc system pre-push hook (GIT-05): blocks all push attempts inside the
# dev container. There is no environment toggle to bypass this from inside
# the container -- review and push from the host machine.
echo "aidc: git push is disabled inside the dev container." >&2
echo "aidc: review and push from the host machine." >&2
exit 1
