# ArgoCD Ghost Alarm Incident Analysis (2026-04-23)

<br/>

## Summary

Between 06:33 and 06:54 KST on 2026-04-23, a burst of "restarted" / "deploy success" notifications hit the `#argocd-alarm` Slack channel for five `example-project`-family Applications. On investigation:

- **dev-example-project-game
- **qa-example-project-game

Three root causes stacked. The **essential one is a design flaw in the notification rules (Cause C)**; A and B are environmental triggers that let the flaw surface.

1. **(Environmental) `argocd-application-controller` reconcile gap**: Some apps had their `reconciledAt` frozen from 2026-04-21 21:11 UTC, others from 2026-04-22 08:54 UTC — **12 to 24 hours of no reconciliation**, all of them released at once on 04-22 21:33 UTC (04-23 06:33 KST).
2. **(Environmental) dedup key reshuffle from a notifications config change**: `mgmt-notifications.yaml` was upgraded on 2026-04-22 15:27 KST, changing the `oncePer` dedup key formula for every trigger. Existing "already sent" annotations no longer matched the new keys — **previously-sent events became eligible for redelivery**.
3. **(Essential) Design flaw in the `on-restarted`

<br/>

## Incident Timeline

All times show UTC and KST. CI commit times are based on the commit date in the `server/argocd-applicationset` GitLab repo.

| UTC | KST | Event |
|---|---|---|
| 2026-04-21 08:32 | 2026-04-21 17:32 | **commit `678c8b4`** (`somaz`) — `argo-cd` helm chart `9.5.1 → 9.5.2` upgrade. Backup folder `backup/20260421_173002/` created. `upgrade.sh` applied to the cluster at the same time. |
| 2026-04-21 21:11 | 2026-04-22 06:11 | `reconciledAt` of `dev1-secondary-project-admin`, `qa-example-project-app-admin`, `staging-example-project-admin`, `qa-example-project-admin` froze here (no further update for 24+ hours). |
| 2026-04-22 03:03 | 2026-04-22 12:03 | **commit `996e330`** (`somaz`) — `fix: argocd notifiactions rules`. Added `oncePer` dedup keys and buffer conditions to every trigger in `mgmt-notifications.yaml`. |
| 2026-04-22 06:27 (approx) | 2026-04-22 15:27 | Rerun of `upgrade.sh` applied the above change to the `argocd-notifications-cm` in the cluster (based on file mtime). |
| 2026-04-22 08:34 | 2026-04-22 17:34 | `dev-example-project-game` last healthy sync (rev `412cd4c6`). |
| 2026-04-22 08:54 | 2026-04-22 17:54 | `dev-example-project-game` sync `18f0cb44` finished → **12 h 39 min reconcile gap begins**. |
| 2026-04-22 08:54 – 10:18 | 2026-04-22 17:54 – 19:18 | `cicd@example.com` bot pushed 5 commits including the `b4482c5f` tag (game/admin/app-admin) — ArgoCD failed to detect them. |
| 2026-04-22 21:33:10–12 | 2026-04-23 06:33:10–12 | `staging-example-project-game`, `qa-example-project-game`, `dev-example-project-game`, etc. all resumed reconciliation simultaneously — "comparison expired" appeared in the log. |
| 2026-04-22 21:33:12–13 | 2026-04-23 06:33:12–13 | `dev-example-project-game` actually synced (image `e277267a → b4482c5f`); `on-restarted` + `on-deployed` fired. |
| 2026-04-22 21:53:53 | 2026-04-23 06:53:53 | `dev-example-project-game` `reconciledAt` refreshed again → transient Progressing during rolling update + new dedup key → **"restarted" / "deploy success" fired a second time for the same 20-min-old deployment**. |
| 2026-04-22 21:53:58–59 | 2026-04-23 06:53:58–59 | `dev-example-project-admin` sync ran (image `e277267a → b4482c5f`); normal alarms. |
| 2026-04-23 00:19 (approx) | 2026-04-23 09:19 | `argocd-notifications-controller` restarted (inferred from pod AGE 22h). |

<br/>

## Per-symptom Analysis

<br/>

### 1. dev-example-project-game

**Evidence:**

```bash
kubectl get rs -n dev-example-project --sort-by='.metadata.creationTimestamp'
# dev-example-project-game-866cf5dc78 (replicas=0, image e277267a, age 16h)   ← previous
# dev-example-project-game-b9665c884  (replicas=2, image b4482c5f, age 3h30m) ← new deploy
```

The image tag actually changed from `e277267a → b4482c5f`. The commits were pushed automatically from the CI pipeline by the `cicd` bot (`391d7125`, `f6bfad25` in `argocd-applicationset`), with commit dates 2026-04-22 10:16–18 UTC (KST 19:16–19:18).

**Evidence of the delay (from `argocd-application-controller` logs):**

```
2026-04-22T21:33:12Z  Refreshing app status (comparison expired, requesting refresh.
                       reconciledAt: 2026-04-22 08:54:20 UTC, expiry: 10m0s), level (2)
                       application=dev-example-project-game
```

- With the configured `timeout.reconciliation: 600s` (10 min), detection should have happened within 10 minutes.
- In reality `reconciledAt` was stuck at 08:54:20 UTC for 12 h 39 min.
- Reconciliation finally resumed at 21:33:12 UTC when the controller noticed the comparison had expired.

**Why a second "restarted" fired at 06:53 after the 06:33 deploy:**

During the Deployment rolling update, pods were rotated sequentially and health stayed `Progressing` for ~20 minutes. In that window, the 10-minute reconcile cycle refreshed `reconciledAt` from `21:33:12Z` to `21:53:53Z`, and because `on-restarted` used `oncePer: app.status.reconciledAt`, **a second "restarted" alarm fired for the same operation**.

Similarly, `on-deployed`'s `oncePer: app.status.summary.images.join(',')` saw `old + new` images during the rollout and then just `new` afterward — so the key value changed, and **a second "deploy success" fired for the same operation**.

<br/>

### 2. qa-example-project-game

**Evidence:**

```bash
kubectl get pods -n qa-example-project
# qa-example-project-game-69797797d5-542lh  1/1  Running  0  8d
# qa-example-project-game-69797797d5-zfbmq  1/1  Running  0  8d

kubectl get pods -n staging-example-project
# staging-example-project-game-7bc47bf4fd-z75g7  1/1  Running  7 (15d ago)  15d
```

Pod AGE 8–15 days, RESTARTS 0 (or last restart 15 days ago). **Nothing touched these pods in the early morning.**

**ArgoCD Application `operationState`:**

