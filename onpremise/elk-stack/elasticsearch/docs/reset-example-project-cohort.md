# ExampleProject raw + cohort index reset guide

Operations doc for [`../scripts/reset-example-project-cohort.sh`](../scripts/reset-example-project-cohort.sh). Used at moments where `userId` restarts from 1 (e.g. the QA DB reset scheduled for 2026-05-20), so the raw / cohort indices are cleared and the cohort transform repopulates from fresh data only.

`--env NAME` accepts any DNS-label-ish prefix — `qa`, `dev`, `stg`, `prd`, etc. The index / transform names resolve to `<NAME>-example-project-game` / `<NAME>-example-project-game-user-cohort`.

<br/>

## What it does

The steps below run in order. Steps 3a and 3b are opt-in.

| Step | Action | Default | Scenario A |
|---|---|---|---|
| 0 | Pre-flight — confirm transform exists, assert fluentd buffer queue is empty | ✓ | ✓ (queue check skipped) |
| 1 | `POST /_transform/<env>-example-project-game-user-cohort/_stop?wait_for_completion=true&force=true` | ✓ | ✓ |
| 2 | `DELETE /<env>-example-project-game-user-cohort` (cohort destination index) | ✓ | ✓ |
| 3 | `DELETE /<env>-example-project-game` (raw index) | ✓ | ✓ |
| **3a** | Wipe fluentd buffer (`StatefulSet/fluentd` scale 0 → cleanup Job → scale 1) | — | ✓ (`--reset-fluentd-buffer`) |
| **3b** | Wipe fluent-bit state (`Deployment/fluent-bit` scale 0 → cleanup Job → scale 1) | — | ✓ (`--reset-fluent-bit-checkpoint`) |
| 4 | `kubectl -n logging rollout restart deployment/fluent-bit` | ✓ | skipped (step 3b already brought a fresh pod up) |
| 5 | Poll `_count > 0` until the raw index has been auto-recreated (default 120s) | ✓ | ✓ |
| 6 | `POST /_transform/<env>-example-project-game-user-cohort/_start` | ✓ | ✓ |
| 7 | `GET /<raw>/_count` + `GET /<cohort>/_search?size=3` plus a manual-verify reminder | ✓ | ✓ |

<br/>

## Usage

```bash
# Show help
./reset-example-project-cohort.sh -h

# === Scenario A — "only post-delete logs" (the default intent for the QA DB reset) ===
# Wipes fluent-bit checkpoint + storage chunks AND the fluentd buffer.
# A few seconds of in-flight data for dev/stg is dropped as a side effect.
./reset-example-project-cohort.sh --env qa --scenario-a

# === Scenario B — plain ES-side reset (default) ===
# Keeps the fluent-bit checkpoint and just rolls fluent-bit. Some pre-delete
# in-flight data may leak into the new raw index.
./reset-example-project-cohort.sh --env qa
#   → Type 'reset qa' to continue:   ← must match exactly

# === Partial automation ===
# Only wipe the fluentd buffer
./reset-example-project-cohort.sh --env qa --reset-fluentd-buffer

# Only wipe the fluent-bit state (incl. storage chunks)
./reset-example-project-cohort.sh --env qa --reset-fluent-bit-checkpoint

# === Other ===
# DEV — non-interactive (CI etc.)
./reset-example-project-cohort.sh --env dev --confirm

# Validate the step sequence without touching ES / kubectl
./reset-example-project-cohort.sh --env qa --dry-run --confirm --scenario-a

# fluent-bit has already been rotated manually
./reset-example-project-cohort.sh --env qa --skip-fluent-bit-restart

# Increase the raw-index repopulation timeout (default 120s)
./reset-example-project-cohort.sh --env qa --wait-data-seconds 300

# Override the fluentd buffer-queue safety check (dangerous — see section below)
./reset-example-project-cohort.sh --env qa --force-with-fluentd-buffer
```

<br/>

## Flags

