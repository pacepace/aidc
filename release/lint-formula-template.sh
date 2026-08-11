#!/usr/bin/env bash
# lint-formula-template.sh -- reject dangerous Ruby in the Homebrew formula
# templates. These templates are rendered by .github/workflows/release.yml and
# shipped to the tap repo, where they run UNPRIVILEGED on every user's machine
# via `brew install` (and `brew test`). A single malicious construct sneaked
# into a template reaches every user on the next tagged release. This lint is
# one of the two required defenses (the other is CODEOWNERS on release/Formula/).
#
# It scans each release/Formula/*.tmpl for:
#   - execution / subprocess / eval / metaprogramming constructs
#   - filesystem, network, and env/introspection access
#   - shell-style ${...} placeholders (we use __VAR__, never ${...})
#   - any __PLACEHOLDER__ outside the documented allowlist (catches typos that
#     would otherwise ship a literal __VESRION__ to users)
#
# Heredoc awareness: `<<~EOS ... EOS` bodies are Ruby STRING content, so
# backticks there are literal text (safe) -- only string INTERPOLATION
# (`#{ ... }`) executes. Inside a heredoc we therefore flag only dangerous
# interpolation; in code context we apply the full forbidden set (including bare
# backticks and %x{}). Full-line `#` comments are excluded (but `#{...}` is code).
# Any hit fails with file:line:reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL_DIR="${SCRIPT_DIR}/Formula"

# Forbidden constructs in CODE context (extended regex, single alternation).
# Includes bare backtick and %x{} command execution.
FORBIDDEN_CODE='system[[:space:]]*\(|exec[[:space:]]*\(|\beval\b|instance_eval|class_eval|define_method|IO\.popen|Open3\.|Process\.|Kernel\.|__send__|\.send[[:space:]]*\(|\bspawn\b|`|%x[{(\[]|open[[:space:]]*\(|URI\.open|File\.|Pathname|Dir\.glob[[:space:]]*\([^"'\'']|Net::HTTP|Net::FTP|TCPSocket|UDPSocket|\bsocket\b|OpenSSL::|require_relative|\brequire\b|ENV\[|ENV\.fetch|__FILE__|__dir__|Formula\[|Tap\.|\bprepend\b|\bextend\b|singleton_class|\?[a-zA-Z_]+\.[a-zA-Z_]+[[:space:]]*:|\$\{[^}]*\}'

# Dangerous content inside a heredoc string INTERPOLATION `#{ ... }`.
FORBIDDEN_INTERP='#\{[^}]*(`|\(|%x|system|exec|eval|__send__|\.send|IO\.|Open3|Kernel|Process|\bspawn\b|open|File\.|ENV|Dir\.glob|require)'

# Documented placeholder allowlist. Anything else matching __NAME__ fails.
ALLOWED_PLACEHOLDERS=' __VERSION__ __SHA256__ __VERSION_TAG__ __VERSION_TAG_SAFE__ '

fail=0

scan() {
    local f="$1" in_heredoc=0 term="" lineno=0 line
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))

        if [ "$in_heredoc" -eq 1 ]; then
            if printf '%s' "$line" | grep -qE "^[[:space:]]*${term}[[:space:]]*$"; then
                in_heredoc=0; term=""
                continue
            fi
            if printf '%s' "$line" | grep -qE "$FORBIDDEN_INTERP"; then
                echo "FAIL ${f}:${lineno}: dangerous interpolation in heredoc -> ${line}" >&2
                fail=1
            fi
            continue
        fi

        # Full-line comment (`# ...`, but not `#{...}`): skip.
        if printf '%s' "$line" | grep -qE '^[[:space:]]*#([^{]|$)'; then
            continue
        fi

        # Code line: apply full forbidden set.
        if printf '%s' "$line" | grep -qE "$FORBIDDEN_CODE"; then
            echo "FAIL ${f}:${lineno}: forbidden construct -> ${line}" >&2
            fail=1
        fi

        # Heredoc start? (`<<~EOS`, `<<-EOS`, `<<EOS`, `<<"EOS"`, `<<'EOS'`)
        if printf '%s' "$line" | grep -qE '<<[~-]?["'\'']?[A-Za-z_][A-Za-z0-9_]*'; then
            term="$(printf '%s' "$line" | sed -E 's/.*<<[~-]?["'\'']?([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
            in_heredoc=1
        fi
    done < "$f"
}

shopt -s nullglob
templates=("${TMPL_DIR}"/*.tmpl)
if [ "${#templates[@]}" -eq 0 ]; then
    echo "lint-formula-template: no templates found in ${TMPL_DIR}" >&2
    exit 1
fi

for tmpl in "${templates[@]}"; do
    scan "$tmpl"
    # Undocumented placeholders (whole-file scan).
    while IFS= read -r ph; do
        [ -n "$ph" ] || continue
        case "$ALLOWED_PLACEHOLDERS" in
            *" $ph "*) : ;;
            *) echo "FAIL ${tmpl}: undocumented placeholder '${ph}'" >&2; fail=1 ;;
        esac
    done < <(grep -oE '__[A-Z0-9_]+__' "$tmpl" | sort -u)
done

if [ "$fail" -ne 0 ]; then
    echo "lint-formula-template: FAILED (see above)" >&2
    exit 1
fi
echo "lint-formula-template: OK (${#templates[@]} template(s) clean)"
