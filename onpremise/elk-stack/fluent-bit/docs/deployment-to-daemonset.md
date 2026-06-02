# Fluent Bit Deployment → DaemonSet migration record

The fluent-bit topology in `values/dev.yaml` was switched from a single-replica NFS-aggregator Deployment to a per-node stdout DaemonSet on **2026-05-19 10:18 ~ 10:32 KST**. This document captures the background, command sequence, gap measurements, and the operational procedure to reproduce the same migration in prod or any new environment.

> This document is *a record of a one-time migration plus a reproduction procedure*. The current operating topology is documented in the header of `values/dev.yaml`; prod tail-option recommendations live in [prod-tail-config-en.md](./prod-tail-config.md); index recovery in [reingest-procedure-en.md](./reingest-procedure.md).

<br/>

## 1. Why the switch

| Aspect | Before (NFS aggregator) | After (stdout DaemonSet) |
|---|---|---|
| kind | Deployment | DaemonSet |
| replicas | 1 (RWO state PVC lock constraint) | One per worker node (compute-01/02/03 = 3) |
| log source | 4 NFS RWX PVCs (`/volume1/nfs/example-project/{dev,staging,qa}/...`) holding application log files | kubelet-managed `/var/log/containers/*.log` (cri format) on the node |
| state | RWO PVC `fluent-bit-state-pvc` on NFS + `updateStrategy: Recreate` | Node hostPath `/var/lib/fluent-bit/` (one per node) |
| parser | `example-project_json` (direct NDJSON parse) | `cri` → lua strip_ansi → `pino_pretty_extract` → `example-project_json_extract` |
| ingest gap during update | Tens of seconds (Recreate stop-then-start) | ~10 seconds (rolling) |
| Single node failure impact | Aggregator pod dies → ingest fully halts | One node down → other 2 pods keep ingesting |
| Single fail-domain | One NFS server (192.168.1.5) | None (per-node independence) |

Three primary motivations:
1. **Single NFS aggregator → SPOF.** A stuck NFS server or RWX mount halts ingest entirely.
2. **Cloud portability.** RWX NFS volumes are not guaranteed in cloud environments. stdout works the same everywhere.
3. **Collection-loss traceability.** With NFS files, fluent-bit's inotify occasionally missed rotation events; with stdout, kubelet handles file lifecycle deterministically.

<br/>

## 2. PoC parallel-operation period

Before the migration, the PoC release `fluent-bit-stdout` ran in parallel with the NFS aggregator for about 16 hours. Verification results:

| Check | Result |
|---|---|
| docs.count over the same time window | NFS 861 / stdout 882, drift +2.44% |
| Last 50 traceIds from NFS → stdout lookup (with 2m propagation buffer) | 48/50 = 96.0% |
| stdout DaemonSet 3 pods restart | 0 |
| fluentd `skip invalid event` | 0 |

The decision trail for the parallel-run PoC lives in the git log of fluent-bit / stdout DaemonSet commits.

<br/>

## 3. Migration steps (command sequence)

The migration spans two helm releases, so order matters.

```bash
cd observability/logging/fluent-bit

# 0. Backup (start from a clean working tree)
cp values/dev.yaml         values/dev.yaml.pre-stdout-transition
cp values/dev-stdout.yaml  values/dev-stdout.yaml.archive
cp helmfile.yaml           helmfile.yaml.pre-stdout-transition
git status   # should show only the three untracked backups

# 1. Rewrite values/dev.yaml into the 4-INPUT DaemonSet shape:
#    - Expand dev-stdout.yaml's PoC 1-INPUT into 4 (dev game / dev battle / qa game / staging game)
#    - One Tag per INPUT: example-project.stdout.{env}.{component}.*
#    - One DB path per INPUT (tail-dev-game.db, tail-dev-battle.db, tail-qa-game.db, tail-stg-game.db)
#    - Reclaim the hostPath name: /var/lib/fluent-bit-stdout → /var/lib/fluent-bit
#    - Four modify filters set per-component log_source values
#      (dev-example-project-game, dev-example-project-battle, qa-example-project-game, stg-example-project-game)
#    - Keep the 🔥 PINO-PRETTY markers (until the game team turns it off — see pino-pretty-removal-en.md)

# 2. Remove dev-stdout.yaml and drop the fluent-bit-stdout release block from helmfile.yaml
rm values/dev-stdout.yaml

# 3. Validate with lint + diff (require explicit user approval before continuing)
helmfile lint
helmfile -l name=fluent-bit diff

# 4. Step A: uninstall the PoC release — helmfile no longer knows about it, so call helm directly
helm uninstall fluent-bit-stdout -n logging

# 5. Step B: upgrade the main release (Deployment → DaemonSet)
helmfile -l name=fluent-bit apply

# 6. Verify
kubectl -n logging get pods -l app.kubernetes.io/instance=fluent-bit -o wide   # DaemonSet 3/3 Ready
kubectl -n logging get deployment | grep fluent-bit                              # should be empty
kubectl -n logging get pvc | grep -E "fluentbit|fluent-bit"                      # should be empty (helm auto-cleanup)
# Force ingest activity on the 4 indices — application rollout restart is the fastest path
kubectl -n dev-example-project rollout restart deployment dev-example-project-game
kubectl -n dev-example-project rollout restart deployment dev-example-project-battle
kubectl -n qa-example-project  rollout restart deployment qa-example-project-game
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASS" "https://localhost:9200/_cat/indices/dev-example-project-game,dev-example-project-battle,qa-example-project-game,stg-example-project-game?v&h=index,docs.count"

# 7. Remove backups
rm values/dev.yaml.pre-stdout-transition \
   values/dev-stdout.yaml.archive \
   helmfile.yaml.pre-stdout-transition

# 8. Commit
git add helmfile.yaml values/dev.yaml values/dev-stdout.yaml
git commit -m "feat(observability/logging/fluent-bit): migrate to stdout DaemonSet, retire NFS aggregator"
```

