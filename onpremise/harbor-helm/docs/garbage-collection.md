# Harbor Garbage Collection

The GC schedule that reclaims Harbor registry disk, and the capacity analysis behind it.

<br/>

## What GC actually does — two separate operations

This is easy to get wrong: **the core of GC has nothing to do with tags.**

| Phase | Operation | Always runs? |
|---|---|---|
| ① `delete_untagged` | Delete **manifests (artifacts)** that carry no tag at all | Optional |
| ② Blob sweep | Reclaim **layers no manifest references** from disk | **Always** |

② is what GC really is. Harbor does not remove blobs when an artifact is deleted — it leaves them behind, and this is the phase that sweeps them up. Tags are irrelevant to it.

**No option deletes a referenced image.** That is why GC, unlike a retention policy, needs no "what do we throw away" decision.

<br/>

## Why it was scheduled (analysis, 2026-08-05)

| Item | State |
|---|---|
| GC schedule | **None** |
| GC run history | A single **manual** run on 2026-04-27 (100 days earlier) |
| Retention policies | **None** on any of the 4 projects |
| Cleanup CronJob | None — [`scripts/image-cleanup/`](../scripts/image-cleanup/) is run by hand |

In other words, **the only cleanup mechanism was somebody remembering to run it manually every ~100 days.**

### Measuring what was reclaimable

| Measurement | Value |
|---|---|
| Disk, measured (`du /storage`) | **85G** |
| Sum of Harbor quotas | **60.8G** (library 30.8G · example-project 21.2G · toolchain 8.6G · secondary-project 151M) |
| **Difference = orphaned blobs** | **≈ 24G** |

The quota sum double-counts blobs shared between projects, so it **overestimates** — and it is still 24G below the disk figure. The real orphan total is higher, and all of it is reclaimed by phase ② — capacity gained **without deleting anything new**.

The previous manual run gives the sense of scale:

```
2026-04-27 manual GC:  freed 109.5G | blobs 14,852 | manifests 5,519
```

109.5G reclaimed in one run, and 100 days later it was back up to 85G.

<br/>

## The schedule in effect

```bash
./scripts/admin/harbor-admin.sh gc-status
```

| Item | Value |
|---|---|
| cron | `0 0 20 * * 6` |
| Actual time | **Sat 20:00 UTC = Sun 05:00 KST** |
| `delete_untagged` | `true` |
| `workers` | `1` |

### Why this slot

- **Weekend** — GC briefly slows the registry, so it has to stay clear of CI hours
- **05:00 KST** — after all three backup CronJobs (etcd 02:00, app backups 03:00, harbor-db 04:00 KST)
- **Weekly** — 24G over 100 days is roughly 1.7G per week, so each run stays short. The point is to stop a 109G backlog from forming again

### Why `delete_untagged: true`

To also sweep abandoned build cache (the `*/cache` repositories — 8 of them, 858 artifacts, ~20G). **The cache actually in use is tagged and survives**: of the 143 artifacts in `example-project/game/cache`, 118 carry tags, and only the 25 superseded ones are affected.

The first build after a GC may be slower from a cache miss, but nothing breaks.

<br/>

## ⚠️ This setting does not live in git

The GC schedule is a **runtime setting stored in Harbor's database** — the same category as the OIDC configuration, and not expressible as a Helm value.

That means **reinstalling Harbor or restoring its database drops the schedule.** To restore it:

```bash
./scripts/admin/harbor-admin.sh gc-schedule --dry-run   # inspect the payload
./scripts/admin/harbor-admin.sh gc-schedule             # apply
```

If you restored from the [database backup](db-backup.md), the schedule comes back with it and no action is needed.

<br/>

## Next step — retention (not applied)

GC only reclaims what has already been discarded; it never decides **what** to discard. Reducing the referenced artifacts needs a retention policy, and none of the 4 projects has one.

In priority order:

1. **Aggressive retention on `*/cache` repositories** — build cache only needs the last 5–10. That turns 858 artifacts into a few dozen, and GC reclaims the blobs behind them
2. **Retention on image repositories** — "keep the last N" for places like `example-project/*` where a commit-SHA tag accumulates every build. This needs more care than (1): N must be generous enough that a rollback target is never deleted

For context, the image side is healthier than it looks — `example-project/game` holds 131 artifacts, but the oldest push is 2026-06-25, only six weeks back.

<br/>

## Related documents

| Document | Description |
|---|---|
| [`scripts/admin/README-en.md`](../scripts/admin/README.md) | Full `harbor-admin.sh` command list |
| [`scripts/image-cleanup/README-en.md`](../scripts/image-cleanup/README.md) | Manual image cleanup scripts |
| [`docs/db-backup-en.md`](db-backup.md) | Harbor database backup |
