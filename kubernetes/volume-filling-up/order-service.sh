#!/bin/sh
# order-service: order transactions against orders-db, busier in the afternoon than at
# night (UTC). Every chunk it adjusts its rate to keep the database's daily write
# volume steady.
set -u

DAILY=${DAILY_WRITE_MIB:-1300}
CHUNK=${CHUNK_SECONDS:-300}
BACKPRESSURE=${BACKPRESSURE_DISK_PCT:-93}
SCALE=${PGBENCH_SCALE:-50}
DATA_DIR=${DB_DATA_DIR:-/var/lib/postgresql/data}
rate=${START_TPS:-5}
# Share of the day's traffic per UTC hour, x100 (they average 100).
WEIGHTS="90 75 60 50 45 40 40 45 55 70 85 110 125 130 145 155 160 160 155 145 130 120 110 100"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) level=$1 $2"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }

until pg_isready -q; do log info "msg=\"waiting for ${PGHOST:-db}\""; sleep 5; done

# The primary key is the last step of a load, so a load cut short is redone.
if [ "$(q "select to_regclass('public.pgbench_accounts_pkey') is not null")" != "t" ]; then
  log info "msg=\"loading order tables\" scale=$SCALE"
  pgbench -i -q -s "$SCALE" || { log error "msg=\"load failed\""; exit 1; }
fi

chunks_per_day=$((86400 / CHUNK))
while true; do
  w=$(echo "$WEIGHTS" | awk -v h="$(date -u +%H)" '{print $(h+1)}')
  target=$(awk -v t="$DAILY" -v w="$w" -v n="$chunks_per_day" 'BEGIN{printf "%d", t*1048576*w/100/n}')

  pct=$(q "create temp table if not exists _df(l text); truncate _df;
           copy _df from program 'df -kP $DATA_DIR | tail -1'; select l from _df" |
        awk '{printf "%d", $3*100/$2}')
  if [ "${pct:-0}" -ge "$BACKPRESSURE" ]; then
    log warn "msg=\"orders-db volume nearly full, holding new orders\" disk_pct=$pct"
    sleep "$CHUNK"
    continue
  fi

  lsn0=$(q "select pg_current_wal_lsn()")
  if [ -z "$lsn0" ]; then
    log warn "msg=\"orders-db unavailable, retrying\""
    sleep 10
    continue
  fi
  tx=$(pgbench -n -c 2 -j 1 -R "$rate" -T "$CHUNK" 2>&1 |
       awk -F': ' '/number of transactions actually processed/{print $2+0}')
  wal=$(q "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$lsn0')::bigint")
  log info "msg=\"orders processed\" orders=${tx:-0} tps=$rate"
  # A chunk cut short by a database restart says nothing about the rate.
  [ "${tx:-0}" -gt 0 ] && [ -n "$wal" ] || continue

  # Towards the target, at most 3x either way per chunk.
  rate=$(awk -v r="$rate" -v t="$target" -v p="$wal" 'BEGIN{
    if (p <= 0) p = 1; f = t / p; if (f > 3) f = 3; if (f < 0.33) f = 0.33
    r = r * f; if (r < 0.2) r = 0.2; if (r > 400) r = 400; printf "%.2f", r }')
done
