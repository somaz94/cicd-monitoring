# es-index-retention

CronJob that deletes over-retention documents from the on-prem log indices daily.

<br/>

## Overview

On-prem log indices are **fixed-name and ever-growing**. fluentd writes `index_name ${log_source}` with no date suffix (`observability/logging/fluentd/values/dev.yaml`), so these indices — one per environment and component — accumulate documents indefinitely.

The AWS cluster (`../../elasticsearch-aws/`) uses date-based daily indices (`prod-example-app-game-2026.06.18`), so it can trim them with an **ILM `delete` phase that drops the whole index** (`../../elasticsearch-aws/scripts/bootstrap-ilm-template.sh`). On-prem cannot use a whole-index ILM delete: the index stays alive and keeps growing, so deleting it whole would drop current logs too. Retention is therefore done with **document-level `_delete_by_query` on `@timestamp`**.

This CronJob is the **in-cluster automation counterpart** of the laptop-oriented manual script [`../scripts/delete_old_indices.sh`](../scripts/delete_old_indices.sh). The manual script stays for ad-hoc runs from a developer machine (via port-forward); this CronJob owns the daily scheduled trim.

> 🔴 **The `must_not` clause must be kept in both queries.** The delete query is "old documents **minus** the cohort anchor", and the anchors are the `data.requestPath.keyword: "/users/create"` documents. The cohort transform computes `first_seen` from a scripted_metric over them, so deleting even one re-triggers the continuous transform, which recomputes `first_seen` as null and **irrecoverably** corrupts that cohort record. With the guard on only one side, the sentence above — that the two do the same thing — becomes false: the manual script was in fact missing it until 2026-08-10.

<br/>

## Files

The CronJob definition is a single file: `manifests/cronjob.yaml`.

<br/>

## How it works

1. **Scheduling**: `spec.schedule` + `spec.timeZone` in `manifests/cronjob.yaml` are authoritative. The schedule is offset from the cluster-maintenance CronJobs (e.g. etcd-defrag) to avoid overlap — read that CronJob's own `spec.schedule` for its window.
2. **Connection**: in-cluster, so no port-forward. curls the same-namespace ES service `https://elasticsearch-es-http:9200` directly (ECK self-signed cert → `-k`).
3. **Auth**: the `elastic` key of secret `elasticsearch-es-elastic-user`, injected as an env `secretKeyRef`.
4. **Cutoff**: ES date-math `now-${RETENTION_DAYS}d`, computed server-side — no client-side date math (avoids busybox `date` lacking relative-date support).
5. **Targets**: iterates only the **explicit allow-list** in the `INDICES` env. `conflicts=proceed` keeps a live-writing index from aborting the batch on version conflicts.

<br/>

## Target indices (allow-list) — important

Only the indices **named in the `INDICES` env** are processed. Because it is an explicit list and not a glob, anything below is never touched.

| Class | Index | Action |
|---|---|---|
| raw logs (trimmed) | **every** index listed in `INDICES` in `manifests/cronjob.yaml` | delete docs older than the retention window (`RETENTION_DAYS` in `manifests/cronjob.yaml`) — except `/users/create` docs, see below |
| **cohort (excluded)** | every index ending in `*-user-cohort` | **never touched** |
| **system (excluded)** | `.ds-*`, `.internal.*` | **never touched** |

> ⚠️ **Excluding the cohort index is necessary but NOT sufficient.** The cohort transform's `first_seen` is anchored to the **`/users/create` event inside the raw `-game` index** (`scripted_metric` in `../transforms/dev-example-project-game-user-cohort.json` — returns `null` when no such doc exists). If a still-active user's `/users/create` doc ages past the retention window and is deleted from the raw index, the continuous transform re-triggers and recomputes `first_seen` as `null`, silently corrupting the cohort record.
>
> The delete query therefore carries a **`must_not { data.requestPath.keyword: /users/create }`** guard so the registration anchor is kept forever (one doc per registration = negligible volume). Same intent as AWS's [`bootstrap-cohort-template.sh`](../../elasticsearch-aws/scripts/bootstrap-cohort-template.sh) exempting cohort from ILM delete.
>
> **Forbidden: adding `*-user-cohort` to `INDICES`, and removing the `/users/create` must_not guard from the delete query.**

