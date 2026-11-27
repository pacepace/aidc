#!/usr/bin/env bash
# Keeps a user's Role in step with aidc's scripts (scripts/k8s/manifests.sh, K8S_USER_RULES,
# K8S_USER_CLUSTER_RULES and K8S_NETWORK_RULES; docs/design-12-kubernetes.md, "Users and
# credentials").
#
# Reads every kubectl call in scripts/ (all go through k8s_kubectl), works out the API resource
# and RBAC verb each one needs, and fails when:
#   - a call a user runs needs a (resource, verb) the user's rules do not grant (a new command
#     would fail under a user's own kubeconfig);
#   - the rules grant a (resource, verb) no call uses and no reason below names (the Role grows
#     beyond what aidc does);
#   - a call cannot be read (a new form this test does not know): it must be taught, not skipped;
#   - a call into another namespace (--network) needs what the network grant does not give, or
#     the grant gives what no such call uses;
#   - the MCP's rules grant anything the user's do not;
#   - a rule names a resource under another API group than the resource's own, or loses (or
#     gains) a resourceName restriction (the aidc-user token);
#   - a grant decided against is made: listing Ingresses cluster-wide;
#   - kubectl is called directly instead of through k8s_kubectl.
# Calls through lib.sh's k8s_get (and session-create's k8s_read on top of it) are read as the
# `kubectl get` they make. What `kubectl apply` and `kubectl create -f -` make comes from
# rendering each manifest function, not from a list.
#
# Needs python3, yq and jq; skips without them.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-rbac-$$"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/home/.config/aidc"

for t in python3 yq jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }
done

# The rules, and the kinds each manifest function renders (settings from a scratch config; no
# cluster is asked).
export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts"
printf 'kubernetes:\n  storage_class: s\n  user: alice\n' > "$HOME/.config/aidc/config.yaml"
# shellcheck disable=SC1091,SC2034
(
    . "$AIDC_ROOT/scripts/k8s/lib.sh"; . "$AIDC_ROOT/scripts/k8s/manifests.sh"; k8s_load_settings
    . "$AIDC_ROOT/scripts/k8s/net.sh"; . "$AIDC_ROOT/scripts/k8s/expose.sh"
    AIDC_VERSION_TAG="test" AIDC_K8S_INGRESS_DOMAIN=pages.example.org AIDC_K8S_INGRESS_CLASS=c
    AIDC_K8S_INGRESS_CONTROLLER_NS=ing AIDC_K8S_INGRESS_CONTROLLER_LABELS='{"app":"ing"}'
    kinds() { yq ea -N '.kind' - | grep -v '^null$' | sort -u | paste -sd, -; }
    # Every controller's form: the kinds either may make.
    controllers() { local c; for c in traefik ingress-nginx; do AIDC_K8S_INGRESS_CONTROLLER=$c "$@"; done; }
    {
        printf 'RULES user\n%s\nRULES user-cluster\n%s\nRULES mcp\n%s\nRULES mcp-cluster\n%s\nRULES network\n%s\n' \
            "$K8S_USER_RULES" "$K8S_USER_CLUSTER_RULES" "$K8S_MCP_RULES" \
            "$K8S_MCP_CLUSTER_RULES" "$K8S_NETWORK_RULES"
        printf 'RENDER k8s_render_session %s\n' "$(k8s_render_session s1 /home/alice/r default '{}' s1-audit-1 10.0.0.1 | kinds)"
        printf 'RENDER k8s_render_git %s\n' "$(k8s_render_git '{}' | kinds)"
        printf 'RENDER k8s_render_repo_dir %s\n' "$(k8s_render_repo_dir p /home/alice/r make '{}' | kinds)"
        printf 'RENDER k8s_render_git_repos %s\n' "$(k8s_render_git_repos aidc-u-alice 'a/b' | yq -p=json '.kind')"
        printf 'RENDER k8s_render_relay %s\n' "$(k8s_render_relay s1 db.example.org 192.0.2.7 declared s1-audit-1 '{}' 5432 | kinds)"
        printf 'RENDER k8s_render_network %s\n' "$(k8s_render_network s1 shop | kinds)"
        printf 'RENDER k8s_render_expose %s\n' "$(controllers k8s_render_expose s1 'u:$apr1$x' 8080 9090 | kinds)"
        printf 'RENDER k8s_render_expose_login %s\n' "$(controllers k8s_render_expose_login s1 'u:$apr1$x' | kinds)"
        printf 'RENDER k8s_render_transcripts %s\n' "$(k8s_render_transcripts | kinds)"
        printf 'RENDER k8s_render_mcp %s\n' "$(k8s_render_mcp '{}' 10.0.0.1:6443 | kinds)"
        printf 'RENDER k8s_render_mcp_state %s\n' "$(k8s_render_mcp_state | kinds)"
        printf 'RENDER k8s_render_mcp_token %s\n' "$(k8s_render_mcp_token t | kinds)"
        printf 'RENDER k8s_render_mcp_config %s\n' "$(k8s_render_mcp_config 10.0.0.1:6443 | kinds)"
        printf 'RENDER k8s_render_mcp_expose %s\n' "$(AIDC_K8S_INGRESS_DOMAIN=pages.example.org k8s_render_mcp_expose | kinds)"
        printf 'RENDER k8s_render_mcp_service %s\n' "$(k8s_render_mcp_service | kinds)"
        printf 'RENDER k8s_render_claude_config %s\n' "$(k8s_render_claude_config | kinds)"
        printf 'RENDER k8s_render_claude_accounts %s\n' "$(k8s_render_claude_accounts | kinds)"
        printf 'RENDER k8s_render_broker_config %s\n' "$(k8s_render_broker_config | kinds)"
        printf 'RENDER k8s_render_broker %s\n' "$(k8s_render_broker '{}' | kinds)"
        printf 'RENDER k8s_render_claude_forget %s\n' "$(k8s_render_claude_forget s1 '{}' | kinds)"
        printf 'RENDER k8s_render_claude_token %s\n' "$(k8s_render_claude_token s1 t | kinds)"
        printf 'RENDER k8s_render_sync_claim %s\n' "$(k8s_render_sync_claim | kinds)"
        printf 'RENDER k8s_render_sync_config %s\n' "$(k8s_render_sync_config 'mac ABC 192.168.1.2 22000' | kinds)"
        printf 'RENDER k8s_render_sync %s\n' "$(k8s_render_sync '{}' 'mac ABC 192.168.1.2 22000' | kinds)"
    } > "$SCRATCH/facts"
)