```yaml
qa-example-project-game:
  operationState.startedAt:  2026-04-17T06:57:55Z   # 6 days ago
  operationState.finishedAt: 2026-04-17T06:57:55Z   # 6 days ago
  reconciledAt:              2026-04-22T21:33:12Z   # ← this morning
  notif-annotation: "2026-04-22T21:33:12Z:on-restarted:..."

staging-example-project-game:
  operationState.startedAt:  2026-04-17T06:39:47Z
  operationState.finishedAt: 2026-04-17T06:39:47Z
  reconciledAt:              2026-04-22T21:33:10Z
```

- `operationState` is **unchanged since 04-17** — no actual sync operation.
- Only `reconciledAt` advanced to 21:33 UTC (the controller cleared its backlog and reconciled every app at once).
- Because `on-restarted`'s dedup key is `reconciledAt`, the new value triggered re-evaluation. At that instant, ArgoCD's cached health momentarily read as `Progressing` (or a state reset after config reload), and the alarm fired.

Because the alarm template renders the "restart time" field with `{{.app.status.operationState.startedAt}}`, the raw `2026-04-17T06:57:55Z` (6 days old!) appeared in the Slack message, which was confusing by itself. The `(UTC+9=KST)` label made the timezone interpretation worse.

<br/>

### 3. Cluster-wide reconcile gap

```
reconciledAt            app                          op.finishedAt           op.phase
2026-04-21T21:11:03Z    dev1-secondary-project-admin             2026-04-17T07:18:19Z    Succeeded
2026-04-21T21:11:03Z    qa-example-project-app-admin        2026-04-17T07:00:11Z    Succeeded
2026-04-21T21:11:03Z    staging-example-project-admin       2026-04-17T06:41:31Z    Succeeded
2026-04-21T21:11:09Z    qa-example-project-admin            2026-04-17T06:58:57Z    Succeeded
2026-04-22T08:40:59Z    dev-example-project-app-admin       2026-04-22T08:40:59Z    Succeeded
2026-04-22T21:33:10Z    staging-example-project-game        2026-04-17T06:39:47Z    Succeeded
2026-04-22T21:33:12Z    qa-example-project-game             2026-04-17T06:57:55Z    Succeeded
2026-04-22T21:53:53Z    dev-example-project-game            2026-04-22T21:33:13Z    Succeeded
2026-04-22T21:53:54Z    dev-example-project-battle          2026-04-17T07:18:19Z    Succeeded
2026-04-22T21:53:59Z    dev-example-project-admin           2026-04-22T21:53:59Z    Succeeded
```

- **Four apps** were stuck at `2026-04-21T21:11Z` and did not recover (24+ hours stuck at the time of investigation).
- **Other apps** got stuck around `2026-04-22T08:54Z` and recovered at `21:33–21:53Z`.
- In other words: **the controller collectively skipped reconciliation of many apps at once.**

<br/>

## Root Cause Analysis

<br/>

### Cause A — anomaly in the application-controller reconcile queue

Observed facts:
- `argocd-application-controller-0` pod AGE = 40 h at the time of writing (no restart).
- `timeout.reconciliation: 600s` is correctly set (confirmed in `argocd-cm`).
- No `git` / `repo` / `webhook` error or warning in the log.
- Yet `reconciledAt` for several apps did not update for 12–24 hours.

Hypotheses (unconfirmed):
- **Controller work-queue rate-limiter** or **sharding replica mismatch** may have dropped app keys that never got re-enqueued.
- **Chart upgrade on 04-21 17:30 KST (v9.5.1 → v9.5.2, appVersion v3.3.6 → v3.3.7)** might have caused the controller to omit some apps while rebuilding its internal indexes.
- The "comparison expired" at 04-22 21:33 UTC recognized the stuck state and force-refreshed, but it is unclear why it took 12 hours.

Further verification points:
- `argocd_app_reconcile` metric histogram trend (via Grafana).
- `argocd-application-controller` `ARGOCD_CONTROLLER_REPLICAS` / sharding settings.
- Redis pod availability (possibly a cache invalidation issue).

<br/>

### Cause C (essential) — design flaw in the `on-restarted` / `on-deployed` dedup keys

ArgoCD notifications' `oncePer` rule is "send at most once per unique key value". That is: **when the key changes, it sends again.** So the key has to be an **event identifier**. Instead, the current config uses a **state snapshot**.

<br/>

#### Problem with `on-restarted`

```yaml
trigger.on-restarted:
  when: |
    app.status.health.status == 'Progressing' and
    (app.status.operationState == nil or
     (app.status.operationState.phase in ['Succeeded','Failed','Error'] and
      time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() > 3))
  oncePer: app.status.reconciledAt   # ← state snapshot
```

- `reconciledAt` is not a pod-restart event; it updates on **ArgoCD's periodic polling (every 10 min).**
- If a single pod crash keeps health at `Progressing` for 20 minutes, two or three reconcile ticks happen and each produces a **new `reconciledAt` = new dedup key = new alarm.**
- The qa/staging ghost alarms fell out of the same mechanic. There was no real restart, but at the moment the 12-hour reconcile gap cleared, `reconciledAt` advanced, the notifications-controller transiently evaluated health as `Progressing`, and the trigger fired.
- The reason dev-example-project-game got a second "restarted" at 06:53 is exactly the same: the rolling update took 20 minutes and `reconciledAt` advanced from `21:33:12Z` to `21:53:53Z` during that time.

**Correct design:**

```yaml
oncePer: app.status.operationState.finishedAt
# Equivalent intent: one sync operation = one alarm
```
- Fires once per sync operation.
- Pure pod crashes unrelated to a sync may not be captured by this key, so a separate `on-pod-restart` trigger — or using ArgoCD's `resource.health` events — is more precise for that purpose.

<br/>

#### Problem with `on-deployed`

```yaml
trigger.on-deployed:
  when: |
    app.status.operationState.phase == 'Succeeded' and
    app.status.health.status == 'Healthy' and
    app.status.operationState != null
  oncePer: app.status.summary.images.join(',')   # ← state snapshot
```

- During a rolling update, `summary.images` contains both `old + new` images.
- After the rollout, `old` drops and only `new` remains.
- The key changes from `[old,new]` → `[new]` for the same sync, so **"deploy success" fires twice.**
- This is exactly what produced the two "deploy success" alarms at 06:33 and 06:53 for dev-example-project-game.

**Correct design:**

```yaml
oncePer: app.status.operationState.finishedAt  # 1 sync → 1 alarm
# or
oncePer: app.status.sync.revision              # 1 git revision → 1 alarm
```

<br/>

#### Core principle

> **`oncePer` keys must carry a "unique event identifier", not a "state snapshot". If you use a state snapshot, the key changes as state naturally evolves, producing duplicates and false positives.**

