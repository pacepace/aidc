#!/usr/bin/env bash
# Library for `aidc update`: how was this CLI installed, and is a newer
# release out? Pure functions -- no network, no docker -- so tests/unit can
# pin them without a daemon. Bash 3.2 compatible (no sort -V: BSD sort on
# macOS has no such flag).

# Print how the aidc tree rooted at $1 was installed:
#   git        a clone/checkout (.git present; a worktree's .git is a file)
#   brew       a Homebrew keg (…/Cellar/aidc/<ver>/libexec or aidc@X.Y)
#   installer  install.sh layout (~/.local/share/aidc/aidc-<version>)
#   unknown    anything else (copied by hand, vendored, …)
aidc_install_kind() { # root
    local root="$1"
    if [ -d "${root}/.git" ] || [ -f "${root}/.git" ]; then
        printf 'git\n'; return 0
    fi
    case "$root" in
        */Cellar/aidc/*|*/Cellar/aidc@*/*) printf 'brew\n'; return 0 ;;
    esac
    case "$(basename "$root")" in
        aidc-[0-9]*)
            case "$(basename "$(dirname "$root")")" in
                aidc) printf 'installer\n'; return 0 ;;
            esac ;;
    esac
    printf 'unknown\n'
}

# Print the Homebrew formula name a keg path was installed from: `aidc` for
# …/Cellar/aidc/<ver>/libexec, `aidc@1.3` for the versioned line. The tap
# publishes both, and `brew upgrade` must name the one that is installed.
aidc_brew_formula() { # root
    local rest="${1##*/Cellar/}"
    printf '%s\n' "${rest%%/*}"
}

# Compare two release tags (vX.Y.Z, optional pre-release/build suffix which
# is ignored). Prints -1, 0 or 1 for a<b, a=b, a>b.
aidc_semver_cmp() { # a b
    local a="${1#v}" b="${2#v}"
    a="${a%%[-+]*}"; b="${b%%[-+]*}"
    local i x y
    for i in 1 2 3; do
        x="$(printf '%s' "$a" | cut -d. -f"$i")"
        y="$(printf '%s' "$b" | cut -d. -f"$i")"
        x="${x:-0}"; y="${y:-0}"
        if [ "$x" -lt "$y" ]; then printf -- '-1\n'; return 0; fi
        if [ "$x" -gt "$y" ]; then printf '1\n'; return 0; fi
    done
    printf '0\n'
}

# Print the tag of the latest GitHub release for $1 (owner/repo), or nothing
# if the API call fails. Same parse as install.sh's latest_tag.
aidc_latest_release_tag() { # repo
    curl -fsSL "https://api.github.com/repos/${1}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/'
}
