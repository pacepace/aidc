#!/usr/bin/env bash
# aidc user creds <name> [--out FILE] [--duration D] [--token] [--revoke]: a kubeconfig for the
# user's ServiceAccount (aidc-user in <prefix>-u-<name>), holding a token from the TokenRequest
# API and the cluster's server and CA from the credentials in use. The admin runs it (aidc user
# add does), and so may the user, with their own kubeconfig, to renew it before it expires.
#
# The token goes only into the file (mode 0600, never inside a git work tree), or to stdout with
# --token; never into a log line. --revoke replaces the ServiceAccount, which invalidates every
# token issued for it before, then issues a new one (admin only).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

USER_NAME="" OUT="" DURATION="" PRINT_TOKEN="" REVOKE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-user.sh" --help ;;
        --out|--duration)
            [ $# -ge 2 ] || die "$1 needs a value"
            if [ "$1" = --out ]; then OUT="$2"; else DURATION="$2"; fi
            shift 2 ;;
        --token) PRINT_TOKEN=1; shift ;;
        --revoke) REVOKE=1; shift ;;
        -*) die "unknown option: $1 (aidc user creds <name> [--out FILE] [--duration D] [--token] [--revoke])" ;;
        *)
            [ -z "$USER_NAME" ] || die "aidc user creds takes one name (got: ${USER_NAME} $1)"
            USER_NAME="$1"; shift ;;
    esac
done
[ -n "$USER_NAME" ] || die "usage: aidc user creds <name> [--out FILE] [--duration D] [--token] [--revoke]"
k8s_valid_label "$USER_NAME" || die "user name '${USER_NAME}' must be lowercase letters, digits and dashes (a DNS label)"
[ -z "$PRINT_TOKEN" ] || [ -z "$OUT" ] || die "--token prints the token instead of writing a file: not with --out"
k8s_require || exit 1
# No credentials where the admission policies cannot exist (lib.sh, K8S_NO_VAP_WHY).
k8s_has_vap || die "$K8S_NO_VAP_WHY"
DURATION="${DURATION:-$AIDC_K8S_USER_TOKEN_TTL}"
if [ -z "$DURATION" ] || ! printf '%s' "$DURATION" | grep -Eqx '([0-9]+h)?([0-9]+m)?([0-9]+s)?'; then
    die "token lifetime '${DURATION}' is not a duration such as 720h or 90m"
fi

ns=$(k8s_user_ns "$USER_NAME")
ctx="${ns}"

# Where the file goes: --out; else the kubeconfig aidc is configured with when it is this
# user's own (renewing in place); else ~/.config/aidc/users/<name>.kubeconfig.
if [ -z "$OUT" ] && [ -z "$PRINT_TOKEN" ]; then
    if [ -n "$AIDC_K8S_KUBECONFIG" ] && [ -f "$AIDC_K8S_KUBECONFIG" ] \
            && [ "$(k8s_kubectl config current-context 2>/dev/null || true)" = "$ctx" ]; then
        OUT="$AIDC_K8S_KUBECONFIG"
    else
        OUT="${XDG_CONFIG_HOME:-$HOME/.config}/aidc/users/${USER_NAME}.kubeconfig"
    fi