python3 -I - "$AIDC_ROOT/scripts" "$SCRATCH/facts" <<'PY'
import os, re, sys

scripts, facts_path = sys.argv[1], sys.argv[2]

# ---- the rules and renders --------------------------------------------------------------------
rules, renders, cur = {}, {}, None
unnamed = {}  # per rules table, the (resource, verb) grants not narrowed to one object's name
groups = []   # (rules table, resource, API group, resourceName or "")
for line in open(facts_path):
    line = line.rstrip("\n")
    if line.startswith("RULES "):
        cur = line.split()[1]; rules[cur] = set(); unnamed[cur] = set(); continue
    if line.startswith("RENDER "):
        f = line.split(" ", 2); renders[f[1]] = [k for k in (f[2] if len(f) > 2 else "").split(",") if k]; cur = None; continue
    if cur and line.strip():
        f = line.split()
        g = "" if f[0] == "core" else f[0]
        groups.append((cur, f[1], g, f[3] if len(f) > 3 else ""))
        for v in f[2].split(","):
            rules[cur].add((f[1], v))
            if len(f) <= 3: unnamed[cur].add((f[1], v))

KIND = {"Pod": "pods", "Service": "services", "ConfigMap": "configmaps",
        "PersistentVolumeClaim": "persistentvolumeclaims", "Deployment": "deployments",
        "StatefulSet": "statefulsets", "NetworkPolicy": "networkpolicies", "Ingress": "ingresses",
        "Secret": "secrets", "Middleware": "middlewares"}
ALIAS = {"pod": "pods", "pods": "pods", "pvc": "persistentvolumeclaims",
         "persistentvolumeclaims": "persistentvolumeclaims", "pv": "persistentvolumes",
         "service": "services", "services": "services", "svc": "services",
         "configmap": "configmaps", "configmaps": "configmaps", "deployment": "deployments",
         "deployments": "deployments", "statefulset": "statefulsets", "statefulsets": "statefulsets",
         "networkpolicy": "networkpolicies", "networkpolicies": "networkpolicies",
         "runtimeclass": "runtimeclasses", "storageclass": "storageclasses", "nodes": "nodes",
         "node": "nodes", "events": "events", "ingress": "ingresses", "ingresses": "ingresses",
         "ingressclass": "ingressclasses", "secret": "secrets", "secrets": "secrets",
         "middlewares.traefik.io": "middlewares"}
