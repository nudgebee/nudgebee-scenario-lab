#!/usr/bin/env bash
# Upstream rate limit scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh deploy    # deploy the shop and the reconcile job, healthy, plus two alarm rules
#   ./run.sh break     # give the reconcile job 20 workers: it takes the processor's whole limit
#   ./run.sh fix       # back to 1 worker
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete the scenario's resources
#
# A chained failure. storefront -> checkout -> payments-gateway, and a batch job,
# ledger-reconcile, in another namespace that also calls payments-gateway. The card
# processor behind payments-gateway allows LIMIT calls a second for the whole account,
# shared by every caller. `break` changes ledger-reconcile from 1 worker to WORKERS --
# the kind of change that gets a nightly job done sooner. It now takes most of the
# limit, payments-gateway answers 429 to whatever goes over it, and checkout turns
# each 429 into a 503 for shoppers.
#
# Checkout's alarm fires, but checkout is healthy, and so is payments-gateway. The
# cause is a change in a namespace neither of them is in.
#
# Deploy first and break later: NudgeBee connects the two alarms through its service
# map, which learns that checkout calls payments-gateway from live traffic.
set -euo pipefail

NS=${NS:-nudgebee-demo}
BATCH_NS=${BATCH_NS:-nudgebee-demo-batch}   # the scenario's own; cleanup deletes it when empty
LIMIT=${LIMIT:-20}                # processor calls a second, for the whole account
WORKERS=${WORKERS:-20}            # ledger-reconcile workers after `break`, 2 calls a second each
SEVERITY=${SEVERITY:-warning}     # severity label on both alarms
ALERTS=${ALERTS:-auto}            # auto | vm | prometheus | none
MONITOR_LABELS=${MONITOR_LABELS:-}  # extra labels for the rules and the scrape: k=v,k=v
ALERT_WEBHOOK=${ALERT_WEBHOOK:-}  # optional: route these two alarms to this URL (a NudgeBee agent's /api/alerts)
IMAGE=${IMAGE:-python:3.12-alpine}
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=upstream-rate-limit

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for v in "$LIMIT" "$WORKERS"; do
  case "$v" in '' | *[!0-9]*) die "LIMIT and WORKERS must be whole numbers" ;; esac
done

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
            requests: {cpu: 20m, memory: 32Mi}
            limits: {memory: 64Mi}'

# $1 namespace  $2 name  $3 role  $4 yes = serves HTTP  $5 extra env entries
render_workload() {
  local serve=""
  [ "$4" = yes ] && serve='
          ports: [{name: http, containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: http}, periodSeconds: 5}'
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $2
  namespace: $1
  labels: {app: $2, scenario: $NAME}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $2}
  template:
    metadata:
      labels: {app: $2, scenario: $NAME}
    spec:
      terminationGracePeriodSeconds: 0$sec_pod
      volumes: [{name: app, configMap: {name: shop-app}}]
      containers:
        - name: $2
          image: $IMAGE
          command: [python, /app/shop.py]
          env:
            - {name: ROLE, value: $3}
            - {name: PYTHONDONTWRITEBYTECODE, value: "1"}$5$serve
          volumeMounts: [{name: app, mountPath: /app}]$sec_ctr
---
EOF
}

render_shop() {
  render_workload "$NS" payments-gateway payments-gateway yes "
            - {name: LIMIT, value: \"$LIMIT\"}"
  render_workload "$NS" checkout checkout yes ""
  render_workload "$NS" storefront storefront no ""
  for svc in payments-gateway checkout; do
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $svc
  namespace: $NS
  labels: {scenario: $NAME}
spec:
  selector: {app: $svc}
  ports: [{name: http, port: 80, targetPort: http}]
---
EOF
  done
}

# $1 = workers
render_reconcile() {
  render_workload "$BATCH_NS" ledger-reconcile ledger-reconcile no "
            - {name: WORKERS, value: \"$1\"}
            - {name: PAYMENTS_URL, value: \"http://payments-gateway.$NS.svc/charge\"}"
}

extra_labels() {
  local kv
  for kv in $(echo "$MONITOR_LABELS" | tr ',' ' '); do
    printf ', %s: "%s"' "${kv%%=*}" "${kv#*=}"
  done
}

alert_flavour() {
  case "$ALERTS" in
    vm | prometheus | none) echo "$ALERTS"; return ;;
    auto) ;;
    *) die "ALERTS must be auto, vm, prometheus or none" ;;
  esac
  # api-resources exits 1 when any aggregated API is down, even after printing
  # what it found, so read its output rather than its exit status.
  local vm prom
  vm=$(kubectl api-resources --api-group=operator.victoriametrics.com -o name 2>/dev/null || true)
  prom=$(kubectl api-resources --api-group=monitoring.coreos.com -o name 2>/dev/null || true)
  if grep -q '^vmrules\.' <<<"$vm"; then
    echo vm
  elif grep -q '^prometheusrules\.' <<<"$prom"; then
    echo prometheus
  else
    echo none
  fi
}