<br/>

## 4. Resources helm cleaned up automatically + one manual cleanup

`helmfile -l name=fluent-bit apply` deleted the following resources whose manifests no longer render under the new chart values (effects of `persistentVolumes.enabled: false` and `persistentVolumeClaims.enabled: false`):

- `Deployment/fluent-bit`
- `PVC/dev-example-project-game-app-logs-pvc-fluentbit`
- `PVC/dev-example-project-battle-app-logs-pvc-fluentbit`
- `PVC/qa-example-project-game-app-logs-pvc-fluentbit`
- `PVC/stg-example-project-game-app-logs-pvc-fluentbit`
- `PVC/fluent-bit-state-pvc`
- The 4 explicit-manifest PVs (`*-app-logs-pv-fluentbit`). Their `reclaimPolicy: Retain` did not block deletion — they were chart-managed objects, so helm removed them too. The data on the NFS server (192.168.1.5) itself was preserved (which is what Retain actually guarantees)

**One manual cleanup — the fluent-bit-state-pvc dynamically-provisioned PV**

The state PVC received its PV through the storage class `nfs-client-server1` via *dynamic provisioning* (PV name pattern: `pvc-<uuid>`). That PV is not chart-managed — the NFS subdir provisioner created it — so helm only deleted the PVC. The PV is left dangling in `Released` state. Manual cleanup:

```bash
# Find Released PVs related to fluent-bit
kubectl get pv | grep -iE "Released.*fluent-bit"
# → pvc-<uuid>  ...  Released   logging/fluent-bit-state-pvc  ...

# Delete (the NFS directory itself is Retain-policy and remains on the NFS server)
kubectl delete pv pvc-<uuid>
```

PV cleaned up in this migration: `pvc-c3bca255-fdf5-44be-9230-da3643774535` (NFS path `/data/nfs/logging/fluent-bit-state-pvc`, server 192.168.1.10). Reclaim the NFS-side disk space separately if needed.

So the plan's separate `kubectl delete` step for the NFS aggregator PVC/PVs is **not required** (helm handles them), and only the state-pvc's dangling PV needs one manual cleanup.

> The NFS server (192.168.1.5) still holds the application log files under `/volume1/nfs/example-project/*/server/logs/` — applications keep writing to them. For stdout-vs-NFS verification or for index loss recovery, [reingest-procedure-en.md](./reingest-procedure.md) describes how to replay from the NFS originals.

<br/>

## 5. Gap measurement

Ingest-loss window between `helm uninstall fluent-bit-stdout` (PoC release teardown) and `helmfile -l name=fluent-bit apply` (Deployment → DaemonSet swap):

| Step | Timestamp (2026-05-19 KST) | Note |
|---|---|---|
| Step A executed | 10:25:5x | stdout DaemonSet 3 pods Terminating |
| stdout pods fully terminated | 10:26:1x | ~10s |
| Step B executed | 10:26:17 | NFS Deployment Terminate + DaemonSet rollout |
| DaemonSet 3/3 Ready | 10:26:25 | ~8s |

Total application-stdout loss window: **under ~10s**. Far shorter than the plan's estimate of 30s ~ 2min. Reason: the new DaemonSet pods became Ready quickly thanks to ConfigMap mount + cached image.

> Application output written between the NFS aggregator's last consumed offset and the gap end is *not* permanently lost — those lines still exist in the NFS files and can be re-ingested if needed. But the stdout side starts from EOF (`Read_from_Head false`), so stdout-path lines within the gap cannot be re-collected through stdout.

<br/>

## 6. Verification results

Measured roughly 6 minutes after the swap (DaemonSet started at 2026-05-19 10:26:18 KST / 01:26:18 UTC):

