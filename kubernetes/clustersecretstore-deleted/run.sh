#!/usr/bin/env bash
# Deleted ClusterSecretStore: one cluster-scoped object gone, many failures.
#
#   ./run.sh break     # sync four secrets through one ClusterSecretStore, delete it, then restart
#   ./run.sh fix       # recreate the store; every ExternalSecret recovers at once
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete everything this scenario created
#
# Deleting the store breaks nothing at first: External Secrets keeps the
# Secrets it already wrote, so running pods carry on. The damage shows up later,
# when a Secret is rotated or a pod restarts on a fresh Secret: ESO cannot
# recreate it, and three services in two namespaces fail to start, each with a
# different "secret not found". They look like three incidents. They are one:
# every failing ExternalSecret points at the same missing ClusterSecretStore.
#
# Requires External Secrets Operator (external-secrets.io/v1 API, v0.17+). The
# store uses ESO's built-in fake provider, so no cloud credentials are needed.
set -euo pipefail

NS=${NS:-nudgebee-demo}
NS2=${NS2:-nudgebee-demo-billing}
STORE=${STORE:-shop-secrets}
LABEL=scenario=clustersecretstore-deleted

# name:namespace pairs, so loops below stay readable
FAILING_ES="checkout-db:$NS payment-gateway:$NS orders-db:$NS invoice-smtp:$NS2"
FAILING_DEPLOY="checkout-api:$NS orders-api:$NS invoice-worker:$NS2"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

preflight() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  kubectl get crd clustersecretstores.external-secrets.io externalsecrets.external-secrets.io >/dev/null 2>&1 \
    || die "External Secrets Operator is not installed (https://external-secrets.io)"
  # Never touch a store this script did not create: the name could be real.
  local owner
  owner=$(kubectl get clustersecretstore "$STORE" -o jsonpath='{.metadata.labels.scenario}' 2>/dev/null || true)
  if kubectl get clustersecretstore "$STORE" >/dev/null 2>&1 && [ "$owner" != clustersecretstore-deleted ]; then
    die "ClusterSecretStore $STORE exists and was not created by this scenario; set STORE=<other name>"
  fi
  # Same for the namespaced objects break overwrites or deletes by name.
  local pair kind name ns
  for pair in $FAILING_ES catalog-flags:$NS; do
    for kind in secret externalsecret; do
      not_ours "$kind" "${pair%%:*}" "${pair#*:}"
    done
  done
  for pair in $FAILING_DEPLOY catalog-api:$NS; do not_ours deploy "${pair%%:*}" "${pair#*:}"; done
  not_ours secretstore local-config "$NS"
}

# Dies if <kind> <name> exists in <ns> without this scenario's label.
not_ours() {
  local label
  kubectl -n "$3" get "$1" "$2" >/dev/null 2>&1 || return 0
  label=$(kubectl -n "$3" get "$1" "$2" -o jsonpath='{.metadata.labels.scenario}')
  [ "$label" = clustersecretstore-deleted ] \
    || die "$1 $3/$2 exists and was not created by this scenario; set NS / NS2 to other namespaces"
}

# kubectl apply from stdin, hiding ESO's "isn't currently maintained" warning
# for the fake provider without hiding a failed apply.
apply() {
  local out rc=0
  out=$(kubectl apply -f - 2>&1) || rc=$?
  printf '%s\n' "$out" | grep -v "isn't currently maintained" || true
  return "$rc"
}

store_yaml() {
  cat <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: $STORE
  labels: {scenario: clustersecretstore-deleted}
spec:
  provider:
    fake:
      data:
      - key: /shop/checkout/db
        value: '{"DB_USER":"checkout","DB_PASSWORD":"demo-only"}'
      - key: /shop/payments/gateway
        value: '{"GATEWAY_KEY":"demo-only"}'
      - key: /shop/orders/db
        value: '{"DB_USER":"orders","DB_PASSWORD":"demo-only"}'
      - key: /shop/billing/smtp
        value: '{"SMTP_USER":"invoices","SMTP_PASSWORD":"demo-only"}'
EOF
}