# $1 = vm | prometheus. The two operators share these specs; only the kinds differ.
render_alarms() {
  local api rule scrape
  if [ "$1" = vm ]; then
    api=operator.victoriametrics.com/v1beta1 rule=VMRule scrape=VMPodScrape
  else
    api=monitoring.coreos.com/v1 rule=PrometheusRule scrape=PodMonitor
  fi
  cat <<EOF
apiVersion: $api
kind: $scrape
metadata:
  name: $NAME
  namespace: $NS
  labels: {scenario: $NAME$(extra_labels)}
spec:
  selector:
    matchLabels: {scenario: $NAME}
  podMetricsEndpoints: [{port: http, path: /metrics}]
---
apiVersion: $api
kind: $rule
metadata:
  name: $NAME
  namespace: $NS
  labels: {scenario: $NAME$(extra_labels)}
spec:
  groups:
    - name: $NAME
      rules:
        - alert: PaymentsGatewayRateLimited
          expr: |
            sum by (namespace, service) (
              rate(http_requests_total{namespace="$NS", service="payments-gateway", code="429"}[2m])
            ) > 1
          for: 1m
          labels: {severity: $SEVERITY, deployment: payments-gateway}
          annotations:
            summary: "payments-gateway is refusing {{ \$value | humanize }} calls/s with 429 Too Many Requests"
        - alert: CheckoutErrorRateHigh
          expr: |
            sum by (namespace, service) (rate(http_requests_total{namespace="$NS", service="checkout", code=~"5.."}[2m]))
              /
            sum by (namespace, service) (rate(http_requests_total{namespace="$NS", service="checkout"}[2m]))
              > 0.1
          for: 2m
          labels: {severity: $SEVERITY, deployment: checkout}
          annotations:
            summary: "checkout is failing {{ \$value | humanizePercentage }} of orders with a 5xx"
EOF
}

# $1 = vm | prometheus, $2 = alert names as a regex. Routes this scenario's
# alarms, and only those, at $SEVERITY, to ALERT_WEBHOOK -- for example a
# NudgeBee agent's http://<runner service>.<namespace>.svc/api/alerts.
# Alertmanager scopes the route to this namespace by itself. If your root
# routes stop on your severity before namespace routes are reached, choose a
# SEVERITY they do not match.
render_route() {
  if [ "$1" = vm ]; then
    cat <<EOF
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlertmanagerConfig
metadata:
  name: $NAME
  namespace: $NS
  labels: {scenario: $NAME$(extra_labels)}
spec:
  receivers:
    - name: nudgebee
      webhook_configs: [{url: "$ALERT_WEBHOOK", send_resolved: true}]
  route:
    receiver: nudgebee
    matchers: ['alertname=~"$2"', 'severity="$SEVERITY"']
    group_by: [alertname]
    group_wait: 10s
    group_interval: 1m
    repeat_interval: 1h
EOF
  else
    cat <<EOF
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: $NAME
  namespace: $NS
  labels: {scenario: $NAME$(extra_labels)}
spec:
  receivers:
    - name: nudgebee
      webhookConfigs: [{url: "$ALERT_WEBHOOK", sendResolved: true}]
  route:
    receiver: nudgebee
    matchers:
      - {name: alertname, matchType: "=~", value: "$2"}
      - {name: severity, matchType: "=", value: "$SEVERITY"}
    groupBy: [alertname]
    groupWait: 10s
    groupInterval: 1m
    repeatInterval: 1h
EOF
  fi
}

