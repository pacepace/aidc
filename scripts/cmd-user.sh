#!/usr/bin/env bash
# desc: Add, credential and remove users on the Kubernetes backend (namespace, disk, kubeconfig).
#
# Usage: aidc user <add|creds|allow-network|remove> <name> [options]
#
# Users exist on the Kubernetes backend only (docs/design-12-kubernetes.md, "Users and
# credentials"): each has a namespace and one disk shared by their sessions, and their own
# namespace-scoped credentials. Each subcommand is scripts/k8s/user-<name>.sh.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc user <add|creds|allow-network|remove> <name> [options]

  add <name> [--out FILE] [--duration D]
           (admin) Create <name>'s area in the cluster of the `kubernetes:` config: a
           namespace (Pod Security "baseline") and a disk (on kubernetes.storage_class)
           that all of <name>'s sessions share, and <name>'s credentials: a ServiceAccount
           that may do what aidc does in that namespace and nothing in any other, one for
           their MCP server, and a kubeconfig for <name> (see creds). The new user then
           adds their own GitHub login and Claude accounts; the admin never handles them
           (they run `aidc git setup`, log in to GitHub with `aidc git login` and to Claude
           through `aidc git attach`). Safe to run again.
  creds <name> [--out FILE] [--duration D] [--token] [--revoke]
           Issue <name>'s kubeconfig again: a new token (kubernetes.user_token_ttl, default
           720h, or --duration) and the cluster's server and CA from the credentials in
           use. Written mode 0600 to ~/.config/aidc/users/<name>.kubeconfig (or --out;
           renewed in place when aidc is configured with <name>'s own kubeconfig); never
           inside a git work tree. The token is printed only with --token (then no file).
           An admin or <name> may renew; --revoke (admin) invalidates every earlier token.
  allow-network <name> [<namespace>] [--remove]
           (admin) Let <name> give their sessions another namespace (aidc create
           --network, aidc network add): a RoleBinding in <namespace> that lets <name>
           and their MCP server list its Services (the session resolves them by name),
           nothing else, never cluster-wide. aidc's own namespaces and the system ones
           are refused. --remove takes it back; with no namespace, lists the granted ones.
  remove <name> [--yes]
           (admin) Remove <name> and everything aidc made for them: namespace, disk, kept
           audit trails (their volumes and data too, whatever the class retains),
           credentials and bindings. Refuses while <name> has sessions; asks first (type
           the name) unless --yes.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/user-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown user subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
