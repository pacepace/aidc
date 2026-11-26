#!/usr/bin/env bash
# The user's Claude account broker, from the laptop's side (K8S-16, K8S-17): starting it, asking
# it, and readying or removing a session's Claude config dir. Sourced by claude.sh (aidc claude),
# session-create.sh, session-kill.sh and git-setup.sh; lib.sh and manifests.sh first.
# What runs in the cluster: manifests.sh, "Claude: one login per user, and its broker", and
# broker/claude-broker.sh.

# k8s_broker_state <namespace>: RUNNING, STARTING or NOT RUNNING, from the Deployment; returns 2,
# saying why, when the cluster did not answer.
k8s_broker_state() {
    local out
    out=$(k8s_get "$1" deployment "$K8S_BROKER_NAME" -o 'jsonpath={.metadata.name}|{.status.readyReplicas}') \
        || { printf 'unknown (the cluster did not answer: %s)' "$out"; return 2; }
    case "$out" in
        "") printf 'NOT RUNNING' ;;
        *"|"|*"|0") printf 'STARTING' ;;
        *) printf 'RUNNING' ;;
    esac
}

# k8s_broker_exec <namespace> <claude-broker args...>: run claude-broker in the broker's pod, with
# no stdin (an exec reads all of it otherwise).
k8s_broker_exec() {
    local ns="$1"
    shift
    k8s_kubectl -n "$ns" exec "deployment/${K8S_BROKER_NAME}" -c broker -- claude-broker "$@" </dev/null
}

# k8s_broker_exec_tty <namespace> <claude-broker args...>: the same with this terminal, for
# Claude's own login.
k8s_broker_exec_tty() {
    local ns="$1"
    shift
    k8s_kubectl -n "$ns" exec -it "deployment/${K8S_BROKER_NAME}" -c broker -- claude-broker "$@"
}

# k8s_broker_start <namespace>: the broker's claims, settings and pod, applied; waits until it
# is ready. Returns 1, saying why.
k8s_broker_start() {
    local ns="$1" sel
    k8s_ensure_claude_config "$ns" || return 1
    k8s_ensure_claude_accounts "$ns" || return 1
    k8s_render_broker_config | k8s_kubectl apply -f - >/dev/null \
        || { err "could not write the Claude account broker's settings"; return 1; }
    sel=$(k8s_node_selector) || return 1
    k8s_render_broker "$sel" | k8s_kubectl apply -f - >&2 \
        || { err "could not apply the Claude account broker"; return 1; }
    k8s_kubectl -n "$ns" rollout status "deployment/${K8S_BROKER_NAME}" --timeout=300s >&2 \
        || { err "the Claude account broker did not become ready; see: kubectl -n ${ns} describe pod -l app=${K8S_BROKER_NAME} (is its image built? aidc k8s build --only broker)"; return 1; }
}

# k8s_claude_session_ready <namespace> <session>: the session's Claude config dir in claude-config,
# and, when the user's broker runs, the active account's credentials in it now, so its Claude
# starts logged in (K8S_CLAUDE_VIA=broker). Without a broker (K8S_CLAUDE_VIA=none) the caller may
# hand the session a long-lived token (k8s_claude_token_secret), or it logs in itself. Returns 1
# only when the claim cannot be made.
k8s_claude_session_ready() {
    local ns="$1" session="$2" state rc=0
    K8S_CLAUDE_VIA=none
    k8s_ensure_claude_config "$ns" || return 1
    state=$(k8s_broker_state "$ns") || rc=$?
    if [ "$rc" != 0 ]; then
        info "cannot tell whether your Claude account broker runs (${state}): ${session}'s Claude may need /login"
        return 0
    fi
    case "$state" in
        RUNNING)
            # shellcheck disable=SC2034  # read by the caller (session-create.sh)
            K8S_CLAUDE_VIA=broker
            if k8s_broker_exec "$ns" session "$session" >/dev/null 2>&1; then
                info "Claude: ${session} uses your account broker's active account (aidc claude account list)"
            else
                info "your Claude account broker did not answer for ${session}: it writes its login within a minute, or log in inside the session"
            fi ;;
        *) [ "${K8S_CLAUDE_QUIET_NONE:-}" = 1 ] \
               || info "Claude: no account broker runs, so ${session} logs in itself (aidc attach ${session}, then /login); aidc claude account add <name> sets one login up for every session" ;;
    esac
}

# k8s_claude_token_secret <namespace> <session>: with no broker, the stopgap until one: the
# long-lived inference token `aidc claude-token setup` stored on this machine
# (~/.config/aidc/claude-oauth-token, from `claude setup-token`), handed to the session as
# CLAUDE_CODE_OAUTH_TOKEN from a Secret of its own, as Docker's aidc create does. Sets
# AIDC_K8S_CLAUDE_TOKEN_SECRET=1 when it made one. Returns 1 when the cluster refuses it.
k8s_claude_token_secret() {
    local ns="$1" session="$2" file="${HOME}/.config/aidc/claude-oauth-token" tok
    AIDC_K8S_CLAUDE_TOKEN_SECRET=0
    [ -f "$file" ] || return 0
    tok=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
    case "$tok" in
        sk-ant-oat01-*) ;;
        *) info "Claude: ${file} does not hold a token (aidc claude-token setup); ${session} logs in itself"; return 0 ;;
    esac
    k8s_kubectl -n "$ns" delete secret "$(k8s_claude_token_name "$session")" --ignore-not-found >/dev/null \
        || { err "could not replace ${session}'s Claude token"; return 1; }
    k8s_render_claude_token "$session" "$tok" | k8s_kubectl create -f - >/dev/null \
        || { err "the cluster did not take ${session}'s Claude token"; return 1; }
    AIDC_K8S_CLAUDE_TOKEN_SECRET=1
    export AIDC_K8S_CLAUDE_TOKEN_SECRET
    info "Claude: ${session} uses your long-lived token (aidc claude-token; inference only: Remote Control unavailable). aidc claude account add <name> sets up the account broker instead"
}

# k8s_claude_session_forget <namespace> <session>: the killed session's Claude config dir removed:
# by the broker when it runs, else by a one-shot pod. A failure is said, never fatal (the
# folder is reused by a later session of the same name).
k8s_claude_session_forget() {
    local ns="$1" session="$2" state rc=0 sel have pod="${2}-claude-forget"
    have=$(k8s_get "$ns" pvc "$K8S_CLAUDE_CONFIG_CLAIM" -o name) || have="?"
    [ -n "$have" ] || return 0
    state=$(k8s_broker_state "$ns") || rc=$?
    if [ "$rc" = 0 ] && [ "$state" = RUNNING ] && k8s_broker_exec "$ns" forget "$session" >/dev/null 2>&1; then
        return 0
    fi
    sel=$(k8s_node_selector) || { err "could not remove ${session}'s Claude config dir"; return 0; }
    k8s_kubectl -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
    if ! k8s_render_claude_forget "$session" "$sel" | k8s_kubectl apply -f - >/dev/null; then
        err "could not remove ${session}'s Claude config dir (in claim ${K8S_CLAUDE_CONFIG_CLAIM})"
        return 0
    fi
    k8s_kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=120s >/dev/null 2>&1 \
        || err "${session}'s Claude config dir may not be removed yet (pod ${pod})"
    k8s_kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
