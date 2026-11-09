#!/usr/bin/env bash
# Volume-filling-up scenario for the NudgeBee Scenario Lab.
#
#   ./run.sh break     # deploy the database healthy, then drop its WAL archive mount
#   ./run.sh fix       # mount the archive again; Postgres catches up and frees the volume
#   ./run.sh status    # where things stand
#   ./run.sh cleanup   # delete the scenario's resources, volumes included
#
# A slow one. The database's volume fills a steady ~13% a day, which is what the
# disk forecast needs: it wants 48 hours of history before its first warning, and
# the volume reaches 85% about five days after `break`. Add a Disk SLO on the claim
# right after `break` (it prints how).
#
# The fault: orders-db archives every WAL segment to /wal-archive. A change to the
# StatefulSet drops that mount. archive_command then fails, and Postgres keeps every
# segment it has not archived, so pg_wal grows until the volume is full.
#
# order-service writes about DAILY_WRITE_MIB of WAL a day, busier in the afternoon
# (UTC), and re-tunes its rate every 5 minutes to hold that whatever a transaction
# costs on this storage. It stops taking orders at 93% full, so the database stays
# up for the breach alert and the fix.
set -euo pipefail

NS=${NS:-nudgebee-demo}
DB=${DB:-orders-db}
APP=${APP:-order-service}
SIZE=${SIZE:-10Gi}
ARCHIVE_SIZE=${ARCHIVE_SIZE:-20Gi}
STORAGE_CLASS=${STORAGE_CLASS:-}   # empty: the cluster's default class
DAILY_WRITE_MIB=${DAILY_WRITE_MIB:-1300}
IMAGE=${IMAGE:-postgres:16.4}
HERE=$(cd "$(dirname "$0")" && pwd)
CLAIM="data-$DB-0"
ARCHIVE="$DB-wal-archive"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

sql() { kubectl -n "$NS" exec "$DB-0" -c postgres -- psql -X -q -At -U postgres -d orders -c "$1"; }
disk() { kubectl -n "$NS" exec "$DB-0" -c postgres -- df -h /var/lib/postgresql/data | tail -1 | awk '{print $3" of "$2" used ("$5")"}'; }

# $1 = the seconds to wait, $2 = a query that answers t when done
wait_sql() {
  local i
  for i in $(seq 1 $(($1 / 5))); do
    [ "$(sql "$2" 2>/dev/null)" = t ] && return 0
    sleep 5
  done
  return 1
}

# On first start the image runs a socket-only server to create the database, and the
# readiness probe can pass against it. The real server is the one listening on TCP.
wait_db() {
  wait_sql 180 "select current_setting('listen_addresses') <> ''" || die "$DB did not come up; see: kubectl -n $NS logs $DB-0"
}

render_archive_claim() {
  cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $ARCHIVE
  labels: {app: $DB}
spec:
  accessModes: [ReadWriteOnce]
  ${STORAGE_CLASS:+storageClassName: $STORAGE_CLASS}
  resources: {requests: {storage: $ARCHIVE_SIZE}}
EOF
}

# $1 = the archive mount: on | off
render_db() {
  local mount="" volume=""
  if [ "$1" = on ]; then
    mount='
            - {name: wal-archive, mountPath: /wal-archive}'
    volume="
      volumes:
        - name: wal-archive
          persistentVolumeClaim: {claimName: $ARCHIVE}"
  fi
  cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $DB
  labels: {app: $DB}
spec:
  clusterIP: None
  selector: {app: $DB}
  ports: [{name: postgres, port: 5432, targetPort: postgres}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $DB
  labels: {app: $DB}
spec:
  serviceName: $DB
  replicas: 1
  selector:
    matchLabels: {app: $DB}
  template:
    metadata:
      labels: {app: $DB}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: postgres
          image: $IMAGE
          args:
            - -c
            - shared_buffers=128MB
            - -c
            - max_wal_size=1GB
            - -c
            - checkpoint_timeout=15min
            - -c
            - archive_mode=on
            - -c
            - archive_command=test ! -f /wal-archive/%f && cp %p /wal-archive/%f
          env:
            - {name: POSTGRES_DB, value: orders}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: $DB-credentials, key: password}}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          ports: [{name: postgres, containerPort: 5432}]
          readinessProbe:
            exec: {command: [pg_isready, -U, postgres, -d, orders]}
            periodSeconds: 10
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 512Mi}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}$mount$volume
  volumeClaimTemplates:
    - metadata:
        name: data
        labels: {app: $DB}
      spec:
        accessModes: [ReadWriteOnce]
        ${STORAGE_CLASS:+storageClassName: $STORAGE_CLASS}
        resources: {requests: {storage: $SIZE}}
EOF
}

render_app() {
  cat <<EOF
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
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: $APP
          image: $IMAGE
          command: [sh, /app/order-service.sh]
          env:
            - {name: PGHOST, value: $DB}
            - {name: PGUSER, value: postgres}
            - {name: PGDATABASE, value: orders}
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: $DB-credentials, key: password}}
            - {name: DAILY_WRITE_MIB, value: "$DAILY_WRITE_MIB"}
            - {name: START_TPS, value: "20"}
          resources:
            requests: {cpu: 20m, memory: 32Mi}
            limits: {memory: 128Mi}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts: [{name: app, mountPath: /app}]
      volumes:
        - name: app
          configMap: {name: $APP-app}
