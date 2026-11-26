#!/usr/bin/env bash
# Payment quota scenario on the OpenTelemetry demo shop, for the NudgeBee Scenario Lab.
#
#   ./run.sh setup     # put a shared quota in front of the shop's payment, plus two alarm rules
#   ./run.sh break     # start a settlement batch that uses the quota up; it stops by itself
#   ./run.sh fix       # stop the batch now
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # remove the batch and the rules, and the quota if setup added it
#
# Unlike the other Kubernetes scenarios, this one changes an application you
# already run: the OpenTelemetry demo (Astronomy Shop). `setup` adds a sidecar,
# `processor-gateway`, to the demo's payment Deployment. It takes payment's port
# and forwards to the service on the next port, so the Service, checkout's
# PAYMENT_ADDR and every service-map edge stay the same. It allows LIMIT calls/s
# across all callers, the way a card processor limits a merchant account, and
# answers gRPC RESOURCE_EXHAUSTED over it. Normal demo traffic is far below it.
#
# `break` starts a second caller of payment, a settlement batch at RATE calls/s,
# as Job mj-06 (the same id as the fault in nudgebee/opentelemetry-demo, so that
# repo's fault.sh sees it too). The quota is gone, checkout fails orders, and the
# cause is neither checkout nor payment.
#
# Run `setup` HOURS before `break`. If the sidecar is the newest change on
# payment, an investigation blames it ("a restrictive quota was just added") and
# never asks who is using the quota. `break` refuses to run until payment's last
# change is MIN_AGE_MINUTES old; FORCE=1 overrides.
set -euo pipefail

NS=${NS:-demo}                          # the demo's namespace
IMAGE_BASE=${IMAGE_BASE:-}             # e.g. ghcr.io/open-telemetry/demo:3.0.0; default: from payment's image
LIMIT=${LIMIT:-5}                       # quota, calls a second, shared by every caller
RATE=${RATE:-20}                        # the batch's calls a second
WORKERS=${WORKERS:-8}                   # the batch's threads
DURATION=${DURATION:-840}               # seconds the batch runs before it exits by itself
MIN_AGE_MINUTES=${MIN_AGE_MINUTES:-120} # how old payment's last change must be for `break`
FORCE=${FORCE:-}
SEVERITY=${SEVERITY:-warning}           # severity label on both alarms
ALERTS=${ALERTS:-auto}                  # auto | vm | prometheus | none
MONITOR_LABELS=${MONITOR_LABELS:-}      # extra labels for the rules and the route: k=v,k=v
ALERT_WEBHOOK=${ALERT_WEBHOOK:-}        # optional: route both alarms to this URL (a NudgeBee agent's /api/alerts)
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=otel-demo-payment-quota            # label on the rules and route only
JOB=mj-06
JOB_LABEL=maintenance.platform/job      # the fork's label for its faults
GW=processor-gateway
GW_CM=payment-processor-gateway         # the name the demo's Helm chart gives it too
PORT_ANN=processor-gateway/app-port-before

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for v in "$LIMIT" "$RATE" "$WORKERS" "$DURATION" "$MIN_AGE_MINUTES"; do
  case "$v" in '' | *[!0-9]* | 0) die "LIMIT, RATE, WORKERS, DURATION and MIN_AGE_MINUTES must be whole numbers above 0" ;; esac
done

# Nothing the batch creates, and nothing next to payment, carries a "scenario"
# label: an investigation reads those objects, and a label saying this is a lab
# scenario puts the answer in front of it. Only the alarm rule and the route do.
# For the same reason the gateway config goes in without its comments, the
# batch's code says only what a real batch would, and the rule group (which
# vmalert copies onto every alert as `alertgroup`) has a neutral name.

# The demo's images share a repo and a tag prefix: <repo>:<version>-<service>.
# Read that off payment's own image, so the sidecar and the batch match the
# demo's version and registry.
image_base() {
  if [ -n "$IMAGE_BASE" ]; then echo "$IMAGE_BASE"; return; fi
  local img
  img=$(kubectl -n "$NS" get deploy payment -o jsonpath='{.spec.template.spec.containers[?(@.name=="payment")].image}')
  case "$img" in *-payment) echo "${img%-payment}" ;; *) die "cannot tell the demo's image tag from '$img'; set IMAGE_BASE" ;; esac
}

