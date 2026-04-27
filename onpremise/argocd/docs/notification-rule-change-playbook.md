# Notification Rule Change Playbook

<br/>

## Purpose

A documented procedure for managing the **one-time redelivery storm** that occurs whenever `trigger` or `template` definitions in `values/mgmt-notifications.yaml` are changed. The playbook was written after the 2026-04-23 incident, where changing the `oncePer` formula pushed 30 "deploy success" notifications into the Slack `#argocd-alarm` channel in a single burst.

<br/>

## Core principle: full prevention is not possible

**The moment you change a `trigger` field that affects the dedup key (`oncePer` / `when` / `send`), redelivery is structurally unavoidable.** Here is why:

1. The ArgoCD notifications-controller stores the "hash of (trigger, oncePer value) already delivered" in each `Application`'s `metadata.annotations.notified.notifications.argoproj.io`.
2. Changing the trigger formula produces a **different hash for the same application state**.
3. When the controller evaluates after a restart, it sees "no such hash in the annotation → first delivery" and **emits one notification per trigger per application**.

Avoidance approaches that were tried and **do not work**:
- Emptying the subscription temporarily and restarting the controller → no subscription means no send attempt at all, so the annotation is never updated; the same redelivery happens once the subscription is restored.
- Scaling the controller to 0 → deleting the annotations manually → scaling back up: manual deletion resets every hash to "never seen", which causes the same mass redelivery.
- Pre-computing new-formula hashes into the annotation: the hashing logic lives inside the controller and cannot be replicated externally.

Therefore, this playbook targets **"minimize impact and keep it predictable"** rather than "eliminate it".

<br/>

## Impact-minimization principles

1. **Apply during quiet hours** — performing the change outside business hours (for example weekdays 04:00–06:00 KST) means operators see the storm only as read-through backlog the next morning.
2. **Pre-announce** — right before `helmfile apply`, post a message to `#argocd-alarm` such as "notification rule change, ~N one-time redeliveries expected". This prevents other operators from mistaking the storm for real events.
3. **Batch changes** — group multiple trigger changes into a single apply. Splitting them causes separate redelivery storms.
4. **Minimize scope** — edits to strings or comments that do not touch `oncePer` do not affect the dedup hash. Separate dedup-affecting changes from cosmetic ones.

<br/>

## Procedure (checklist)

### Pre-flight (just before the change)

- [ ] **1. Impact analysis**: run `git diff values/mgmt-notifications.yaml` and look for `oncePer` / `when` edits.
- [ ] **2. List affected triggers**: record the trigger names being changed.
- [ ] **3. Count delivery targets**: `kubectl get app -n argocd | wc -l` — this is the upper bound of redelivery per changed trigger.
- [ ] **4. Estimate redelivery volume**: (number of changed triggers) × (apps currently satisfying the when clause).
- [ ] **5. Post a Slack pre-notice** to `#argocd-alarm`.
- [ ] **6. (Optional) Back up the annotation** for rollback.

### Apply

- [ ] **1. Commit / push the file.**
- [ ] **2. Review the rendered result with** `cd cicd/argo-cd && helmfile diff`.
- [ ] **3.** `helmfile apply`.
- [ ] **4.** `kubectl rollout restart deployment/argocd-notifications-controller -n argocd` — load the new configuration.
- [ ] **5. Wait for the restart to complete**: `kubectl rollout status deployment/argocd-notifications-controller -n argocd`.

### Post-check

- [ ] **1. Actual send count** — count "Sending notification" entries in the controller logs.
- [ ] **2. Compare to estimate** — if the delta is large, investigate whether real events were mixed in.
- [ ] **3. Cross-check against Slack** by scrolling the channel.
- [ ] **4. (Optional) Post a completion notice**: "rule change complete, N one-time redeliveries done".

<br/>

## Scripting

To avoid running this checklist manually every time, use the helper script.

**Location:** `cicd/argo-cd/scripts/notify-rule-change.sh`

**Supported commands:**

| Command | Purpose |
|---|---|
| `check` | Dry run. Shows impacted triggers and the estimated redelivery count only (no Slack send). |
| `pre` | Just before the change: impact analysis + Slack pre-notice to `#argocd-alarm`. |
| `post` | Just after the change: aggregate actual sends from the last 15 min + controller goroutine reading + Slack completion notice. |
| `status` | Routine health check: goroutine count / recent log activity / oldest `reconciledAt` per app. |

**What the script does for you:**
- Auto-detect impacted triggers based on `git diff values/mgmt-notifications.yaml` (looks at `oncePer` / `when` / `send` changes).
- Estimate redelivery volume as (application count) × (changed trigger count).
- Fetch the Slack bot token from `argocd-notifications-secret` and send pre/post notices through the `chat.postMessage` API.
- On `post`: tally "Sending notification" and "already sent" log lines from the notifications-controller.
- Surface the controller goroutine count as an informational number (the actual stuck check uses reconcile activity).

**What the script cannot do:**
- Block the redelivery itself (impossible — see the top of this document).
- Mute the Slack channel automatically (the Slack API only supports user-scoped mute, not bot-initiated).
- Control the exact send timing (depends on when the controller finishes its restart).

<br/>

## End-to-end workflow example

Recommended order when changing a notification rule. Example scenario: adjust the `oncePer` formula of the `on-deployed` trigger.

### 1) Edit the values file

```bash
cd ~/gitlab-project/kuberntes-infra/cicd/argo-cd
vi values/mgmt-notifications.yaml
```