In ArgoCD, the unique identifier of "a sync operation" is `operationState.finishedAt`, and the identifier of "a git-revision deploy" is `sync.revision`. The current triggers use neither.

<br/>

### Cause B — dedup key reshuffle from the notifications config change

The trigger block in `values/mgmt-notifications.yaml` was updated on 04-22 15:27 KST (confirmed by diffing against `backup/20260421_173002/mgmt-notifications.yaml`):

| Trigger | Before | After |
|---|---|---|
| `on-deployed` | `oncePer: app.status.summary.images[0]` | `oncePer: app.status.summary.images.join(',')` |
| `on-restarted` | `Progressing`, no dedup | + 3-min post-sync buffer, `oncePer: app.status.reconciledAt` |
| `on-health-degraded` | `Degraded`, no dedup | + 3-min post-sync buffer, `oncePer: app.status.reconciledAt` |
| `on-sync-failed` | no dedup | `oncePer: app.status.operationState.finishedAt` |
| `on-sync-status-out-of-sync` | no dedup | `oncePer: app.status.sync.revision` |
| `on-health-missing` / `on-health-unknown` | no dedup | `oncePer: app.status.reconciledAt` |

Effect:
- The dedup hash saved in each app's `metadata.annotations.notified.notifications.argoproj.io` was computed with the **old key formula**.
- With the new formula, none of the existing annotations match, so the notifications-controller treats every event as "never sent".
- Hence, the moment Cause A released the reconcile backlog at 21:33 UTC (all `reconciledAt` values updated), every app that satisfied a trigger condition was eligible to send under a new dedup key.

<br/>

### Combined outcome of Cause A + Cause B + Cause C

| App | A (stuck duration) | B (new dedup key) | Final result |
|---|---|---|---|
| dev-example-project-game | 12 h 39 min stuck | applied | Real deploy + on-restarted alarm (06:33) → 20 min later, rolling-update refresh of reconciledAt redelivers (06:53) |
| dev-example-project-admin | same | applied | Real deploy + normal alarm (06:54) |
| qa-example-project-game | stuck | applied | No real change, but on-restarted + on-deployed fired as ghost alarms (06:33) |
| staging-example-project-game | stuck | applied | Same ghost-alarm pattern (06:33) |
| qa/staging-example-project-admin etc. | still stuck (24 h) | — | Not yet released (reconcileAt unchanged) |

<br/>

## Changes made right before the incident (operator commits)

Git log under `cicd/argo-cd/` in `kuberntes-infra` (newest first):

| Commit | Time (KST) | Author | Summary |
|---|---|---|---|
| `996e330` | 2026-04-22 12:03 | `somaz` | `fix: argocd notifiactions rules` — added `oncePer` dedup + post-sync buffers to every trigger |
| `678c8b4` | 2026-04-21 17:32 | `somaz` | `feat: upgrade argocd 9.5.1 -> 9.5.2` (appVersion v3.3.6 → v3.3.7) |
| `8b89f73` | 2026-04-16 18:49 | `somaz` | `refactor(cicd/argo-cd): split mgmt.yaml into core/server/redis/notifications value files` |

Changes relevant to this incident:
- `996e330` — **the commit that introduced Cause B (dedup key reshuffle)**. The intent in adding `oncePer` was to suppress duplicate alarms; choosing `reconciledAt`
- `678c8b4` — the chart upgrade, whose timing overlaps with Cause A (the controller collectively skipping some apps). There is no direct evidence that the upgrade caused the stuck state (controller pod AGE 40h with no restarts), but the correlation is worth recording.
- `8b89f73` — unrelated to this incident (values file split refactor).

<br/>

## Prevention / Improvement Proposals

<br/>

### Short-term actions

1. **Manually refresh the stuck apps.** `qa-example-project-app-admin`, `staging-example-project-admin`, `qa-example-project-admin`, `dev1-secondary-project-admin` are still stuck at `04-21T21:11Z`; a manual refresh is required.
   ```bash
   argocd app get <APP_NAME> --refresh
   # or
   kubectl annotate app -n argocd <APP_NAME> argocd.argoproj.io/refresh=hard --overwrite
   ```

2. **Consider restarting application-controller.** If the cause is internal controller state, a restart is the fastest recovery. Since a restart may trigger a large sync wave, prefer off-hours.
   ```bash
   kubectl rollout restart statefulset/argocd-application-controller -n argocd
   ```

<br/>

### Mid-term actions

3. **Establish a procedure for dedup annotation handling on notifications config changes.** When the `oncePer` formula changes, either wipe every Application's `notified.notifications.argoproj.io` annotation up front or document "one-time redelivery expected" in the release note.

4. **Change trigger `oncePer` keys to "event identifiers" (top priority).** Detailed proposal appears in the "Recommended changes" section below. As Cause C described, the current snapshot-style keys make duplicates structurally unavoidable.

5. **Improve the "restart time" / "deploy time" display in the alarm template.**
   - Current: `{{.app.status.operationState.startedAt}} (UTC+9=KST)`, but the raw value is UTC (`Z` suffix). The label misleads readers.
   - Fix options:
     - Convert to KST inside the Go template: `{{ (call .time.Parse .app.status.operationState.startedAt).In (call .time.LoadLocation "Asia/Seoul") }}`
     - Or change the label to `restart time (UTC)`.

<br/>

### Long-term actions

6. **Strengthen controller monitoring.**
   - Add `argocd_app_reconcile` histogram, `reconciledAt` age distribution, and work-queue depth panels to Grafana.
   - Add an Alertmanager rule for "Application `reconciledAt` older than 30 minutes" (early stuck detection).

7. **Automate a smoke test after `upgrade.sh`.** Right after running `upgrade.sh`, run a minimal check:
   - Every Application's `reconciledAt` is within the last 10 minutes.
   - No ERROR in `argocd-application-controller` logs.
   - `argocd-notifications-controller` pod health.

<br/>

## Recommended changes (values/mgmt-notifications.yaml)

Principle: **use a "unique event identifier" in `oncePer`.**

- "1 sync = 1 alarm" → `app.status.operationState.finishedAt`
- "1 git revision = 1 alarm" → `app.status.sync.revision`
- `reconciledAt` changes every polling cycle, so it must **never** be used as a dedup key.

<br/>

### Priority fixes

<br/>

#### (1) `trigger.on-deployed` — stop duplicate firings during rolling update

```yaml
# Before (current)
trigger.on-deployed: |
  - description: Application is synced and healthy after any operation.
    send:
    - app-deployed
    when: |
      app.status.operationState.phase == 'Succeeded' and
      app.status.health.status == 'Healthy' and
      app.status.operationState != null
    oncePer: app.status.summary.images.join(',')     # ← state snapshot

# After (recommended)
trigger.on-deployed: |
  - description: Application is synced and healthy after any operation.
    send:
    - app-deployed
    when: |
      app.status.operationState.phase == 'Succeeded' and
      app.status.health.status == 'Healthy' and
      app.status.operationState != null
    oncePer: app.status.operationState.finishedAt    # ← 1 sync = 1 alarm
```

