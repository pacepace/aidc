#!/usr/bin/env bash
# One Claude history per repo across the cluster and the user's machines, with Syncthing
# (K8S-18; docs/design-12-kubernetes.md, "One history per repo, on every machine"). The parts
# both sides run: what is synced (the folder's .stignore), the Mac's alias folders, and the
# lease hooks a machine's own Claude runs. Sourced by cmd-sync.sh and scripts/k8s/sync.sh;
# self-contained (tests/unit/test-lib-self-contained.sh).

# The Syncthing folder id both sides use for the Claude folder (~/.claude on a machine, the
# user's disk's .claude in the cluster).
# shellcheck disable=SC2034  # read by the scripts that source this
AIDC_SYNC_FOLDER_ID="aidc-claude"

# aidc_sync_stignore: the folder's .stignore, the sync set ruled 2026-11-24: projects/
# (conversations and memory), CLAUDE.md, rules/, skills/, agents/, commands/, keybindings.json;
# never credentials, .claude.json or live-process state; never a Mac's alias folders. The first
# pattern that matches decides, so the exclusions come first.
aidc_sync_stignore() {
    cat <<'STIGNORE'
// aidc (K8S-18): what Syncthing carries between your machines and the cluster.
// Written by aidc; the same on every side. Changes here are overwritten.
/projects/-Users-*
(?d).DS_Store
!/projects
!/CLAUDE.md
!/rules
!/skills
!/agents
!/commands
!/keybindings.json
*
STIGNORE
}

# aidc_sync_write_stignore <claude-dir>: the .stignore into <claude-dir> by temp then rename.
# Returns 1, saying why on stderr.
aidc_sync_write_stignore() {
    local dir="$1" tmp
    [ -d "$dir" ] || { printf '[aidc] error: %s is not a folder\n' "$dir" >&2; return 1; }
    tmp=$(mktemp "${dir}/.stignore.XXXXXX") || { printf '[aidc] error: cannot write in %s\n' "$dir" >&2; return 1; }
    if aidc_sync_stignore > "$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "${dir}/.stignore"; then
        return 0
    fi
    rm -f -- "$tmp"
    printf '[aidc] error: cannot write %s/.stignore\n' "$dir" >&2
    return 1
}

# aidc_claude_encode <path>: the name Claude Code gives a path's history folder (every character
# outside [A-Za-z0-9] a dash).
aidc_claude_encode() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g'
}

# aidc_sync_reconcile <projects-dir> <this-home> <linux-home>: on a machine whose home is not
# the cluster's (a Mac's /Users/<name>), history is kept under the Linux name, which is what is
# synced: each <linux-home>-named folder gets an alias, a symlink named for this home, so
# Claude here appends to the same transcripts and finds the same memory; a folder Claude made
# here under this home's name with no Linux one yet is moved to the Linux name and aliased.
# Dangling aliases are removed. Never touches a folder both names have (said, left alone).
# Prints one line per change.
aidc_sync_reconcile() {
    local projects="$1" here linux d name rest target alias
    here=$(aidc_claude_encode "$2") linux=$(aidc_claude_encode "$3")
    [ -d "$projects" ] || return 0
    [ "$here" != "$linux" ] || return 0
    for d in "$projects"/"$here" "$projects"/"$here"-*; do
        [ -e "$d" ] || [ -L "$d" ] || continue
        name=$(basename -- "$d") rest="${name#"$here"}"
        target="${projects}/${linux}${rest}"
        if [ -L "$d" ]; then
            [ -e "$d" ] || { rm -f -- "$d" && printf 'removed the alias %s (its folder is gone)\n' "$name"; }
            continue
        fi
        if [ -e "$target" ]; then
            printf 'left %s as it is: %s exists too (move what you want to keep into it, then remove %s)\n' "$name" "${linux}${rest}" "$name" >&2
            continue
        fi
        mv -- "$d" "$target" && ln -s -- "${linux}${rest}" "$d" \
            && printf 'moved %s to %s (synced), with an alias\n' "$name" "${linux}${rest}"
    done
    for d in "$projects"/"$linux" "$projects"/"$linux"-*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        name=$(basename -- "$d") rest="${name#"$linux"}"
        alias="${projects}/${here}${rest}"
        [ -e "$alias" ] || [ -L "$alias" ] && continue
        ln -s -- "$name" "$alias" && printf 'aliased %s as %s\n' "$name" "${here}${rest}"
    done
}

# aidc_sync_strip_links <projects-dir>: symlinks inside the conversations' folders removed (a
# synced symlink points at whatever its path is on the receiving machine: #35). The aliases
# at the top of projects/ are not inside a folder and stay.
aidc_sync_strip_links() {
    [ -d "$1" ] || return 0
    find "$1" -mindepth 2 -type l -print -delete 2>/dev/null | sed 's/^/removed a synced symlink: /'
}

# aidc_sync_install_hooks <settings.json> <lease-command>: the lease hooks added to a machine's
# own Claude settings (SessionStart, UserPromptSubmit, Stop, SessionEnd), once, keeping
# everything else there. Returns 1, saying why on stderr.
aidc_sync_install_hooks() {
    local f="$1" cmd="$2" cur new tmp
    cur='{}'
    if [ -f "$f" ]; then
        cur=$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) \
            || { printf '[aidc] error: %s is not a JSON object: nothing changed\n' "$f" >&2; return 1; }
    fi
    new=$(printf '%s' "$cur" | jq --arg cmd "$cmd" '
        reduce ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd") as $e (.;
            if any((.hooks[$e] // [])[]?.hooks[]?; .command == $cmd) then .
            else .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [{type: "command", command: $cmd}]}]) end)') \
        || { printf '[aidc] error: cannot add the hooks to %s\n' "$f" >&2; return 1; }
    mkdir -p -- "$(dirname -- "$f")" || return 1
    tmp=$(mktemp "$(dirname -- "$f")/.settings.json.XXXXXX") || return 1
    if printf '%s\n' "$new" > "$tmp" && mv -f -- "$tmp" "$f"; then
        return 0
    fi
    rm -f -- "$tmp"
    printf '[aidc] error: cannot write %s\n' "$f" >&2
    return 1
}
