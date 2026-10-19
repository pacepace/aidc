#!/usr/bin/env bash
# aidc yq wrapper -- sourced by config.sh and network.sh, each on its own.
#
# yq guesses which argument is its expression: when the first one names a file in
# the current directory, yq reads that file and runs the default expression on it.
# `yq eval .profile config.yaml` run from $HOME therefore printed ~/.profile, and
# `aidc create` rejected it as the profile name. --expression says outright which
# argument is the expression; yq releases older than the flag still get the
# guessing form, which is right whenever no such file is in the way.
#
# Bash 3.2 compatible. Defines no die/err: a sourced library reports its own
# failures (tests/unit/test-lib-self-contained.sh).

# AIDC_NO_YQ=1 hides yq, so the unit tests can run the awk fallbacks on a machine
# that has it (a defect in one parser hid behind the other once).
_aidc_has_yq() { [ "${AIDC_NO_YQ:-}" != 1 ] && command -v yq >/dev/null 2>&1; }

# Whether this yq has --expression, decided once here in the sourcing shell: most
# calls run inside $(...), where an answer cached on first use would be lost. No
# pipe into grep: under pipefail, grep -q exiting early can kill yq with SIGPIPE,
# the check then reads as "no flag", and the guessing form comes back.
_AIDC_YQ_EXPR_FLAG=""
if _aidc_has_yq; then
    case "$(yq eval --help 2>&1)" in
        *--expression*) _AIDC_YQ_EXPR_FLAG="--expression" ;;
    esac
fi

# aidc_yq <expression> [yq args and files...]: `yq eval` with the expression pinned.
aidc_yq() {
    local expr="$1"
    shift
    if [ -n "$_AIDC_YQ_EXPR_FLAG" ]; then
        yq eval --expression "$expr" "$@"
    else
        yq eval "$expr" "$@"
    fi
}