EOF
}

apply_db() {
  render_db "$1" | kubectl -n "$NS" apply -f -
  kubectl -n "$NS" rollout status "sts/$DB" --timeout=300s
}

cmd_break() {
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"

  say "1/4  Deploying $NS/$DB and $NS/$APP, healthy: WAL archived to $ARCHIVE"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NS" get secret "$DB-credentials" >/dev/null 2>&1 ||
    kubectl -n "$NS" create secret generic "$DB-credentials" \
      --from-literal=password="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  render_archive_claim | kubectl -n "$NS" apply -f -
  kubectl -n "$NS" create configmap "$APP-app" --from-file="$HERE/order-service.sh" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f -
  apply_db on
  render_app | kubectl -n "$NS" apply -f -
  wait_db
  sql "select pg_switch_wal()" >/dev/null
  wait_sql 60 "select coalesce(last_archived_time > coalesce(last_failed_time, '-infinity'), false) from pg_stat_archiver" ||
    die "$DB is not archiving even with the archive mounted -- not this scenario"
  echo "     archiving works: $(sql "select archived_count from pg_stat_archiver") segment(s) archived"

  say "2/4  Waiting for $APP to load its tables (a few minutes)"
  wait_sql 900 "select to_regclass('public.pgbench_accounts_pkey') is not null" ||
    die "$APP did not finish loading; see: kubectl -n $NS logs deploy/$APP"

  say "3/4  Dropping the archive mount from $DB, a StatefulSet change"
  apply_db off
  wait_db
  sql "select pg_switch_wal()" >/dev/null
  wait_sql 90 "select coalesce(last_failed_time > coalesce(last_archived_time, '-infinity'), false) from pg_stat_archiver" ||
    die "archiving has not failed yet; check: $0 status"

  say "4/4  Archiving now fails, and every WAL segment stays on the volume:"
  echo "     $NS/$CLAIM: $(disk)"

  cat <<TXT

  The volume now grows about $DAILY_WRITE_MIB MiB a day. The timings below are for a 10Gi volume:

  1. Now, in NudgeBee: Apps & Infra -> PVC -> $CLAIM ($NS) -> row menu
     -> Disk SLO -> 85% -> Save. Check now shows the climb; it needs
     48 hours of history before it can project.
  2. ~2 days:  "Disk saturation breach predicted", MEDIUM, with a fill date.
  3. ~3 days:  the same alert, HIGH (fill date under 48 hours away).
  4. ~5 days:  "Disk saturation SLO breached". $APP holds new orders at 93%.

  Then ask NudgeBee why $CLAIM is filling up.
  Expect: pg_wal holds most of the volume because archive_command fails --
          /wal-archive no longer exists since the StatefulSet change dropped
          the $ARCHIVE mount. Fix: mount it again. Resizing the
          volume (what the alert offers) only buys time.

  Fix it yourself:  $0 fix
TXT
}

cmd_fix() {
  kubectl -n "$NS" get sts "$DB" >/dev/null 2>&1 || die "$NS/$DB not found -- run '$0 break' first"
  local before
  before=$(disk)
  say "Mounting $ARCHIVE again"
  apply_db on
  wait_db
  wait_sql 900 "select count(*) = 0 from pg_ls_archive_statusdir() where name like '%.ready'" ||
    die "the archiver has not caught up; check: $0 status"
  sql "checkpoint" >/dev/null
  echo "     archived the backlog; $CLAIM: $before -> $(disk)"
}

cmd_status() {
  echo "workload: $NS/$APP -> $NS/$DB"
  kubectl -n "$NS" get pod "$DB-0" >/dev/null 2>&1 || { echo "  (not deployed)"; return 0; }
  kubectl -n "$NS" get pods -l "app in ($DB,$APP)"
  echo
  echo "volume $CLAIM: $(disk)"
  echo
  echo "archiver (archived | failed | last archived | last failed):"
  sql "select archived_count, failed_count, last_archived_time, last_failed_time from pg_stat_archiver" | sed 's/^/  /' || true
  echo "  waiting to archive: $(sql "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'") segment(s)"
  echo
  echo "last $APP log lines:"
  kubectl -n "$NS" logs "deploy/$APP" --tail=3 2>/dev/null | sed 's/^/  /' || true
}

# The namespace may hold other scenarios, so only delete what this one made.
cmd_cleanup() {
  kubectl -n "$NS" delete deploy "$APP" --ignore-not-found
  kubectl -n "$NS" delete sts "$DB" --ignore-not-found
  kubectl -n "$NS" delete service "$DB" --ignore-not-found
  kubectl -n "$NS" delete configmap "$APP-app" --ignore-not-found
  kubectl -n "$NS" delete secret "$DB-credentials" --ignore-not-found
  kubectl -n "$NS" delete pvc "$CLAIM" "$ARCHIVE" --ignore-not-found
}

case "${1:-}" in
  break)   cmd_break ;;
  fix)     cmd_fix ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: $0 {break|fix|status|cleanup}" ;;
esac