### 2) Pre-commit impact analysis

```bash
./scripts/notify-rule-change.sh check
```

Example output:
```
== Impact analysis based on git diff (values/mgmt-notifications.yaml) ==
Impacted triggers:
  - trigger.on-deployed
Estimated redelivery (upper bound): 10 events = 10 apps × 1 trigger
(Actual sends are limited to apps that currently match the when clause)
```

If the blast radius is wider than expected, stop here and consider splitting the change.

### 3) Commit

```bash
git add values/mgmt-notifications.yaml
git commit -m "fix(cicd/argo-cd): <summary of change>"
```

### 4) Pre-notice

```bash
./scripts/notify-rule-change.sh pre
```

This posts the following message to `#argocd-alarm`:
```
:warning: Upcoming ArgoCD notification rule change
• Scope: trigger.on-deployed
• Expected redelivery: up to 10 events
• You may see deploy/restart alarms without any real event for the next few minutes — safe to ignore.
```

### 5) Apply

```bash
helmfile apply
kubectl rollout restart deployment/argocd-notifications-controller -n argocd
kubectl rollout status deployment/argocd-notifications-controller -n argocd --timeout=60s
```

**ℹ️ Note:** `helmfile apply` patches the ArgoCD ConfigMaps, which **triggers a settings reload in the application-controller**. Under v3.3.7 this path caused a work-queue stall, but **the regression is fixed in v3.3.8 (chart 9.5.4)** — verified on 2026-04-24 (see ghost-alarm-incident-2026-04-23-en.md, "2026-04-24 v3.3.8 upgrade result" section). Keep an eye on reconcile activity in the next step regardless.

### 6) Post-verification + completion notice

```bash
./scripts/notify-rule-change.sh post
```

Example output (healthy):
```
== Actual send count after the change ==
Last 15 min: 10 sent / 25 already-sent (suppressed)

== Controller goroutine check (informational) ==
Goroutines=287 (within baseline; count alone does not indicate stuck — see reconcile activity)

== Slack completion notice ==
Slack post succeeded → #argocd-alarm
```

Example output (stuck suspected):
```
== Controller goroutine check (informational) ==
Goroutines=3204 — above baseline threshold 3000. Unusual; capture pprof and investigate.
```

If the goroutine count is unusually high **and** recent reconcile activity is zero, restart the application-controller immediately.

### 7) Routine health check

```bash
./scripts/notify-rule-change.sh status
```

Run this regularly, or run it first whenever an `ArgoCDControllerReconcileStuck` alert arrives in Slack. Example output:
```
== Controller state ==
Goroutines: 287 (informational only; baseline depends on app count)
log lines (last 11m): 42
completed reconciles in last 10m: 7

== Oldest reconciledAt per app (top 5) ==
  dev-example-project-admin                       reconciledAt=2026-04-23T05:12:34Z (3 min ago)
  dev-example-project-app-admin                   reconciledAt=2026-04-23T05:12:35Z (3 min ago)
  ...
```

If every app has reconciled within the last ~10 min, the controller is healthy. If only some apps are stale for hours, suspect a controller sharding / queue issue. If every app is stale, the controller is stuck for certain.

<br/>

## Response to an `ArgoCDControllerReconcileStuck` alert

When this alert fires to Slack `#infra-alerts`, **always** start by running the helper.

```bash
# 1) Diagnose
./scripts/notify-rule-change.sh status

# 2) Recover via restart
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=120s

# 3) Confirm recovery
./scripts/notify-rule-change.sh status
# If every app's reconciledAt is within a few minutes, you are done.
```

Log the recurrence (for example "stuck after morning deploy", "stuck with no trigger") in `ghost-alarm-incident-2026-04-23-en.md` under the post-incident follow-up section.

<br/>

## Slack notice message templates

The script uses these automatically, but keep them for manual posting:

**Pre-change message:**

```
:warning: Upcoming ArgoCD notification rule change
- Scope: <trigger name list>
- Expected redelivery: ~N events (<trigger count> × <app count>)
- Apply time: YYYY-MM-DD HH:MM KST
- Deploy/restart alarms may fire without a real event for the next few minutes — safe to ignore.
```

**Post-change message:**

```
:white_check_mark: ArgoCD notification rule change complete
- Actual sends: N (expected: M)
- Restart time: YYYY-MM-DD HH:MM KST
- Treat any further alarms as real events.
```

<br/>

## Edge cases

### Adding or removing a `trigger` only

- Adding a new trigger while leaving existing ones alone: **only the new trigger causes redelivery across all apps.**
- Removing a trigger from `subscriptions` only: **the annotation stays but the delivery path is gone** → no redelivery. When you reinstate it later, nothing replays (annotation is preserved).

### Changing only `template` (message format, etc.)

- If `oncePer` and `when` are unchanged, the annotation hash is the same → **no redelivery.**

### Changing only `subscription.recipients` (Slack channel)

- The dedup hash includes the receiver identifier. A new channel produces a new hash → **full redelivery to the new channel.**
- The old channel receives nothing further (by design).

<br/>

## Related documents

- 2026-04-23 ghost alarm incident analysis: [ghost-alarm-incident-2026-04-23-en.md](ghost-alarm-incident-2026-04-23-en.md)
- Follow-up inquiry prompt: [ghost-alarm-followup-prompt-en.md](ghost-alarm-followup-prompt-en.md)
- Upstream ArgoCD notifications docs: <https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/>
