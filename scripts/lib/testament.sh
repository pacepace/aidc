# shellcheck shell=bash
# testament in aidc sessions (K8S-25): the test runner's newest release, built on this machine.
#
# testament's repo is private for now, so installing it is optional (owner rulings 2026-11-24):
# only when the user's config names the repo (`testament: {repo: <ssh url>}`), fetched with the
# user's own SSH key (git over ssh, never gh, no token), at its newest vX.Y.Z tag, built into a
# wheel here (uv build) and cached per tag. The wheel goes into the dev image's build context
# (aidc rebuild, a first create, aidc k8s build) and, on `aidc upgrade`, into the running
# session. No key or token enters an image or a session: only the wheel does. Integrity rests on
# the SSH-authenticated fetch of the tag's commit.
#
# Missing config, no access, no uv: one line on stderr, and the build or upgrade goes on
# without testament. Nothing here fails a caller.
#
# Sourced after config.sh. Reports with printf to stderr and return codes only (a helper from
# another library may not be there: .claude/rules/learnings/shell-libraries.md). Runs no docker
# and no kubectl: the backends hand aidc_testament_install their own copy and exec.

_aidc_testament_note() { printf '[aidc] testament: %s\n' "$*" >&2; }

# aidc_testament_repo: the configured repo, "" when none.
aidc_testament_repo() {
    local cfg v=""
    cfg=$(_aidc_global_config_file)
    [ -n "$cfg" ] || return 0
    if _aidc_has_yq; then
        v=$(aidc_yq '.testament.repo // ""' "$cfg" 2>/dev/null || true)
    fi
    [ -n "$v" ] || v=$(_aidc_yaml_nested "$cfg" testament repo)
    printf '%s' "$v"
}

# _aidc_testament_run <seconds> <cmd...>: the command, ended after <seconds> where timeout(1)
# exists (it does not on stock macOS; there git's own ssh ConnectTimeout bounds the wait).
_aidc_testament_run() {
    local t="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}

# aidc_testament_newest_tag <repo>: the newest vX.Y.Z tag (numeric order), or returns 1.
aidc_testament_newest_tag() {
    local refs
    refs=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}" \
        _aidc_testament_run 60 git ls-remote --tags --refs -- "$1" 2>/dev/null) || return 1
    printf '%s\n' "$refs" | awk '{ sub("^refs/tags/", "", $2); print $2 }' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 | sed 's/^/v/' | grep .
}

# aidc_testament_wheel: the newest release's wheel, its path on stdout; returns 1 (with one line
# on stderr saying why) when there is none to install.
aidc_testament_wheel() {
    local repo tag cache dir work w
    repo=$(aidc_testament_repo)
    if [ -z "$repo" ]; then
        _aidc_testament_note "not configured (testament.repo in your aidc config); going on without it"
        return 1
    fi
    # The user's SSH key fetches it: an ssh URL only (an https one would reach for a token).
    case "$repo" in
        -*|*[[:space:]]*) _aidc_testament_note "testament.repo is not a git ssh URL; going on without it"; return 1 ;;
        ssh://?*|[A-Za-z0-9._-]*@?*:?*) ;;
        *) _aidc_testament_note "testament.repo must be an ssh URL (git@host:owner/name.git or ssh://...); going on without it"; return 1 ;;
    esac
    if ! tag=$(aidc_testament_newest_tag "$repo"); then
        _aidc_testament_note "cannot read its release tags with your SSH key (no access?); going on without it"
        return 1
    fi
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/aidc/testament"
    dir="${cache}/${tag}"
    w=$(find "$dir" -maxdepth 1 -type f -name 'testament-*.whl' 2>/dev/null | head -n1)
    if [ -n "$w" ]; then
        printf '%s\n' "$w"
        return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
        _aidc_testament_note "${tag}: uv is not installed here, so it cannot be built; going on without it"
        return 1
    fi
    mkdir -p "$cache" || { _aidc_testament_note "cannot make ${cache}; going on without it"; return 1; }
    work=$(mktemp -d "${cache}/.build.XXXXXX") || { _aidc_testament_note "cannot make a build folder; going on without it"; return 1; }
    if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}" \
            _aidc_testament_run 300 git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" -- "$repo" "${work}/src" >/dev/null 2>&1; then
        rm -rf "$work"; _aidc_testament_note "cannot fetch ${tag}; going on without it"; return 1
    fi
    if ! _aidc_testament_run 600 uv build -q --wheel --out-dir "${work}/dist" "${work}/src" >/dev/null 2>&1; then
        rm -rf "$work"; _aidc_testament_note "${tag} did not build into a wheel; going on without it"; return 1
    fi
    w=$(find "${work}/dist" -maxdepth 1 -type f -name 'testament-*.whl' | head -n1)
    if [ -z "$w" ]; then
        rm -rf "$work"; _aidc_testament_note "${tag} built no testament wheel; going on without it"; return 1
    fi
    rm -rf "$dir"; mkdir -p "$dir" && mv -f "$w" "$dir/" || { rm -rf "$work"; _aidc_testament_note "cannot cache the wheel; going on without it"; return 1; }
    rm -rf "$work"
    printf '%s/%s\n' "$dir" "${w##*/}"
}

