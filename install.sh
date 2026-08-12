#!/usr/bin/env bash
# aidc installer -- download a release, verify it, symlink the CLI.
#
#   curl -fsSL https://github.com/pacepace/aidc/releases/latest/download/install.sh | bash
#   ... | bash -s -- --version v1.0.0     # pin a version
#   bash install.sh --list                # show installable versions
#   bash install.sh --prune               # remove non-current installed versions
#
# What it does, in order:
#   1. resolves the requested tag (default: latest release),
#   2. downloads that tag's source tarball from GitHub,
#   3. verifies its sha256 against the checksum published in the Homebrew tap
#      (pacepace/homebrew-aidc) -- hard abort on mismatch or no published sum,
#   4. extracts to ~/.local/share/aidc/aidc-<version>/,
#   5. symlinks ~/.local/bin/aidc to it.
# Upgrading re-runs the same flow and flips the symlink; the previous version
# dir stays on disk for instant rollback until you --prune it.
#
# The whole script is functions; `main "$@"` is the last line, so a truncated
# download parses to a no-op instead of executing half an installer.
#
# Must stay bash-3.2 compatible (macOS /bin/bash), like the aidc CLI itself.

set -euo pipefail

REPO="pacepace/aidc"
TAP_RAW="https://raw.githubusercontent.com/pacepace/homebrew-aidc/main/Formula"
SHARE_DIR="${HOME}/.local/share/aidc"
BIN_DIR="${HOME}/.local/bin"

err()  { printf 'install.sh: error: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
aidc installer

Usage:
  install.sh [--version vX.Y.Z]   install (default: latest release)
  install.sh --list               list installable release versions
  install.sh --prune              remove installed versions other than current
  install.sh --help               this text
EOF
}

need() {
    command -v "$1" >/dev/null 2>&1 || { err "'$1' is required to install aidc"; exit 1; }
}

sha256_of() { # file
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Print the tag of the latest GitHub release.
latest_tag() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/'
}

list_tags() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=30" \
        | grep '"tag_name"' | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/  \1/'
}

# Print the sha256 the tap publishes for $1 (a tag), or nothing if the tap has
# no formula pinning exactly that tag.
published_sha256() { # tag
    tag="$1"
    major_minor="$(printf '%s' "$tag" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')"
    for formula in "aidc.rb" "aidc@${major_minor}.rb"; do
        body="$(curl -fsSL "${TAP_RAW}/${formula}" 2>/dev/null || true)"
        [ -n "$body" ] || continue
        formula_tag="$(printf '%s\n' "$body" | grep -m1 'archive/refs/tags/' \
            | sed 's|.*tags/\(v[^"]*\)\.tar\.gz.*|\1|')"
        if [ "$formula_tag" = "$tag" ]; then
            printf '%s\n' "$body" | grep -m1 '^  sha256 ' \
                | sed 's/.*"\([0-9a-f]\{64\}\)".*/\1/'
            return 0
        fi
    done
    return 0
}

check_runtime_deps() {
    # Not needed to install, but aidc won't run without them -- warn now, while
    # the user is already in setup mode, instead of failing later mid-create.
    command -v docker >/dev/null 2>&1 \
        || info "note: 'docker' not found -- aidc needs Docker (with the 'docker compose' v2 plugin) to run."
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        info "note: 'docker compose' v2 plugin not found -- install it (bundled with Docker Desktop; docker-compose-plugin on Linux)."
    fi
    command -v jq >/dev/null 2>&1 \
        || info "note: 'jq' not found -- aidc needs it at runtime (apt/brew install jq)."
    command -v yq >/dev/null 2>&1 \
        || info "note: 'yq' not found -- optional, needed for full config support."
}

do_install() { # tag
    tag="$1"
    case "$tag" in
        v[0-9]*.[0-9]*.[0-9]*) : ;;
        *) err "'${tag}' does not look like a release tag (vX.Y.Z)"; exit 1 ;;
    esac
    version="${tag#v}"

    expected="$(published_sha256 "$tag")"
    if [ -z "$expected" ]; then
        err "the Homebrew tap publishes no checksum for ${tag}; refusing to install unverified bytes."
        err "install that version from source instead: git clone https://github.com/${REPO} (see README)."
        exit 1
    fi

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/aidc-install.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT

    info "downloading aidc ${tag} ..."
    curl -fsSL -o "${tmp}/aidc.tar.gz" \
        "https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"

    actual="$(sha256_of "${tmp}/aidc.tar.gz")"
    if [ "$actual" != "$expected" ]; then
        err "sha256 mismatch for ${tag}:"
        err "  expected (tap):   ${expected}"
        err "  actual (download): ${actual}"
        err "refusing to install."
        exit 1
    fi
    info "sha256 verified against the Homebrew tap."

    tar -xzf "${tmp}/aidc.tar.gz" -C "$tmp"
    src="${tmp}/aidc-${version}"
    [ -d "$src" ] || { err "tarball did not contain aidc-${version}/"; exit 1; }

    dest="${SHARE_DIR}/aidc-${version}"
    mkdir -p "$SHARE_DIR" "$BIN_DIR"
    rm -rf "$dest"
    mv "$src" "$dest"
    ln -sfn "${dest}/scripts/aidc" "${BIN_DIR}/aidc"

    info "installed aidc ${tag} -> ${dest}"
    info "linked ${BIN_DIR}/aidc"
    case ":${PATH}:" in
        *":${BIN_DIR}:"*) : ;;
        *) info "note: ${BIN_DIR} is not on your PATH -- add it to your shell profile." ;;
    esac
    # sed -n 1p, not head -1: head closing the pipe early would SIGPIPE the CLI
    # under pipefail and fail an otherwise-successful install.
    "${BIN_DIR}/aidc" help | sed -n '1p'
    check_runtime_deps
}

do_prune() {
    current=""
    if [ -L "${BIN_DIR}/aidc" ]; then
        # BSD readlink has no -f; the raw link target is enough here.
        current="$(readlink "${BIN_DIR}/aidc")"
    fi
    [ -d "$SHARE_DIR" ] || { info "nothing installed under ${SHARE_DIR}."; return 0; }
    for dir in "${SHARE_DIR}"/aidc-*; do
        [ -d "$dir" ] || continue
        case "$current" in
            "$dir"/*) info "keeping  $dir (current)" ;;
            *) rm -rf "$dir"; info "removed  $dir" ;;
        esac
    done
}

main() {
    need curl; need tar
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || { err "need sha256sum or shasum to verify the download"; exit 1; }

    tag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) [ $# -ge 2 ] || { err "--version needs an argument"; exit 1; }
                       tag="$2"; shift 2 ;;
            --list)    list_tags; exit 0 ;;
            --prune)   do_prune; exit 0 ;;
            --help|-h) usage; exit 0 ;;
            *)         err "unknown option '$1'"; usage >&2; exit 1 ;;
        esac
    done

    if [ -z "$tag" ]; then
        tag="$(latest_tag)"
        [ -n "$tag" ] || { err "could not resolve the latest release tag"; exit 1; }
    fi
    do_install "$tag"
}

main "$@"