CLUSTER = {"nodes", "persistentvolumes", "runtimeclasses", "storageclasses", "ingressclasses"}

# Calls only an admin makes (they set up the cluster, users and the system namespace), or that
# go to the system namespace and degrade to a note without the right (aidc k8s check).
ADMIN_FILES = {"k8s/user-add.sh", "k8s/user-remove.sh", "k8s/k8s-setup.sh", "k8s/k8s-build.sh",
               "k8s/user-allow-network.sh"}
ADMIN_LINES = [("k8s/user-creds.sh", "delete serviceaccount"),       # --revoke
               ("k8s/user-creds.sh", "k8s_render_user_access"),      # --revoke
               ("k8s/k8s-check.sh", '-n "$sys_ns"')]                 # the registry
# Calls whose resource is a variable, resolved here by hand (file, text in the call) -> needs.
DECLARED = {
    # k8s_expose_taken: the user's own namespace ("-n $1"), then every namespace ("-A"), which a
    # user may not list (NOT_GRANTED) and the check skips.
    ("k8s/expose.sh", "k8s_kubectl $scope get ingress"): [("ingresses", "list")],
    ("k8s/lib.sh", 'k8s_kubectl "$verb" -f -'): [("configmaps", "create"), ("configmaps", "update")],
    ("k8s/session-kill.sh", 'annotate "$audit"'): [("persistentvolumeclaims", "get"), ("persistentvolumeclaims", "patch")],
    ("k8s/session-logs.sh", 'logs ${FOLLOW[@]+"${FOLLOW[@]}"} "$target"'): [("pods", "get"), ("pods/log", "get")],
}
# The wrappers' own bodies: their callers are read instead.
WRAPPER_BODIES = [("k8s/lib.sh", 'k8s_kubectl -n "$ns" get "$@"'), ("k8s/session-create.sh", 'k8s_get "$ns" "$@"'),
                  ("k8s/manifests.sh", '"$4" | k8s_kubectl apply -f -')]
# k8s_ensure_claim <namespace> <claim> <what> <render-function> applies what its last word
# renders: each call is read as an apply of that function, which must render claims only.
ENSURE_CLAIM = re.compile(r'\bk8s_ensure_claim\s+("[^"]*"|\S+)\s+("[^"]*"|\S+)\s+("[^"]*"|\S+)\s+(\w+)')
ensure_calls = 0
# Wrapper -> how many words come before the `kubectl get` arguments (the namespace; k8s_read's
# description).
WRAPPERS = {"k8s_get": 1, "k8s_read": 1}
# Calls into another namespace (the one --network gives a session): need the network grant
# (K8S_NETWORK_RULES), not the user's Role. Matched by (file, the call's namespace word).
OTHER_NS = {("k8s/net.sh", "$target")}
# Decided against, and why (a test fails if they are ever granted).
NOT_GRANTED = {
    ("ingresses", "list", "user-cluster"): "it would show every user's page names; the page name check reads the user's own namespace and the admission policy keeps users' names apart",
    ("secrets", "get", "user"): "a page's login is made with create and removed by name: no read of the namespace's Secrets (only the MCP token Secret, by name)",
    ("secrets", "list", "user"): "as get",
    ("services", "list", "user-cluster"): "another namespace's Services are readable only where an admin grants it (aidc user allow-network)",
}
# Granted with no call of its own, and why.
REASONS = {
    ("events", "get"): "kubectl describe, which aidc's errors point to",
    ("events", "list"): "kubectl describe", ("events", "watch"): "kubectl describe",
    ("pods/exec", "get"): "kubectl exec's websocket is a GET; API servers authorize it as get or create",
    ("serviceaccounts/token", "create"): "aidc user creds, a user renewing their own kubeconfig",
}
for r in ("pods", "services", "configmaps", "persistentvolumeclaims", "deployments",
          "statefulsets", "networkpolicies", "persistentvolumes", "ingresses"):
    REASONS[(r, "watch")] = "kubectl delete --wait, wait and rollout status watch what they wait for"
    REASONS[(r, "list")] = "kubectl get -l and delete -l list first"

