#!/usr/bin/env bash
# Copy-forward transcript mirror (design-09, MCP-15). Sourced by user-main.sh
# INSIDE the dev container, and sourced directly by
# tests/unit/test-transcript-mirror.sh on the host -- one function, two
# callers, so the test exercises the exact code that ships, not a re-implemented
# copy that could drift from production behavior.
#
# Copies Claude's JSONL transcripts into the MCP-readable audit volume so the
# MCP server can deliver completed turns by direct file read. Regular
# top-level session files only (no symlink deref, no subagents/ recursion).
#
# Each file is copied via temp-file + rename, NOT `cp` straight into the
# destination name. `cp` writes the destination in place; on a multi-MB
# transcript the MCP server can open and read it mid-write and see a
# torn/truncated copy. `mv` within the same directory is a same-filesystem
# rename, which POSIX guarantees is atomic -- a reader always sees either the
# complete old file or the complete new one, never a partial one. (Prod
# incident 2026-07-18: a torn in-place copy raced the MCP server's reconnect
# re-anchor and caused a duplicate-delivery burst to the orchestrator; see
# docs/done/design-09-callback-delivery.md and mcp/src/aidc_mcp/tools.py's
# _baseline_watermark, which now also refuses to act on a torn read as
# defense in depth -- this function removes the torn read at the source.)

# One pass over every *.jsonl in $1, copy-forwarding changed files into $2.
# Args: src_dir dest_dir
aidc_mirror_copy_forward_pass() {
    local _src="$1" _dest_dir="$2" f _base _dest _tmp
    for f in "${_src}"/*.jsonl; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        _base=$(basename "$f")
        _dest="${_dest_dir}/${_base}"
        # cp -u equivalent: skip the copy (and the mtime churn a reader could
        # race) when the destination is already current.
        [ -e "$_dest" ] && [ ! "$f" -nt "$_dest" ] && continue
        _tmp="${_dest_dir}/.${_base}.$$.tmp"
        cp -p -- "$f" "$_tmp" 2>/dev/null && mv -f -- "$_tmp" "$_dest" 2>/dev/null
        rm -f -- "$_tmp" 2>/dev/null   # in case cp/mv failed partway
    done
}
