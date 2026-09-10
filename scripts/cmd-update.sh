#!/usr/bin/env bash
# desc: Update the aidc CLI itself (installer, Homebrew, or git checkout).
#
# Usage: aidc update [--check] [--version vX.Y.Z]
#
# Detects how this copy of aidc was installed and runs the matching update:
#
#   installer   re-runs the latest release's install.sh (the README's curl
#               one-liner). Installs alongside the old version and flips the
#               ~/.local/bin/aidc symlink; the old dir stays for rollback.
#   brew        `brew upgrade aidc`
#   git         `git pull --ff-only` in the checkout
#
# This updates the CLI only. Container images are built from the CLI's tree,
# so follow with `aidc rebuild`, then `aidc upgrade <session>` per session.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/update.sh
. "$AIDC_SCRIPTS/lib/update.sh"

REPO="pacepace/aidc"
INSTALLER_URL="https://github.com/${REPO}/releases/latest/download/install.sh"

CHECK=0
WANT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<'HELP'
aidc update [--check] [--version vX.Y.Z]

Update the aidc CLI to the latest release, using whichever method installed
this copy (install.sh, Homebrew, or a git checkout).

  --check            report the installed and latest versions; change nothing
  --version vX.Y.Z   install that release instead of the latest (installer
                     installs only)

Images are built from the CLI's tree, so after updating run `aidc rebuild`,
then `aidc upgrade <session>` for each running session.
HELP
            exit 0 ;;
        --check) CHECK=1; shift ;;
        --version)
            [ $# -ge 2 ] || die "--version needs an argument"
            WANT="$2"; shift 2 ;;
        *) die "unknown option '$1' (see aidc update --help)" ;;
    esac
done

KIND="$(aidc_install_kind "$AIDC_ROOT")"
CURRENT="${AIDC_VERSION:-$(head -n1 "${AIDC_ROOT}/VERSION")}"
LATEST="$(aidc_latest_release_tag "$REPO" || true)"

info "installed: aidc ${CURRENT} (${KIND}: ${AIDC_ROOT})"
if [ -n "$LATEST" ]; then
    info "latest:    aidc ${LATEST}"
else
    info "latest:    (could not reach the GitHub releases API)"
fi

if [ "$CHECK" = 1 ]; then
    [ -n "$LATEST" ] || exit 1
    case "$(aidc_semver_cmp "$CURRENT" "$LATEST")" in
        -1) info "update available: run \`aidc update\`"; exit 0 ;;
        *)  info "up to date"; exit 0 ;;
    esac
fi

if [ -n "$WANT" ] && [ "$KIND" != installer ]; then
    die "--version applies to installer-managed copies only (this one is ${KIND})"
fi

if [ -z "$WANT" ] && [ -n "$LATEST" ] && [ "$KIND" != git ]; then
    if [ "$(aidc_semver_cmp "$CURRENT" "$LATEST")" != "-1" ]; then
        info "already up to date"
        exit 0
    fi
fi

case "$KIND" in
    installer)
        require_cmd curl
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/aidc-update.XXXXXX")"
        trap 'rm -rf "$tmp"' EXIT
        info "fetching ${INSTALLER_URL}"
        curl -fsSL -o "${tmp}/install.sh" "$INSTALLER_URL" \
            || die "could not download install.sh"
        if [ -n "$WANT" ]; then
            bash "${tmp}/install.sh" --version "$WANT"
        else
            bash "${tmp}/install.sh"
        fi
        ;;
    brew)
        require_cmd brew
        formula="$(aidc_brew_formula "$AIDC_ROOT")"
        info "running: brew upgrade ${formula}"
        brew upgrade "$formula"
        ;;
    git)
        require_cmd git
        if [ -n "$(git -C "$AIDC_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            die "checkout at ${AIDC_ROOT} has uncommitted changes; commit or stash them, then re-run"
        fi
        info "running: git pull --ff-only in ${AIDC_ROOT}"
        git -C "$AIDC_ROOT" pull --ff-only \
            || die "fast-forward pull failed; resolve it in ${AIDC_ROOT} by hand"
        ;;
    *)
        die "cannot tell how aidc was installed at ${AIDC_ROOT}; update it the way you installed it (see README)"
        ;;
esac

info "CLI updated. Images are built from the CLI's tree, so next:"
info "  aidc rebuild                 # bake images at the new version"
info "  aidc upgrade <session>       # per running session"
