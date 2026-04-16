# ECK Stack Upgrade / Rollback Guide

Covers both Elasticsearch and Kibana. Describes the safety features in `upgrade.sh`, the automatic rollback flow, and incident response procedures.

Both ES and Kibana use the `local-cr-version` canonical template, so this guide applies to both.

<br/>

## Table of contents

1. [Background: 2026-04-16 incident](#background-2026-04-16-incident)
2. [Safety features](#safety-features)
3. [Normal upgrade flow](#normal-upgrade-flow)
4. [Rollback flow](#rollback-flow)
5. [Incident scenarios](#incident-scenarios)
6. [Manual recovery](#manual-recovery)
7. [Pre-flight checklist](#pre-flight-checklist)

<br/>

## Background: 2026-04-16 incident

`./upgrade.sh` detected `9.4.0` as the latest GA from the Elastic artifacts API and applied it, but the image had not yet been published on `docker.elastic.co`. Result:

1. **ImagePullBackOff**: ES/Kibana pods stuck in Init with missing `9.4.0` image
2. **Rollback blocked**: After `./upgrade.sh --rollback`, running `helmfile apply` was denied by the ECK admission webhook:
   ```
   admission webhook "elastic-es-validation-v1.k8s.elastic.co" denied the request:
   spec.version: Invalid value: "9.0.0": Downgrades are not supported
   ```
3. **Operator CrashLoopBackOff**: Manually deleting the webhook caused the ECK operator to crash because its startup expected the webhook to exist
4. **Helm `failed` release**: The failed `helmfile apply` left the Helm release in `failed` status, making subsequent `helmfile diff` runs return nothing

All four issues are now prevented or automatically recovered by the safety features below.

<br/>

## Safety features

### Upgrade flow (7 steps)

| Step | Safety | Prevents |
|---|---|---|
| **2/7** | **Cluster health pre-flight** | Starting an upgrade while CR phase is not `Ready` or health is `red` |
| **4/7** | **Image verification + fallback search** | Upgrading to a version listed in the artifact feed but not yet published as a Docker image. Automatically searches older GA versions for the newest available |
| **5/7** | **Dependency CR constraint** (Kibana only) | Kibana version > Elasticsearch version (connection break) |
| **5/7** | **Major bump snapshot warning** | Upgrading across major versions (8.x → 9.x) without a snapshot |

### Rollback flow (auto-handled, 7 steps)

| Step | Safety | Prevents |
|---|---|---|
| **1/7** | **Operator scale-down first** | Operator crash when the webhook is deleted |
| **2/7** | **Webhook removal** | Admission webhook blocking the downgrade |
| **3/7** | **Helm failed release recovery** | `helmfile diff` returning empty (comparing against failed revision) |
| **5/7** | **Webhook recreation** | Operator unable to find webhook after restart |
| **6/7** | **Operator Ready wait** | Declaring success before the operator pod is actually Ready |
| **7/7** | **CR Ready wait** | Declaring rollback success before the CR is actually restored |

### Other

| Feature | Location |
|---|---|
| `check-versions.sh` **NO_IMG status** — prevents mis-reporting unavailable versions as UPDATE | [check-versions.sh](../../../../scripts/helm-upgrade/check-versions.sh) |
| **Downgrade detection** — auto-detects during rollback → offers webhook handling | `do_rollback()` |

<br/>

## Normal upgrade flow

```bash
cd observability/logging/elasticsearch

# 1. Dry-run (checks health + image availability + dependencies)
./upgrade.sh --dry-run

# 2. Apply (updates Chart.yaml + values/mgmt.yaml)
./upgrade.sh

# 3. Push to cluster
helmfile diff
helmfile apply

# 4. Keep Kibana on the same Stack version (ES first, Kibana later)
cd ../kibana
./upgrade.sh
helmfile apply
```

### Upgrade abort scenarios

**Step 2 — cluster health abnormal**
```
[Step 2/7] Pre-flight cluster health check...
  CR phase:  ApplyingChanges
  ERROR: CR is in transient state 'ApplyingChanges'. A reconcile may be in progress.

  Proceed anyway? [y/N]:
```
Likely a prior upgrade hasn't finished. Watch `kubectl -n logging get elasticsearch -w` until Ready.

**Step 4 — image not published yet**
```
[Step 4/7] Verifying container image...
  Checking: docker.elastic.co/elasticsearch/elasticsearch:9.4.0

  WARNING: Container image not found in registry.

  Searching for the newest GA version with a published image...
    9.4.0: not found
    9.3.3: available

  Latest available (with published image): 9.3.3

  Use 9.3.3 instead of 9.4.0? [y/N]:
```
`y` to proceed with 9.3.3. `n` aborts with the suggested `--version 9.3.3` command.

**Step 5 — dependency CR constraint** (Kibana only)
```
[Step 5/7] Compatibility checks
  Checking dependency CR version constraint...
  Dependency elasticsearch/elasticsearch version: 9.0.0

  ERROR: target version 9.3.3 is HIGHER than elasticsearch version 9.0.0.
  kibana must be <= elasticsearch version.
  Upgrade elasticsearch first, then retry.
```
Upgrade Elasticsearch first, then retry Kibana.

**Step 5 — major version bump**
```
  !! MAJOR VERSION BUMP: 8.x -> 9.x
  !!
  !! STRONGLY RECOMMENDED: take an Elasticsearch snapshot before proceeding.
  !! https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-snapshots.html

  Continue with major version upgrade? [y/N]:
```
Proceeding with `y` without a snapshot leaves no recovery option on failure.

### Preflight across all charts

```bash
./scripts/helm-upgrade/check-versions.sh --updates-only
```

```
UPDATE   local-with-templates      0.56.0   0.57.2           observability/logging/_optional/fluent-bit-aws/upgrade.sh
NO_IMG   local-cr-version          9.0.0    9.4.0 (→9.3.3)   observability/logging/elasticsearch/upgrade.sh
         -> 9.4.0 image missing; latest available: 9.3.3 (use --version 9.3.3)
```

The arrow notation (`9.4.0 (→9.3.3)`) shows the latest version in the feed and the newest version whose image is actually published.

<br/>

## Rollback flow

### Automatic rollback (recommended)

```bash
cd observability/logging/elasticsearch   # or kibana
./upgrade.sh --rollback
```

Script behavior:

1. Lists backups → pick a number
2. Restores Chart.yaml + values/mgmt.yaml
3. **Downgrade detection**: compares backup version with live cluster CR version via `kubectl`
4. If downgrade detected:
   ```
   WARNING: This is a version downgrade (9.4.0 -> 9.0.0).
   Operator admission webhooks typically block CR version downgrades.

   Automatically handle the webhook and apply rollback? [y/N]:
   ```
5. `y` triggers the 7-step auto-handler:

| Step | Action | Rationale |
|---|---|---|
| 1/7 | `kubectl scale sts elastic-operator --replicas=0` + pod delete wait | prevents operator crash when webhook is deleted |
| 2/7 | `kubectl delete validatingwebhookconfiguration elastic-operator.elastic-system.k8s.elastic.co` | lifts downgrade block |
| 3/7 | `helm status` failed check → `helm rollback` if needed | normalizes Helm internal state so helmfile diff works |
| 4/7 | `helmfile apply` | CR updated to the backup version |
| 5/7 | `cd ../eck-operator && helmfile sync` | recreates webhook (auto-detects the eck-operator directory) |
| 6/7 | `kubectl scale sts elastic-operator --replicas=1` + Ready wait | operator comes back up (blocks until pod Ready) |
| 7/7 | CR phase=Ready wait (5 min timeout) | verifies rollback actually completed |

### When not a downgrade

If backup version ≥ live CR version (e.g. test rollback), the script just restores files:
```
Rollback complete! Run 'helmfile diff' to verify, then 'helmfile apply'.
```
No webhook issues — just run `helmfile apply` manually.

### Rolling back both ES and Kibana

Each component is independent:

```bash
cd observability/logging/elasticsearch
./upgrade.sh --rollback

cd ../kibana
./upgrade.sh --rollback
```

The operator/webhook gets bounced twice (once per component). Slight redundancy but the result is correct.

<br/>

## Incident scenarios

### Scenario 1: `ImagePullBackOff` right after upgrade

```
elasticsearch-es-default-0   0/1   Init:ImagePullBackOff
```

**Cause**: Step 4 was bypassed, or network/registry issue during pull.

**Response**:
1. Verify image presence:
   ```bash
   curl -sSL "https://docker-auth.elastic.co/auth?service=token-service&scope=repository:elasticsearch/elasticsearch:pull" \
     | jq -r .token \
     | xargs -I{} curl -sSI -H "Authorization: Bearer {}" \
       "https://docker.elastic.co/v2/elasticsearch/elasticsearch/manifests/<VERSION>"
   ```
2. If image is missing, run the auto-rollback:
   ```bash
   ./upgrade.sh --rollback
   ```

### Scenario 2: `helmfile apply` blocked by webhook

```
Error: UPGRADE FAILED: admission webhook "elastic-es-validation-v1.k8s.elastic.co"
denied the request: spec.version: Downgrades are not supported
```

**Cause**: Files rolled back, then `helmfile apply` was run manually (bypassing the webhook handler).

**Response**: Run `./upgrade.sh --rollback` again and answer `y`. The Helm failed state is also auto-recovered in Step 3.

### Scenario 3: ECK operator `CrashLoopBackOff`

```
elastic-operator-0   0/1   CrashLoopBackOff
```

Operator logs:
```
error: validatingwebhookconfigurations.admissionregistration.k8s.io
"elastic-operator.elastic-system.k8s.elastic.co" not found
```

**Cause**: Webhook was deleted but not recreated.

**Response**:
```bash
cd observability/logging/eck-operator
helmfile sync

kubectl -n elastic-system delete pod elastic-operator-0
```

### Scenario 4: `helmfile diff` returns empty

```
$ helmfile diff
Comparing release=elasticsearch, chart=., namespace=logging
$ # No diff shown, but cluster CR is on a different version
```

**Cause**: Previous `helmfile apply` failed → Helm release in `failed` status. Helm compares against the failed revision's desired state.

**Response**:
```bash
helm list -n logging
helm history <release> -n logging
helm rollback <release> <last-successful-revision> -n logging
helmfile apply
```

Covered automatically by `./upgrade.sh --rollback` Step 3.

<br/>

## Manual recovery

When the automation fails or is unavailable:

```bash
# 1. Scale down operator (prevents webhook recreation)
kubectl -n elastic-system scale sts elastic-operator --replicas=0
kubectl -n elastic-system wait --for=delete pod/elastic-operator-0 --timeout=60s

# 2. Remove webhook
kubectl delete validatingwebhookconfiguration \
  elastic-operator.elastic-system.k8s.elastic.co --ignore-not-found

# 3. Recover Helm failed release (if applicable)
helm list -n logging
# If elasticsearch/kibana release status=failed:
helm history elasticsearch -n logging
helm rollback elasticsearch <rev> -n logging

# 4. Patch CRs directly to target version (no webhook)
kubectl -n logging patch elasticsearch elasticsearch \
  --type=merge -p '{"spec":{"version":"9.0.0"}}'
kubectl -n logging patch kibana kibana \
  --type=merge -p '{"spec":{"version":"9.0.0"}}'

# 5. Sync helmfile state
cd observability/logging/elasticsearch && helmfile apply
cd ../kibana && helmfile apply

# 6. Recreate webhook
cd ../eck-operator && helmfile sync

# 7. Bring operator back + Ready wait
kubectl -n elastic-system scale sts elastic-operator --replicas=1
kubectl -n elastic-system wait --for=condition=Ready pod/elastic-operator-0 --timeout=120s

# 8. Verify CRs are Ready
kubectl -n logging wait elasticsearch/elasticsearch \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
kubectl -n logging wait kibana/kibana \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
```

<br/>

## Pre-flight checklist

Before upgrade:

- [ ] `./scripts/helm-upgrade/check-versions.sh --updates-only` — no `NO_IMG` status
- [ ] `./upgrade.sh --dry-run` — Step 2 health, Step 4 image, Step 5 dependency all pass
- [ ] ECK Operator supports the target Stack version ([Compatibility matrix](https://www.elastic.co/support/matrix))
- [ ] ES and Kibana on the same Stack version (ES first, then Kibana)
- [ ] For major bumps (8.x → 9.x): **take an Elasticsearch snapshot first** — no recovery possible otherwise
- [ ] `helm history` shows a recent successful revision (rollback point exists)

Before rollback:

- [ ] `kubectl` context points to the correct cluster (`kubectl config current-context`)
- [ ] Target backup exists (`./upgrade.sh --list-backups`)
- [ ] For downgrades, answer `y` to the auto-handler prompt → full automated flow

<br/>

## References

- [helm-upgrade system guide](../../../../scripts/helm-upgrade/README-en.md)
- [local-cr-version canonical template](../../../../scripts/helm-upgrade/templates/local-cr-version.sh)
- [ECK Operator chart](../../eck-operator/)
- [Elasticsearch compatibility matrix](https://www.elastic.co/support/matrix)