# ---- reading the calls -----------------------------------------------------------------------
def tokens(s):
    """Shell words up to the end of the command (| > < ; ) && ||), keeping quotes and $( )."""
    out, i, n = [], 0, len(s)
    while i < n:
        while i < n and s[i] in " \t": i += 1
        if i >= n or s[i] in "|><;)&": break
        j, depth, q = i, 0, None
        while j < n:
            c = s[j]
            if q:
                if c == "\\" and q == '"': j += 2; continue
                if c == q and depth == 0: q = None
                elif c == "$" and s[j+1:j+2] == "(": depth += 1; j += 1
                elif c == ")" and depth: depth -= 1
                elif c == '"' and depth and q == '"': pass
            else:
                if c in "'\"": q = c
                elif c == "$" and s[j+1:j+2] == "(": depth += 1; j += 1
                elif c == ")" and depth: depth -= 1
                elif depth == 0 and c in " \t|><;)&": break
            j += 1
        if s[i:j].isdigit() and s[j:j+1] in "<>": break    # 2>/dev/null
        out.append(s[i:j]); i = j
    return out

def unq(t):
    return t.replace('"', "").replace("'", "")

FLAGS_WITH_VALUE = {"-n", "-c", "-l", "-o", "-p", "-f", "--type", "--for", "--timeout",
                    "--duration", "--from-file", "--field-selector", "--request-timeout"}

def res_of(word):
    w = unq(word).split("/")[0]
    if w not in ALIAS: return None
    return ALIAS[w]

needs, other_needs, problems, calls = {}, {}, [], 0
other = False
# The user's MCP server runs the CLI under its own ServiceAccount (K8S_MCP_RULES) for
# session_create, session_list and session_status (and their resources): `aidc create|list|
# status --backend kubernetes`, with no --port or --expose (its config has no ports:). Every
# call those reach must be within the MCP's rules: the scripts of those verbs, minus their
# page and tunnel lines, and the helpers they call in the libraries.
MCP_SCRIPTS = {"k8s/session-create.sh", "k8s/session-list.sh", "k8s/session-status.sh",
               "k8s/session-where.sh"}
# The helpers in scope are every function those scripts call, and every function those call
# in turn: read from the scripts, not listed by hand, so a helper a verb starts calling is held
# to the MCP's rules too. Left out: the functions that make pages and tunnels (defined in
# expose.sh and tunnel.sh, which the server never asks for: no --expose, no ports:), but not
# their readers, which every status runs. The dispatcher's own cluster call for these verbs
# (the audit size warning) is in scope as well.
def _functions():
    bodies, where = {}, {}
    for root, _, files in os.walk(scripts):
        for f in files:
            if not f.endswith(".sh") and f != "aidc": continue
            rel_ = os.path.relpath(os.path.join(root, f), scripts)
            name, body = None, []
            for line in open(os.path.join(root, f)).read().split("\n"):
                m = re.match(r"^(\w+)\(\)\s*\{", line)
                if m: name, body = m.group(1), [line[m.end():]]; continue
                if name is not None:
                    if line.startswith("}"): bodies[name] = "\n".join(body); where[name] = rel_; name = None
                    else: body.append(line)
    return bodies, where
_bodies, _defined_in = _functions()
def _called(text):
    """The functions `text` calls: its words outside comments that name a function."""
    code = "\n".join("" if l.lstrip().startswith("#") else l.split(" #")[0] for l in text.split("\n"))
    return {fn for fn in _bodies if re.search(r"(^|[^\w-])" + re.escape(fn) + r"\b", code)}
MCP_READERS = {"k8s_exposed", "k8s_tunnels", "k8s_expose_host", "k8s_port_ok", "k8s_port_spec"}
MCP_USER_ONLY_FUNCS = {fn for fn, f in _defined_in.items()
                       if f in ("k8s/expose.sh", "k8s/tunnel.sh") and fn not in MCP_READERS}
# The long-lived Claude token is a file on the user's own machine (aidc claude-token); the
# server's CLI never hands one on: session-create.sh skips it under the server (AIDC_MCP_BACKEND).
MCP_USER_ONLY_FUNCS |= {"k8s_claude_token_secret"}
def _user_only(line):
    return bool(_called(line) & MCP_USER_ONLY_FUNCS)
