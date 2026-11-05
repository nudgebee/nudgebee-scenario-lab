#!/usr/bin/env bash
# Helm drift, CPU: a CPU request edited three times with kubectl, outside Helm.
#
#   ./run.sh break     # install healthy, then raise the CPU request three times with kubectl
#   ./run.sh fix       # roll back to what Helm says the release should be
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # uninstall the release
#
# Someone chasing slowness bumps the CPU request by hand: 100m -> 250m -> 500m,
# then types "1000" meaning 1000m. That last one asks for a thousand cores, the
# new pod sits Pending forever, and because the rollout keeps the old pod until
# the new one is Ready, the service keeps working. The Deployment eventually
# reports ProgressDeadlineExceeded and stays there.
#
# The evidence is history: one Helm revision at 100m, and four ReplicaSets
# whose creation times and CPU requests tell the story of the three edits.
# STEP_WAIT spaces the edits (default 240s, ~12 minutes in all).
set -euo pipefail

NS=${NS:-nudgebee-demo}
REL=${REL:-pricing-engine}
STEP_WAIT=${STEP_WAIT:-240}
CHART=$(cd "$(dirname "$0")/../helm-drift-chart" && pwd)

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

preflight() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  command -v helm >/dev/null || die "helm is not installed"
}

live_cpu() { kubectl -n "$NS" get deploy "$REL" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'; }

set_cpu() {
  kubectl -n "$NS" patch deploy "$REL" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"$1\"}]"
}

cmd_break() {
  preflight
  say "1/5  Installing Helm release $NS/$REL, working (CPU request 100m)"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install "$REL" "$CHART" -n "$NS" --set holdMi=8 --wait --timeout 180s
  [ "$(live_cpu)" = 100m ] || die "release did not install with a 100m CPU request"

  say "2/5  kubectl edit #1: CPU request 100m -> 250m"
  set_cpu 250m
  kubectl -n "$NS" rollout status "deploy/$REL" --timeout=180s
  sleep "$STEP_WAIT"

  say "3/5  kubectl edit #2: CPU request 250m -> 500m"
  set_cpu 500m
  kubectl -n "$NS" rollout status "deploy/$REL" --timeout=180s
  sleep "$STEP_WAIT"

  say "4/5  kubectl edit #3: CPU request 500m -> 1000 (meant 1000m)"
  set_cpu 1000

  say "5/5  Waiting for the new pod to report FailedScheduling"
  local i ok=0
  for i in $(seq 1 30); do
    if kubectl -n "$NS" get events --field-selector reason=FailedScheduling -o name 2>/dev/null | grep -q .; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || die "no FailedScheduling event -- did the cluster find room for 1000 CPUs?"
  kubectl -n "$NS" get pods -l "app=$REL"
  echo
  echo "ReplicaSets (one per edit):"
  kubectl -n "$NS" get rs -l "app=$REL" --sort-by=.metadata.creationTimestamp \
    -o 'custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,CPU:.spec.template.spec.containers[0].resources.requests.cpu,READY:.status.readyReplicas'
  echo
  helm history "$REL" -n "$NS"

  cat <<TXT

  The service still works: the old pod keeps serving. Ask NudgeBee:

    "The $REL rollout in $NS looks stuck and a pod has been Pending for a
     while. Nobody ran a deploy. What happened?"

  Expect: the CPU request was changed three times with kubectl, outside Helm
          (100m -> 250m -> 500m -> 1000), the last one asking for 1000 cores
          (likely meant 1000m), so the new pod cannot be scheduled. Helm still
          says 100m at revision 1. Fix: roll back to the Helm-defined state,
          e.g. helm rollback $REL (Helm 4: add --force-conflicts).

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  preflight
  helm status "$REL" -n "$NS" >/dev/null 2>&1 || die "release $NS/$REL not found -- run '$0 break' first"
  local rev force=()
  rev=$(helm history "$REL" -n "$NS" -o json | tr '{' '\n' | grep '"status":"deployed"' \
    | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2)
  [ -n "$rev" ] || die "no deployed revision for $NS/$REL"
  helm version --short | grep -q '^v3\.' || force=(--force-conflicts)
  say "Rolling back to the Helm-defined state (revision $rev)"
  helm rollback "$REL" "$rev" -n "$NS" "${force[@]}" --wait --timeout 180s
  [ "$(live_cpu)" = 100m ] || die "CPU request is still $(live_cpu) after the rollback"
  kubectl -n "$NS" get pods -l "app=$REL"
  echo "     CPU request back to 100m"
}

cmd_status() {
  echo "release: $NS/$REL"
  helm history "$REL" -n "$NS" --max 3 2>/dev/null || echo "  (not installed)"
  echo
  echo "live CPU request: $(live_cpu 2>/dev/null || echo '-')"
  kubectl -n "$NS" get pods -l "app=$REL" 2>/dev/null || true
}

cmd_cleanup() { helm uninstall "$REL" -n "$NS" --ignore-not-found; }

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
