# ExampleProject raw + cohort index reset guide

Operations doc for [`../scripts/reset-example-project-cohort.sh`](../scripts/reset-example-project-cohort.sh). Used at moments where `userId` restarts from 1 (or jumps to a new sequence) — e.g. a QA DB reset — so the raw / cohort indices are cleared and the cohort transform repopulates from fresh data only.

`--env NAME` accepts any DNS-label-ish prefix — `qa`, `dev`, `stg`, `prod`, etc. The index / transform names resolve to `<NAME>-example-project-game` / `<NAME>-example-project-game-user-cohort`.

> **Scope (2026-05-22 cleanup)** — the script only automates the **ES-side reset** (transform stop

<br/>

## What it does

| Step | Action |
|---|---|
| 0 | Pre-flight — confirm transform exists |
| 1 | `POST /_transform/<env>-example-project-game-user-cohort/_stop?wait_for_completion=true&force=true` |
| 2 | `DELETE /<env>-example-project-game-user-cohort` (cohort destination index) |
| 2a | `PUT /<env>-example-project-game-user-cohort` with the explicit mapping from `../transforms/<env>-example-project-game-user-cohort.mapping.json` — pinning `active_dates` as `keyword` so the dashboard retention runtime fields (`d1_live..d30_live`) keep working. Skipped (with a warning) when the mapping file is absent — falling back to ES dynamic mapping would infer `active_dates` as `date` and silently zero every retention metric. |
| 3 | `DELETE /<env>-example-project-game` (raw index) |
| 4 | `kubectl -n logging rollout restart daemonset/fluent-bit` + `rollout status` (skip with `--skip-fluent-bit-restart`) |
| 5 | Poll `_count > 0` until the raw index has been auto-recreated (default 10s). On timeout, PUT an empty raw index as a placeholder — step 6/7's transform reset/start require the source to exist. fluent-bit populates it via dynamic mapping when the first doc arrives. |
| 6 | `POST /_transform/<env>-example-project-game-user-cohort/_reset` — clear the in-memory checkpoint + stats. Without this the next start would try to resume from the previous `time_upper_bound` and never backfill the empty dest index. |
| 7 | `POST /_transform/<env>-example-project-game-user-cohort/_start` |
| 8 | `GET /<raw>/_count` + `GET /<cohort>/_search?size=3` plus a manual-verify reminder |

The step 2a explicit-mapping PUT is the key piece (added 2026-05-27) — the old flow let ES dynamic mapping create the cohort index at transform-start time, and `active_dates` (ISO date strings like `"2026-05-22"`) was inferred as `date`. The cohort data view runtime fields `d1_live..d30_live` then compared `String == ZonedDateTime` and emitted 0 for every horizon. The dashboard rendered normally but every curve sat on the X axis — it took 5 days to notice (2026-05-22 QA cohort incident). See [transforms/README-en.md → "Dest-index mapping"](../transforms/README.md#dest-index-mapping----idmappingjson).

The step 4 rollout restart is the next key piece — when fluent-bit's new pod reopens the hostPath SQLite checkpoint, if the file it points to has become stale (the QA pod restarted or the log rotated, so the inode changed) it falls back to EOF-polling on the new file. That means the new raw index sees post-reset data only without explicitly wiping the checkpoint — unless the fluentd buffer holds old chunks, in which case verification's `min_ts` catches it.

The step 5 polling is a sanity check that fluent-bit's chain is forwarding new traffic after the rollout. In an idle environment (off-hours, lunch break, no traffic) the timeout is the expected outcome — the script then PUTs an empty raw index so step 6/7's transform reset/start clear ES's source-existence check (`validation_exception: no such index`) and the transform starts in idle polling mode until fluent-bit's first doc lands.

The step 6 `_reset` — if you skip it (bare `_start`) the transform's in-memory checkpoint stays alive and only attempts incremental forward from the old `time_upper_bound`, so the new cohort index never receives the backfill and retention appears "stuck at empty". We tripped this once during the 2026-05-27 QA fix.

<br/>

## Execution

Both paths produce the same result (ES-side reset + fluent-bit rollout). The difference is depth of automation.

| Path | When |
|---|---|
| **Manual procedure** ([Option A](#option-a--manual-procedure) below) | Run each command yourself when watching progress step by step. Useful for learning or debugging. |
| **Script automation** ([Option B](#option-b--script-automation) below) | Repetitive ops / automation. fluent-bit rollout restart + raw repopulation polling + verify all in one go. |

<br/>

### Option A — Manual procedure

```bash
# [0] Export the Elasticsearch password (~15 min validity)
export PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

# [1] Stop the transform (wait_for_completion=true blocks until stop completes)
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -X POST \
  "https://localhost:9200/_transform/qa-example-project-game-user-cohort/_stop?wait_for_completion=true&force=true"

# [2] DELETE the cohort destination index
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -X DELETE \
  "https://localhost:9200/qa-example-project-game-user-cohort"

# [2a] PUT the cohort destination index with explicit mapping — active_dates must be keyword
#      so the dashboard retention runtime fields keep working.
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -H 'Content-Type: application/json' -X PUT \
  "https://localhost:9200/qa-example-project-game-user-cohort" \
  --data-binary @- < ../transforms/qa-example-project-game-user-cohort.mapping.json

# [3] DELETE the raw index
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -X DELETE \
  "https://localhost:9200/qa-example-project-game"

# [4] (optional) Roll the fluent-bit DaemonSet — the new pod reopens the hostPath
#     checkpoint and falls back to EOF-polling on the rotated log file.
#     Skip when the source pod has just been restarted itself.
kubectl -n logging rollout restart daemonset/fluent-bit
kubectl -n logging rollout status daemonset/fluent-bit --timeout=180s

# [5] Reset the transform — clear in-memory checkpoint + stats so the next
#     _start reprocesses the source index from scratch.
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -X POST \
  "https://localhost:9200/_transform/qa-example-project-game-user-cohort/_reset"

# [6] Start the transform — the raw index is auto-recreated when fluent-bit
#     forwards the next new doc.
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -X POST \
  "https://localhost:9200/_transform/qa-example-project-game-user-cohort/_start"
```

<br/>

### Option B — Script automation

```bash
cd observability/logging/elasticsearch/scripts

# Help
./reset-example-project-cohort.sh -h

# Default — typed-word prompt 'reset qa' required to proceed
./reset-example-project-cohort.sh --env qa

# Options
./reset-example-project-cohort.sh --env dev --yes                # skip prompt (CI / automation)
./reset-example-project-cohort.sh --env qa --dry-run --yes       # print steps without touching cluster
./reset-example-project-cohort.sh --env qa --skip-fluent-bit-restart # fluent-bit already rotated manually
./reset-example-project-cohort.sh --env qa --wait-data-seconds 60    # raw repopulation polling timeout (default 10)
```

<br/>

### Verification (Manual

```bash
# 1. New UUIDs + raw docs.count > 0
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" "https://localhost:9200/_cat/indices/qa-example-project-game*?v"

# 2. Raw min/max timestamp + userId — min_ts post-reset is the desired signal
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -H 'Content-Type: application/json' \
  "https://localhost:9200/qa-example-project-game/_search?pretty" -d '{
    "size":0,
    "aggs":{"min_ts":{"min":{"field":"@timestamp"}},"max_ts":{"max":{"field":"@timestamp"}},
            "min_uid":{"min":{"field":"data.userId"}},"max_uid":{"max":{"field":"data.userId"}}}
  }'

# 3. Cohort first_seen — all post-reset. hits=0 is fine until /users/create traffic happens.
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" -H 'Content-Type: application/json' \
  "https://localhost:9200/qa-example-project-game-user-cohort/_search?pretty" -d '{
    "size":5,"sort":[{"first_seen":"asc"}],"_source":["user_id","first_seen"]
  }'

# 4. Visual check in Kibana (DAU/NU/WAU/MAU appear immediately; Retention Curve needs signup traffic)
# http://kibana.example.com/app/dashboards#/view/qa-pm-retention-dashboard
```

If old data leaks into the new raw index (`min_ts` in step 2 is pre-reset), the fluentd buffer was non-empty at the reset moment — see [Manual cleanup](#manual-cleanup--fluent-bit--fluentd-state) below.

<br/>

## Flags

| Flag | Description |
|---|---|
| `--env NAME` | (required) environment / index prefix. DNS-label form (`^[a-z][a-z0-9-]*$`). Examples: `qa`, `dev`, `stg`, `prod` |
| `--dry-run` | print the planned curl / kubectl calls without executing them |
| `--skip-fluent-bit-restart` | skip step 4's `rollout restart` |
| `--wait-data-seconds N` | step 5 polling timeout (default 10). Reaching the timeout is not fatal — warns and proceeds to step 6 (transform auto-picks up the raw index when docs arrive). |
| `--yes` | skip the interactive prompt (CI use) |
| `-h`, `--help` | usage |

<br/>

## Env overrides (rarely needed)

```
NAMESPACE_ES=logging       NAMESPACE_FB=logging
ES_POD=elasticsearch-es-default-0    ES_CONTAINER=elasticsearch
ES_SVC=localhost   ES_PORT=9200   ES_SCHEME=https
ES_SECRET=elasticsearch-es-elastic-user   ES_USER=elastic
FB_DAEMONSET=fluent-bit
```

`FB_DAEMONSET` is just the DaemonSet name. Layouts other than DaemonSet (e.g. legacy Deployment) are no longer supported — single DaemonSet + hostPath as of the 2026-05-19 migration.

<br/>

## Manual cleanup — fluent-bit / fluentd state

The script's ES-side reset alone is sufficient 99% of the time (the 2026-05-22 QA index reset went through this path). Additional cleanup is only needed in these abnormal cases:

- fluentd has chunks queued in its buffer because ES forwarding stalled — after the raw index is deleted, those chunks re-flush into the new index and bring old docs back.
- fluent-bit DaemonSet's hostPath SQLite checkpoint still points at the inode of a *valid* log file that holds significant old data (rare — pod restart / log rotation usually invalidates the checkpoint naturally).

Automation is intentionally omitted — fluent-bit DaemonSet (hostPath) and fluentd StatefulSet (RWO PVC) layouts shift with `helmfile.yaml` changes, so any automated cleanup would go stale again. Use the manual recipes below.

<br/>

### fluentd buffer wipe (StatefulSet + PVC, affects all envs)

`observability/logging/fluentd/values/dev.yaml` configures the ES output as:

```
<buffer tag,log_source>
  @type file
  path /var/log/fluent/elasticsearch-buffers
  total_limit_size 4GB
  retry_forever true
  flush_at_shutdown true
</buffer>
```

`persistence.enabled: true`

> **Warning**: this wipe discards every env's buffered chunks at once — typically 0 to a few seconds of in-flight data per env when fluentd is healthy. For an env-scoped wipe, dig into the `elasticsearch-buffers/` filenames (chunks are tagged) or wait for the buffer to drain naturally.

```bash
# 1. Bring fluentd down (flush_at_shutdown=true forces one final flush — drop the raw index BEFORE this so the flush hits the new index)
kubectl -n logging scale statefulset/fluentd --replicas=0
kubectl -n logging wait pod fluentd-0 --for=delete --timeout=120s

# 2. Cleanup Job — mount the PVC + wipe the buffer directory
kubectl -n logging apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: fluentd-buffer-cleanup
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: cleanup
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'rm -rfv /buffers/elasticsearch-buffers/* 2>/dev/null; rm -rfv /buffers/elasticsearch-buffers/.??* 2>/dev/null; ls -la /buffers/elasticsearch-buffers/ 2>/dev/null || true'
          volumeMounts:
            - { name: target, mountPath: /buffers }
      volumes:
        - name: target
          persistentVolumeClaim:
            claimName: fluentd-buffer-fluentd-0
EOF
kubectl -n logging wait job/fluentd-buffer-cleanup --for=condition=complete --timeout=120s
kubectl -n logging logs job/fluentd-buffer-cleanup --tail=20
kubectl -n logging delete job/fluentd-buffer-cleanup

# 3. Bring fluentd back
kubectl -n logging scale statefulset/fluentd --replicas=1
kubectl -n logging rollout status statefulset/fluentd --timeout=180s
```

<br/>

### fluent-bit hostPath wipe (DaemonSet + per-node, affects all envs)

The fluent-bit DaemonSet's SQLite checkpoint and storage chunks live on each node's hostPath `/var/lib/fluent-bit/`. Since it's per-node hostPath (not a PVC) a single cleanup Job can only touch one node — you need a privileged DaemonSet pattern.

> **Warning**: this wipe discards every env's tail checkpoint + storage chunks at once (all envs share `/var/lib/fluent-bit/`). For an env-scoped wipe, target only the per-env files (`rm -f /var/lib/fluent-bit/tail-<env>-game.db*`) — the `storage/` chunks are shared and cannot be split cleanly.

```bash
# 1. Cleanup DaemonSet — privileged hostPath mount + wipe + sleep (DaemonSet ensures every node runs it)
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit-hostpath-cleanup
  namespace: logging
spec:
  selector:
    matchLabels: { app: fluent-bit-hostpath-cleanup }
  template:
    metadata:
      labels: { app: fluent-bit-hostpath-cleanup }
    spec:
      hostNetwork: false
      tolerations:
        - operator: Exists
      containers:
        - name: cleanup
          image: busybox:1.36
          securityContext: { privileged: true, runAsUser: 0 }
          command:
            - sh
            - -c
            - 'rm -rfv /host-state/storage/* /host-state/tail-*.db* 2>/dev/null; ls -la /host-state/ 2>/dev/null || true; sleep 3600'
          volumeMounts:
            - { name: state, mountPath: /host-state }
      volumes:
        - name: state
          hostPath: { path: /var/lib/fluent-bit, type: DirectoryOrCreate }
EOF

# 2. Confirm a pod landed on every node + inspect output
kubectl -n logging get pod -l app=fluent-bit-hostpath-cleanup -o wide
kubectl -n logging logs -l app=fluent-bit-hostpath-cleanup --tail=20 --prefix

# 3. Once cleanup is done, delete the DaemonSet (it sleeps 3600s so explicit delete is required)
kubectl -n logging delete daemonset/fluent-bit-hostpath-cleanup

# 4. Roll fluent-bit so the now-empty state starts fresh from EOF
kubectl -n logging rollout restart daemonset/fluent-bit
kubectl -n logging rollout status daemonset/fluent-bit --timeout=180s
```

<br/>

## Related documentation

- [scripts/README-en.md](../scripts/README.md) — directory index.
- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../transforms/README-en.md](../transforms/README.md) — cohort transform definitions and the `apply.sh` / `export.sh` guide.
- [`../../fluent-bit/docs/deployment-to-daemonset-en.md`](../../fluent-bit/docs/deployment-to-daemonset.md) — 2026-05-19 fluent-bit Deployment → DaemonSet migration trail.