_seed = set(["aidc_audit_warn_k8s"])
for rel_ in MCP_SCRIPTS:
    for line in open(os.path.join(scripts, rel_)).read().split("\n"):
        if not _user_only(line): _seed |= _called(line)
MCP_FUNCS, _todo = set(), list(_seed - MCP_USER_ONLY_FUNCS)
while _todo:
    fn = _todo.pop()
    if fn in MCP_FUNCS or fn in MCP_USER_ONLY_FUNCS: continue
    MCP_FUNCS.add(fn)
    _todo += [g for g in _called("\n".join(l for l in _bodies.get(fn, "").split("\n")
                                             if not _user_only(l))) - MCP_FUNCS]
for fn in ("k8s_get", "k8s_session_taint", "k8s_wait_dev_ready", "k8s_ensure_transcripts",
           "k8s_exposed"):
    if fn not in MCP_FUNCS:
        print(f"  FAIL: the MCP scope misses {fn}: the call graph reader is broken"); sys.exit(1)
for fn in ("k8s_expose_check", "k8s_render_expose_login", "k8s_tunnel_start"):
    if fn in MCP_FUNCS:
        print(f"  FAIL: the MCP scope holds {fn}, which the server never runs"); sys.exit(1)
mcp_needs, mcp_scope = {}, False
def need(where, r, v):
    (other_needs if other else needs).setdefault((r, v), []).append(where)
    if mcp_scope and not other:
        mcp_needs.setdefault((r, v), []).append(where)

def render_of(line):
    """The manifest function piped into this call (whole names: k8s_render_expose is not
    k8s_render_expose_login)."""
    fns = [fn for fn in renders if re.search(r"\b" + fn + r"\b", line)]
    return fns[0] if fns else None