app_env() { # $1 deployment, $2 container, $3 env var
  kubectl -n "$NS" get deploy "$1" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"$2"'")].env[?(@.name=="'"$3"'")].value}' 2>/dev/null || true
}
has_gateway() {
  kubectl -n "$NS" get deploy payment -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null |
    tr ' ' '\n' | grep -qx "$GW"
}
# setup records the app's original port on the ConfigMap it creates; the demo's
# Helm chart, which can also add the sidecar, does not. So this says who added it.
# (`with index` rather than `index`: a missing key would print "<no value>".)
setup_added_gateway() {
  [ -n "$(kubectl -n "$NS" get configmap "$GW_CM" \
    -o go-template='{{with .metadata.annotations}}{{with index . "'"$PORT_ANN"'"}}{{.}}{{end}}{{end}}' 2>/dev/null || true)" ]
}
payment_selector() {
  kubectl -n "$NS" get deploy payment -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//'
}
# When payment last changed: the newest of its live ReplicaSets and its pods.
# The pods matter because a rollback to an earlier template reuses that
# revision's old ReplicaSet, timestamp and all, while the pods are new.
last_change() {
  {
    kubectl -n "$NS" get rs -l "$(payment_selector)" \
      -o go-template='{{range .items}}{{if gt .spec.replicas 0}}{{.metadata.creationTimestamp}}{{"\n"}}{{end}}{{end}}'
    kubectl -n "$NS" get pods -l "$(payment_selector)" \
      -o go-template='{{range .items}}{{.metadata.creationTimestamp}}{{"\n"}}{{end}}'
  } | sort | tail -1
}
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
minutes_since() {
  local t
  [ -n "$1" ] || die "could not read when $NS/payment last changed"
  t=$(epoch "$1" 2>/dev/null) || die "could not read when $NS/payment last changed"
  echo $((($(date -u +%s) - t) / 60))
}
refusals_last_minute() {
  kubectl -n "$NS" logs deploy/payment -c "$GW" --since=60s 2>/dev/null | grep -c 'processor quota exceeded' || true
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

install_gateway() {
  local port app_port collector
  port=$(app_env payment payment PAYMENT_PORT)
  case "$port" in '' | *[!0-9]*) die "$NS/payment has no numeric PAYMENT_PORT -- is this the OpenTelemetry demo?" ;; esac
  app_port=$((port + 1))
  collector=$(app_env payment payment OTEL_COLLECTOR_NAME)
  [ -n "$collector" ] || die "$NS/payment has no OTEL_COLLECTOR_NAME -- is this the OpenTelemetry demo?"

  kubectl -n "$NS" create configmap "$GW_CM" --dry-run=client -o yaml \
    --from-literal=envoy.tmpl.yaml="$(grep -v '^ *#' "$HERE/gateway-envoy.yaml" |
      sed -e "s/__LISTEN_PORT__/$port/" -e "s/__APP_PORT__/$app_port/" -e "s/__LIMIT__/$LIMIT/g")" |
    kubectl annotate --local -f - "$PORT_ANN=$port" -o yaml | kubectl -n "$NS" apply -f - >/dev/null

  kubectl -n "$NS" patch deploy payment --type strategic -p "$(cat <<EOF
{"spec": {"template": {"spec": {
  "containers": [
    {"name": "payment",
     "env": [{"name": "PAYMENT_PORT", "value": "$app_port"}],
     "volumeMounts": [{"name": "$GW", "mountPath": "/etc/$GW"}]},
    {"name": "$GW",
     "image": "$(image_base)-frontend-proxy",
     "command": ["/bin/sh", "-c", "envsubst < /etc/$GW/envoy.tmpl.yaml > /tmp/envoy.yaml && exec envoy -c /tmp/envoy.yaml --log-level warn"],
     "env": [{"name": "OTEL_COLLECTOR_NAME", "value": "$collector"}],
     "volumeMounts": [{"name": "$GW", "mountPath": "/etc/$GW"}],
     "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "128Mi"}}}],
  "volumes": [{"name": "$GW", "configMap": {"name": "$GW_CM"}}]}}}}
EOF
)" >/dev/null
  kubectl -n "$NS" rollout status deploy/payment --timeout=180s >/dev/null
}