| Flag | Description |
|---|---|
| `--env NAME` | (required) environment / index prefix. DNS-label form (`^[a-z][a-z0-9-]*$`). Examples: `qa`, `dev`, `stg`, `prd` |
| `--dry-run` | print the planned curl / kubectl calls without executing them |
| `--skip-fluent-bit-restart` | skip step 4's `rollout restart` |
| `--wait-data-seconds N` | step 5 polling timeout (default 120) |
| `--confirm` | skip the interactive prompt (CI use) |
| `--force-with-fluentd-buffer` | proceed even when the step 0 buffer-queue check fails |
| `--reset-fluent-bit-checkpoint` | enable step 3b — wipe env tail SQLite + shared `storage/*` chunks. Implies `--skip-fluent-bit-restart`. |
| `--reset-fluentd-buffer` | enable step 3a — wipe the `elasticsearch-buffers/*` dir on the fluentd PVC. Implies the step 0 buffer-queue check is skipped. |
| `--scenario-a` | macro — enables both flags above plus `--skip-fluent-bit-restart`. Recommended when the intent is "only post-delete logs". |
| `-h`, `--help` | usage |

<br/>

## Env overrides (rarely needed)

```
NAMESPACE_ES=logging       NAMESPACE_FB=logging
ES_POD=elasticsearch-es-default-0    ES_CONTAINER=elasticsearch
ES_SVC=localhost   ES_PORT=9200   ES_SCHEME=https
ES_SECRET=elasticsearch-es-elastic-user   ES_USER=elastic
FB_DEPLOYMENT=fluent-bit        FB_STATE_PVC=fluent-bit-state-pvc
FD_STATEFULSET=fluentd          FD_POD=fluentd-0
CLEANUP_IMAGE=busybox:1.36
```

<br/>

## Interaction with fluent-bit and fluentd

`reset-example-project-cohort.sh` only touches the ES side, but the real pipeline is **NFS log files → fluent-bit → fluentd → ES**. If the operational intent is "**only logs that arrive after the delete moment should land in the new raw index**", both fluent-bit and fluentd need to be considered too — otherwise pre-delete data bleeds back into the fresh raw index.

<br/>

### fluent-bit tail SQLite checkpoint — reset it for the "post-delete only" scenario

Each fluent-bit `tail` input records the last read position as `(inode, offset)` in a SQLite DB. Per `observability/logging/fluent-bit/values/dev.yaml`:

```
DB /fluent-bit/state/tail-dev-game.db
DB /fluent-bit/state/tail-dev-battle.db
DB /fluent-bit/state/tail-stg-game.db
DB /fluent-bit/state/tail-qa-game.db
```

These DBs live on `fluent-bit-state-pvc` (ReadWriteOnce, 5Gi, nfs-client-server1) and survive pod restarts / `rollout restart`.

#### Scenarios

| Scenario | Checkpoint handling | Outcome |
|---|---|---|
| **A. "Only post-delete logs"** (the default intent for the QA DB reset) | **Reset** the checkpoint. With `Read_from_Head false` + an empty SQLite, the new pod starts polling from the current EOF. | Old data that fluent-bit had already read does not land in the new raw index. |
| B. "Best-effort retention of pre-delete logs" (ES-side reset only) | Keep it. The new pod resumes from the last offset. | Whatever fluent-bit had read but ES hadn't yet ingested gets re-forwarded into the new raw index. |

The default operation (QA DB reset on 2026-05-20) is **A**, so the **checkpoint must be wiped**. This script automates that as step 3b via `--reset-fluent-bit-checkpoint` or `--scenario-a`; the "manual procedure" below is the same thing done by hand, for debugging or off-script use.

<br/>

#### Manual reset procedure (Scenario A — equivalent to `--reset-fluent-bit-checkpoint`)

The WAL-mode sidecar files (`*-shm`, `*-wal`) must be removed too for a clean wipe. The PVC is RWO and SQLite holds a lock while open, so bring fluent-bit down first, mount the PVC from a cleanup Job to delete the files, then bring fluent-bit back up.

