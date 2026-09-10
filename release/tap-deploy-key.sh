#!/usr/bin/env bash
# Create (or rotate) the deploy key the release workflow uses to push rendered
# formulae to the Homebrew tap.
#
#   bash release/tap-deploy-key.sh            # generate, install, store, wipe
#   bash release/tap-deploy-key.sh --status   # show what is installed; change nothing
#
# What it does, in order:
#   1. generates an ed25519 keypair in a private temp dir,
#   2. removes any deploy key of the same title from the tap repo (rotation),
#   3. adds the PUBLIC half to pacepace/homebrew-aidc as a write deploy key,
#   4. stores the PRIVATE half as the TAP_DEPLOY_KEY Actions secret on
#      pacepace/aidc (the name release.yml reads),
#   5. deletes both halves. Only the fingerprint is ever printed.
#
# A deploy key never expires and can only touch the one repo it is added to,
# so there is no rotation calendar: run this again only to rotate on demand,
# and revoke from the tap repo's Settings -> Deploy keys if it is ever
# compromised. Verify a fresh key with a dry-run dispatch of release.yml.
#
# Needs: ssh-keygen, gh (logged in as an admin of both repos).

set -euo pipefail

SRC_REPO="pacepace/aidc"
TAP_REPO="pacepace/homebrew-aidc"
SECRET_NAME="TAP_DEPLOY_KEY"
KEY_TITLE="aidc release workflow"

err()  { printf '[tap-deploy-key] error: %s\n' "$*" >&2; }
info() { printf '[tap-deploy-key] %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { err "need '$1' on PATH"; exit 1; }; }

# Print "<id> <fingerprint>" for every deploy key on the tap with our title.
installed_keys() {
    gh api "repos/${TAP_REPO}/keys" \
        --jq ".[] | select(.title == \"${KEY_TITLE}\") | \"\(.id) \(.key)\"" 2>/dev/null \
        | while read -r id key; do
            printf '%s %s\n' "$id" "$(printf '%s\n' "$key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
          done
}

status() {
    info "tap repo:   ${TAP_REPO}"
    if [ -n "$(installed_keys)" ]; then
        installed_keys | while read -r id fp; do info "deploy key: id=${id} ${fp} (\"${KEY_TITLE}\")"; done
    else
        info "deploy key: none titled \"${KEY_TITLE}\""
    fi
    if gh secret list -R "$SRC_REPO" 2>/dev/null | awk '{print $1}' | grep -qx "$SECRET_NAME"; then
        info "secret:     ${SECRET_NAME} is set on ${SRC_REPO}"
    else
        info "secret:     ${SECRET_NAME} is NOT set on ${SRC_REPO}"
    fi
}

case "${1:-}" in
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --status)  need gh; need ssh-keygen; status; exit 0 ;;
    "")        : ;;
    *)         err "unknown option '$1'"; exit 1 ;;
esac

need ssh-keygen; need gh
gh auth status >/dev/null 2>&1 || { err "gh is not logged in"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/tap-deploy-key.XXXXXX")"
chmod 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

ssh-keygen -q -t ed25519 -N '' -C "${KEY_TITLE} -> ${TAP_REPO}" -f "${tmp}/key"
fp="$(ssh-keygen -lf "${tmp}/key.pub" | awk '{print $2}')"
info "generated ed25519 key ${fp}"

# Rotate: drop any previous key with our title so exactly one is live.
installed_keys | while read -r id old_fp; do
    gh api -X DELETE "repos/${TAP_REPO}/keys/${id}" >/dev/null
    info "removed previous deploy key id=${id} ${old_fp}"
done

gh repo deploy-key add "${tmp}/key.pub" -R "$TAP_REPO" --allow-write -t "$KEY_TITLE" >/dev/null
info "added write deploy key to ${TAP_REPO}"

gh secret set "$SECRET_NAME" -R "$SRC_REPO" < "${tmp}/key"
info "stored private key as secret ${SECRET_NAME} on ${SRC_REPO}"

info "done. verify with: gh workflow run release.yml -R ${SRC_REPO} -f tag=<existing tag>"
