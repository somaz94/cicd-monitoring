# Fluent Bit tail Input — dev vs prod Recommended Settings

The fluent-bit `tail` input options in `values/dev.yaml` reflect the current dev-cluster configuration. **Using the same settings in prod risks log loss on restart**, so this document captures the recommended prod values.

> **Current dev state (2026-05-13~ )**: Tier 1 / Phase 1a + buffer hardening applied.
> - fluent-bit: `DB` checkpoints, `storage.type filesystem`, state PVC (`fluent-bit-state-pvc`, declared 5Gi / actual 2Gi, `nfs-client-server1`), `updateStrategy: Recreate`, OUTPUT `storage.total_limit_size 2G`.
> - fluentd: buffer `queue_limit_length 128` + `total_limit_size 4GB` + `retry_forever true` + `<secondary>` JSON format + PrometheusRule with 7 alerts.
> - Only `Read_from_Head` remains `false` (awaiting Phase 1b promotion).
> - Detailed change log: see the git log for fluent-bit-related commits. For re-ingest after index loss, see [reingest-procedure-en.md](./reingest-procedure-en.md).

<br/>

## ⚠️ RWO state PVC + SQLite — `updateStrategy: Recreate` required

The Phase 1a state PVC is `ReadWriteOnce` and contains four SQLite databases. With the chart's default `RollingUpdate`:

1. The new pod is created first (maxSurge=1)
2. While the old pod is still alive, the new pod tries to open the SQLite DBs → **`error=database is locked`**
3. The new pod fails input initialization → **CrashLoopBackOff**

