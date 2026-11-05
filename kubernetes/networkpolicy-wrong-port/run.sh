#!/usr/bin/env bash
# NetworkPolicy wrong-port scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh break     # deploy the service healthy, then lock it down with a NetworkPolicy on the wrong port
#   ./run.sh fix       # allow the port the pod actually listens on
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete the scenario's resources
#
# A silent failure. Every pod stays Running and Ready, the Service keeps its
# endpoints, there are no restarts and no warning events, so no alert fires.
# The only symptom is timeouts in the caller's logs. You find this one by
# asking NudgeBee, the way a user would report it.
#
# The fault: the policy allows port 80, the Service port. NetworkPolicy is
# matched against the destination pod's port after the Service has translated
# it, which is 8080, so nothing matches and the traffic is dropped.
#
# Needs a CNI that enforces NetworkPolicy (Calico, Cilium, GKE Dataplane V2...).
# `break` checks this and stops if traffic still flows.
set -euo pipefail

NS=${NS:-nudgebee-demo}
API=${API:-cart-api}
WEB=${WEB:-web-shop}
IMAGE=${IMAGE:-busybox:1.36}
POLICY="allow-$WEB-to-$API"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

pod_security='
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: {type: RuntimeDefault}'
container_security='
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources:
            requests: {cpu: 5m, memory: 16Mi}
            limits: {memory: 32Mi}'

apply_app() {
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $API
  labels: {app: $API}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $API}
  template:
    metadata:
      labels: {app: $API}
    spec:
      terminationGracePeriodSeconds: 0$pod_security
      volumes: [{name: www, emptyDir: {}}]
      containers:
        - name: $API
          image: $IMAGE
          command: [sh, -c, 'echo "{\"items\":[]}" > /www/index.html && echo "listening on :8080" && exec httpd -f -p 8080 -h /www']
          ports: [{name: http, containerPort: 8080}]
          volumeMounts: [{name: www, mountPath: /www}]$container_security
---
apiVersion: v1
kind: Service
metadata:
  name: $API
spec:
  selector: {app: $API}
  ports: [{name: http, port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $WEB
  labels: {app: $WEB}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $WEB}
  template:
    metadata:
      labels: {app: $WEB}
    spec:
      terminationGracePeriodSeconds: 0$pod_security
      containers:
        - name: $WEB
          image: $IMAGE
          command:
            - sh
            - -c
            - |
              while true; do
                if wget -q -O- -T 5 http://$API/ >/dev/null 2>&1; then echo "loaded cart from $API"
                else echo "ERROR: request to http://$API/ timed out after 5s"; fi
                sleep 10
              done$container_security
EOF
}

# $1 = allowed port
apply_policy() {
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $POLICY
spec:
  podSelector: {matchLabels: {app: $API}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {app: $WEB}}}]
      ports: [{protocol: TCP, port: $1}]
EOF
}

# Each call is a new connection, so it sees the current policy.
reachable() { kubectl -n "$NS" exec "deploy/$WEB" -- wget -q -O- -T 5 "http://$API/" >/dev/null 2>&1; }

wait_reachable() { # $1 = want 0 (reachable) or 1 (blocked)
  local i
  for i in $(seq 1 12); do
    if reachable; then [ "$1" = 0 ] && return 0; else [ "$1" = 1 ] && return 0; fi
    sleep 5
  done
  return 1
}

cmd_break() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"

  say "1/3  Deploying $NS/$WEB -> $NS/$API, working, no policy"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NS" delete networkpolicy "$POLICY" --ignore-not-found >/dev/null
  apply_app
  kubectl -n "$NS" rollout status "deploy/$API" --timeout=180s
  kubectl -n "$NS" rollout status "deploy/$WEB" --timeout=180s
  wait_reachable 0 || die "$WEB cannot reach $API even without a policy -- not this scenario"
  echo "     $WEB -> $API works"

  say "2/3  Locking $API down: allow only $WEB, on port 80"
  apply_policy 80
  if ! wait_reachable 1; then
    kubectl -n "$NS" delete networkpolicy "$POLICY" --ignore-not-found >/dev/null
    die "traffic still flows: this cluster's CNI does not enforce NetworkPolicy. Policy removed."
  fi

  say "3/3  Blocked. Pods, Service and endpoints all look healthy:"
  kubectl -n "$NS" get pods -l "app in ($API,$WEB)"
  kubectl -n "$NS" get endpoints "$API"

  cat <<TXT

  No alert fires for this one. Ask NudgeBee, the way a user would report it:

    "$WEB in $NS can't load the cart, requests to $API just hang.
     All the pods look healthy. What's going on?"

  Expect: the policy $POLICY allows port 80, the Service port, but
          NetworkPolicy matches the pod port after Service translation,
          which is 8080. Fix: allow 8080 (or the named port http).

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$NS" get networkpolicy "$POLICY" >/dev/null 2>&1 || die "$NS/$POLICY not found -- run '$0 break' first"
  say "Allowing the pod port, 8080"
  apply_policy 8080
  wait_reachable 0 || die "$WEB still cannot reach $API"
  echo "     $WEB -> $API works again"
}

cmd_status() {
  echo "workload: $NS/$WEB -> $NS/$API"
  kubectl -n "$NS" get pods -l "app in ($API,$WEB)" 2>/dev/null || echo "  (not deployed)"
  echo
  echo "policy ports:"
  kubectl -n "$NS" get networkpolicy "$POLICY" -o jsonpath='  {.spec.ingress[0].ports[*].port}{"\n"}' 2>/dev/null \
    || echo "  (no policy)"
  echo
  echo "last $WEB log lines:"
  kubectl -n "$NS" logs "deploy/$WEB" --tail=3 2>/dev/null | sed 's/^/  /' || true
}

# The namespace may hold other scenarios, so only delete what this one made.
cmd_cleanup() {
  kubectl -n "$NS" delete networkpolicy "$POLICY" --ignore-not-found
  kubectl -n "$NS" delete deploy "$API" "$WEB" --ignore-not-found
  kubectl -n "$NS" delete service "$API" --ignore-not-found
}

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