remove_gateway() {
  local port
  port=$(kubectl -n "$NS" get configmap "$GW_CM" \
    -o go-template='{{with .metadata.annotations}}{{with index . "'"$PORT_ANN"'"}}{{.}}{{end}}{{end}}')
  kubectl -n "$NS" patch deploy payment --type strategic -p "$(cat <<EOF
{"spec": {"template": {"spec": {
  "containers": [
    {"name": "$GW", "\$patch": "delete"},
    {"name": "payment",
     "env": [{"name": "PAYMENT_PORT", "value": "$port"}],
     "volumeMounts": [{"mountPath": "/etc/$GW", "\$patch": "delete"}]}],
  "volumes": [{"name": "$GW", "\$patch": "delete"}]}}}}
EOF
)" >/dev/null
  kubectl -n "$NS" rollout status deploy/payment --timeout=180s >/dev/null
  kubectl -n "$NS" delete configmap "$GW_CM" --ignore-not-found >/dev/null
}

# $1 = vm | prometheus. The two operators share the rule spec; only the kind differs.
render_rules() {
  local api kind
  if [ "$1" = vm ]; then api=operator.victoriametrics.com/v1beta1 kind=VMRule; else api=monitoring.coreos.com/v1 kind=PrometheusRule; fi
  cat <<EOF
apiVersion: $api
kind: $kind
metadata:
  name: $NAME
  namespace: $NS
  labels: {scenario: $NAME$(extra_labels)}
spec:
  groups:
    - name: otel-demo-shop
      interval: 15s
      rules:
        # checkout failing orders; same name as the demo pack's rule, scoped to
        # checkout. The deployment label is what NudgeBee files the alarm under.
        - alert: OtelDemoGRPCServerErrorRate
          expr: |
            label_replace(
              (
                sum by (service_name, k8s_deployment_name, namespace, rpc_method) (
                  rate(rpc_server_call_duration_count{namespace="$NS", service_name="checkout", rpc_response_status_code!="OK"}[2m])
                )
                /
                sum by (service_name, k8s_deployment_name, namespace, rpc_method) (
                  rate(rpc_server_call_duration_count{namespace="$NS", service_name="checkout"}[2m])
                )
              ) > 0.01,
              "deployment", "\$1", "k8s_deployment_name", "(.+)")
          for: 1m
          labels: {severity: $SEVERITY}
          annotations:
            summary: "High gRPC server error rate for {{ \$labels.service_name }} {{ \$labels.rpc_method }} in $NS namespace"
        # the quota refusing calls to payment, from the sidecar's counters
        - alert: OtelDemoPaymentQuotaExhausted
          expr: |
            label_replace(
              sum by (k8s_deployment_name, namespace) (
                rate(http_local_rate_limit_rate_limited{namespace="$NS", envoy_local_http_ratelimit_prefix="processor_quota"}[2m])
              ) > 0.5,
              "deployment", "\$1", "k8s_deployment_name", "(.+)")
          for: 1m
          labels: {severity: $SEVERITY, service_name: payment}
          annotations:
            summary: "Card processor quota refusing payment calls in $NS namespace"
EOF
}

# $1 = vm | prometheus. Routes both alarms, and only those, at $SEVERITY, to
# ALERT_WEBHOOK. Alertmanager scopes the route to this namespace by itself. If
# your root routes stop on your severity before namespace routes are reached,
# choose a SEVERITY they do not match.
render_route() {
  local names="OtelDemoGRPCServerErrorRate|OtelDemoPaymentQuotaExhausted"
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
    matchers: ['alertname=~"$names"', 'severity="$SEVERITY"']
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
      - {name: alertname, matchType: "=~", value: "$names"}
      - {name: severity, matchType: "=", value: "$SEVERITY"}
    groupBy: [alertname]
    groupWait: 10s
    groupInterval: 1m
    repeatInterval: 1h
EOF
  fi
}

