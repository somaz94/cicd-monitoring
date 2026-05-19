# Fluent Bit Index Re-ingest Procedure

Operational procedure to re-ingest game logs from NFS into Elasticsearch after losing an index.

<br/>

## Background: DB ≠ ES asynchrony

With the Phase 1a configuration applied in [values/dev.yaml](../values/dev.yaml), fluent-bit persists per-INPUT tail offsets to SQLite databases. However:

```
DB (Fluent Bit "how far it has read")   ≠   ES Index (what was actually indexed)
```

- DB only tracks how far each file has been **read**
- ES indexing reflects what was successfully **forwarded** through fluentd → ES
- The two are not synchronized

So when an ES index is lost (intentionally or accidentally — disk failure, mistaken `DELETE /example-project-*`, ILM misconfiguration, ECK reset, etc.):
- DB is intact → Fluent Bit thinks "already shipped"
- No automatic re-ingest → **manual procedure required**

<br/>

## When this procedure applies

- Intentional ES index deletion (mistaken `DELETE` calls etc.)
- Partial index loss after ES disk failure
- ILM/retention policy misconfigured, deleting indices earlier than intended
- Re-populating historical data after Kibana index pattern restructure
- ECK Elasticsearch cluster reset / rebuild

If ES snapshots are available, prefer them. This procedure is a fallback when snapshots are absent or when only certain fluent-bit INPUT data needs replaying.

<br/>

## Pre-flight checks

```bash
# Fluent Bit state / candidate INPUTs
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit
kubectl get pvc -n logging fluent-bit-state-pvc

# Confirm target logs still exist on NFS (must be fresher than Ignore_Older 7d)
# Path mapping: see persistentVolumes block in values/dev.yaml
```

With `Ignore_Older 7d` (current setting) only the last 7 days are re-ingestable. Older data is ignored even if NFS files survive. Temporarily widen `Ignore_Older` (commit + helmfile apply) before re-ingest if longer windows are needed, then restore to `7d`.

<br/>

## Full re-ingest (all INPUTs)

> dev cluster, logging namespace.

```bash
# 1. Stop Fluent Bit
kubectl scale deployment fluent-bit -n logging --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=fluent-bit -n logging --timeout=60s

# 2. Delete .db files on the state PVC (filesystem chunk buffer is preserved)
#    The fluent-bit image is distroless; mount the PVC with a busybox helper pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fb-state-cleaner
  namespace: logging
spec:
  restartPolicy: Never
  containers:
    - name: cleaner
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /state/ && echo '--- before' && rm -fv /state/tail-*.db /state/tail-*.db-wal /state/tail-*.db-shm && echo '--- after' && ls -la /state/"]
      volumeMounts:
        - name: state
          mountPath: /state
  volumes:
    - name: state
      persistentVolumeClaim:
        claimName: fluent-bit-state-pvc
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/fb-state-cleaner -n logging --timeout=60s
kubectl logs -n logging fb-state-cleaner
kubectl delete pod -n logging fb-state-cleaner

# 3. (optional) To re-ingest beyond 7 days, temporarily widen Ignore_Older in values/dev.yaml,
#    commit + helmfile apply, then restore to 7d after stabilization.
#    In Phase 1a (Read_from_Head false) Ignore_Older alone is not enough —
#    switch Read_from_Head to true at the same time so the new file scan reads from head.
#    → Once Phase 1b is in effect, widening Ignore_Older alone is sufficient.

# 4. Restart Fluent Bit
kubectl scale deployment fluent-bit -n logging --replicas=1
kubectl rollout status deployment/fluent-bit -n logging

# 5. Monitor re-ingest
kubectl logs -n logging deployment/fluent-bit --follow
# Watch target index doc count in Kibana
```

<br/>

## Partial re-ingest (single INPUT)

Lost only one environment's index (e.g. qa-game)? Delete that INPUT's DB only; other INPUTs are unaffected.

```bash
# Same procedure; replace the cleaner rm command with:
#   rm -fv /state/tail-qa-game.db /state/tail-qa-game.db-wal /state/tail-qa-game.db-shm
```

Pick any of: dev-game / dev-battle / stg-game / qa-game. DB filenames match the `DB` option of each INPUT in [values/dev.yaml](../values/dev.yaml).

<br/>

## Phase 1a vs Phase 1b behavior

| Phase | After DB deletion + fluent-bit restart | Outcome |
|---|---|---|
| **Phase 1a** (current, `Read_from_Head false`) | Empty DB; active files treated as new files → start from EOF | **No re-ingest happens**. Historical NFS data is not pushed to ES |
| **Phase 1b** (`Read_from_Head true`) | Empty DB → all files read from head → full re-ingest | **Everything within the `Ignore_Older` window is re-indexed** |

→ **Meaningful re-ingest requires Phase 1b**. If re-ingest is needed while still on Phase 1a, choose one of:

1. Temporarily set `Read_from_Head true` in values/dev.yaml + helmfile apply + delete DB + restart + restore to `false` after stabilization (workaround if a permanent Phase 1b switch is too risky right now)
2. Permanently transition to Phase 1b, then run this procedure

<br/>

## Constraints

- Data outside the `Ignore_Older 7d` window is skipped even if NFS files exist. To align with the 90-day NFS retention policy, widen `Ignore_Older` (e.g. `90d`) in values.
- Deleting the DB drops all per-file offsets for that INPUT — in Phase 1b that re-ingests every file from head. Fine-grained replay (specific files only) is not possible with fluent-bit alone.
- Re-ingest causes ES indexing load spikes → run during off-peak hours with prior notice.
- fluentd-0 buffer saturation is absorbed by fluent-bit retry / disk buffer, but fluentd-0 throughput itself can be the bottleneck (single replica).

<br/>

## Verification

```bash
# 1. After cleaner runs, confirm .db files are gone in its output
# 2. After fluent-bit restart, confirm DB + storage filesystem in startup logs:
#    [storage] created root path /fluent-bit/state/storage/
#    [input:tail:tail.N] storage_strategy='filesystem' (memory + filesystem)
#    [input:tail:tail.N] db: delete unmonitored stale inodes from the database: count=0
# 3. Watch target index doc count grow (Kibana / curl)
curl -sk -u "$ES_USER:$ES_PASS" "https://es.example.com/qa-example-project-game-*/_count" | jq .
# 4. After completion, sanity-check NFS line count vs ES doc count (rough agreement)
```

<br/>

## Stronger defenses (out of scope, separate plan)

This procedure is a fallback after ES index loss. A comprehensive backup strategy lives elsewhere:

- **ES snapshot repository (S3/NFS) + Snapshot Lifecycle Management (SLM)** — point-in-time index recovery. Faster and more accurate than this procedure, no 7-day window constraint.
- **NFS game-log retention** — keep ≥ 90 days (align with `Ignore_Older`).
- **Kibana saved object backup** — protect dashboards / index patterns.

<br/>

## References

- Applied values: [../values/dev.yaml](../values/dev.yaml)
- Phase 1a background: [prod-tail-config-en.md](./prod-tail-config-en.md)
- Fluent Bit tail DB official docs: https://docs.fluentbit.io/manual/pipeline/inputs/tail#db