Effect:
- Even when `summary.images` flips from `[old,new]` → `[new]` mid-rollout, `finishedAt` stays the same → single send.
- A Helm value-only change (no image tag change) still fires correctly once the sync succeeds.

Alternative: `oncePer: app.status.sync.revision` — group by git commit; same revision resynced multiple times still fires once.

<br/>

#### (2) `trigger.on-restarted` — stop redelivery on every polling tick

```yaml
# Before (current)
trigger.on-restarted: |
  - description: Application has been restarted (not due to sync)
    send:
    - app-restarted
    when: |
      app.status.health.status == 'Progressing' and
      (app.status.operationState == nil or
       (app.status.operationState.phase in ['Succeeded', 'Failed', 'Error'] and
        app.status.operationState.finishedAt != nil and
        time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() > 3))
    oncePer: app.status.reconciledAt                 # ← changes every poll

# After (recommended)
trigger.on-restarted: |
  - description: Application has been restarted (not due to sync)
    send:
    - app-restarted
    when: |
      app.status.health.status == 'Progressing' and
      (app.status.operationState == nil or
       (app.status.operationState.phase in ['Succeeded', 'Failed', 'Error'] and
        app.status.operationState.finishedAt != nil and
        time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() > 3))
    oncePer: app.status.operationState.finishedAt    # ← once per operation
```

Effect:
- All Progressing transitions after a given sync fire at most once.
- Structurally blocks the qa/staging ghost alarm path (where `reconciledAt` alone advanced after the reconcile-gap release).

Caveat — the original intent was to detect **sync-independent** crashes/drains. Switching the dedup to `finishedAt` means multiple crashes after the same sync are coalesced into a single alarm, which reduces detection resolution.
- If per-pod-crash alarms are required, do that at the Kubernetes layer via an Alertmanager rule (e.g. increases in `kube_pod_container_status_restarts_total`).
- ArgoCD notifications is at its best at the "application level" — per-pod crashes belong to Prometheus.

<br/>

#### (3) `trigger.on-health-degraded` — same principle

```yaml
# Before
oncePer: app.status.reconciledAt

# After
oncePer: app.status.operationState.finishedAt
```

<br/>

### Items to leave as-is

| Trigger | Current `oncePer` | Decision | Rationale |
|---|---|---|---|
| `on-sync-failed` | `operationState.finishedAt` | **keep** | Already an event identifier. One alarm per failed sync is correct. |
| `on-sync-status-out-of-sync` | `sync.revision` | **keep** | Dedups per git revision — appropriate. |
| `on-health-missing` | `reconciledAt` | keep (can revisit) | "Missing" can persist long; per-poll redelivery may actually be desired. Revisit based on operator feedback. |
| `on-health-unknown` | `reconciledAt` | keep (can revisit) | Same as above. |

<br/>

### Apply procedure

```bash
# 1) Edit and commit
cd ~/gitlab-project/kuberntes-infra
vi cicd/argo-cd/values/mgmt-notifications.yaml
git diff cicd/argo-cd/values/mgmt-notifications.yaml
git add cicd/argo-cd/values/mgmt-notifications.yaml
git commit -m "fix(cicd/argo-cd): use finishedAt as oncePer key to prevent duplicate notifications"

# 2) Apply to the cluster (requires operator approval)
cd cicd/argo-cd
./upgrade.sh           # helmfile apply

# 3) Verify
kubectl get cm argocd-notifications-cm -n argocd \
  -o jsonpath='{.data.trigger\.on-deployed}' | grep oncePer

# 4) (Optional) Clean up lingering dedup annotations if an older state still blocks
kubectl get app -n argocd -o name | while read a; do
  kubectl annotate $a notified.notifications.argoproj.io- -n argocd
done
```

<br/>

## Final architecture

After reviewing two choices (A / B), we picked **Option B** as the most practical for the current environment. The configuration is staged so that Option A can be enabled later by uncommenting a few blocks.

<br/>

### Side-by-side comparison

| Dimension | **Option B (chosen)** | Option A (future option) |
|---|---|---|
| ArgoCD notifications (`#argocd-alarm`) | Handles sync events and **health state (Degraded/Missing/Unknown)** | Handles sync events only |
| Alertmanager (`#infra-alerts`) | **Just `ArgoCDControllerReconcileStuck`** (detect controller silence) | Controller silence + per-app state (Degraded/Missing/OutOfSync) |
| Recovery alarm (back to Healthy) | None (no `send_resolved`) | Automatic RESOLVED via Alertmanager |
| Silencing | Not possible | Available from the Alertmanager UI |
| Inhibit rule | None | Controller-stuck can suppress downstream |
| Operational complexity | Low (existing flow preserved) | Medium (operators must learn the split) |

<br/>

### Rationale for Option B

1. **Measured firing rate is zero.** As of 2026-04-23 there are no Degraded apps and `on-health-degraded` fired 0 times in the last 22 hours. Option A's biggest wins (auto-RESOLVED, silencing) will rarely apply.
2. **The key lesson of this incident is a single `ReconcileStuck` alert.** Cause A (12 h controller gap) cannot be detected by notifications at all (the controller is silent when stuck, and so is the notifications-controller). Only Alertmanager can catch it, and a single alert covers the case.
3. **Minimal change footprint.** Operators keep watching `#argocd-alarm` as before — no new channel split, no confusion.
4. **Expandable.** If Degraded starts occurring often, Option A is a few uncommented lines away.

<br/>

### Configuration summary (Option B)

| Component | File | Content |
|---|---|---|
| ArgoCD notifications | `cicd/argo-cd/values/mgmt-notifications.yaml` | Subscription enables 7 triggers (4 sync + 3 health). Comments describe how to switch to Option A. |
| PrometheusRule | `observability/monitoring/kube-prometheus-stack/values/mgmt-alerts.yaml` | `argocd-alerts` group has **only `ArgoCDControllerReconcileStuck` active**; `ArgoCDAppDegraded/Missing/OutOfSync` are commented. |
| Alertmanager | `observability/monitoring/kube-prometheus-stack/values/mgmt-alertmanager.yaml` | ArgoCD inhibit_rule commented (a single alert does not need inhibit; uncomment when enabling Option A). |

<br/>

### Option B → Option A switch procedure

Uncomment the "Option A" blocks in three files.

