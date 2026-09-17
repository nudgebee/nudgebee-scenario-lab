#!/usr/bin/env bash
# CrashLoopBackOff scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh break     # deploy the service healthy, then break it with a config change
#   ./run.sh fix        # revert the config change yourself
#   ./run.sh status     # where things stand
#   ./run.sh cleanup    # delete the namespace
#
# `break` deploys the service WORKING first and waits for it to be Ready before
# breaking it. That ordering is the scenario: the failure has to have a cause
# that happened at a knowable time. Starting from a broken Deployment gives
# NudgeBee a pod that has never worked and no change to point at, which is not
# what a real incident looks like and not what is worth evaluating.
#
# Repeatable on the same workload. The agent suppresses a repeat alert for a
# workload for one hour and that suppression is held in the runner's memory, so
# `break` restarts the runner first to clear it. Set SKIP_AGENT_RESTART=1 to
# leave the agent alone and change APP between runs instead.
set -euo pipefail

NS=${NS:-nudgebee-demo}
APP=${APP:-checkout-api}
# Any image with a shell works. Override on clusters that cannot pull from
# Docker Hub -- an image the cluster cannot pull produces ImagePullBackOff,
# which is a different alert and the wrong scenario.
IMAGE=${IMAGE:-busybox:1.36}
SKIP_AGENT_RESTART=${SKIP_AGENT_RESTART:-}
AGENT_NS=${AGENT_NS:-}
AGENT_DEPLOY=${AGENT_DEPLOY:-}

GOOD_DSN="postgres://checkout:secret@postgres-primary:5432/checkout"
BAD_DSN="postgres-primary"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

find_runner() {
  [ -n "$AGENT_NS" ] && [ -n "$AGENT_DEPLOY" ] && return 0
  local line
  line=$(kubectl get deploy -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
    | awk '$2 ~ /runner$/ && $1 ~ /nudgebee/ {print; exit}')
  [ -n "$line" ] || return 1
  AGENT_NS=${AGENT_NS:-$(echo "$line" | awk '{print $1}')}
  AGENT_DEPLOY=${AGENT_DEPLOY:-$(echo "$line" | awk '{print $2}')}
}

preflight() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  if [ -z "$SKIP_AGENT_RESTART" ] && ! find_runner; then
    die "no agent runner found. Install the NudgeBee agent, set AGENT_NS and AGENT_DEPLOY, or run with SKIP_AGENT_RESTART=1"
  fi
}

# $1 = DATABASE_URL value, $2 = container command
apply_app() {
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $APP-config
data:
  DATABASE_URL: "$1"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP
  labels: {app: $APP}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $APP}
  template:
    metadata:
      labels: {app: $APP}
      annotations: {nudgebee.io/scenario-config: "$1"}
    spec:
      terminationGracePeriodSeconds: 0
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: $APP
          image: $IMAGE
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          envFrom:
            - configMapRef: {name: $APP-config}
          command:
            - sh
            - -c
            - |
              $2
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
EOF
}

healthy_cmd='echo "starting checkout-api"; echo "config: DATABASE_URL=$DATABASE_URL"; echo "connected to postgres-primary:5432"; echo "listening on :8080"; sleep 100000'
# Exits IMMEDIATELY. Deliberate: a container that lingers before dying reports
# Ready for those seconds, and a health snapshot landing in that window reads
# the workload as recovered and closes the alert while the pod is still
# crashing. A fast exit is never Ready, so the alert stays open until it is
# genuinely fixed.
broken_cmd='echo "starting checkout-api"; echo "config: DATABASE_URL=$DATABASE_URL"; echo "FATAL: invalid DATABASE_URL: expected postgres://user:pass@host:5432/db"; echo "panic: failed to open database connection"; exit 1'

reset_agent_suppression() {
  if [ -n "$SKIP_AGENT_RESTART" ]; then
    say "1/4  Skipping the agent restart (SKIP_AGENT_RESTART set)"
    echo "     Use a workload name you have not used in the last hour, or the"
    echo "     alert is suppressed as a repeat. Current: $APP"
    return 0
  fi
  find_runner
  say "1/4  Clearing the agent's alert suppression ($AGENT_NS/$AGENT_DEPLOY)"
  echo "     The 1h per-workload rate limit is in memory; a restart resets it."
  kubectl -n "$AGENT_NS" rollout restart "deploy/$AGENT_DEPLOY"
  kubectl -n "$AGENT_NS" rollout status "deploy/$AGENT_DEPLOY" --timeout=180s
}

cmd_break() {
  preflight
  reset_agent_suppression

  say "2/4  Deploying $NS/$APP, working"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  apply_app "$GOOD_DSN" "$healthy_cmd"
  kubectl -n "$NS" rollout status "deploy/$APP" --timeout=180s
  kubectl -n "$NS" get pods -l "app=$APP"

  say "3/4  Breaking it with a config change"
  echo "     DATABASE_URL: a DSN -> a bare hostname"
  apply_app "$BAD_DSN" "$broken_cmd"

  say "4/4  Waiting for CrashLoopBackOff (the agent fires at restartCount >= 2)"
  local i
  for i in $(seq 1 40); do
    if kubectl -n "$NS" get pods -l "app=$APP" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null \
        | awk '$1>=2{f=1} END{exit !f}'; then
      break
    fi
    sleep 5
  done
  kubectl -n "$NS" get pods -l "app=$APP"

  cat <<TXT

  NudgeBee -> Troubleshoot -> Pod Errors
    Expect:  "Pod $NS/$APP-... is in CrashLoopBackOff", Open
    Show:    Investigation Analysis -- what is broken, and what changed just before
             Remediation -- "Revert the change", one click

  Let NudgeBee revert it, or do it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$NS" get deploy "$APP" >/dev/null 2>&1 || die "$NS/$APP not found -- run '$0 break' first"
  say "Reverting the config change"
  apply_app "$GOOD_DSN" "$healthy_cmd"
  kubectl -n "$NS" rollout status "deploy/$APP" --timeout=180s
  kubectl -n "$NS" get pods -l "app=$APP"

  cat <<TXT

  The alert closes once NudgeBee sees the workload healthy again.

  To run it again:  $0 break
TXT
}

cmd_status() {
  if find_runner; then
    echo "agent:    $AGENT_NS/$AGENT_DEPLOY"
    kubectl -n "$AGENT_NS" get deploy "$AGENT_DEPLOY" --no-headers 2>/dev/null || true
  else
    echo "agent:    not found"
  fi
  echo
  echo "workload: $NS/$APP"
  kubectl -n "$NS" get pods -l "app=$APP" 2>/dev/null || echo "  (not deployed)"
  echo
  echo "DATABASE_URL:"
  kubectl -n "$NS" get configmap "$APP-config" -o jsonpath='  {.data.DATABASE_URL}{"\n"}' 2>/dev/null \
    || echo "  (not deployed)"
}

cmd_cleanup() { kubectl delete namespace "$NS" --ignore-not-found; }

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
