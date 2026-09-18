# Harbor Database Backup

A CronJob that dumps Harbor's PostgreSQL database daily. The manifests live in [`manifests/db-backup-pvc.yaml`](../manifests/db-backup-pvc.yaml) and [`manifests/db-backup-cronjob.yaml`](../manifests/db-backup-cronjob.yaml).

<br/>

## Why only the database

**The registry blob store is deliberately not backed up.**

| Target | Measured size (2026-08-05) | Reproducible |
|---|---|---|
| Registry blobs (`harbor-registry` PVC) | **85G** (4 projects: library / example-project / secondary-project / toolchain) | Yes — CI builds every image from a git commit, and mirrored images can be re-pulled from upstream |
| `registry` database | **19.9M** dump | **No** |

Copying 85G to NFS every night is expensive and buys only rebuild time. The database, by contrast, holds the things that can only be recreated by hand:

- Projects, users, RBAC
- **Robot accounts** — a `harbor-robot-secret` in several namespaces references them
- Replication rules, retention policies, webhooks
- **The tag-to-manifest mapping**

That last one is the point. Lose the database and the 85G of layers is still on disk, but **nothing knows which digest was which tag.**

<br/>

## How it works

| Item | Value |
|---|---|
| Schedule | `0 4 * * *` (Asia/Seoul) — owned by `spec.schedule` in `manifests/db-backup-cronjob.yaml`. Clear of etcd-backup at 02:00 and the other app backups at 03:00 |
| Target DB | `registry` (Harbor 2.x uses a single database) |
| Output | `/backup-data/harbor-registry-<YYYYMMDD>.sql` |
| Retention | 30 days — owned by the `RETENTION_DAYS` env var in `manifests/db-backup-cronjob.yaml` |
| Volume | PVC `harbor-db-backup`, 10Gi RWX, `nfs-client-server` — size and StorageClass are owned by `manifests/db-backup-pvc.yaml` |
| NAS path | `harbor/harbor-db-backup/` |
| Image | The `postgres` alpine image from docker.io — the tag is owned by the `image` field in `manifests/db-backup-cronjob.yaml` |

<br/>

### Things to know

- **The image's major version tracks the server.** The client major must match the major `harbor-database` actually reports. `pg_dump` refuses to run against a server newer than itself, and a dump taken by a newer client can emit syntax an older server cannot restore. **When a Harbor chart bump changes the bundled postgres version, change this image tag too.** This was missed once: a chart bump moved harbor-db's postgres from 15 to 18, the backup pin did not follow, and every run from 2026-08-13 failed with `server version mismatch`. Check the server version with:

  ```bash
  kubectl exec -n harbor sts/harbor-database -- postgres --version
  ```

- **The image is pulled from docker.io, not the Harbor mirror.** This job exists for the case where Harbor is broken; a backup that has to pull its own image through the thing it is backing up is not a backup.
- **It runs as uid 70.** The alpine variant of the postgres image numbers postgres as uid/gid 70; the Debian-based postgres image uses 999. Changing the image **variant** means changing `runAsUser` / `runAsGroup` — a major bump alone does not (alpine kept 70 across 15 to 18).
- **A dump only counts as successful if it passes verification.** `pg_dump` writes its terminating marker only after everything else, so the job checks the last five lines for `PostgreSQL database dump complete` and, if it is missing, deletes the file and fails. A truncated dump is indistinguishable from a good one on disk, and the moment of discovery would otherwise be a restore attempt during an outage.
- **A failed run leaves nothing on the volume.** The output redirect creates the file before `pg_dump` runs, so a failure that never reaches the verification step — version mismatch, bad credentials, refused connection — can leave an empty file behind. A `trap ... EXIT` owns cleanup on every failure path and is disarmed once verification passes. It is disarmed *before* retention runs, so the dump just taken can never be deleted by it.

<br/>

## Apply

```bash
kubectl apply -f manifests/db-backup-pvc.yaml
kubectl apply -f manifests/db-backup-cronjob.yaml
```

Verify immediately instead of waiting for 04:00:

```bash
kubectl create job --from=cronjob/harbor-db-backup harbor-db-backup-test -n harbor
kubectl logs -n harbor job/harbor-db-backup-test -f
kubectl delete job harbor-db-backup-test -n harbor
```

That manual run also populates `kube_cronjob_status_last_successful_time`, which closes the no-data window on the `HarborDBBackupStale` alert.

<br/>

## Verification

```bash
# CronJob / PVC state
kubectl -n harbor get cronjob harbor-db-backup
kubectl -n harbor get pvc harbor-db-backup

# Recent runs
kubectl -n harbor get jobs -l app.kubernetes.io/name=harbor-db-backup
```

The job prints the dumps on the volume at the end of its log — the log doubles as the inventory a restore starts from.

<br/>

## Restore

> 🔴 Restore with Harbor scaled down. Pushing a `--clean` dump while harbor-core / jobservice are still attached lets reads land mid-drop and leaves the state inconsistent.

```bash
# 1. Scale Harbor down (leave the database up)
kubectl -n harbor scale deploy --replicas=0 \
  harbor-core harbor-jobservice harbor-portal harbor-registry

# 2. Pick the dump to restore
kubectl -n harbor get pvc harbor-db-backup
#    List the files from the backup job log, or on the NAS under harbor/harbor-db-backup/

# 3. Apply the dump (it carries its own DROP/CREATE statements)
kubectl -n harbor exec -i sts/harbor-database -c database -- \
  sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -d registry' \
  < harbor-registry-<YYYYMMDD>.sql

# 4. Scale Harbor back up
kubectl -n harbor scale deploy --replicas=1 \
  harbor-core harbor-jobservice harbor-portal harbor-registry
```

<br/>

### After a restore

- Log in and confirm the project list is back
- Confirm robot accounts still work — pull using each namespace's `harbor-robot-secret`
- Confirm tags resolve to real images (`docker pull`)

Because the blob store is not backed up, **a DB restore alone is not enough if the blob volume was lost too.** In that case the database gives you back the list of tags, and the images themselves have to be refilled by CI rebuild or re-pulled from upstream.

<br/>

## Alerts

Defined in the `backup-alerts` group of `observability/monitoring/kube-prometheus-stack/values/dev-alerts-backup.yaml`.

| Alert | Condition | Severity |
|---|---|---|
| `HarborDBBackupStale` | No successful run in 36 hours | warning |
| `HarborDBBackupMissing` | The CronJob object itself is gone | warning |

Warning rather than the critical the etcd backup alerts carry: losing the Harbor database means a manual rebuild, whereas losing etcd means rebuilding the cluster.
