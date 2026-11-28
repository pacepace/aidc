#!/usr/bin/env bash
# Sourced by every unit test that runs the aidc CLI or a script under scripts/, or that stubs
# docker or kubectl (.claude/rules/learnings/core.md, "Tests and the real host"): docker and
# kubectl first on PATH are stubs, and the test refuses to run unless `command -v` finds them.
# A real docker or kubectl left on PATH is harmless only while the code it reaches does nothing;
# once that code does real work, a test builds images and starts containers on the owner's host
# (2026-11-28). test-stub-tools-guard.sh fails any test that should use this and does not.
#
#   stub_tools <dir>
#       Makes <dir>, puts a stub there for each of docker and kubectl the test has not written
#       itself (one that does nothing, says what it was asked, and fails), puts <dir> first on
#       PATH, and exits the test, failing, unless `command -v docker` and `command -v kubectl`
#       are the files in <dir>. A test writes its own stubs into <dir>, before or after.
#   stub_tools_check
#       The same check again (after a test changed PATH): exits the test, failing, unless both
#       still resolve to stubs in the dir stub_tools was given.
#
# What is here must not need anything from the test (sourced before its own helpers).

STUB_TOOLS_NAMES="docker kubectl"

stub_tools() {
    local dir="${1:?stub_tools: no directory}" t
    mkdir -p -- "$dir" || { echo "FAIL: stub_tools: cannot make ${dir}; refusing to run"; exit 1; }
    dir=$(cd -- "$dir" && pwd -P) || { echo "FAIL: stub_tools: cannot enter ${dir}; refusing to run"; exit 1; }
    for t in $STUB_TOOLS_NAMES; do
        [ -e "${dir}/${t}" ] && continue
        printf '#!/bin/sh\necho "%s stub (tests/unit/lib/stub-tools.sh): not expected here: $*" >&2\nexit 1\n' "$t" > "${dir}/${t}"
        chmod +x "${dir}/${t}"
    done
    STUB_TOOLS_DIR="$dir"
    PATH="${dir}:${PATH}"
    export PATH STUB_TOOLS_DIR
    hash -r 2>/dev/null || true
    stub_tools_check
}

stub_tools_check() {
    local t found
    [ -n "${STUB_TOOLS_DIR:-}" ] || { echo "FAIL: stub_tools_check before stub_tools; refusing to run"; exit 1; }
    hash -r 2>/dev/null || true
    for t in $STUB_TOOLS_NAMES; do
        found=$(command -v "$t" 2>/dev/null || true)
        if [ -n "$found" ]; then
            found=$(cd -- "$(dirname -- "$found")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename -- "$found")") || found="?"
        fi
        if [ "$found" != "${STUB_TOOLS_DIR}/${t}" ] || [ ! -x "$found" ]; then
            echo "FAIL: ${t} is not the test's stub (command -v ${t}: ${found:-none}; want ${STUB_TOOLS_DIR}/${t}); refusing to run"
            exit 1
        fi
    done
}
