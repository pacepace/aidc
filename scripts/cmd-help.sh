#!/usr/bin/env bash
# desc: Show this help.
#
# Usage: aidc help
#
# Globs cmd-*.sh in $AIDC_SCRIPTS and prints each subcommand's "# desc:"
# line. Adding a new cmd-foo.sh automatically registers `aidc foo`.

set -euo pipefail

# Source common only for AIDC_SCRIPTS (dispatcher already exports it).
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set; invoke via the aidc dispatcher}"

cat <<EOF
aidc ${AIDC_VERSION:-(unversioned)} - AI Dev Container CLI

Usage:
  aidc <subcommand> [args...]

Subcommands:
EOF

# List subcommands in alphabetical order. Each cmd-*.sh's second line is
# expected to be `# desc: short description`; pull that for the listing.
for script in "$AIDC_SCRIPTS"/cmd-*.sh; do
    [ -f "$script" ] || continue
    name=$(basename "$script" .sh)
    name=${name#cmd-}
    desc=$(sed -n '2{s/^# desc:[[:space:]]*//p;}' "$script")
    [ -z "$desc" ] && desc="(no description)"
    printf '  %-10s  %s\n' "$name" "$desc"
done

cat <<'EOF'

Run `aidc <subcommand> --help` for details on a specific subcommand (where
supported), or read docs/done/design-05-cli.md.
EOF
