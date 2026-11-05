#!/usr/bin/env bash
# Service targetPort scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh break     # deploy healthy, then point the Service at a port nothing listens on
#   ./run.sh fix       # point it back at the container port
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete the scenario's resources
#
# A silent failure. The Service keeps its endpoints (they just carry the wrong
# port), every pod stays Running and Ready, there are no restarts and no
# warning events. Callers get an instant "connection refused". No alert fires,
# so you find it by asking NudgeBee.
set -euo pipefail

NS=${NS:-nudgebee-demo}
API=${API:-inventory-api}
WEB=${WEB:-order-worker}
IMAGE=${IMAGE:-busybox:1.36}

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
          command: [sh, -c, 'echo "{\"sku\":\"A1\",\"stock\":12}" > /www/index.html && echo "listening on :8080" && exec httpd -f -p 8080 -h /www']
          ports: [{name: http, containerPort: 8080}]
          volumeMounts: [{name: www, mountPath: /www}]$sec_ctr
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
      terminationGracePeriodSeconds: 0$sec_pod
      containers:
        - name: $WEB
          image: $IMAGE
          command:
            - sh
            - -c
            - |
              while true; do
                if out=\$(wget -q -O- -T 5 http://$API/ 2>&1); then echo "reserved stock via $API"
                else echo "ERROR: stock check against http://$API/ failed: \$out"; fi
                sleep 10
              done$sec_ctr
EOF
}

# $1 = targetPort
apply_service() {
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $API
spec:
  selector: {app: $API}
  ports: [{name: http, port: 80, targetPort: $1}]
EOF
}

reachable() { kubectl -n "$NS" exec "deploy/$WEB" -- wget -q -O- -T 5 "http://$API/" >/dev/null 2>&1; }

wait_reachable() { # $1 = 0 want reachable, 1 want broken
  local i
  for i in $(seq 1 12); do
    if reachable; then [ "$1" = 0 ] && return 0; else [ "$1" = 1 ] && return 0; fi
    sleep 5
  done
  return 1
}

cmd_break() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"

  say "1/3  Deploying $NS/$WEB -> $NS/$API, working"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  apply_app
  apply_service 8080
  kubectl -n "$NS" rollout status "deploy/$API" --timeout=180s
  kubectl -n "$NS" rollout status "deploy/$WEB" --timeout=180s
  wait_reachable 0 || die "$WEB cannot reach $API even when healthy -- not this scenario"
  echo "     $WEB -> $API works"

  say "2/3  Changing the Service targetPort: 8080 -> 8081"
  apply_service 8081
  wait_reachable 1 || die "$WEB still reaches $API after the change -- not this scenario"

  say "3/3  Broken. Pods Ready, Service has endpoints:"
  kubectl -n "$NS" get pods -l "app in ($API,$WEB)"
  kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=$API"

  cat <<TXT

  No alert fires for this one. Ask NudgeBee, the way a user would report it:

    "$WEB in $NS keeps failing its stock checks against $API with
     connection refused. The pods are all up. What's wrong?"

  Expect: Service $API sends traffic to targetPort 8081, but the container
          listens on 8080, so connections are refused even though the
          Service has endpoints. Fix: targetPort 8080 (or the named port http).

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$NS" get service "$API" >/dev/null 2>&1 || die "$NS/$API not found -- run '$0 break' first"
  say "Pointing the Service back at 8080"
  apply_service 8080
  wait_reachable 0 || die "$WEB still cannot reach $API"
  echo "     $WEB -> $API works again"
}

cmd_status() {
  echo "workload: $NS/$WEB -> $NS/$API"
  kubectl -n "$NS" get pods -l "app in ($API,$WEB)" 2>/dev/null || echo "  (not deployed)"
  echo
  echo "Service targetPort:"
  kubectl -n "$NS" get service "$API" -o jsonpath='  {.spec.ports[0].targetPort}{"\n"}' 2>/dev/null || echo "  (no service)"
  echo
  echo "last $WEB log lines:"
  kubectl -n "$NS" logs "deploy/$WEB" --tail=3 2>/dev/null | sed 's/^/  /' || true
}

cmd_cleanup() {
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