→ Setting `updateStrategy: { type: Recreate }` terminates the old pod before starting the new one. Trade-off: ~tens of seconds of ingest downtime during rolling restarts (Phase 1a's DB + filesystem chunk buffer absorbs NFS appends during that window, so no data is lost).

Recommend the same pattern in prod: RWO state PVC + DB checkpoint + `updateStrategy: Recreate`. Exposed as the `updateStrategy` values key in fluent-bit chart 0.57.x.

<br/>

## Three key options

### 1) `Read_from_Head`

Decides where to start reading when fluent-bit first discovers a file.

| Value | Behavior | Trade-off |
|---|---|---|
| `false` (dev) | Read from end of file | Logs appended between restart events are **permanently lost**. Acceptable in dev |
| `true` (prod) | Read from beginning | **Must be combined with `DB` checkpoint** — otherwise every restart re-ingests history (duplicates) |

In prod always use `true` + `DB`. Setting `true` alone causes the same lines to be ingested into ES on every restart.

<br/>

### 2) `DB` (sqlite checkpoint) — new in prod recommendation

fluent-bit persists each file's current read offset to a sqlite DB → on pod restart it resumes from exactly that position. No duplicates, no losses.

```ini
DB              /var/lib/fluent-bit/example-project-game.db
DB.locking      true
DB.journal_mode WAL
```

**Critical — persist the DB file**: the `DB` file must live on a PV (PVC) or hostPath so that the checkpoint survives pod restarts. If it sits in emptyDir, the sqlite file vanishes on every restart, defeating the purpose of `Read_from_Head true`.

Suggested mounts:
- PVC: portable across nodes, RWO is enough
- hostPath: pinned to a node — simpler for DaemonSets

<br/>

### 3) `Ignore_Older`

Files whose mtime is older than N hours/days are skipped at *initial* discovery. Files already being tailed are unaffected.

| Value | Suitable for | Trade-off |
|---|---|---|
| `0` (disabled) | Not recommended | First install ingests every historical log on the NFS at once → ES bootstrap load spike |
| `7d` (same as dev) | Recommended prod default | Skips files unmodified for over a week — safety net. No impact on steady-state operation |
| `30d` | If you also want a month of history | Larger ES indices, larger first backfill |
| `1d` | Very conservative | Too little backfill — usually unnecessary |

Keep `7d` in prod. With the DB checkpoint in place, it functions purely as a safety net.

<br/>

## Standard recommended INPUT block (prod)

```ini
[INPUT]
    Name tail
    Path /fluent-bit/logs/example-project/prod/game/*
    Path_Key filepath
    Tag example-project.prod.game
    Parser example-project_json
    Refresh_Interval 10

    # Read policy — exact resume from checkpoint
    Read_from_Head true
    DB /var/lib/fluent-bit/example-project-prod-game.db
    DB.locking true
    DB.journal_mode WAL
    Ignore_Older 7d

    # Buffer / memory
    Mem_Buf_Limit 100MB
    Skip_Long_Lines On
    Skip_Empty_Lines On

    # Disk spill (for memory pressure)
    storage.type filesystem
```

Combine with filesystem storage in the `[SERVICE]` section:

```ini
[SERVICE]
    storage.path              /var/lib/fluent-bit/storage
    storage.sync              normal
    storage.checksum          off
    storage.max_chunks_up     256
    storage.backlog.mem_limit 256M
```

<br/>

## dev vs prod comparison

| Option | dev (current, Phase 1a applied) | prod recommended | Why |
|---|---|---|---|
| `Read_from_Head` | `false` | `true` (Phase 1b) | Combined with DB checkpoint → zero loss, zero duplication. dev will promote to Phase 1b after stabilization |
| `DB` checkpoint | **4 files on state PVC (.db)** ✅ | persisted on PV (PVC) | Resume reads across restarts |
| `DB.locking` | `true` ✅ | `true` | Safe under NFS / concurrency |
| `DB.sync` | `normal` ✅ | `normal` | sqlite WAL fsync cadence |
| `Ignore_Older` | `7d` | `7d`~`90d` (align with NFS retention) | Prevent NFS backfill spike on first install. Aligning with retention widens the re-ingest window |
| `storage.type` | `filesystem` ✅ | `filesystem` | Disk spill on memory pressure, buffer survives ES/fluentd outages |
| `storage.path` (SERVICE) | `/fluent-bit/state/storage/` ✅ | path on PV | Persist filesystem chunk buffer |
| `storage.backlog.mem_limit` | `50M` ✅ | `256M+` | Prod traffic |
| `Mem_Buf_Limit` | `50MB` | `100MB+` | Prod traffic |
| `Refresh_Interval` | `10` | `10` (keep) | New-file detection cadence (s). 5–30s is reasonable on NFS |
| OUTPUT `Retry_Limit` | `no_limits` ✅ | `no_limits` | Survive transient fluentd outages |
| OUTPUT `storage.total_limit_size` | `2G` ✅ | `5G+` | Disk-buffer cap (scale for prod throughput) |
| `updateStrategy.type` | `Recreate` ✅ | `Recreate` | Avoid multi-pod SQLite lock clash on RWO state PVC |

<br/>

## Migration caveats

When moving from dev to prod, switching `Read_from_Head` to `true` while the DB is empty makes fluent-bit re-read every file from the start → duplicate ingestion into ES.

Correct sequence (Phase 1a → 1b model):
1. Add PV/PVC or hostPath mount first (target for the DB file) — **applied in dev on 2026-05-13**
2. Declare the mount in `extraVolumeMounts` for the state path (e.g. `/fluent-bit/state`)
3. Roll out the INPUT block with `DB` + `storage.type filesystem` while keeping `Read_from_Head false` (Phase 1a) → first deploy starts from EOF, zero ES duplicates
4. Restart fluent-bit pod → DB files auto-created; every subsequent restart resumes exactly
5. After ≥ 1 week of stability with every active file present in the DB → promote to `Read_from_Head true` (Phase 1b). Restarts crossing a rotation point no longer drop logs.

`Ignore_Older` cannot be used to limit backfill volume here — game logs append every second, so every active file passes the mtime filter and `Read_from_Head true` will still read each from head. Backfill control comes only from the Phase 1a/1b split.

<br/>

## References

- Current dev INPUT definition (Phase 1a applied): [../values/dev.yaml](../values/dev.yaml)
- Re-ingest procedure after index loss: [reingest-procedure-en.md](./reingest-procedure-en.md)
- Official docs: https://docs.fluentbit.io/manual/pipeline/inputs/tail
- DB / checkpoint: https://docs.fluentbit.io/manual/pipeline/inputs/tail#db
- filesystem storage: https://docs.fluentbit.io/manual/administration/buffering-and-storage