for root, _, files in os.walk(scripts):
    for f in files:
        if not f.endswith(".sh") and f != "aidc": continue
        path = os.path.join(root, f); rel = os.path.relpath(path, scripts)
        text = open(path).read()
        joined = re.sub(r"\\\n\s*", " ", text)
        func = None
        for ln, line in enumerate(joined.split("\n"), 1):
            fm = re.match(r"^(\w+)\(\)\s*\{", line)
            if fm: func = fm.group(1)
            elif line.startswith("}"): func = None
            mcp_scope = ((rel in MCP_SCRIPTS and not _user_only(line)) or func in MCP_FUNCS)
            code = line.split(" #")[0] if not line.lstrip().startswith("#") else ""
            direct = re.search(r"(^\s*|\$\(\s*|[|;&]\s*|\b(then|do|else|if|!)\s+)kubectl\s", code)
            if direct and rel != "k8s/lib.sh" and code[:direct.start()].count('"') % 2 == 0:
                problems.append(f"{rel}: kubectl called directly (use k8s_kubectl): {line.strip()}")
            for em in ENSURE_CLAIM.finditer(code):
                fn, where, other = em.group(4), f"{rel}: {line.strip()[:110]}", False
                ensure_calls += 1; calls += 1
                if fn not in renders:
                    problems.append(f"k8s_ensure_claim with no known render function: {where}"); continue
                if renders[fn] != ["PersistentVolumeClaim"]:
                    problems.append(f"k8s_ensure_claim applies {fn}, which renders {renders[fn]}, not one claim: {where}"); continue
                for v in ("get", "create", "patch"): need(where, "persistentvolumeclaims", v)
            for m in re.finditer(r"\b(k8s_kubectl|k8s_get|k8s_read)\b", code):
                fn, rest = m.group(1), code[m.end():]
                if rest.startswith("()"): continue        # the definition
                if fn == "k8s_read" and rel != "k8s/session-create.sh": continue
                where = f"{rel}: {line.strip()[:110]}"
                calls += 1
                other = False
                if rel in ADMIN_FILES or any(rel == a and s in line for a, s in ADMIN_LINES):
                    continue
                if any(rel == a and s in line for a, s in WRAPPER_BODIES):
                    continue
                dec = [d for (a, s), d in DECLARED.items() if a == rel and s in line]
                if dec:
                    for r, v in dec[0]: need(where, r, v)
                    continue
                t = tokens(rest)
                if fn in WRAPPERS:
                    pre, t = t[:WRAPPERS[fn]], t[WRAPPERS[fn]:]
                    if fn == "k8s_get" and pre and (rel, unq(pre[0])) in OTHER_NS: other = True
                    t = ["get"] + t
                words, i = [], 0
                while i < len(t):
                    w = unq(t[i])
                    if re.match(r"\$\{\w+:\+-", w):       # ${x:+-l "$x"}: an optional flag
                        i += 2; continue
                    if w.startswith("-"):
                        i += 2 if (w in FLAGS_WITH_VALUE and "=" not in w) else 1
                        continue
                    words.append(t[i]); i += 1
                if not words:
                    problems.append(f"cannot read: {where}"); continue
                sub = unq(words[0])
                if sub in ("auth", "config", "api-resources") or (sub == "get" and "--raw" in rest):
                    continue                              # always allowed, or local
                if sub == "exec":
                    need(where, "pods/exec", "create"); need(where, "pods", "get"); continue
                if sub == "logs":
                    need(where, "pods/log", "get"); need(where, "pods", "get")
                    if len(words) > 1 and unq(words[1]).startswith("deployment/"):
                        need(where, "deployments", "get"); need(where, "pods", "list")
                    continue
                if sub == "port-forward":
                    need(where, "pods/portforward", "create"); need(where, "pods", "get"); continue
                if sub == "create":
                    if "--dry-run=client" in rest: continue
                    if len(words) > 1 and unq(words[1]) == "token":
                        need(where, "serviceaccounts/token", "create"); continue
                    if re.search(r"-f -", rest) and "SelfSubjectRulesReview" in line: continue
                    fn = render_of(line[:m.start()]) if re.search(r"-f -", rest) else None
                    if fn:
                        for k in renders[fn]: need(where, KIND[k], "create")
                        continue
                    problems.append(f"cannot read create: {where}"); continue
                if sub == "apply":
                    fn = render_of(line[:m.start()])
                    pre = line[:m.start()]
                    if fn:
                        for k in renders[fn]:
                            for v in ("get", "create", "patch"): need(where, KIND[k], v)
                    elif "create configmap" in pre:
                        for v in ("get", "create", "patch"): need(where, "configmaps", v)
                    else:
                        problems.append(f"cannot tell what is applied: {where}")
                    continue
                if sub in ("rollout", "set"):
                    target = words[2] if len(words) > 2 else ""
                    r = res_of(target)
                    if not r: problems.append(f"cannot read {sub}: {where}"); continue
                    if sub == "rollout" and unq(words[1]) == "status":
                        for v in ("get", "list", "watch"): need(where, r, v)
                    else:
                        need(where, r, "get"); need(where, r, "patch")
                    continue
                if sub == "wait":
                    r = res_of(words[1]) if len(words) > 1 else None
                    if not r: problems.append(f"cannot read wait: {where}"); continue
                    for v in ("get", "list", "watch"): need(where, r, v)
                    continue
                if sub in ("get", "delete", "patch", "annotate"):
                    if len(words) < 2: problems.append(f"cannot read {sub}: {where}"); continue
                    if "/" in unq(words[1]):              # type/name type/name ...
                        rs = sorted({res_of(x) for x in words[1:] if "/" in unq(x)}, key=str)
                    else:
                        rs = [res_of(x) for x in unq(words[1]).split(",")]
                    if None in rs: problems.append(f"unknown resource in: {where}"); continue
                    named = len(words) > 2 or "/" in unq(words[1])
                    for r in rs:
                        if sub == "get": need(where, r, "get" if named else "list")
                        elif sub == "delete":
                            need(where, r, "delete")
                            if not named: need(where, r, "list")
                        else: need(where, r, "get" if sub == "annotate" else "patch"); need(where, r, "patch")
                    continue
                problems.append(f"unknown kubectl verb '{sub}': {where}")

granted_ns, granted_cl = rules["user"], rules["user-cluster"]
for (r, v), wh in sorted(needs.items()):
    ok = (r, v) in (granted_cl if r in CLUSTER else granted_ns)
    print(f"  {'PASS' if ok else 'FAIL'}: {v} {r} granted ({len(wh)} call(s), e.g. {wh[0]})")
    if not ok: problems.append(f"{v} {r} is used but not granted: {wh[0]}")
for rv in sorted((granted_ns | granted_cl) - set(needs)):
    if rv in REASONS:
        print(f"  PASS: {rv[1]} {rv[0]} granted with no call: {REASONS[rv]}")
    else:
        problems.append(f"{rv[1]} {rv[0]} is granted but no call uses it and no reason is named")
