#!/usr/bin/env bash
# tarball-audit-extracted.sh <path-to-downloaded-tarball.tar.gz>
#
# Audit the ACTUAL contents of the downloaded release tarball (via `tar tzf`, no
# extraction). This is the second of the two required release gates: it defends
# against `.gitattributes` export-subst / export-ignore configs that make the
# archive diverge from the git tree that tarball-audit.sh checks.
#
# Any forbidden path exits non-zero and aborts the release.
set -euo pipefail

TARBALL="${1:-}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "::error::usage: tarball-audit-extracted.sh <tarball.tar.gz>" >&2
    exit 2
fi

# GNU tar guard: BSD tar's `tzf` symlink formatting differs and would mis-audit.
# The release workflow runs on ubuntu-latest (GNU tar); fail loudly if not.
if ! tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar'; then
    echo "::error::tarball-audit-extracted.sh requires GNU tar (the workflow runs on ubuntu-latest); refusing to run under a different tar implementation" >&2
    exit 2
fi

# Same patterns as tarball-audit.sh (paths here carry the top-level
# aidc-<version>/ prefix, which the (^|/) anchors tolerate).
FORBIDDEN='(^|/)tests/scratch/|(^|/)audit/|\.env$|\.env\.[^/]*$|(^|/)\.envrc$|\.pem$|\.key$|(^|/)id_rsa|(^|/)id_ed25519|\.p12$|\.pfx$'
ALLOW='(^|/)proxy/audit/|(^|/)tests/scratch/\.gitkeep$'

contents="$(tar tzf "$TARBALL")"
# Drop directory entries first (GNU tar lists a dir with a trailing slash). A
# forbidden pattern like tests/scratch/ matches the empty tracked-dir entry
# itself, which carries no data and is not a forbidden FILE — its only tracked
# child, .gitkeep, is explicitly allowed. Any real file UNDER a forbidden dir
# does not end in "/", so it still gets caught by the FORBIDDEN check below.
matches="$(printf '%s\n' "$contents" | grep -v '/$' | grep -E "$FORBIDDEN" | grep -vE "$ALLOW" || true)"

if [ -n "$matches" ]; then
    echo "::error::release aborted -- forbidden files present in the tarball:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    exit 1
fi
echo "tarball-audit (extracted): OK"