# aidc_testament_version <wheel>: the version in a wheel's file name (testament-<v>-...whl).
aidc_testament_version() {
    local n="${1##*/}"
    n="${n#testament-}"
    printf '%s' "${n%%-*}"
}

# aidc_testament_stage <context> <stage>: <stage> becomes a copy of the dev image's build context
# <context> with testament/ holding the newest wheel, or nothing (the image then has no
# testament). Returns 1 only when the copy itself fails.
aidc_testament_stage() {
    local ctx="$1" stage="$2" w
    mkdir -p "$stage" && cp -R "${ctx}/." "$stage/" || {
        printf '[aidc] error: cannot copy %s to a build folder\n' "$ctx" >&2; return 1; }
    mkdir -p "${stage}/testament" && find "${stage}/testament" -maxdepth 1 -name '*.whl' -exec rm -f {} + || return 1
    if w=$(aidc_testament_wheel); then
        cp "$w" "${stage}/testament/" || { _aidc_testament_note "cannot stage the wheel; going on without it"; return 0; }
        _aidc_testament_note "$(aidc_testament_version "$w") goes into the image"
    fi
    return 0
}

# aidc_testament_install <copy-fn> <exec-fn>: put the newest release into a running session, in
# its user's home (it survives restarts there; a login shell finds it first). <copy-fn> SRC DEST
# copies a file into the session; <exec-fn> CMD... runs a command in it as the session user.
# Both are the backend's. Says what it did in one line; never fails the caller.
aidc_testament_install() {
    local copy="$1" run="$2" w v have dest
    w=$(aidc_testament_wheel) || return 0
    v=$(aidc_testament_version "$w")
    have=$("$run" sh -c 'PATH="$HOME/.local/bin:$PATH" testament --version 2>/dev/null' </dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [ "$have" = "$v" ]; then
        _aidc_testament_note "${v} is already in the session"
        return 0
    fi
    dest="/tmp/${w##*/}"
    if ! "$copy" "$w" "$dest"; then
        _aidc_testament_note "cannot copy ${v} into the session; it keeps ${have:-none}"
        return 0
    fi
    # shellcheck disable=SC2016  # expanded by the session's shell
    if "$run" sh -c 'uv tool install -q --force --python /usr/bin/python3 "$1" >/dev/null 2>&1; rc=$?; rm -f "$1" 2>/dev/null; exit $rc' sh "$dest" </dev/null; then
        _aidc_testament_note "${v} installed in the session (was ${have:-none})"
    else
        _aidc_testament_note "${v} did not install in the session; it keeps ${have:-none}"
    fi
    return 0
}
