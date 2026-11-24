# shellcheck shell=bash
# The git container's shared pieces on the CLI side, for both backends (docs/design-12-kubernetes.md,
# "Git"): which backend `aidc git` and `aidc repo` talk to, and the helpers that print what the
# git container says. No docker or kubectl here: each backend's scripts call their own.
#
# Defines no die/err: a sourced library reports its own failures (test-lib-self-contained.sh).

# aidc_git_backend: where the user's git container is, "docker" or "kubernetes": the --backend
# flag (the dispatcher passes it as AIDC_BACKEND_FLAG), else the global config's top-level
# `backend:` (as `aidc create` reads it), else kubernetes when the config has a `kubernetes:`
# block, else docker. Returns 1, saying why on stderr, for any other name.
aidc_git_backend() {
    local b="${AIDC_BACKEND_FLAG:-}" cfg="${HOME}/.config/aidc/config.yaml"
    if [ -z "$b" ] && [ -f "$cfg" ]; then
        b=$(sed -n 's/^backend:[[:space:]]*["'"'"']\{0,1\}\([a-z0-9]*\).*/\1/p' "$cfg" 2>/dev/null | head -n1)
        if [ -z "$b" ] && grep -q '^kubernetes:' "$cfg" 2>/dev/null; then b=kubernetes; fi
    fi
    case "${b:-docker}" in
        docker) printf 'docker' ;;
        kubernetes|k8s) printf 'kubernetes' ;;
        *) printf '[aidc] error: unknown backend: %s; the backends are docker and kubernetes\n' "$b" >&2; return 1 ;;
    esac
}

# aidc_printable: stdin to stdout without control characters other than tab and newline (an
# escape sequence, a carriage return, a bell). For text a session can write (folder names,
# branch names, origin URLs) on its way to the user's terminal.
aidc_printable() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}
# aidc_bytes <size>: a Kubernetes-style size (512Mi, 1Gi, 2G, 1500) in bytes; returns 1 when unreadable.
aidc_bytes() {
    local n="${1%%[!0-9]*}" u="${1##*[0-9]}"
    [ -n "$n" ] || return 1
    case "$u" in
        "") echo "$n" ;; Ki) echo $((n * 1024)) ;; Mi) echo $((n * 1024 ** 2)) ;; Gi) echo $((n * 1024 ** 3)) ;;
        Ti) echo $((n * 1024 ** 4)) ;; k|K) echo $((n * 1000)) ;; M) echo $((n * 1000 ** 2)) ;;
        G) echo $((n * 1000 ** 3)) ;; T) echo $((n * 1000 ** 4)) ;; *) return 1 ;;
    esac
}
# aidc_git_print_protection: `gitctl protection` lines on stdin, for the user. Returns 1 when
# something is missing (force pushes or deletion not blocked, merge commits not allowed).
aidc_git_print_protection() {
    local k v repo="" def="" f="" d="" m="" sq="" rb=""
    while read -r k v; do
        case "$k" in repo) repo="$v" ;; default) def="$v" ;; force-push) f="$v" ;; deletion) d="$v" ;;
            merge-commit) m="$v" ;; squash) sq="$v" ;; rebase) rb="$v" ;; esac
    done
    printf 'GitHub protections of %s (default branch %s):\n' "${repo:-?}" "${def:-?}"
    printf '  force pushes:   %s\n  deletion:       %s\n  merge commits:  %s (squash %s, rebase %s)\n' \
        "${f:-unknown}" "${d:-unknown}" "${m:-unknown}" "${sq:-unknown}" "${rb:-unknown}"
    [ "$f" = blocked ] && [ "$d" = blocked ] && [ "$m" = allowed ]
}
# aidc_git_print_tidy: `gitctl tidy` lines on stdin, for the user: what went, then every leftover.
aidc_git_print_tidy() {
    local k v done_="" left=""
    while read -r k v; do
        case "$k" in
            deleted-remote) done_+=$'\n'"  deleted on GitHub: ${v}" ;;
            deleted-branch) done_+=$'\n'"  deleted branch: ${v}" ;;
            removed-worktree) done_+=$'\n'"  removed worktree: ${v}" ;;
            pruned) done_+=$'\n'"  pruned the record of a deleted worktree: ${v}" ;;
            kept-remote) left+=$'\n'"  merged, but GitHub kept it: ${v}" ;;
            unpushed) left+=$'\n'"  unpushed: ${v#* } (${v%% *} commit(s) on no GitHub branch)" ;;
            unmerged) left+=$'\n'"  pushed, not merged yet: ${v}" ;;
            uncommitted) left+=$'\n'"  merged, but its worktree has uncommitted changes: ${v}" ;;
            checked-out) left+=$'\n'"  merged, but the working copy has it checked out: ${v}" ;;
            detached) left+=$'\n'"  worktree on a detached HEAD: ${v}" ;;
            locked) left+=$'\n'"  locked worktree: ${v}" ;;
            orphaned) left+=$'\n'"  orphaned worktree folder (its record is gone): ${v}" ;;
            cannot-delete) left+=$'\n'"  the git container cannot delete: ${v}" ;;
        esac
    done
    printf 'tidied:%s\n' "${done_:- nothing to delete}"
    printf 'left for you:%s\n' "${left:- nothing}"
}
