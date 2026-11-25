# shellcheck shell=bash
# LAN pages: a Kubernetes session's port on the home network at a stable name (K8S-15).
#
# `aidc create --expose <port> [--login]` gives the session:
#   - a ClusterIP Service for its dev pod (<session>-dev) on the exposed ports;
#   - an Ingress per port at <session>-<user>.<domain> (the first port) and
#     <session>-<port>-<user>.<domain> (any further one), the domain from the user's config
#     (kubernetes.ingress.domain), never aidc's;
#   - a NetworkPolicy letting in only the ingress controller's pods, on those ports only;
#   - with --login (the developer's choice per session; aidc imposes none: owner ruling
#     2026-11-24), a generated username and password, printed once and kept only as an htpasswd
#     hash, put in front of every exposed port by the controller's own mechanism: a Traefik
#     basicAuth Middleware, or ingress-nginx's auth annotations. Another controller refuses
#     --login rather than expose the page without the login asked for. The controller is the
#     config's kubernetes.ingress.controller or the IngressClass's exact spec.controller, never
#     a guess from a name; after the page is made, create opens it once without the login and
#     removes it again unless it answered 401.
# TLS: a Secret in the user's namespace (tls_secret), a cert-manager ClusterIssuer
# (cluster_issuer), or else the controller's default certificate (a wildcard one serves every
# name under the domain). `aidc kill` removes all of it (labelled with the session).
#
# Sourced after lib.sh and manifests.sh.

# k8s_expose_host <session> <port> <first: 1|0>: the page's host name.
k8s_expose_host() {
    if [ "$3" = 1 ]; then
        printf '%s-%s.%s' "$1" "$AIDC_K8S_USER" "$AIDC_K8S_INGRESS_DOMAIN"
    else
        printf '%s-%s-%s.%s' "$1" "$2" "$AIDC_K8S_USER" "$AIDC_K8S_INGRESS_DOMAIN"
    fi
}

# k8s_expose_check <session> <login 0|1> <port>...: whether the config can expose these ports;
# prints why not on stderr and returns 1.
k8s_expose_check() {
    local s="$1" login="$2" p first=1 host
    shift 2
    [ -n "$AIDC_K8S_INGRESS_DOMAIN" ] || {
        printf -- '--expose needs kubernetes.ingress.domain in your config: the wildcard domain your pages live under (README, Kubernetes backend)\n' >&2
        return 1; }
    printf '%s' "$AIDC_K8S_INGRESS_DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || {
        printf 'kubernetes.ingress.domain %s is not a domain name\n' "'$AIDC_K8S_INGRESS_DOMAIN'" >&2; return 1; }
    [ -n "$AIDC_K8S_INGRESS_CLASS" ] || {
        printf -- '--expose needs kubernetes.ingress.class in your config: the IngressClass of the controller that serves the domain\n' >&2
        return 1; }
    k8s_ingress_controller_settle || return 1
    if [ -z "$AIDC_K8S_INGRESS_CONTROLLER_NS" ] || [ -z "$AIDC_K8S_INGRESS_CONTROLLER_LABELS" ]; then
        printf -- '--expose needs kubernetes.ingress.controller_namespace and controller_labels for a %s controller: only its pods are let in to the port\n' "$AIDC_K8S_INGRESS_CONTROLLER" >&2
        return 1
    fi
    if [ "$login" = 1 ]; then
        case "$AIDC_K8S_INGRESS_CONTROLLER" in
            traefik|ingress-nginx) ;;
            *) printf -- '--login: aidc puts a login in front of a page with Traefik or ingress-nginx; the controller of IngressClass %s is %s (set kubernetes.ingress.controller when it is one of those; README, Kubernetes backend, says how to add one by hand)\n' "'$AIDC_K8S_INGRESS_CLASS'" "'$AIDC_K8S_INGRESS_CONTROLLER'" >&2
               return 1 ;;
        esac
        command -v openssl >/dev/null 2>&1 || { printf -- '--login needs openssl on this machine (it hashes the password)\n' >&2; return 1; }
        command -v curl >/dev/null 2>&1 || { printf -- '--login needs curl on this machine (it checks the page asks for the login)\n' >&2; return 1; }
    fi
    for p in "$@"; do
        host=$(k8s_expose_host "$s" "$p" "$first")
        local label="${host%%.*}"
        [ "${#label}" -le 63 ] || { printf 'the page name %s is longer than 63 characters: pick a shorter session name\n' "$label" >&2; return 1; }
        first=0
    done
}

