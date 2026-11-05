#!/usr/bin/env bash
# Ingress host scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh break     # deploy healthy behind an Ingress, then edit the rule's host with a typo
#   ./run.sh fix       # put the right host back
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete the scenario's resources
#
# A silent failure. The Ingress class is right, the backend
# Service has endpoints, every pod is Running and Ready, and there are no
# warning events. Requests for the real hostname get the controller's default
# 404. No alert fires, so you find it by asking NudgeBee.
#
# Needs an ingress controller. Defaults to ingress-nginx; override
# INGRESS_CLASS and INGRESS_URL (the controller's in-cluster address) for others.
set -euo pipefail

NS=${NS:-nudgebee-demo}
API=${API:-catalog-web}
CLIENT=${CLIENT:-catalog-probe}
IMAGE=${IMAGE:-busybox:1.36}
HOST=${HOST:-catalog.example.test}
TYPO=${TYPO:-catalog.exmaple.test}
INGRESS_CLASS=${INGRESS_CLASS:-nginx}
INGRESS_URL=${INGRESS_URL:-http://ingress-nginx-controller.ingress-nginx.svc.cluster.local}

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

sec_pod='
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: {type: RuntimeDefault}'
sec_ctr='
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
      terminationGracePeriodSeconds: 0$sec_pod
      volumes: [{name: www, emptyDir: {}}]
      containers:
        - name: $API
          image: $IMAGE
          command: [sh, -c, 'echo "catalog ok" > /www/index.html && exec httpd -f -p 8080 -h /www']
          ports: [{name: http, containerPort: 8080}]
          volumeMounts: [{name: www, mountPath: /www}]$sec_ctr
---
apiVersion: v1
kind: Service
metadata:
  name: $API
spec:
  selector: {app: $API}
  ports: [{name: http, port: 80, targetPort: http}]
---
# Stands in for external users: calls the site by its public name, through the
# ingress controller, the way a browser would.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $CLIENT
  labels: {app: $CLIENT}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $CLIENT}
  template:
    metadata:
      labels: {app: $CLIENT}
    spec:
      terminationGracePeriodSeconds: 0$sec_pod
      containers:
        - name: $CLIENT
          image: $IMAGE
          command:
            - sh
            - -c
            - |
              while true; do
                if out=\$(wget -q -O- -T 5 --header "Host: $HOST" $INGRESS_URL/ 2>&1); then echo "GET http://$HOST/ ok"
                else echo "ERROR: GET http://$HOST/ failed: \$out"; fi
                sleep 10
              done$sec_ctr
EOF
}

# $1 = host on the Ingress rule
apply_ingress() {
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $API
spec:
  ingressClassName: $INGRESS_CLASS
  rules:
    - host: $1
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: $API, port: {name: http}}
EOF
}

reachable() {
  kubectl -n "$NS" exec "deploy/$CLIENT" -- wget -q -O- -T 5 --header "Host: $HOST" "$INGRESS_URL/" 2>/dev/null | grep -q "catalog ok"
}

wait_reachable() { # $1 = 0 want reachable, 1 want broken
  local i
  for i in $(seq 1 18); do
    if reachable; then [ "$1" = 0 ] && return 0; else [ "$1" = 1 ] && return 0; fi
    sleep 5
  done
  return 1
}

cmd_break() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  kubectl get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1 || die "no IngressClass '$INGRESS_CLASS' -- set INGRESS_CLASS and INGRESS_URL"

  say "1/3  Deploying $NS/$API behind an Ingress for $HOST, working"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  apply_app
  apply_ingress "$HOST"
  kubectl -n "$NS" rollout status "deploy/$API" --timeout=180s
  kubectl -n "$NS" rollout status "deploy/$CLIENT" --timeout=180s
  wait_reachable 0 || die "http://$HOST/ does not work through $INGRESS_URL even when healthy -- check INGRESS_URL"
  echo "     http://$HOST/ works"

  say "2/3  Editing the Ingress rule's host: $HOST -> $TYPO"
  apply_ingress "$TYPO"
  wait_reachable 1 || die "http://$HOST/ still works after the change -- not this scenario"

  say "3/3  Broken. Ingress class and backend are fine:"
  kubectl -n "$NS" get ingress "$API"
  kubectl -n "$NS" get pods -l "app in ($API,$CLIENT)"

  cat <<TXT

  No alert fires for this one. Ask NudgeBee, the way a user would report it:

    "Users get a 404 on http://$HOST/ since this morning. $API in
     $NS looks healthy. What's going on?"

  Expect: the Ingress $API has host $TYPO (typo), so the controller
          has no rule for $HOST and answers with its default 404. The
          backend is fine. Fix: set the rule's host to $HOST.

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$NS" get ingress "$API" >/dev/null 2>&1 || die "$NS/$API not found -- run '$0 break' first"
  say "Putting the host back: $HOST"
  apply_ingress "$HOST"
  wait_reachable 0 || die "http://$HOST/ still fails"
  echo "     http://$HOST/ works again"
}

cmd_status() {
  echo "site: http://$HOST/ -> $NS/$API"
  kubectl -n "$NS" get ingress "$API" 2>/dev/null || echo "  (no ingress)"
  echo
  kubectl -n "$NS" get pods -l "app in ($API,$CLIENT)" 2>/dev/null || true
  echo
  echo "last $CLIENT log lines:"
  kubectl -n "$NS" logs "deploy/$CLIENT" --tail=3 2>/dev/null | sed 's/^/  /' || true
}

cmd_cleanup() {
  kubectl -n "$NS" delete ingress "$API" --ignore-not-found
  kubectl -n "$NS" delete deploy "$API" "$CLIENT" --ignore-not-found
  kubectl -n "$NS" delete service "$API" --ignore-not-found
}

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
