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

# aidc_yq <expression> [yq args and files...]: `yq eval` with the expression pinned.
aidc_yq() {
    local expr="$1"
    shift
    if [ -z "${_AIDC_YQ_EXPR_FLAG+set}" ]; then
        _AIDC_YQ_EXPR_FLAG=""
        if yq eval --help 2>/dev/null | grep -q -- '--expression'; then
            _AIDC_YQ_EXPR_FLAG="--expression"
        fi
    fi
    if [ -n "$_AIDC_YQ_EXPR_FLAG" ]; then
        yq eval --expression "$expr" "$@"
    else
        yq eval "$expr" "$@"
    fi
}