render_job() {
  local addr collector
  addr=$(app_env checkout checkout PAYMENT_ADDR)
  collector=$(app_env payment payment OTEL_COLLECTOR_NAME)
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
  labels: {$JOB_LABEL: $JOB}
spec:
  # The batch exits cleanly after DURATION, so the Job completes rather than
  # fails (a failed Job is an event of its own). This deadline is the backstop.
  activeDeadlineSeconds: $((DURATION + 120))
  backoffLimit: 0
  template:
    metadata:
      labels: {$JOB_LABEL: $JOB, app.kubernetes.io/name: settlement-sync}
    spec:
      restartPolicy: Never
      volumes: [{name: script, configMap: {name: settlement-sync}}]
      containers:
        - name: settlement-sync
          image: $(image_base)-recommendation
          workingDir: /app
          command: [/venv/bin/opentelemetry-instrument, /venv/bin/python, /batch/settlement_sync.py]
          env:
            # The demo's generated stubs live in /app; python only adds the
            # script's own directory to the path.
            - {name: PYTHONPATH, value: /app}
            - {name: PAYMENT_ADDR, value: "${addr:-payment:8080}"}
            - {name: WORKERS, value: "$WORKERS"}
            - {name: RATE, value: "$RATE"}
            - {name: DURATION_SECONDS, value: "$DURATION"}
            - {name: OTEL_SERVICE_NAME, value: settlement-sync}
            - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://$collector:4317"}
            - {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: grpc}
            - {name: OTEL_METRICS_EXPORTER, value: none}
            - {name: OTEL_LOGS_EXPORTER, value: none}
          volumeMounts: [{name: script, mountPath: /batch}]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 256Mi}
EOF
}

cmd_setup() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  kubectl -n "$NS" get deploy payment checkout >/dev/null 2>&1 ||
    die "no payment and checkout Deployments in namespace '$NS' -- install the OpenTelemetry demo, or set NS"
  local flavour
  flavour=$(alert_flavour)

  say "1/2  The quota in front of $NS/payment"
  if has_gateway; then
    if setup_added_gateway; then echo "     already added by an earlier setup"; else echo "     already there, from the demo's Helm values"; fi
    kubectl -n "$NS" rollout status deploy/payment --timeout=180s >/dev/null ||
      die "$NS/payment is not rolled out -- see: kubectl -n $NS describe deploy payment"
  else
    install_gateway
    echo "     added: $LIMIT calls/s shared by every caller; payment rolled out with the sidecar"
  fi
  kubectl -n "$NS" get pods -l "$(payment_selector)" --field-selector=status.phase=Running

  say "2/2  Alarm rules"
  if [ "$flavour" = none ]; then
    echo "     No VictoriaMetrics or Prometheus operator found (or ALERTS=none): no alarms."
    echo "     The scenario still works; you ask NudgeBee instead of opening an alarm."
  else
    render_rules "$flavour" | kubectl apply -f -
    echo "     OtelDemoGRPCServerErrorRate (checkout) and OtelDemoPaymentQuotaExhausted, severity=$SEVERITY"
    if [ -n "$ALERT_WEBHOOK" ]; then
      render_route "$flavour" | kubectl apply -f -
      echo "     routed to $ALERT_WEBHOOK"
    fi
  fi

  local changed age
  changed=$(last_change)
  age=$(minutes_since "$changed")
  cat <<TXT

  Ready. payment last changed $age min ago ($changed). Wait until that is at
  least $MIN_AGE_MINUTES min, so the sidecar is not the newest change on
  payment when the alarms fire, then:

    $0 break
TXT
}