# k8s_expose_taken <namespace> <host>: 0 (printing where) when another Ingress already serves
# <host>, in the user's namespace or (when this user may read them) any other.
k8s_expose_taken() {
    local out
    for scope in "-n $1" "-A"; do
        # shellcheck disable=SC2086  # the scope is two words or one
        out=$(k8s_kubectl $scope get ingress -o json --request-timeout=10s </dev/null 2>/dev/null) || continue
        out=$(printf '%s' "$out" | jq -r --arg h "$2" '.items[] | select([.spec.rules[]?.host] | index($h)) | "\(.metadata.namespace)/\(.metadata.name)"' | head -n1)
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    done
    return 1
}

# k8s_htpasswd_line <user> <password>: an htpasswd line (apr1), which Traefik and ingress-nginx
# both read.
k8s_htpasswd_line() {
    printf '%s:%s' "$1" "$(printf '%s' "$2" | openssl passwd -apr1 -stdin)"
}

# k8s_render_expose <session> <login-secret-htpasswd or ""> <port>...: the Service, the ingress
# NetworkPolicy, the login (when given) and an Ingress per port.
k8s_render_expose() {
    local s="$1" htpasswd="$2" ns labels p first=1 host svc_ports="" pol_ports="" ann tls
    shift 2
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, aidc/session: ${s}"
    for p in "$@"; do
        svc_ports="${svc_ports}    - {name: p${p}, port: ${p}, targetPort: ${p}}
"
        pol_ports="${pol_ports}{protocol: TCP, port: ${p}}, "
    done
    pol_ports="[${pol_ports%, }]"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata: {name: ${s}-dev, namespace: ${ns}, labels: {${labels}, app: expose}}
spec:
  selector: {aidc/session: ${s}, app: dev}
  ports:
${svc_ports%$'\n'}
---
# Only the ingress controller's pods may open the exposed ports; nothing else reaches the dev pod.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${s}-expose, namespace: ${ns}, labels: {${labels}, app: expose}}
spec:
  podSelector: {matchLabels: {aidc/session: ${s}, app: dev}}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ${AIDC_K8S_INGRESS_CONTROLLER_NS}}}
          podSelector: {matchLabels: ${AIDC_K8S_INGRESS_CONTROLLER_LABELS}}
      ports: ${pol_ports}
EOF
    ann=""
    if [ -n "$htpasswd" ]; then
        case "$AIDC_K8S_INGRESS_CONTROLLER" in
            traefik)
                cat <<EOF
---
apiVersion: v1
kind: Secret
metadata: {name: ${s}-login, namespace: ${ns}, labels: {${labels}, app: expose}}
type: Opaque
stringData: {users: $(jq -n --arg v "$htpasswd" '$v')}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: ${s}-login, namespace: ${ns}, labels: {${labels}, app: expose}}
spec:
  basicAuth: {secret: ${s}-login, realm: ${s}}
EOF
                ann="traefik.ingress.kubernetes.io/router.middlewares: ${ns}-${s}-login@kubernetescrd" ;;
            ingress-nginx)
                cat <<EOF
---
apiVersion: v1
kind: Secret
metadata: {name: ${s}-login, namespace: ${ns}, labels: {${labels}, app: expose}}
type: Opaque
stringData: {auth: $(jq -n --arg v "$htpasswd" '$v')}
EOF
                ann="nginx.ingress.kubernetes.io/auth-type: basic, nginx.ingress.kubernetes.io/auth-secret: ${s}-login, nginx.ingress.kubernetes.io/auth-realm: ${s}" ;;
        esac
    fi
    [ -z "$AIDC_K8S_INGRESS_CLUSTER_ISSUER" ] || ann="${ann:+${ann}, }cert-manager.io/cluster-issuer: ${AIDC_K8S_INGRESS_CLUSTER_ISSUER}"
    for p in "$@"; do
        host=$(k8s_expose_host "$s" "$p" "$first")
        first=0
        if [ -n "$AIDC_K8S_INGRESS_TLS_SECRET" ]; then
            tls="[{hosts: [${host}], secretName: ${AIDC_K8S_INGRESS_TLS_SECRET}}]"
        elif [ -n "$AIDC_K8S_INGRESS_CLUSTER_ISSUER" ]; then
            tls="[{hosts: [${host}], secretName: ${s}-expose-${p}-tls}]"
        else
            tls="[{hosts: [${host}]}]"
        fi
        cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${s}-expose-${p}
  namespace: ${ns}
  labels: {${labels}, app: expose}
  annotations: {aidc/expose-port: "${p}"${ann:+, ${ann}}}
