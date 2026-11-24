#!/usr/bin/env bash
# Keeps a user's Role in step with aidc's scripts (scripts/k8s/manifests.sh, K8S_USER_RULES and
# K8S_USER_CLUSTER_RULES; docs/design-12-kubernetes.md, "Users and credentials").
#
# Reads every kubectl call in scripts/ (all go through k8s_kubectl), works out the API resource
# and RBAC verb each one needs, and fails when:
#   - a call a user runs needs a (resource, verb) the user's rules do not grant (a new command
#     would fail under a user's own kubeconfig);
#   - the rules grant a (resource, verb) no call uses and no reason below names (the Role grows
#     beyond what aidc does);
#   - a call cannot be read (a new form this test does not know): it must be taught, not skipped;
#   - the MCP's rules grant anything the user's do not;
#   - kubectl is called directly instead of through k8s_kubectl.
# What `kubectl apply` makes comes from rendering each manifest function, not from a list.
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
    AIDC_VERSION_TAG="test"
    kinds() { yq ea -N '.kind' - | sort -u | paste -sd, -; }
    {
        printf 'RULES user\n%s\nRULES user-cluster\n%s\nRULES mcp\n%s\nRULES mcp-cluster\n%s\n' \
            "$K8S_USER_RULES" "$K8S_USER_CLUSTER_RULES" "$K8S_MCP_RULES" "$K8S_MCP_CLUSTER_RULES"
        printf 'RENDER k8s_render_session %s\n' "$(k8s_render_session s1 /home/alice/r default '{}' s1-audit-1 10.0.0.1 | kinds)"
        printf 'RENDER k8s_render_git %s\n' "$(k8s_render_git '{}' | kinds)"
        printf 'RENDER k8s_render_repo_dir %s\n' "$(k8s_render_repo_dir p /home/alice/r make '{}' | kinds)"
        printf 'RENDER k8s_render_git_repos %s\n' "$(k8s_render_git_repos aidc-u-alice 'a/b' | yq -p=json '.kind')"
    } > "$SCRATCH/facts"
)

python3 -I - "$AIDC_ROOT/scripts" "$SCRATCH/facts" <<'PY'
import os, re, sys

scripts, facts_path = sys.argv[1], sys.argv[2]

# ---- the rules and renders --------------------------------------------------------------------
rules, renders, cur = {}, {}, None
for line in open(facts_path):
    line = line.rstrip("\n")
    if line.startswith("RULES "):
        cur = line.split()[1]; rules[cur] = set(); continue
    if line.startswith("RENDER "):
        _, fn, kinds = line.split(" ", 2); renders[fn] = [k for k in kinds.split(",") if k]; cur = None; continue
    if cur and line.strip():
        f = line.split()
        g = "" if f[0] == "core" else f[0]
        for v in f[2].split(","):
            rules[cur].add((f[1], v))

KIND = {"Pod": "pods", "Service": "services", "ConfigMap": "configmaps",
        "PersistentVolumeClaim": "persistentvolumeclaims", "Deployment": "deployments",
        "StatefulSet": "statefulsets", "NetworkPolicy": "networkpolicies"}
ALIAS = {"pod": "pods", "pods": "pods", "pvc": "persistentvolumeclaims",
         "persistentvolumeclaims": "persistentvolumeclaims", "pv": "persistentvolumes",
         "service": "services", "services": "services", "svc": "services",
         "configmap": "configmaps", "configmaps": "configmaps", "deployment": "deployments",
         "deployments": "deployments", "statefulset": "statefulsets", "statefulsets": "statefulsets",
         "networkpolicy": "networkpolicies", "networkpolicies": "networkpolicies",
         "runtimeclass": "runtimeclasses", "storageclass": "storageclasses", "nodes": "nodes",
         "node": "nodes", "events": "events"}
CLUSTER = {"nodes", "persistentvolumes", "runtimeclasses", "storageclasses"}

# Calls only an admin makes (they set up the cluster, users and the system namespace), or that
# go to the system namespace and degrade to a note without the right (aidc k8s check).
ADMIN_FILES = {"k8s/user-add.sh", "k8s/user-remove.sh", "k8s/k8s-setup.sh", "k8s/k8s-build.sh"}
ADMIN_LINES = [("k8s/user-creds.sh", "delete serviceaccount"),       # --revoke
               ("k8s/user-creds.sh", "k8s_render_user_access"),      # --revoke
               ("k8s/k8s-check.sh", '-n "$sys_ns"')]                 # the registry