```bash
ENV=qa   # or dev

# 1. Take fluent-bit down (RWO PVC unmounts only after the pod is gone)
kubectl -n logging scale deployment/fluent-bit --replicas=0
kubectl -n logging wait pod -l app.kubernetes.io/name=fluent-bit \
  --for=delete --timeout=60s

# 2. Cleanup Job — remove the tail DB (and optionally the storage chunks)
kubectl -n logging apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: fluent-bit-state-cleanup-${ENV}
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: cleanup
          image: busybox:1.36
          command: ["sh", "-c", "rm -fv /state/tail-${ENV}-game.db* && rm -rf /state/storage/*"]
          volumeMounts:
            - name: state
              mountPath: /state
      volumes:
        - name: state
          persistentVolumeClaim:
            claimName: fluent-bit-state-pvc
EOF
kubectl -n logging wait job/fluent-bit-state-cleanup-${ENV} \
  --for=condition=complete --timeout=60s
kubectl -n logging delete job/fluent-bit-state-cleanup-${ENV}

# 3. Bring fluent-bit back up
kubectl -n logging scale deployment/fluent-bit --replicas=1
kubectl -n logging rollout status deployment/fluent-bit --timeout=120s
```

> **Warning**: deleting `storage/*` discards fluent-bit's filesystem chunks — input-side buffer that has not yet been forwarded to fluentd. This matches scenario A's intent but permanently drops that data; do it deliberately.

<br/>

### fluentd buffer — this is the real footgun

The ES output in `observability/logging/fluentd/values/dev.yaml` is wired as:

```
<buffer tag,log_source>
  @type file
  path /var/log/fluent/elasticsearch-buffers
  total_limit_size 4GB
  queue_limit_length 128
  retry_type exponential_backoff
  retry_forever true
  overflow_action block
  flush_at_shutdown true
</buffer>
```

`persistence.enabled: true`

- If ES has been slow and chunks are sitting in the buffer when the raw index is deleted, those chunks will be re-flushed into the new raw index — **old docs re-ingested**.
- `retry_forever true` keeps the retry queue alive indefinitely. A plain `rollout restart` is no remedy: `flush_at_shutdown true` forces a flush on shutdown.

Step 0 of the script reads `fluentd_output_status_buffer_queue_length{type="elasticsearch"}` directly from the fluentd pod's `:24231/metrics` endpoint and aborts unless it's 0. Two overrides: (a) `--force-with-fluentd-buffer` — accept the risk that the buffer leaks into the new index, (b) `--reset-fluentd-buffer` — wipe the buffer outright (scenario A option).

<br/>

#### When the buffer is non-empty

Pick one (or just use `--reset-fluentd-buffer` to wipe it):

1. **Wait for natural drain after ES recovery** — wait for `fluentd_output_status_buffer_queue_length` (or `_total_bytes`) to hit 0.
2. **Explicit drain + restart** —
   ```bash
   kubectl -n logging scale deployment/fluentd --replicas=0   # flush_at_shutdown=true → one final flush attempt
   # Wait for the flush to finish on the ES side → delete the raw index → restart fluentd
   kubectl -n logging scale deployment/fluentd --replicas=1
   ```
   Note: this still races old chunks into the new raw index.
3. **Discard the buffer then restart** (only when losing old data is acceptable) —
   ```bash
   kubectl -n logging scale deployment/fluentd --replicas=0
   # cleanup pod → mount PVC → rm -rf /var/log/fluent/elasticsearch-buffers/* → exit
   kubectl -n logging scale deployment/fluentd --replicas=1
   ```
   For a "drop old data on purpose" operation like the QA reset, (3) is the cleanest — this is exactly what `--reset-fluentd-buffer` automates.

<br/>

## Related documentation

- [scripts/README-en.md](../scripts/README-en.md) — directory index.
- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../transforms/README-en.md](../transforms/README-en.md) — cohort transform definitions and the `apply.sh` / `export.sh` guide.