externalsecret() { # name namespace storeKind storeName key
  cat <<EOF
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: $1
  namespace: $2
  labels: {scenario: clustersecretstore-deleted}
spec:
  refreshInterval: 1m
  secretStoreRef: {kind: $3, name: $4}
  target:
    name: $1
    template:
      metadata:
        labels: {scenario: clustersecretstore-deleted}
  dataFrom:
  - extract: {key: $5}
EOF
}

deployment() { # name namespace secret... (each becomes an envFrom)
  local name=$1 ns=$2; shift 2
  local env="" s
  for s in "$@"; do env="$env
        - secretRef: {name: $s}"; done
  cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: $ns
  labels: {scenario: clustersecretstore-deleted, app: $name}
spec:
  replicas: 1
  selector: {matchLabels: {app: $name}}
  template:
    metadata:
      labels: {scenario: clustersecretstore-deleted, app: $name}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 65534}
      containers:
      - name: $name
        image: busybox:1.36
        command: ["/bin/sh", "-c", "echo '$name: credentials loaded, serving'; while true; do sleep 3600; done"]
        envFrom:$env
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true}
        resources:
          requests: {cpu: 5m, memory: 16Mi}
          limits: {memory: 32Mi}
EOF
}

workloads_yaml() {
  cat <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: local-config
  namespace: $NS
  labels: {scenario: clustersecretstore-deleted}
spec:
  provider:
    fake:
      data:
      - key: /catalog/flags
        value: '{"FEATURE_FLAGS":"new-search=on"}'
EOF
  externalsecret checkout-db     "$NS"  ClusterSecretStore "$STORE" /shop/checkout/db
  externalsecret payment-gateway "$NS"  ClusterSecretStore "$STORE" /shop/payments/gateway
  externalsecret orders-db       "$NS"  ClusterSecretStore "$STORE" /shop/orders/db
  externalsecret invoice-smtp    "$NS2" ClusterSecretStore "$STORE" /shop/billing/smtp
  externalsecret catalog-flags   "$NS"  SecretStore        local-config /catalog/flags
  deployment checkout-api   "$NS"  checkout-db payment-gateway
  deployment orders-api     "$NS"  orders-db
  deployment catalog-api    "$NS"  catalog-flags
  deployment invoice-worker "$NS2" invoice-smtp
}

