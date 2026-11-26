#!/usr/bin/env bash
# One Claude history per repo across the cluster and the user's machines, with Syncthing
# (K8S-18; docs/design-12-kubernetes.md, "One history per repo, on every machine"). The parts
# both sides run: what is synced (the folder's .stignore), the Mac's alias folders, and the
# lease hooks a machine's own Claude runs. Sourced by cmd-sync.sh and scripts/k8s/sync.sh;
# self-contained (tests/unit/test-lib-self-contained.sh).

# Two Syncthing folders, each side the same (docs/design-12-kubernetes.md, "One history per
# repo"):
#   aidc-claude-projects  conversations and memory (~/.claude/projects on a machine, the user's
#                         disk's .claude/projects in the cluster): both ways, under the lease
#   aidc-claude-shared    CLAUDE.md, rules/, skills/, agents/, commands/, keybindings.json: from
#                         the user's machines to the cluster only (a machine's folder is ~/.claude,
#                         Send Only; the cluster's .claude-shared, Receive Only, which sessions
#                         mount read-only). These files are instructions and code a Claude loads;
#                         a sandboxed session must never write what an unsandboxed one on a
#                         machine loads (the 2026-11-24 ruling's reason for settings.json, which
#                         holds for all of them).
# shellcheck disable=SC2034  # read by the scripts that source this
AIDC_SYNC_PROJECTS_ID="aidc-claude-projects"
# shellcheck disable=SC2034  # read by the scripts that source this
AIDC_SYNC_SHARED_ID="aidc-claude-shared"

# aidc_sync_stignore_projects: the projects folder's .stignore: everything but a Mac's alias
# folders (each machine's own) and Finder litter. The first pattern that matches decides.
aidc_sync_stignore_projects() {
    cat <<'STIGNORE'
// aidc (K8S-18): conversations and memory, both ways. Written by aidc; the same on every side.
/-Users-*
(?d).DS_Store
STIGNORE
}

# aidc_sync_stignore_shared: the shared folder's .stignore: the ruled set (2026-11-24) let in,
# everything else of ~/.claude left out (projects/ is its own folder; never credentials,
# .claude.json or live state; settings.json and the status line go by aidc sync push-settings).
aidc_sync_stignore_shared() {
    cat <<'STIGNORE'
// aidc (K8S-18): your Claude files, from your machines to the cluster only. Written by aidc.
(?d).DS_Store
!/CLAUDE.md
!/rules
!/skills
!/agents
!/commands
!/keybindings.json
*
STIGNORE
}

# aidc_sync_write_ignore <dir> <projects|shared>: that folder's .stignore into <dir> by temp then
# rename. Returns 1, saying why on stderr.
aidc_sync_write_ignore() {
    local dir="$1" kind="$2" tmp
    [ -d "$dir" ] || { printf '[aidc] error: %s is not a folder\n' "$dir" >&2; return 1; }
    tmp=$(mktemp "${dir}/.stignore.XXXXXX") || { printf '[aidc] error: cannot write in %s\n' "$dir" >&2; return 1; }
    if "aidc_sync_stignore_${kind}" > "$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "${dir}/.stignore"; then
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

# The stable commands aidc's hooks on a machine run: the `aidc` on PATH, never a versioned
# install path (an update or a prune would leave a hook naming a folder that is gone). An entry
# that names one of these, or an older install path of either, is aidc's own: a re-run
# replaces it rather than adding another.
AIDC_SYNC_LEASE_HOOK="aidc sync lease-hook"
AIDC_SYNC_RECONCILE_HOOK="aidc sync reconcile --hook"
AIDC_SYNC_HOOK_MARK='claude-lease[.]sh|aidc sync (lease-hook|reconcile)'

# aidc_sync_install_hooks <settings.json> <lease|reconcile>: aidc's hook added to a machine's own
# Claude settings, keeping everything else there: the lease at SessionStart, UserPromptSubmit,
# PostToolUse (a long turn keeps it), Stop and SessionEnd; the reconciler at SessionStart. Any
# earlier entry of aidc's for the same events is replaced. Returns 1, saying why on stderr.
aidc_sync_install_hooks() {
    local f="$1" kind="$2" cur new tmp cmd events
    case "$kind" in
        lease) cmd="$AIDC_SYNC_LEASE_HOOK"; events='["SessionStart","UserPromptSubmit","PostToolUse","Stop","SessionEnd"]' ;;
        reconcile) cmd="$AIDC_SYNC_RECONCILE_HOOK"; events='["SessionStart"]' ;;
        *) printf '[aidc] error: no hook %s\n' "$kind" >&2; return 1 ;;
    esac
    cur='{}'
    if [ -f "$f" ]; then
        cur=$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) \
            || { printf '[aidc] error: %s is not a JSON object: nothing changed\n' "$f" >&2; return 1; }
    fi
    new=$(printf '%s' "$cur" | jq --arg cmd "$cmd" --arg kind "$kind" --arg mark "$AIDC_SYNC_HOOK_MARK" --argjson events "$events" '
        def ours: any(.hooks[]?; (.command // "") | test($mark)
                      and (if $kind == "lease" then test("reconcile") | not else test("reconcile") end));
        reduce $events[] as $e (.;
            .hooks[$e] = ([(.hooks[$e] // [])[] | select(ours | not)]
                          + [{hooks: [{type: "command", command: $cmd}]}]))') \
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
