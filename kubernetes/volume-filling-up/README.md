# A volume filling up — days of warning before the disk is full

A cleanup of the orders database's StatefulSet drops a volume mount that looked
unused. It was where the database archived its write-ahead log. Archiving has
failed ever since, so the database keeps every log segment, and its volume
grows a steady ~13% a day. Every pod stays Running and Ready, and in about five
days the disk will be full.

This scenario takes days, not minutes. It exists to show NudgeBee's disk
forecast warning you while there is still time to act.

```bash
./run.sh break
```

## What it does

1. Deploys `orders-db` (Postgres on a 10Gi volume), archiving its WAL to a second volume, `orders-db-wal-archive`. Also deploys `order-service`, which sends it order traffic. Confirms archiving works
2. Waits for `order-service` to load its tables
3. Removes the archive mount from the StatefulSet, the kind of change a "remove unused volumes" tidy-up makes. Confirms archiving now fails
4. From then on, the volume grows about 1.3 GiB a day: busier in the afternoon, quieter at night (UTC)

## Watching the forecast

As soon as `break` finishes, add a Disk SLO on the claim: **Apps & Infra → PVC →
`data-orders-db-0` → row menu → Disk SLO → 85% → Save**. The forecast only
watches claims that have one. It needs 48 hours of history before it can project.

| After `break` | Volume | In NudgeBee |
|---|---|---|
| 0–2 days | ~16% → 42% | **Check now** shows the daily climb, but there is not yet enough history to project |
| ~2 days | ~42% | "Disk saturation breach predicted", MEDIUM, with the date the volume reaches 85% |
| ~3 days | ~59% | The same alert, HIGH: under 48 hours left |
| ~5 days | 85% | "Disk saturation SLO breached" |
| ~6 days | 93% | `order-service` stops taking orders, and the volume holds here |

The number to check is the fill date on the first warning. It should be within
about 16 hours of when the breach alert actually fires.

## Why it fills

Postgres deletes a WAL segment only after `archive_command` has copied it
somewhere. The command copies to `/wal-archive`. With the mount gone, that
directory does not exist, so every copy fails and every segment stays in
`pg_wal`. The archive volume itself is still there, unused: the change dropped
the mount, not the claim.

## The naive answer

> The volume is too small. Resize it.

The alert offers that, and it does buy time. But archiving is still failing, so
the bigger volume fills too, and no WAL has been backed up since the change. The
useful answer names the failing `archive_command` and the dropped mount.

## What to do in NudgeBee

Once the warning fires, ask:

> data-orders-db-0 in nudgebee-demo will be full in a few days. Why is it
> filling up?

A good answer:

- shows that `pg_wal` holds most of the volume
- finds `archive command failed` in the `orders-db` logs, with `/wal-archive` missing
- ties it to the StatefulSet change that dropped the `orders-db-wal-archive` mount, and recommends mounting it again rather than only resizing

Then fix it, or let NudgeBee:

```bash
./run.sh fix   # mounts the archive again; Postgres archives the backlog and the volume drops back
```

## Needs

- Permission to create a StatefulSet and two PersistentVolumeClaims: 10Gi and
  20Gi by default. `SIZE`, `ARCHIVE_SIZE` and `STORAGE_CLASS` override them.
  The timeline above is for 10Gi.
- `allowVolumeExpansion: true` on the StorageClass, if you want to try the resize
- Prometheus collecting kubelet volume stats (`kubelet_volume_stats_*`).
  Without them the forecast has nothing to read.
- A volume type that kubelet reports stats for. Most CSI drivers do; `hostPath`
  and `local` volumes don't.

The cluster pulls `postgres:16.4` from Docker Hub. Set `IMAGE` to a mirror if it
can't.

`order-service` connects as the database superuser, and reads the volume's fill
through a server-side command. That is fine for a throwaway database, but not a
pattern to copy.

`cleanup` deletes only this scenario's resources, both volumes included, and not
the namespace, which other scenarios share.