1. **`cicd/argo-cd/values/mgmt-notifications.yaml`** — comment out the three subscriptions:
    ```yaml
    # - on-health-degraded   # A: comment out when moving to Alertmanager
    # - on-health-missing
    # - on-health-unknown
    ```
2. **`observability/monitoring/kube-prometheus-stack/values/mgmt-alerts.yaml`** — uncomment the three alerts under the `# --- Option A rules (disabled by default) ---` block in the `argocd-alerts` group.
3. **`observability/monitoring/kube-prometheus-stack/values/mgmt-alertmanager.yaml`** — uncomment the ArgoCD inhibit_rule.
4. Apply:
    ```bash
    cd ~/gitlab-project/kuberntes-infra/cicd/argo-cd && helmfile apply
    kubectl rollout restart deployment/argocd-notifications-controller -n argocd

    cd ~/gitlab-project/kuberntes-infra/observability/monitoring/kube-prometheus-stack && helmfile apply
    kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
    ```

Typical reasons to switch:
- Degraded persistence becomes common enough that `send_resolved` (recovery alarm) is actually useful.
- Silencing during maintenance becomes necessary.
- ArgoCD notifications hits another `oncePer`-style issue.

<br/>

### Significance of `ArgoCDControllerReconcileStuck` handled by Alertmanager

Even in Option B, **this alert must live in Alertmanager.** Reasons:
- When the controller itself stalls, the notifications-controller is highly likely to go silent too (exactly what happened on 2026-04-23).
- Prometheus scrapes on an independent cadence, so even if ArgoCD stalls, Alertmanager can still detect **"reconcile counter not increasing"**.
- Normal reconcile interval is 3–10 minutes. No increase for 30 minutes is a clear anomaly.

This alert is **required under both Option A and B**, and is the core recurrence-prevention mechanism produced by this incident.

<br/>

### Prerequisite — metric collection check

The following metrics must be scraped by Prometheus for either Option B or A to work. Verified on 2026-04-23:

```promql
argocd_app_info{name, project, sync_status, health_status, dest_namespace, ...}
argocd_app_reconcile_count   # histogram (use increase() to measure reconcile attempts)
```

Collection path:
- ArgoCD helm values (`metrics.serviceMonitor.enabled: true`) → produces 3 ServiceMonitors (`argocd-application-controller`, `argocd-server`, `argocd-repo-server` in the `monitoring` namespace).
- Prometheus discovers ServiceMonitors labeled `release: kube-prometheus-stack` → scrape is automatically enabled (interval 30s).

Verification command on recurrence:

```bash
PROM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job=~".*argocd.*"}'
# 3 targets with up=1 → healthy
```

<br/>

## Second-round improvements — follow-up from re-reading the alarm text

The first-round change (`oncePer` key swap) alone does not fully resolve the structural issue. After re-reading the 2026-04-23 alarm payloads, we identified **five additional improvement points.**

<br/>

### Improvement A — fix the time-label error in the Slack template

**Problem:** every template renders the timestamp fields like this:

```yaml
"value": "{{.app.status.operationState.startedAt}} (UTC+9=KST)"
```

However the actual value of `operationState.startedAt` is `2026-04-22T21:33:12Z` — **UTC** (the `Z` suffix). The `(UTC+9=KST)` label tricks readers into thinking the value itself has been converted to KST. This very confusion produced the false premise "17:54 KST was the last deploy" during the 2026-04-23 investigation.

**Fix (choose one):**

```yaml
# Option 1: fix the label only (simple, immediately applicable)
"value": "{{.app.status.operationState.startedAt}} (UTC)"

# Option 2: convert to KST via Go template
"value": "{{ (call .time.Parse .app.status.operationState.startedAt).In (call .time.LoadLocation \"Asia/Seoul\") }}"
```

Option 1 is safe and clear. Option 2 requires checking whether those template functions are available in ArgoCD notifications.

<br/>

### Improvement B — widen the `on-restarted` buffer from 3 min to 10 min

**Problem:** the current condition flags "restarted" if the status remains `Progressing` beyond **3 minutes** after `operationState.finishedAt`. In practice `dev-example-project-game`'s rolling update took **~20 minutes** (`21:33:13Z → 21:53:53Z`). A 3-minute buffer cannot distinguish a normal rolling update from a real crash.

**Fix:**

```yaml
trigger.on-restarted: |
  - description: Application has been restarted (not due to sync)
    when: |
      app.status.health.status == 'Progressing' and
      (app.status.operationState == nil or
       (app.status.operationState.phase in ['Succeeded', 'Failed', 'Error'] and
        app.status.operationState.finishedAt != nil and
        time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() > 10))   # ← 3 → 10
```

Trade-off: detection of a sync-independent pod crash is delayed by 10 minutes. Since `on-restarted` is specifically meant to catch "restarts unrelated to sync", the delay is acceptable. Real-time crash detection should lean on Alertmanager's `kube_pod_container_status_restarts_total` rule.

<br/>

### Improvement C — add a stale-operation guard (structural block on ghost alarms)

**Problem:** when Cause A (the controller reconcile gap) releases, the trigger evaluator runs while `finishedAt` is days old. The qa/staging ghost alarms are exactly this scenario: `operationState` still reads `2026-04-17`, yet `reconciledAt` freshly advances to this morning — and `on-restarted` fires.

**Fix:** add a "recent sync" guard to the trigger.

```yaml
trigger.on-restarted: |
  when: |
    app.status.health.status == 'Progressing' and
    app.status.operationState != nil and
    app.status.operationState.finishedAt != nil and
    time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() > 10 and
    time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Hours() < 1   # ← only syncs within the last 1 h

trigger.on-deployed: |
  when: |
    app.status.operationState.phase == 'Succeeded' and
    app.status.health.status == 'Healthy' and
    app.status.operationState != null and
    time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Hours() < 1   # ← same guard
```

With this guard, **"an alarm suddenly arriving today for an operation that happened days ago"** is blocked at the root. The qa/staging ghost alarms of 2026-04-23 fall exactly into this class.

<br/>

### Improvement D — show image tag / git revision in the alarm

**Problem:** the current "deploy success" / "restarted" alarms do not state **which version was deployed**. Readers naturally ask "which deploy is this?".

**Fix:** add two fields to `template.app-deployed`:

```json
{
  "title": "Image",
  "value": "{{ range $i, $img := .app.status.summary.images }}{{ if $i }}, {{ end }}{{ $img }}{{ end }}",
  "short": false
},
{
  "title": "Git Revision",
  "value": "{{.app.status.sync.revision | truncate 8}}",
  "short": true
}
```

(Verify that the Go template `truncate` function is available. If not, use `{{ slice .app.status.sync.revision 0 8 }}`.)

<br/>

### Improvement E — introduce an `on-health-recovered` trigger

