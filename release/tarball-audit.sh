#!/usr/bin/env bash
# tarball-audit.sh -- audit the GIT TREE of the checked-out (tagged) commit for
# files that must never ship in a release. Run by .github/workflows/release.yml
# as a pre-release gate, against the tag's tree (`git ls-tree -r HEAD`), BEFORE
# the GitHub Release is created. Its sibling, tarball-audit-extracted.sh, audits
# the actual downloaded tarball (catching .gitattributes-driven divergence).
#
# Any match exits non-zero and aborts the release.
set -euo pipefail

command -v git >/dev/null 2>&1 || { echo "::error::tarball-audit.sh requires git"; exit 2; }

# Forbidden path patterns (extended regex). Keep in sync with
# tarball-audit-extracted.sh.
#   tests/scratch/*        smoke scratch (repo mounts + audit output)
#   */audit/<session>/     per-session runtime audit dirs
#   .env / *.env / .envrc  env files (credentials)
#   *.pem *.key            private keys
#   id_rsa* id_ed25519*    SSH private keys
#   *.p12 *.pfx            certificate stores
FORBIDDEN='(^|/)tests/scratch/|(^|/)audit/|\.env$|\.env\.[^/]*$|(^|/)\.envrc$|\.pem$|\.key$|(^|/)id_rsa|(^|/)id_ed25519|\.p12$|\.pfx$'

# proxy/audit/ is the audit SIDECAR's build context (aggregate.sh, finalize.sh,
# Dockerfile) -- legitimately committed source, not session data. The
# tests/scratch/.gitkeep placeholder is a tracked directory marker (the scratch
# DATA under it is gitignored), so it is allowed while real scratch files are not.
ALLOW='(^|/)proxy/audit/|(^|/)tests/scratch/\.gitkeep$'

files="$(git ls-tree -r HEAD --name-only)"
matches="$(printf '%s\n' "$files" | grep -E "$FORBIDDEN" | grep -vE "$ALLOW" || true)"

if [ -n "$matches" ]; then
    echo "::error::release aborted -- forbidden files present in the git tree:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    exit 1
fi
echo "tarball-audit (git tree): OK"