# The last full 10-second window, as each service counts it: "ok=48 failed=2".
stats() { kubectl -n "$NS" exec deploy/storefront -- wget -q -O- -T 5 "http://$1/stats" 2>/dev/null || true; }
field() { printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# $1 = healthy (no failed orders) | failing (more than 10% failed). Up to ~2 minutes.
wait_checkout() {
  local i s ok failed
  for i in $(seq 1 24); do
    s=$(stats checkout)
    ok=$(field ok "$s") failed=$(field failed "$s")
    if [ -n "$ok" ] && [ -n "$failed" ] && [ $((ok + failed)) -gt 0 ]; then
      [ "$1" = healthy ] && [ "$failed" = 0 ] && return 0
      [ "$1" = failing ] && [ $((failed * 10)) -gt $((ok + failed)) ] && return 0
    fi
    sleep 5
  done
  return 1
}

rollout() { kubectl -n "$1" rollout status "deploy/$2" --timeout=180s >/dev/null; }

cmd_deploy() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  local flavour
  flavour=$(alert_flavour)

  say "1/3  Deploying storefront -> checkout -> payments-gateway in $NS, and ledger-reconcile (1 worker) in $BATCH_NS"
  local d ns
  for d in "$NS/payments-gateway" "$NS/checkout" "$NS/storefront" "$BATCH_NS/ledger-reconcile"; do
    kubectl -n "${d%%/*}" get deploy "${d#*/}" >/dev/null 2>&1 || continue
    [ "$(kubectl -n "${d%%/*}" get deploy "${d#*/}" -o jsonpath='{.metadata.labels.scenario}')" = "$NAME" ] ||
      die "$d already exists and is not this scenario's; set NS or BATCH_NS to other namespaces"
  done
  # NS is shared with other scenarios. BATCH_NS is labelled as this scenario's
  # only when deploy creates it, and cleanup deletes it only then.
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  if ! kubectl get namespace "$BATCH_NS" >/dev/null 2>&1; then
    kubectl create namespace "$BATCH_NS" >/dev/null
    kubectl label namespace "$BATCH_NS" "scenario=$NAME" >/dev/null
  fi
  for ns in "$NS" "$BATCH_NS"; do
    kubectl -n "$ns" create configmap shop-app --from-file=shop.py="$HERE/shop.py" --dry-run=client -o yaml |
      kubectl label --local -f - "scenario=$NAME" -o yaml | kubectl -n "$ns" apply -f - >/dev/null
  done
  { render_shop; render_reconcile 1; } | kubectl apply -f -
  for d in payments-gateway checkout storefront; do rollout "$NS" "$d"; done
  rollout "$BATCH_NS" ledger-reconcile

  say "2/3  Checking that orders go through"
  wait_checkout healthy || die "checkout is failing orders even when healthy -- not this scenario; see: $0 status"
  echo "     checkout, last 10s:          $(stats checkout)"
  echo "     payments-gateway, last 10s:  $(stats payments-gateway)  (limit ${LIMIT}/s = $((LIMIT * 10)) per 10s)"

  say "3/3  Alarm rules"
  if [ "$flavour" = none ]; then
    echo "     No VictoriaMetrics or Prometheus operator found (or ALERTS=none): no alarms."
    echo "     The scenario still works; you ask NudgeBee instead of opening an alarm."
  else
    render_alarms "$flavour" | kubectl apply -f -
    echo "     PaymentsGatewayRateLimited and CheckoutErrorRateHigh, severity=$SEVERITY"
    if [ -n "$ALERT_WEBHOOK" ]; then
      render_route "$flavour" "PaymentsGatewayRateLimited|CheckoutErrorRateHigh" | kubectl apply -f -
      echo "     routed to $ALERT_WEBHOOK"
    fi
  fi

  cat <<TXT

  Healthy. NudgeBee links checkout's alarm to payments-gateway's through its
  service map, which learns who calls whom from live traffic. Leave this running
  until the map shows checkout -> payments-gateway (up to an hour), then:

    $0 break
TXT
}

