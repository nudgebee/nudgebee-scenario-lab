#!/usr/bin/env bash
# Helm drift, memory: a limit patched with kubectl, outside Helm.
#
#   ./run.sh break     # install the release healthy, then patch its memory limit with kubectl
#   ./run.sh fix       # roll back to what Helm says the release should be
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # uninstall the release
#
# The pods OOMKill and CrashLoop, which is loud: the agent raises an alert.
# The interesting part is the cause. Helm still says the limit is 128Mi at the
# same revision; the live Deployment says 24Mi, and its managedFields show the
# limit now owned by kubectl, not helm. The right fix is a Helm rollback, not
# another kubectl edit that leaves the release and the cluster disagreeing.
set -euo pipefail

NS=${NS:-nudgebee-demo}
REL=${REL:-recommendation}
BAD_LIMIT=${BAD_LIMIT:-24Mi}
CHART=$(cd "$(dirname "$0")/../helm-drift-chart" && pwd)

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

preflight() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  command -v helm >/dev/null || die "helm is not installed"
}

live_limit() { kubectl -n "$NS" get deploy "$REL" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'; }

cmd_break() {
  preflight
  say "1/3  Installing Helm release $NS/$REL, working (memory limit 128Mi)"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install "$REL" "$CHART" -n "$NS" --set strategy=Recreate --wait --timeout 180s
  helm history "$REL" -n "$NS" --max 3
  [ "$(live_limit)" = 128Mi ] || die "release did not install with a 128Mi limit"

  say "2/3  Patching the memory limit with kubectl: 128Mi -> $BAD_LIMIT (Helm is not told)"
  kubectl -n "$NS" patch deploy "$REL" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"$BAD_LIMIT\"}]"

  say "3/3  Waiting for OOMKilled restarts (the agent fires at restartCount >= 2)"
  local i ok=0
  for i in $(seq 1 40); do
    if kubectl -n "$NS" get pods -l "app=$REL" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' \
        | awk '$1>=2 && $2=="OOMKilled"{f=1} END{exit !f}'; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || die "no OOMKilled restarts after 200s -- the process may fit in $BAD_LIMIT on this cluster"
  kubectl -n "$NS" get pods -l "app=$REL"
  echo
  echo "Helm says:  $(helm get values "$REL" -n "$NS" -a -o json | tr -d ' ' | grep -o '"limits":{[^}]*}')  (revision unchanged)"
  echo "Live says:  limits.memory=$(live_limit)"

  cat <<TXT

  Two things to look at in NudgeBee:

  1. Did it notice on its own? Troubleshoot -> Pod Errors should show
     $REL OOMKilled / CrashLoopBackOff, with an investigation.

  2. Ask it, the way an on-call engineer would:

    "$REL in $NS keeps getting OOMKilled. It was fine this morning and
     nobody deployed. What happened?"

  Expect: the memory limit was changed from 128Mi to $BAD_LIMIT with kubectl,
          outside Helm (the release still says 128Mi at the same revision;
          managedFields show kubectl-patch owning the limit). Fix: roll back to
          the Helm-defined state, e.g. helm rollback $REL (Helm 4: add
          --force-conflicts, because kubectl now owns the field), not another
          kubectl edit.

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  preflight
  helm status "$REL" -n "$NS" >/dev/null 2>&1 || die "release $NS/$REL not found -- run '$0 break' first"
  local rev
  # The revision Helm marks "deployed" is the last good one; a failed rollback
  # attempt adds a newer, "failed" revision that is not a rollback target.
  rev=$(helm history "$REL" -n "$NS" -o json | tr '{' '\n' | grep '"status":"deployed"' \
    | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2)
  [ -n "$rev" ] || die "no deployed revision for $NS/$REL"
  say "Rolling back to the Helm-defined state (revision $rev)"
  # Helm 4 applies server-side, and kubectl now owns the limit, so a plain
  # rollback fails with a field conflict. --force-conflicts takes it back.
  # Helm 3 has no such flag and its three-way merge restores the field anyway.
  local force=()
  helm version --short | grep -q '^v3\.' || force=(--force-conflicts)
  helm rollback "$REL" "$rev" -n "$NS" "${force[@]}" --wait --timeout 180s
  [ "$(live_limit)" = 128Mi ] || die "limit is still $(live_limit) after the rollback"
  kubectl -n "$NS" get pods -l "app=$REL"
  echo "     limits.memory back to 128Mi"
}

cmd_status() {
  echo "release: $NS/$REL"
  helm history "$REL" -n "$NS" --max 3 2>/dev/null || echo "  (not installed)"
  echo
  echo "live limits.memory: $(live_limit 2>/dev/null || echo '-')"
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