spec:
  ingressClassName: ${AIDC_K8S_INGRESS_CLASS}
  tls: ${tls}
  rules:
    - host: ${host}
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: ${s}-dev, port: {number: ${p}}}}}
EOF
    done
}

# k8s_expose_login_probe <namespace> <session> <port>...: whether every page asks for the login:
# each is opened once without it and must answer 401. A controller that ignores the login (one
# that only looks like ingress-nginx) would serve the page to anyone, so anything else fails: 2xx
# or 3xx at once (the page answered), a 404, 5xx or no answer once AIDC_K8S_LOGIN_PROBE_WAIT
# seconds (default 60) have passed (the controller takes a few seconds to pick a new Ingress up).
# The page is reached at its Ingress's load balancer address when the cluster gives one (so the
# check does not hang on this machine's DNS for the domain), else by its name. Prints
# "<host> <last status>" for each page that did not, and returns 1 then. The certificate is not
# checked: only the status counts.
k8s_expose_login_probe() {
    local ns="$1" s="$2" p h code end lb first=1 bad=0
    shift 2
    for p in "$@"; do
        h=$(k8s_expose_host "$s" "$p" "$first"); first=0
        end=$(( $(date +%s) + ${AIDC_K8S_LOGIN_PROBE_WAIT:-60} ))
        while :; do
            lb=$(k8s_kubectl -n "$ns" get ingress "${s}-expose-${p}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
                --request-timeout=10s </dev/null 2>/dev/null) || lb=""
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 ${lb:+--resolve "${h}:443:${lb}"} \
                "https://${h}/" </dev/null 2>/dev/null) || true
            code="${code:-000}"
            case "$code" in
                401) break ;;
                2??|3??) printf '%s %s\n' "$h" "$code"; bad=1; break ;;
            esac
            if [ "$(date +%s)" -ge "$end" ]; then printf '%s %s\n' "$h" "$code"; bad=1; break; fi
            sleep 2
        done
    done
    [ "$bad" = 0 ]
}

# k8s_exposed <namespace> <session>: the session's pages, "<port> <host> <login yes|no>" per line.
# Returns 2 when the cluster did not answer.
k8s_exposed() {
    local out
    out=$(k8s_get "$1" ingress -l "aidc/session=${2},app=expose" -o json) || { printf '%s' "$out"; return 2; }
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r '.items[] | [(.metadata.annotations["aidc/expose-port"] // "?"), .spec.rules[0].host,
        (if ((.metadata.annotations // {}) | keys | map(test("router.middlewares|auth-type")) | any) then "yes" else "no" end)]
        | join(" ")' | sort -n
}

# k8s_expose_remove <namespace> <session>: what --expose made (the Ingresses, Service, policy,
# login and any certificate cert-manager made for it). The Middleware kind exists only where
# Traefik's CRDs are installed, so its removal may fail without meaning anything.
k8s_expose_remove() {
    local ns="$1" s="$2" certs
    certs=$(k8s_kubectl -n "$ns" get ingress -l "aidc/session=${s},app=expose" -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.annotations["cert-manager.io/cluster-issuer"]) | .spec.tls[]?.secretName // empty' 2>/dev/null || true)
    k8s_kubectl -n "$ns" delete ingress,secret -l "aidc/session=${s},app=expose" --ignore-not-found >&2 || return 1
    k8s_kubectl -n "$ns" delete middlewares.traefik.io -l "aidc/session=${s},app=expose" --ignore-not-found >/dev/null 2>&1 || true
    # shellcheck disable=SC2086  # one secret name per word
    [ -z "$certs" ] || k8s_kubectl -n "$ns" delete secret $certs --ignore-not-found >&2 || true
}