**Problem:** when an app recovers from Degraded to Healthy, nothing is sent. Operators reading Slack cannot tell whether the problem still persists.

**Fix (new addition):**

```yaml
trigger.on-health-recovered: |
  - description: Application health recovered from Degraded/Missing/Unknown to Healthy
    send:
    - app-health-recovered
    when: |
      app.status.health.status == 'Healthy' and
      app.status.operationState != nil and
      app.status.operationState.finishedAt != nil and
      time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Hours() < 1
    oncePer: app.status.operationState.finishedAt
```

**template (new):**

```yaml
template.app-health-recovered: |
  message: |
    :large_green_circle: Application {{.app.metadata.name}} has recovered to Healthy.
  slack:
    attachments: |
      [{
        "title": "{{ .app.metadata.name}} - Recovered",
        "color": "#18be52",
        "fields": [
          { "title": "Sync status", "value": "{{.app.status.sync.status}}", "short": true },
          { "title": "Health status", "value": "{{.app.status.health.status}}", "short": true },
          { "title": "Namespace", "value": "{{.app.spec.destination.namespace}}", "short": true },
          { "title": "Recovery time", "value": "{{.app.status.operationState.finishedAt}} (UTC)", "short": true }
        ]
      }]
```

Do not forget to add `on-health-recovered` to `subscriptions`.

**Limitation:** ArgoCD notifications cannot trigger directly on "state transitions". The trigger above fires whenever "current = Healthy + recent sync" — meaning it does **not** distinguish "recovered after Degraded" from "always healthy" (it also fires on the latter). A sidecar controller that stores previous health in an annotation would be required to separate them; for simplicity this limitation is acceptable.

<br/>

### Second-round priority

| Order | Item | Difficulty | Effect |
|---|---|---|---|
| 1 | Improvement A (label fix) | Low | Removes user confusion immediately |
| 2 | Improvement C (stale-operation guard) | Low | Structurally blocks ghost alarms |
| 3 | Improvement B (buffer 3 → 10 min) | Low | Fully resolves the dev-example-project-game duplicate |
| 4 | Improvement D (image / revision display) | Medium | Operational convenience |
| 5 | Improvement E (recovery alarm) | Medium | Reflects operator request |

<br/>

## Evidence-collection commands

The commands used during this analysis, for reuse.

```bash
# 1) reconciledAt / operationState of every app
kubectl get applications -n argocd -o json | jq -r '
  .items[] | [.status.reconciledAt, .metadata.name,
               .status.operationState.finishedAt,
               .status.operationState.phase] | @tsv' | sort

# 2) notification dedup annotation of a specific app
kubectl get application <APP_NAME> -n argocd \
  -o jsonpath='{.metadata.annotations.notified\.notifications\.argoproj\.io}' | jq .

# 3) Filter "comparison expired" entries in the application-controller log
kubectl logs -n argocd argocd-application-controller-0 --since=24h | \
  grep -i "comparison expired"

# 4) Trigger-evaluation log in notifications-controller
kubectl logs -n argocd deployment/argocd-notifications-controller --since=24h | \
  grep -E "TRIGGERED|FAILED" | grep <APP_NAME>

# 5) Confirm the actual redeploy via ReplicaSet history
kubectl get rs -n <NAMESPACE> --sort-by='.metadata.creationTimestamp'

# 6) Compare the current config against the backup
cd ~/gitlab-project/kuberntes-infra/cicd/argo-cd
diff -u backup/<BACKUP_DIR>/mgmt-notifications.yaml values/mgmt-notifications.yaml
```

<br/>

## Post-incident follow-up — 2026-04-23 11:11 KST recurrence and trigger identification

While we were **applying the first- and second-round improvements on the very same day**, the newly added `ArgoCDControllerReconcileStuck` alert fired critical. The alert **correctly caught a real stall the moment it happened**, and the investigation pinned down the **trigger mechanism** of Cause A (the controller reconcile gap).

<br/>

### Timeline

| Time (KST) | Event |
|---|---|
| ~11:11 | `cicd/argo-cd/` helmfile apply (applying the `oncePer` key change) |
| ~11:11 | `observability/monitoring/kube-prometheus-stack/` helmfile apply (adding the argocd-alerts rule) |
| ~11:12 | application reconcile logs in the controller went fully silent (stall begins) |
| ~11:20~11:30 | While restarting the notifications controller and verifying metric collection, a critical alert arrived from Alertmanager |
| 11:30~11:32 | Current-state analysis: all 10 apps had frozen `reconciledAt` — some 29 h stale, some 4 h 36 min stale |
| 11:32 | `kubectl rollout restart statefulset/argocd-application-controller -n argocd` |
| 11:32:28 | All 10 apps' `reconciledAt` refreshed to within 5 minutes — recovery complete |

<br/>

### Decisive clue — goroutine count

Controller stats log (printed every 10 min) immediately before the restart:

```
time="2026-04-23T02:11:32Z" Alloc=173129 TotalAlloc=170588644 Sys=596474 NumGC=2058 Goroutines=1446
time="2026-04-23T02:21:32Z" Alloc=145764 TotalAlloc=171288879 Sys=596474 NumGC=2067 Goroutines=1446
```

- **`Goroutines=1446`.** Initially read as "unusually high, goroutine leak suspected". (See the "Diagnosis correction" section further down — after the rollback, we confirmed 1446 is the normal baseline for this cluster, not a leak.)
- `Alloc` (live heap) actually decreases (173 → 145 Mi) — most goroutines are parked with no active work.
- Only the 10-minute stats line appears; **not a single app-level reconcile log.**

<br/>

### Identified trigger mechanism for Cause A

The 5-second window (02:11:30 – 02:11:35Z) right before the stall is the key:

```
02:11:30Z "Using diffing customizations to ignore resource updates"
02:11:30Z "Ignore status for all objects"
02:11:30Z "Notifying 1 settings subscribers: [0xc0005b2070]"
02:11:30Z "Ignore status for all objects"
02:11:30Z "Using diffing customizations to ignore resource updates"
02:11:30Z "Ignore status for all objects"
...(same pattern repeats)...
02:11:35Z "Using diffing customizations to ignore resource updates"
02:11:35Z "Ignore status for all objects"
----- after this line, NO application reconcile logs appear -----
```

- `Notifying ... settings subscribers` = the controller's **internal settings watch seeing a ConfigMap change**.
- This 5-second window coincides exactly with `helmfile apply` patching `argocd-cm` / `argocd-notifications-cm` / `argocd-rbac-cm`.
- The same pattern correlates with the following:
  - **2026-04-21 17:32 KST**: chart upgrade (9.5.1 → 9.5.2, v3.3.6 → v3.3.7) — right after, 4 apps got stuck at `2026-04-21T21:11Z`.
  - **2026-04-22 15:27 KST**: notifications rule change applied — right after, the remaining apps got stuck around `2026-04-22T08:54Z`.
  - **2026-04-23 02:11 UTC (11:11 KST)**: today's helmfile apply — observed live.