cmd_break() {
  if ! kubectl -n "$NS" get deploy payments-gateway >/dev/null 2>&1; then
    cmd_deploy
    echo
    echo "  Breaking straight away. The alarms will fire, but NudgeBee's service map"
    echo "  may not know yet that checkout calls payments-gateway."
  fi
  wait_checkout healthy || die "checkout is already failing orders; run '$0 fix' first"

  local at
  at=$(date -u +%H:%M:%SZ)
  say "1/2  Changing ledger-reconcile in $BATCH_NS from 1 worker to $WORKERS ($at)"
  render_reconcile "$WORKERS" | kubectl apply -f -
  rollout "$BATCH_NS" ledger-reconcile

  say "2/2  Waiting for checkout to fail orders"
  wait_checkout failing || die "checkout is not failing; check: $0 status"
  echo "     checkout, last 10s:          $(stats checkout)"
  echo "     payments-gateway, last 10s:  $(stats payments-gateway)"

  cat <<TXT

  Broken. Every pod is Running and Ready, nothing restarts, and no warning
  events. In about 2 minutes PaymentsGatewayRateLimited fires, and about a
  minute later CheckoutErrorRateHigh. Investigate the checkout alarm in
  NudgeBee, or ask:

    "checkout in $NS started failing orders with 503 a few minutes ago.
     Its pods look fine. What's wrong?"

  Expect: checkout's 503s are payments-gateway answering 429 Too Many
          Requests. The processor's ${LIMIT} calls/s are shared by every caller,
          and ledger-reconcile in $BATCH_NS now takes most of them: it went
          from 1 worker to $WORKERS at $at. Fix: ledger-reconcile back to 1
          worker, or give it a budget of its own. Restarting or scaling checkout
          changes nothing.

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$BATCH_NS" get deploy ledger-reconcile >/dev/null 2>&1 || die "$BATCH_NS/ledger-reconcile not found -- run '$0 deploy' first"
  say "Changing ledger-reconcile back to 1 worker"
  render_reconcile 1 | kubectl apply -f -
  rollout "$BATCH_NS" ledger-reconcile
  wait_checkout healthy || die "checkout is still failing orders; check: $0 status"
  echo "     checkout, last 10s: $(stats checkout)"
}

cmd_status() {
  echo "shop: $NS/storefront -> $NS/checkout -> $NS/payments-gateway  <- $BATCH_NS/ledger-reconcile"
  kubectl -n "$NS" get deploy payments-gateway >/dev/null 2>&1 || { echo "  (not deployed)"; return 0; }
  kubectl -n "$NS" get pods -l "scenario=$NAME"
  kubectl -n "$BATCH_NS" get pods -l "scenario=$NAME" 2>/dev/null || true
  echo
  echo "ledger-reconcile workers: $(kubectl -n "$BATCH_NS" get deploy ledger-reconcile \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WORKERS")].value}' 2>/dev/null || echo '?')"
  echo "checkout, last 10s:          $(stats checkout)"
  echo "payments-gateway, last 10s:  $(stats payments-gateway)  (limit ${LIMIT}/s = $((LIMIT * 10)) per 10s)"
  local svc
  for svc in checkout payments-gateway; do
    echo
    echo "last $svc log lines:"
    kubectl -n "$NS" logs "deploy/$svc" --tail=2 2>/dev/null | sed 's/^/  /' || true
  done
}

# NS may hold other scenarios, so only delete what carries this one's label.
cmd_cleanup() {
  kubectl -n "$NS" delete deploy,service,configmap -l "scenario=$NAME" --ignore-not-found
  local kind
  for kind in vmrule vmpodscrape vmalertmanagerconfig prometheusrule podmonitor alertmanagerconfig; do  # a kind the cluster lacks just errors
    kubectl -n "$NS" delete "$kind" -l "scenario=$NAME" --ignore-not-found 2>/dev/null || true
  done
  kubectl -n "$BATCH_NS" delete deploy,configmap -l "scenario=$NAME" --ignore-not-found 2>/dev/null || true
  if [ "$(kubectl get namespace "$BATCH_NS" -o jsonpath='{.metadata.labels.scenario}' 2>/dev/null || true)" = "$NAME" ]; then
    kubectl delete namespace "$BATCH_NS" --wait=false
  fi
}

case "${1:-}" in
  deploy)  cmd_deploy ;;
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {deploy|break|fix|status|cleanup}" ;;
esac