| Index | docs since DaemonSet start | Note |
|---|---|---|
| `dev-example-project-game` | 562 | Single rollout restart produced many traceIds |
| `dev-example-project-battle` | 15 | Almost no natural activity; only framework startup after rollout |
| `qa-example-project-game` | 452 | Single rollout restart |
| `stg-example-project-game` | 1992 | No rollout, but natural activity alone produced ingest — the staging-example-project-game pod was already running |

DaemonSet stability: 3 pods restart=0 / ready=true. fluentd `skip invalid event` counter stayed at 0.

<br/>

## 7. Lessons learned

| Lesson | Detail |
|---|---|
| Validate path globs against the *actual* cluster | The PoC plan had two path typos. The battle pod prefix is `dev-example-project-battle-*` (not `dev-crmlp-example-project-battle-*` — `crmlp` was a random suffix), and the stg game namespace is `staging-example-project` (not `stg-example-project`). Confirm via `kubectl get pods -A` or by inspecting `/var/log/containers/` before authoring the glob |
| Removing a release block from helmfile.yaml *first* makes helmfile destroy unable to find it | Use `helm uninstall` directly, or temporarily restore the release block. In this migration calling helm directly was the cleanest path |
| Rolling beats Recreate on gap duration | Compared with the NFS aggregator's `updateStrategy: Recreate`, the DaemonSet's rolling finishes in 8~10s thanks to ConfigMap mount + image cache |
| hostPath lifecycle matches node lifecycle | On AWS spot termination or scale-in, the hostPath SQLite DB vanishes with the node, but so does the application pod on that node — the new pod on a new node starts fresh traceIds. Loss / duplication is negligible, and the operational shape is simpler than a PVC alternative |

<br/>

## 8. Follow-ups

- [pino-pretty removal guide](./pino-pretty-removal.md) — lines to delete in dev.yaml once the game team turns off pino-pretty in application stdout
  - **2026-05-19 — partial removal applied**: dev.game (Pino raw NDJSON) and dev.battle (Serilog raw JSON) switched to raw. The lua / pino_pretty_extract Match patterns narrowed to `example-project.stdout.qa.game.*`, and example-project_json_extract was split into a raw branch and a pino-pretty branch. When qa.game also switches, follow §3 of the guide for full removal
  - **2026-05-19 — stg.game INPUT removed**: staging-example-project namespace retired. The Coverage in §1 of this document shrank from 4 INPUTs to 3 INPUTs. Restoring staging will require re-adding both the INPUT and the modify filter
  - **2026-05-19 — fluentd Serilog normalization added**: the dev.battle Serilog schema (Level / Timestamp / MessageTemplate) is now normalized in fluentd's `02_filters.conf` Step 2/3. Mapping details: see §4-3 of the pino-pretty removal guide
  - **2026-05-19 — qa.game pino_pretty_extract regex updated**: now also matches NestJS routing-setup lines like `[ts] INFO: CostumesController {/costumes}: {...}`. The regex was changed to `^\[[^\]]+\]\s+\w+:\s+.*?(?<log>\{"[\w-]+":.*\})\s*$`. Backward-compatible with the original request-handling format A, also handles routing-setup format B and nested-data JSON. Plain-text lines (no JSON) are handled by the fluentd fallback. See §1-1 of the pino-pretty removal guide
  - **2026-05-22 — qa.game raw NDJSON switch complete + pino-pretty workaround full removal applied**: qa.game flipped to raw NDJSON. The `[FILTER] lua strip_ansi` + `[FILTER] parser pino_pretty_extract` + `[PARSER] pino_pretty_extract` + `luaScripts.strip_ansi.lua` block + qa.game-only example-project_json_extract branch in `values/dev.yaml` were all removed; the raw branch was consolidated back to a single `Match example-project.stdout.*` + `Key_Name message`. The `fluent-bit-luascripts` ConfigMap + the `luascripts` volumeMount were auto-pruned by helm. See [pino-pretty removal record](./pino-pretty-removal.md) for the details
  - **2026-05-22 — reset-example-project-cohort.sh cleanup + DaemonSet-only operation confirmed**: the legacy "scenario A" macro in the ES index reset script (`--scenario-a` / `--reset-fluent-bit-checkpoint` / `--reset-fluentd-buffer` / `--force-with-fluentd-buffer`) was wired to the Deployment + PVC layout, so it was removed. Only the ES-side flow (transform stop / cohort+raw DELETE / fluent-bit DaemonSet rollout restart / transform start / verify) remains automated. Abnormal cases that need a fluent-bit/fluentd in-flight wipe are now documented as manual recipes in the "Manual cleanup" section of [reset-example-project-cohort-en.md](../../elasticsearch/docs/reset-example-project-cohort.md)
- `fluent-bit-prod-hardening` plan — prod application is a separate plan. The combination of this migration plus AWS node-ephemerality handling goes there
- Grafana fluent-bit dashboard's DaemonSet awareness — the DaemonSet pod labels (`app.kubernetes.io/instance: fluent-bit`) are identical to the previous Deployment, so the dashboard needs no change
