# Fluent Bit tail Input — dev vs prod Recommended Settings

The fluent-bit `tail` input options in `values/dev.yaml` are tuned conservatively for the dev cluster. **Using the same settings in prod risks log loss on restart**, so this document captures the recommended prod values.

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

| Option | dev (current) | prod recommended | Why |
|---|---|---|---|
| `Read_from_Head` | `false` | `true` | Combined with DB checkpoint → zero loss, zero duplication |
| `DB` checkpoint | none | **persisted on PV / hostPath** | Resume reads across restarts |
| `Ignore_Older` | `7d` | `7d` (keep) | Prevent NFS backfill spike on first install |
| `storage.type` | default (memory) | `filesystem` | Disk spill on memory pressure, buffer survives ES outages |
| `Mem_Buf_Limit` | `50MB` | `100MB+` | Prod traffic |
| `Refresh_Interval` | `10` | `10` (keep) | New-file detection cadence (s). 5–30s is reasonable on NFS |

<br/>

## Migration caveats

When moving from dev to prod, switching `Read_from_Head` to `true` while the DB is empty makes fluent-bit re-read every file from the start → duplicate ingestion into ES.

Correct sequence:
1. Add PV/PVC or hostPath mount first (target for the DB file)
2. Declare the mount in `extraVolumeMounts` for `/var/lib/fluent-bit`
3. Roll out the new INPUT block with `DB` enabled
4. Restart the fluent-bit pod → DB file created
5. Steady-state from there. Subsequent restarts resume from the checkpoint

Alternatively, during initial onboarding use a short boundary like `Ignore_Older 1d` to cap backfill volume, then relax to `7d` once stable.

<br/>

## References

- Dev INPUT definition: [../values/dev.yaml:74-133](../values/dev.yaml#L74-L133)
- Official docs: https://docs.fluentbit.io/manual/pipeline/inputs/tail
- DB / checkpoint: https://docs.fluentbit.io/manual/pipeline/inputs/tail#db
- filesystem storage: https://docs.fluentbit.io/manual/administration/buffering-and-storage