cmd_break() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  has_gateway || die "no $GW on $NS/payment -- run '$0 setup' first"
  local changed age
  changed=$(last_change)
  age=$(minutes_since "$changed")
  if [ "$age" -lt "$MIN_AGE_MINUTES" ] && [ -z "$FORCE" ]; then
    die "payment last changed $age min ago; an investigation would blame that change. Wait until it is $MIN_AGE_MINUTES min old, or set FORCE=1"
  fi
  if [ "$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.active}' 2>/dev/null || true)" = 1 ]; then
    die "the batch is already running -- see: $0 status"
  fi
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null # a finished one from an earlier run

  local at
  at=$(date -u +%H:%M:%SZ)
  say "1/2  Starting the settlement batch, $RATE calls/s against a $LIMIT calls/s quota ($at)"
  kubectl -n "$NS" create configmap settlement-sync --from-file=settlement_sync.py="$HERE/settlement_sync.py" \
    --dry-run=client -o yaml | kubectl label --local -f - "$JOB_LABEL=$JOB" -o yaml | kubectl -n "$NS" apply -f - >/dev/null
  render_job | kubectl apply -f -

  say "2/2  Waiting for the quota to refuse calls"
  local i n=0
  for i in $(seq 1 24); do
    n=$(refusals_last_minute)
    [ "${n:-0}" -gt 0 ] && break
    sleep 5
  done
  [ "${n:-0}" -gt 0 ] || die "no refusals yet; check: $0 status"
  echo "     $n calls refused in the last minute"

  cat <<TXT

  Broken. checkout fails orders whose charge is refused; payment's service is
  healthy and sees only $LIMIT calls/s. In about 2 minutes
  OtelDemoGRPCServerErrorRate fires on checkout and OtelDemoPaymentQuotaExhausted
  on payment. Investigate the checkout alarm in NudgeBee.

  Expect: checkout's failures are payment refusing calls with RESOURCE_EXHAUSTED;
          the quota is $LIMIT calls/s for every caller together, and a
          settlement-sync batch (Job $JOB) started at $at is making most of
          the calls. Fix: stop or slow the batch, or give it its own quota.
          Rolling back or scaling payment or checkout is the wrong answer.

  The batch stops by itself after $((DURATION / 60)) min. Stop it now: $0 fix
TXT
}

cmd_fix() {
  say "Stopping the settlement batch"
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found
  kubectl -n "$NS" delete configmap settlement-sync --ignore-not-found >/dev/null
}

cmd_status() {
  echo "shop: $NS/checkout -> $NS/payment"
  kubectl -n "$NS" get deploy payment >/dev/null 2>&1 || { echo "  (no OpenTelemetry demo in namespace '$NS')"; return 0; }
  if has_gateway; then
    local changed
    changed=$(last_change)
    echo "quota: $GW on payment ($(setup_added_gateway && echo "added by setup" || echo "from Helm values")); payment last changed $(minutes_since "$changed") min ago"
    echo "refused in the last minute: $(refusals_last_minute)"
  else
    echo "quota: none (run setup)"
  fi
  echo
  echo "settlement batch (Job $JOB):"
  kubectl -n "$NS" get job "$JOB" 2>/dev/null || echo "  (not running)"
  kubectl -n "$NS" logs "job/$JOB" --tail=2 2>/dev/null | sed 's/^/  /' || true
}

# NS is the demo's: only delete what this scenario made there.
cmd_cleanup() {
  cmd_fix
  local kind
  for kind in vmrule vmalertmanagerconfig prometheusrule alertmanagerconfig; do # a kind the cluster lacks just errors
    kubectl -n "$NS" delete "$kind" -l "scenario=$NAME" --ignore-not-found 2>/dev/null || true
  done
  if setup_added_gateway; then
    if has_gateway; then
      say "Removing the quota sidecar from $NS/payment"
      remove_gateway
    fi
    kubectl -n "$NS" delete configmap "$GW_CM" --ignore-not-found >/dev/null
  elif has_gateway; then
    echo "Leaving the $GW sidecar: it comes from the demo's Helm values, not from setup."
  fi
}

case "${1:-}" in
  setup)   cmd_setup ;;
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {setup|break|fix|status|cleanup}" ;;
esac