<br/>

### Cause A conclusion (updated)

> **Every time an `argocd-cm`-family ConfigMap is externally patched, the controller's settings-reload path leaks goroutines or deadlocks a work-queue goroutine. Once stuck, the controller does not self-heal without a restart.**

- Version-correlated observation: visible **after the upgrade to ArgoCD v3.3.7 (helm chart 9.5.2)**. Not previously seen on v3.3.6.
- The pod itself is `Running`
- Only `argocd_app_reconcile_count`'s `increase() == 0` catches it → **the `ArgoCDControllerReconcileStuck` alert added during this incident is effectively the only automated detection mechanism.**

<br/>

### Operating principles (confirmed by this incident)

1. **Always verify controller state after `helmfile apply`.** In particular, the goroutine count.
    ```bash
    kubectl logs -n argocd argocd-application-controller-0 --tail=50 \
      | grep -oE 'Goroutines=[0-9]+' | tail -3
    # Normal: ~100-300 (before the rollback's baseline revision of this finding; see
    # the Diagnosis correction section below, where the cluster baseline is 1446).
    ```
2. **Restart immediately on detection.** Recovery is a one-liner:
    ```bash
    kubectl rollout restart statefulset/argocd-application-controller -n argocd
    ```
3. **Never mute or silence `ArgoCDControllerReconcileStuck`.** It is currently the only automated way to catch this stall.

<br/>

### Open follow-up items

- Check GitHub issues upstream for anything related to settings reload / goroutine leak on ArgoCD v3.3.7.
- Enable a pprof endpoint on the controller so that a **goroutine stack dump** can be captured the next time it stalls.
- If it is confirmed as an upstream issue, plan either a rollback to v3.3.6 or waiting for a patch release.
- Consider automatic self-healing (e.g. Alertmanager webhook → Job that restarts the controller), but keep in mind that auto-restart is a workaround, not a fix.

<br/>

## 2026-04-23 final action summary

A chronological digest of everything done that day. In subsequent operation, this section is the "why is it set up this way" reference.

<br/>

### 1. Event timeline (KST)

| Time | Event | Action |
|---|---|---|
| ~06:33 ~ 06:54 | Multiple ghost/duplicate alarms received (qa/staging/dev) | Investigation begins |
| ~10:00 | Cause A/B/C analysis complete | Swap `oncePer` keys to `finishedAt` |
| ~11:11 | First stall detected (`Goroutines=1446`) | helmfile apply followed by controller restart |
| ~11:32 | Stall recurs (~11 min after the restart) | Restart again |
| ~11:46 | Add pprof env + restart | `ARGOCD_APPLICATION_CONTROLLER_PPROF=true` |
| ~11:58 | pprof dump attempt failed (port 6060 refused, 8082 timeout) | Port / endpoint verification becomes a follow-up |
| ~11:59 | Stall recurs again (`Goroutines=1446`) — 4th time that day | Decide to roll back |
| ~12:03 | **Rollback v3.3.7 → v3.3.6** (chart 9.5.2 → 9.5.1) | Restored from `backup/20260421_173002/` (Chart.yaml / helmfile.yaml) |
| ~12:04 | 3 post-rollback alerts (stale instance) | `time() - timestamp(...) < 300` filter added — cleared naturally |
| ~12:05 | **Stability confirmed** (all reconciledAt within 1 min, logs active) | Transition to monitoring phase |

<br/>

### 2. Final configuration (current state)

**ArgoCD (`cicd/argo-cd/`):**

| Item | Current value | Note |
|---|---|---|
| Chart / appVersion | `argo-cd 9.5.4` / `v3.3.8` | Upgraded 2026-04-24. The v3.3.7 work-queue stall is fixed by PR #27400 (= the revert of #27230). See § 2026-04-24 v3.3.8 upgrade result below. |
| `trigger.on-deployed.oncePer` | `app.status.operationState.finishedAt` | 1 sync = 1 alarm |
| `trigger.on-restarted.oncePer` | `app.status.operationState.finishedAt` | Same principle |
| `trigger.on-health-degraded.oncePer` | `app.status.operationState.finishedAt` | Role split with Alertmanager (Option B) — still active in subscriptions |
| `controller.env` — `ARGOCD_APPLICATION_CONTROLLER_PPROF` | `true` | For pprof capture on the next stall. Endpoint verification is open |

**Alertmanager / PrometheusRule (`observability/monitoring/kube-prometheus-stack/`):**

| Alert | expr | Note |
|---|---|---|
| `ArgoCDControllerReconcileStuck` | `increase([30m]) == 0 and timestamp(...) > now-300` | Includes the stale-instance filter. Kept even after the rollback, as a regression monitor |
| `ArgoCDAppDegraded` / `Missing` / `OutOfSync` | Commented (prepared for Option A) | Disabled because we chose Option B |
| ArgoCD inhibit_rule | Commented | Uncomment when enabling Option A |

**Documents and tools:**

- `docs/ghost-alarm-incident-2026-04-23-en.md` (this document) — full analysis
- `docs/notification-rule-change-playbook-en.md` — procedure for future rule changes
- `docs/ghost-alarm-followup-prompt-en.md` — prompt for asking Claude on recurrence
- `docs/upstream-issue-template-en.md` — upstream issue template (English)
- `scripts/notify-rule-change.sh` — rule change / health-check helper

<br/>

### 3. Upstream issue