es_reason() { kubectl -n "$2" get externalsecret "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null; }

wait_es() { # wanted-reason "name:ns ..."
  local want=$1 pair i pending
  for i in $(seq 1 40); do
    pending=0
    for pair in $2; do [ "$(es_reason "${pair%%:*}" "${pair#*:}")" = "$want" ] || pending=1; done
    [ "$pending" = 0 ] && return 0
    sleep 3
  done
  return 1
}

cmd_break() {
  preflight
  say "1/4  Deploying four services; their secrets come from ClusterSecretStore $STORE"
  for n in "$NS" "$NS2"; do kubectl create namespace "$n" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
  store_yaml | apply || die "could not create ClusterSecretStore $STORE"
  workloads_yaml | apply || die "could not create the scenario's workloads"
  wait_es SecretSynced "$FAILING_ES catalog-flags:$NS" || die "ExternalSecrets did not sync -- is the ESO controller running?"
  local pair
  for pair in $FAILING_DEPLOY catalog-api:$NS; do
    kubectl -n "${pair#*:}" rollout status deploy/"${pair%%:*}" --timeout=120s >/dev/null
  done
  kubectl get externalsecret -n "$NS" -l "$LABEL"; kubectl get externalsecret -n "$NS2" -l "$LABEL"

  say "2/4  Deleting ClusterSecretStore $STORE (nothing breaks yet: the Secrets already exist)"
  kubectl delete clustersecretstore "$STORE"
  wait_es SecretSyncedError "$FAILING_ES" || die "ExternalSecrets did not report the missing store within 2 minutes"
  [ "$(es_reason catalog-flags "$NS")" = SecretSynced ] || die "catalog-flags should still be synced"

  say "3/4  Rotating credentials: deleting the four Secrets so ESO pulls fresh values"
  for pair in $FAILING_ES; do kubectl -n "${pair#*:}" delete secret "${pair%%:*}" --ignore-not-found >/dev/null; done

  say "4/4  Restarting checkout-api, orders-api, invoice-worker"
  for pair in $FAILING_DEPLOY; do kubectl -n "${pair#*:}" delete pod -l app="${pair%%:*}" --wait=false >/dev/null; done
  local i stuck
  for i in $(seq 1 30); do
    stuck=0
    for pair in $FAILING_DEPLOY; do
      kubectl -n "${pair#*:}" get pods -l app="${pair%%:*}" \
        -o jsonpath='{.items[*].status.containerStatuses[0].state.waiting.reason}' | grep -q CreateContainerConfigError \
        && stuck=$((stuck + 1))
    done
    [ "$stuck" = 3 ] && break
    sleep 3
  done
  [ "$stuck" = 3 ] || die "expected 3 deployments in CreateContainerConfigError, got $stuck"
  kubectl get pods -n "$NS" -l "$LABEL"; kubectl get pods -n "$NS2" -l "$LABEL"

  cat <<TXT

  Two things to look at in NudgeBee:

  1. Did it notice on its own, and how many incidents did it open?
     Troubleshoot -> Pod Errors should show three CreateContainerConfigError
     pods. The good outcome is one root cause, not three separate ones.

  2. Ask it, the way an on-call engineer would:

    "After this morning's restarts, checkout-api and orders-api in $NS
     and invoice-worker in $NS2 won't start. What's wrong?"

  Expect: one root cause for all three. Their Secrets (checkout-db,
          payment-gateway, orders-db, invoice-smtp) are written by
          ExternalSecrets that all reference ClusterSecretStore $STORE,
          which no longer exists: every one is SecretSyncedError, and their
          UpdateFailed events say 'could not get ClusterSecretStore "$STORE"
          ... not found'. The ESO
          controller is fine (catalog-flags, on a namespaced SecretStore,
          still syncs). Fix: recreate $STORE from source control; ESO then
          rewrites all four Secrets and the pods start. Creating the Secrets
          by hand, or repointing each ExternalSecret, is the wrong fix.

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  preflight
  say "Recreating ClusterSecretStore $STORE"
  store_yaml | apply || die "could not recreate ClusterSecretStore $STORE"
  # Ask ESO to reconcile now instead of waiting for the next refresh.
  local pair
  for pair in $FAILING_ES; do
    kubectl -n "${pair#*:}" annotate externalsecret "${pair%%:*}" force-sync="$(date +%s)" --overwrite >/dev/null
  done
  wait_es SecretSynced "$FAILING_ES" || die "ExternalSecrets did not resync"
  for pair in $FAILING_DEPLOY; do
    kubectl -n "${pair#*:}" rollout status deploy/"${pair%%:*}" --timeout=120s
  done
  echo "     all four ExternalSecrets synced, all pods running"
}

cmd_status() {
  echo "ClusterSecretStore $STORE: $(kubectl get clustersecretstore "$STORE" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo 'MISSING')"
  local n
  for n in "$NS" "$NS2"; do
    echo; echo "namespace $n"
    kubectl get externalsecret,secret,pods -n "$n" -l "$LABEL" 2>/dev/null || true
  done
}

cmd_cleanup() {
  local n
  for n in "$NS" "$NS2"; do
    kubectl delete deploy,externalsecret,secretstore -n "$n" -l "$LABEL" --ignore-not-found
    kubectl delete secret -n "$n" -l "$LABEL" --ignore-not-found
  done
  kubectl delete clustersecretstore -l "$LABEL" --ignore-not-found
  echo "Namespaces $NS and $NS2 were left in place; delete them yourself if this script created them."
}

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