fi
if [ -n "$OUT" ]; then
    case "$OUT" in /*) ;; *) OUT="${PWD%/}/${OUT}" ;; esac
    # Never into a repo: a kubeconfig committed by mistake is a credential on GitHub. The nearest
    # folder that exists is asked, before anything is made; a path the repo ignores is allowed.
    probe=$(dirname "$OUT")
    while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
    if [ "$(git -C "$probe" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ] \
            && ! git -C "$probe" check-ignore -q -- "$OUT" 2>/dev/null; then
        die "${OUT} is inside a git work tree ($(git -C "$probe" rev-parse --show-toplevel)) and not ignored there: a kubeconfig holds a token; write it outside any repo (--out)"
    fi
fi

if [ -n "$REVOKE" ]; then
    info "revoking every token of ${K8S_USER_SA} in ${ns}: replacing the ServiceAccount"
    k8s_kubectl -n "$ns" delete serviceaccount "$K8S_USER_SA" --ignore-not-found --wait=true >&2 \
        || die "could not delete ServiceAccount ${K8S_USER_SA} in ${ns} (revoking takes an admin)"
    k8s_render_user_access "$USER_NAME" | k8s_kubectl apply -f - >/dev/null \
        || die "could not apply ${USER_NAME}'s credentials again in ${ns}"
fi

# The token. Its error, if any, may name the ServiceAccount but never holds a token.
errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
token=$(k8s_kubectl -n "$ns" create token "$K8S_USER_SA" --duration "$DURATION" 2>"$errf") \
    || die "could not issue a token for ${K8S_USER_SA} in ${ns}: $(tail -n1 "$errf") (is ${USER_NAME} added? aidc user add ${USER_NAME})"
printf '%s' "$token" | grep -Eqx '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*' \
    || die "the cluster's answer to the token request is not a token"

# When it really expires: the API server may give less than was asked.
payload=$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')
case $(( ${#payload} % 4 )) in 2) payload="${payload}==" ;; 3) payload="${payload}=" ;; esac
exp=$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null || true)
until=""
if [ -n "$exp" ]; then
    until=$(date -u -d "@${exp}" +%FT%TZ 2>/dev/null || date -u -r "$exp" +%FT%TZ 2>/dev/null || true)
fi

if [ -n "$PRINT_TOKEN" ]; then
    printf '%s\n' "$token"
    info "token for ${K8S_USER_SA} in ${ns}${until:+, valid until ${until}}"
    exit 0
fi

# The cluster as the credentials in use reach it: its server and CA.
view=$(k8s_kubectl config view --minify --raw -o json 2>/dev/null) || die "cannot read the current kubeconfig context"
server=$(printf '%s' "$view" | jq -r '.clusters[0].cluster.server // empty')
[ -n "$server" ] || die "the current kubeconfig context names no cluster server"
ca=$(printf '%s' "$view" | jq -r '.clusters[0].cluster["certificate-authority-data"] // empty')
if [ -z "$ca" ]; then
    cafile=$(printf '%s' "$view" | jq -r '.clusters[0].cluster["certificate-authority"] // empty')
    if [ -n "$cafile" ]; then
        [ -r "$cafile" ] || die "cannot read the cluster's CA file ${cafile}"
        ca=$(base64 < "$cafile" | tr -d '\n')
    fi
fi
insecure=$(printf '%s' "$view" | jq -r '.clusters[0].cluster["insecure-skip-tls-verify"] // false')
tlsname=$(printf '%s' "$view" | jq -r '.clusters[0].cluster["tls-server-name"] // empty')
[ -n "$ca" ] || [ "$insecure" = true ] || info "the current context has no CA: the kubeconfig trusts the system's CAs"

# The folder: one this makes is the admin's alone (0700, with any parents it makes); aidc's own
# folder of kubeconfigs is kept so; any other folder that exists is left as it is (--out may
# name $HOME or /tmp). The file itself is 0600.
outdir=$(dirname "$OUT")
if [ ! -d "$outdir" ]; then
    (umask 077 && mkdir -p "$outdir") || die "cannot make ${outdir}"
elif [ "$outdir" = "${XDG_CONFIG_HOME:-$HOME/.config}/aidc/users" ]; then
    chmod 0700 "$outdir" 2>/dev/null || true
fi
tmp=$(umask 077 && mktemp "$(dirname "$OUT")/.aidc-kubeconfig.XXXXXX")
trap 'rm -f "$errf" "$tmp"' EXIT
jq -n --arg ctx "$ctx" --arg ns "$ns" --arg server "$server" --arg ca "$ca" \
    --arg tlsname "$tlsname" --argjson insecure "$insecure" --rawfile token /dev/stdin '{
    apiVersion: "v1", kind: "Config", preferences: {},
    clusters: [{name: $ctx, cluster: ({server: $server}
        + (if $ca != "" then {"certificate-authority-data": $ca} else {} end)
        + (if $insecure then {"insecure-skip-tls-verify": true} else {} end)
        + (if $tlsname != "" then {"tls-server-name": $tlsname} else {} end))}],
    users: [{name: $ctx, user: {token: ($token | rtrimstr("\n"))}}],
    contexts: [{name: $ctx, context: {cluster: $ctx, user: $ctx, namespace: $ns}}],
    "current-context": $ctx}' <<<"$token" | yq -P '.' > "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$OUT"

info "kubeconfig for ${USER_NAME} (ServiceAccount ${K8S_USER_SA} in ${ns}${until:+, valid until ${until}}): ${OUT}"
if [ "$OUT" != "$AIDC_K8S_KUBECONFIG" ]; then
    info "hand it to ${USER_NAME} privately; in their ~/.config/aidc/config.yaml: kubernetes.kubeconfig: <where they keep it>, kubernetes.user: ${USER_NAME}"
fi
info "renew before it expires: aidc user creds ${USER_NAME} (an admin, or ${USER_NAME} with this kubeconfig)"