# Calls whose resource is a variable, resolved here by hand (file, text in the call) -> needs.
DECLARED = {
    ("k8s/session-create.sh", 'get "$@"'): [("persistentvolumeclaims", "get"), ("networkpolicies", "get"), ("deployments", "get")],
    ("k8s/lib.sh", 'k8s_kubectl "$verb" -f -'): [("configmaps", "create"), ("configmaps", "update")],
    ("k8s/session-kill.sh", 'annotate "$audit"'): [("persistentvolumeclaims", "get"), ("persistentvolumeclaims", "patch")],
    ("k8s/session-logs.sh", 'logs ${FOLLOW[@]+"${FOLLOW[@]}"} "$target"'): [("pods", "get"), ("pods/log", "get")],
}
# Granted with no call of its own, and why.
REASONS = {
    ("events", "get"): "kubectl describe, which aidc's errors point to",
    ("events", "list"): "kubectl describe", ("events", "watch"): "kubectl describe",
    ("pods/exec", "get"): "kubectl exec's websocket is a GET; API servers authorize it as get or create",
    ("serviceaccounts/token", "create"): "aidc user creds, a user renewing their own kubeconfig",
}
for r in ("pods", "services", "configmaps", "persistentvolumeclaims", "deployments",
          "statefulsets", "networkpolicies", "persistentvolumes"):
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

needs, problems, calls = {}, [], 0
def need(where, r, v):
    needs.setdefault((r, v), []).append(where)

for root, _, files in os.walk(scripts):
    for f in files:
        if not f.endswith(".sh") and f != "aidc": continue
        path = os.path.join(root, f); rel = os.path.relpath(path, scripts)
        text = open(path).read()
        joined = re.sub(r"\\\n\s*", " ", text)
        for ln, line in enumerate(joined.split("\n"), 1):
            code = line.split(" #")[0] if not line.lstrip().startswith("#") else ""
            direct = re.search(r"(^\s*|\$\(\s*|[|;&]\s*|\b(then|do|else|if|!)\s+)kubectl\s", code)
            if direct and rel != "k8s/lib.sh" and code[:direct.start()].count('"') % 2 == 0:
                problems.append(f"{rel}: kubectl called directly (use k8s_kubectl): {line.strip()}")
            for m in re.finditer(r"k8s_kubectl\b", code):
                rest = code[m.end():]
                if rest.startswith("()"): continue        # the definition
                where = f"{rel}: {line.strip()[:110]}"
                calls += 1
                if rel in ADMIN_FILES or any(rel == a and s in line for a, s in ADMIN_LINES):
                    continue
                dec = [d for (a, s), d in DECLARED.items() if a == rel and s in line]
                if dec:
                    for r, v in dec[0]: need(where, r, v)
                    continue
                t = tokens(rest)
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
                if sub == "create":
                    if "--dry-run=client" in rest: continue
                    if len(words) > 1 and unq(words[1]) == "token":
                        need(where, "serviceaccounts/token", "create"); continue
                    if re.search(r"-f -", rest) and "SelfSubjectRulesReview" in line: continue
                    problems.append(f"cannot read create: {where}"); continue
                if sub == "apply":
                    fns = [fn for fn in renders if fn in line]
                    pre = line[:m.start()]
                    if fns:
                        for k in renders[fns[0]]:
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
extra = (rules["mcp"] - granted_ns) | (rules["mcp-cluster"] - granted_cl)
if extra: problems.append(f"the MCP's rules grant what the user's do not: {sorted(extra)}")
else: print("  PASS: the MCP's rules are within the user's")
if calls < 60: problems.append(f"only {calls} kubectl calls read: the reader is skipping some")
else: print(f"  PASS: {calls} kubectl calls read")
for p in problems: print(f"  FAIL: {p}")
print(f"\n{'failed: ' + str(len(problems)) if problems else 'passed'}")
sys.exit(1 if problems else 0)
PY