<br/>

## Configuration

Adjust via the env in `manifests/cronjob.yaml`.

| env | default | description |
|---|---|---|
| `RETENTION_DAYS` | the env value in `manifests/cronjob.yaml` is authoritative | Retention in days. Deletes docs older than `now-<N>d`. |
| `INDICES` | see `manifests/cronjob.yaml` (SSOT) | Space-separated target indices. Add a new environment here. Never add cohort/system indices. |
| `ES_HOST` | see `manifests/cronjob.yaml` (SSOT) | in-namespace ES service endpoint. |

Lowering the retention makes already-over-threshold docs eligible for deletion on the next run (intended behavior).

<br/>

## Apply

```bash
# Always confirm the context is onprem-dev first
kubectl config current-context

kubectl apply -f manifests/cronjob.yaml
```

Test immediately without waiting for the next scheduled run:

```bash
kubectl create job --from=cronjob/es-index-retention es-index-retention-manual-$(date +%s) -n logging
kubectl logs -n logging job/es-index-retention-manual-<timestamp> -f
```

<br/>

## Verification

On success, a `_delete_by_query` response prints per index.

```
Index retention: deleting docs older than now-<RETENTION_DAYS>d
Targets: <whatever INDICES lists>            # the run echoes the live list

=== <index> ===
{"took":..,"timed_out":false,"total":0,"deleted":0,"version_conflicts":0,"failures":[]}

Retention run complete.
```

The `=== <index> ===` block above repeats once per index listed in `INDICES`.

> With less data than the retention window (`RETENTION_DAYS`), `deleted:0` is normal (nothing to delete). Once data crosses that window, `deleted` starts to grow.

To reclaim disk immediately after deletion, run a force merge (manual, heavy):

```bash
../scripts/delete_old_indices.sh -f dev-example-project-battle   # delete docs + only_expunge_deletes force merge
```

<br/>

## Troubleshooting

### `ELASTIC_PASSWORD is empty`

The secret `elasticsearch-es-elastic-user` is missing in the `logging` namespace, or lacks the `elastic` key. Check with `kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}'`.

<br/>

### `deleted` larger than expected

`RETENTION_DAYS` may have been set too low by mistake. Deletion is irreversible — confirm a backup exists before changing it. Unlike AWS, this on-prem cluster has no standing SLM snapshot, so take an ad-hoc snapshot first via the [Elastic snapshot/restore guide](https://www.elastic.co/guide/en/elasticsearch/reference/current/snapshot-restore.html) if needed.

<br/>

### Cohort data disappeared (`first_seen` is null)

Check two things: (1) did `*-user-cohort` leak into `INDICES`, and (2) was the `must_not { /users/create }` guard removed from the delete query. Either one wipes the registration anchor from the raw index and corrupts the cohort. For the transform `_reset` + reprocess recovery, see [`../scripts/reset-example-project-cohort.sh`](../scripts/reset-example-project-cohort.sh) — but if the raw `/users/create` docs are already deleted, `first_seen` cannot be restored.

<br/>

## Related docs

- [`../scripts/delete_old_indices.sh`](../scripts/delete_old_indices.sh) — manual ad-hoc cleanup script (the laptop counterpart of this CronJob).
- [`../../elasticsearch-aws/scripts/bootstrap-ilm-template.sh`](../../elasticsearch-aws/scripts/bootstrap-ilm-template.sh) — AWS-side ILM-based automated retention (date-based indices, whole-index delete).
- [`../transforms/README-en.md`](../transforms/README.md) — cohort transform definition (why it is excluded).