for (r, v), wh in sorted(other_needs.items()):
    ok = (r, v) in rules["network"]
    print(f"  {'PASS' if ok else 'FAIL'}: {v} {r} in another namespace granted by allow-network ({len(wh)} call(s), e.g. {wh[0]})")
    if not ok: problems.append(f"{v} {r} in another namespace is used but the network grant lacks it: {wh[0]}")
for rv in sorted(rules["network"] - set(other_needs)):
    problems.append(f"the network grant gives {rv[1]} {rv[0]} but no call into another namespace uses it")
# Each resource under its own API group, and the one resourceName restriction where it belongs.
GROUP = {"pods": "", "pods/exec": "", "pods/log": "", "pods/portforward": "", "services": "",
         "configmaps": "", "persistentvolumeclaims": "", "events": "", "secrets": "",
         "serviceaccounts/token": "", "nodes": "", "persistentvolumes": "",
         "deployments": "apps", "statefulsets": "apps", "networkpolicies": "networking.k8s.io",
         "ingresses": "networking.k8s.io", "ingressclasses": "networking.k8s.io",
         "middlewares": "traefik.io", "runtimeclasses": "node.k8s.io",
         "storageclasses": "storage.k8s.io"}
# The named grants: the user's own token (to renew their kubeconfig) and their MCP server's
# token Secret (aidc mcp reads it into ~/.config/aidc/mcp-token); a grant of a resource with no
# name here is not narrowed.
RESOURCE_NAMES = {("user", "serviceaccounts/token"): {"aidc-user"},
                  ("user", "secrets"): {"", "aidc-mcp-token"}}
before = len(problems)
for which, r, g, n in groups:
    if r not in GROUP: problems.append(f"{which}: {r} has no known API group (teach GROUP)"); continue
    if g != GROUP[r]: problems.append(f"{which}: {r} is granted under API group '{g}', not '{GROUP[r]}'")
    want = RESOURCE_NAMES.get((which, r), {""})
    if n not in want: problems.append(f"{which}: {r} is restricted to '{n}', not one of {sorted(want)}")
for (which, r), names in RESOURCE_NAMES.items():
    for n in names - {""}:
        if not any(w == which and x == r and y == n for w, x, _, y in groups):
            problems.append(f"{which}: {r} ({n}) is not granted")
if len(problems) == before: print(f"  PASS: {len(groups)} rules each under their resource's API group, resourceNames only on the aidc-user token and the MCP token Secret")
for (r, v, which), why in sorted(NOT_GRANTED.items()):
    if (r, v) in unnamed[which]: problems.append(f"{v} {r} ({which}) is granted, decided against: {why}")
    else: print(f"  PASS: not granted, {v} {r} ({which}): {why}")
for (r, v), wh in sorted(mcp_needs.items()):
    ok = (r, v) in (rules["mcp-cluster"] if r in CLUSTER else rules["mcp"])
    print(f"  {'PASS' if ok else 'FAIL'}: the MCP server's CLI: {v} {r} granted ({len(wh)} call(s), e.g. {wh[0]})")
    if not ok: problems.append(f"the MCP server's CLI needs {v} {r}, which K8S_MCP_RULES lacks: {wh[0]}")
if len(mcp_needs) < 10: problems.append(f"only {len(mcp_needs)} needs read for the MCP server's CLI: the scope is missing calls")
extra = (rules["mcp"] - granted_ns) | (rules["mcp-cluster"] - granted_cl)
if extra: problems.append(f"the MCP's rules grant what the user's do not: {sorted(extra)}")
else: print("  PASS: the MCP's rules are within the user's")
if ensure_calls < 5: problems.append(f"only {ensure_calls} k8s_ensure_claim calls read (the transcripts, Claude config and accounts, MCP state and Syncthing claims): the reader is skipping some")
else: print(f"  PASS: {ensure_calls} k8s_ensure_claim calls read, each applying one claim")
if calls < 60: problems.append(f"only {calls} kubectl calls read: the reader is skipping some")
else: print(f"  PASS: {calls} kubectl calls read")
for p in problems: print(f"  FAIL: {p}")
print(f"\n{'failed: ' + str(len(problems)) if problems else 'passed'}")
sys.exit(1 if problems else 0)
PY