**Filed:** [argoproj/argo-cd#27516](https://github.com/argoproj/argo-cd/issues/27516)
— "application-controller reconcile queue silently halts (work queue stall) after settings reload on v3.3.7" (title updated after correction)
— Labels: `bug`, `triage/pending`
— Status (as of 2026-04-24): maintainer `@blakepettersson` replied "Try 3.3.8, there was a fix merged that should address this." Upgraded our dev cluster to v3.3.8 and verified the fix holds (see § 2026-04-24 v3.3.8 upgrade result). Plan to close after >24h of stable operation.

Record further updates in this section.

<br/>

### Diagnosis correction (post-rollback observation)

After ~30 minutes of healthy operation on v3.3.6, the following was confirmed and the original diagnosis is corrected:

| Observation | Morning hypothesis (v3.3.7 observation) | Corrected fact |
|---|---|---|
| `Goroutines=1446` | "Unusually high, likely a leak" | **Normal cluster baseline**. 1446 is also observed under healthy v3.3.6 operation. |
| Root cause of stuck | "Goroutine leak + parked goroutines" | **Work queue silent halt**. The goroutine pool is fine; reconcile processing stops. |
| Recurrence-detection signal | "Goroutine count exceeds a threshold" | **Reconcile counter increment** (`increase(argocd_app_reconcile_count[30m]) == 0`) — the existing alert already uses this correct signal. |
| Difference between v3.3.6 and v3.3.7 | "3.3.7 has a goroutine leak bug" | **With the same goroutine pool, only the reconcile processing path stalls** — root cause still unknown; suspects are #27049 (SettingsManager refactor) and #27230 (informer resync fix). |

**Knock-on changes:**

- `scripts/notify-rule-change.sh` no longer uses a goroutine threshold for stuck detection; it now measures **reconcile activity**. `GOROUTINE_INFO_THRESHOLD=3000` is informational only.
- Upstream issue #27516 title and body were corrected — "goroutines climbing" phrasing removed, "work queue stall" used consistently. The body edit plus a correction comment have been applied.

<br/>

### 4. Open follow-ups

- [ ] **Verify the actual pprof endpoint port.** `ARGOCD_APPLICATION_CONTROLLER_PPROF=true` alone did not produce a listener on 6060. Under v3.3.7, `/debug/pprof/` may live on 8082 (metrics), but that timed out. Re-try on v3.3.8 with the same env (kept for regression capture readiness).
- [x] **Monitor upstream #27516.** 2026-04-24 maintainer `@blakepettersson` pointed to v3.3.8 as the fix; dev-cluster upgrade verified it. Keep logging further updates here.
- [x] **Plan for retrying v3.3.7 (or a later patch).** v3.3.8 confirmed as the fix and applied to the dev cluster on 2026-04-24. See § 2026-04-24 v3.3.8 upgrade result.
- [ ] **Long-term observation on v3.3.8 for similar symptoms.** A day or more of healthy operation confirms the fix. If a stall reappears, roll back immediately and report the regression upstream with a pprof dump.

<br/>

### 5. Recovery reference (immediate action on recurrence)

```bash
# 1) Diagnose
cd ~/gitlab-project/kuberntes-infra/cicd/argo-cd
./scripts/notify-rule-change.sh status

# 2) If stuck (completed reconciles in the last window = 0), restart immediately
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=120s

# 3) If a stall reappears on v3.3.8, roll back to a known-good version:
#    - First choice: v3.3.6 (chart 9.5.1). Originals preserved in backup/20260421_173002/.
#    - Or roll back to the pre-v3.3.8 snapshot via ./upgrade.sh --rollback
#      (restores backup/20260424_111248/, the upgrade-time snapshot).
#    cp backup/20260421_173002/Chart.yaml .
#    cp backup/20260421_173002/helmfile.yaml .
#    helmfile apply
#    # Capture a pprof goroutine dump during the stall and report the regression on upstream #27516.
```

<br/>

## 2026-04-24 v3.3.8 upgrade result

After maintainer `@blakepettersson` responded on upstream #27516 with "Try 3.3.8, there was a fix merged that should address this", the dev cluster was upgraded to v3.3.8 (chart 9.5.4) and the fix was verified.

<br/>

### Timeline (KST)

| Time | Event |
|---|---|
| 11:12 | `./upgrade.sh --version 9.5.4` — bumped Chart.yaml / helmfile.yaml / values.yaml, preserved the v3.3.6 snapshot in `backup/20260424_111248/` |
| 11:13 | Commit `95d72f5`: `feat(cicd/argo-cd): upgrade argocd v3.3.6 -> v3.3.8 (chart 9.5.1 -> 9.5.4)` |
| 11:15:31 | `helmfile apply` succeeded (44s). All component images `v3.3.6 → v3.3.8`, helm release revision 27. |
| 11:16 | First reconcile round on the new controller |
| 11:19:26 | Phase 5 deliberate settings-reload — `kubectl annotate cm argocd-cm / argocd-notifications-cm / argocd-rbac-cm` to fire three extra `Notifying settings subscribers` bursts |
| 11:26~27 | Second reconcile round completed (standard 10-min cycle) |
| 11:36~37 | Third reconcile round completed |
| 11:43 | Final verification — all signals healthy, fix confirmed. Preparing upstream report. |

<br/>

### Quantitative evidence (apply+27min / reload-trigger+23min)

| Signal | Result | On v3.3.7 stall |
|---|---|---|
| `Reconciliation completed` log lines (last 30m) | **18** | 0 (completely silent) |
| Reconcile rounds | Two full rounds at 02:26~27 and 02:36~37 UTC | First round began, then froze |
| `Goroutines` stats line | 1446, steady baseline | 1446 (same value, but during stall) |
| `increase(argocd_app_reconcile_count[30m])` | 8.15 / 15.18 (old/new pod instances) | 0 |
| Active alerts | Only `Watchdog` firing (normal) | `ArgoCDControllerReconcileStuck` critical |
| Application state | Synced / Healthy (10/10) | Several apps with `reconciledAt` stuck for hours |

On v3.3.7 the stall landed **~11 min** after a settings reload. Clearing **~23 min + three extra reload bursts** is decisive evidence that the fix is effective.

<br/>

### Relevant fixes included in v3.3.8

From the v3.3.8 release notes, the commits directly related to this regression:

- **PR [#27400](https://github.com/argoproj/argo-cd/pull/27400)** — "Revert prevent automatic refreshes from informer resync and status updates" (= the revert of #27230). This is exactly the PR we flagged as the **most likely stall cause** during the original diagnosis; the revert clears the work-queue stall.
- PR [#27396](https://github.com/argoproj/argo-cd/pull/27396) — stale-cache fix in the RevisionMetadata handler (secondary possibility).

<br/>

### Operating principles (updated)

With the stall risk gone on v3.3.8, the post-`helmfile apply` check surface simplifies:

1. Run `./scripts/notify-rule-change.sh status` and confirm **"completed reconciles in the last 10m" > 0**. The `Goroutines` value is informational — 1446 is the normal baseline for this cluster.
2. Keep the `ArgoCDControllerReconcileStuck` alert as a regression canary. If v3.3.8 ever regresses, this alert is the first signal.
3. Stall recurrence procedure: capture a pprof dump (port 6060) → roll back immediately → report the regression on upstream #27516.

<br/>

## References

- `values/mgmt-notifications.yaml` — current notifications config
- `backup/20260421_173002/mgmt-notifications.yaml` — pre-change backup
- `backup/20260421_173002/Chart.yaml` — the rollback reference (chart 9.5.1, v3.3.6)
- GitLab repo `server/argocd-applicationset` — where the CI bot pushes image tag updates
- ArgoCD notifications official docs: <https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/>
- Upstream issue: <https://github.com/argoproj/argo-cd/issues/27516>
