# GitLab Runner Installation Guide

This guide describes how to install and configure GitLab Runner on Kubernetes. Deployment is driven by ArgoCD.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/<release>.yaml`; which marker files are in scope is owned by `CONFIG.ARGOCD_PIN_FILES` in `upgrade.py`. `upgrade.py` bumps them together via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of [docs/ci-upgrade.md](../../docs/ci-upgrade.md).

<br/>

## Directory Structure

```
gitlab-runner/
├── Chart.yaml
├── argocd/                     # per-release ArgoCD markers (chart-version SSOT)
├── values.yaml
├── values/
│   ├── build.yaml
│   ├── deploy.yaml
│   ├── old-gitlab-runner.yaml
│   └── backup/
├── upgrade.py
├── backup/
├── README.md
└── README-en.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- ArgoCD watching this repository (infra-applicationset)
- GitLab instance with runner registration token

<br/>

## Installation

<br/>

### 1. Add Helm Repository

```bash
helm repo add gitlab https://charts.gitlab.io
helm repo update
```

<br/>

### 2. Configure Values

Create a values file for each runner (e.g., `values/build.yaml`, `values/deploy.yaml`):

```yaml
gitlabUrl: "https://your-gitlab-instance.com"

## New runner registration token (recommended)
runnerToken: "<GITLAB_RUNNER_TOKEN>"

## Or legacy registration token (deprecated)
# runnerRegistrationToken: "<GITLAB_RUNNER_TOKEN>"

runners:
  tags: "build-image"
```

<br/>

### 3. Check the ArgoCD markers

This component has no helmfile. Each release has one `argocd/<release>.yaml` marker file, which the infra-applicationset git-files generator reads to create the Application. A marker declares `chart.repoURL` / `chart.name` / `chart.version` / `valueFile` / `autoSync`.

```bash
ls argocd/
cat argocd/build-image.yaml
```

<br/>

### 4. Deploy with ArgoCD

```bash
# Bump the chart pin (the markers listed in CONFIG.ARGOCD_PIN_FILES move together)
./upgrade.py --dry-run
./upgrade.py

# Commit and push the marker / values changes
git add cicd/gitlab-runner
git commit -m "chore(gitlab-runner): bump chart"
git push
```

On push, infra-applicationset re-reads the markers and reconciles the Applications. A release with `autoSync: true` needs nothing further; otherwise Sync the app from the ArgoCD UI. Watch progress on the `infra-<release>` apps in the ArgoCD UI.

<br/>

### 5. Verify Installation

```bash
helm list -n gitlab-runner
kubectl get po -n gitlab-runner
```

<br/>

## Upgrade

<br/>

### Check Latest Version

```bash
helm repo update
helm search repo gitlab/gitlab-runner
# NAME                  CHART VERSION  APP VERSION  DESCRIPTION
# gitlab/gitlab-runner  0.81.0         18.4.0       GitLab Runner

# Compare with currently installed version
helm list -n gitlab-runner
```

<br/>

### Using upgrade.py (Recommended)

An automated upgrade script that handles version checking, backup, diff, and rollback.

```bash
# Show help
./upgrade.py -h

# Preview upgrade (no files changed)
./upgrade.py --dry-run

# Upgrade to latest version (auto backup + apply)
./upgrade.py

# Upgrade to a specific version
./upgrade.py --version <chart-version>

# Exclude a values file from the checks (only when you need to)
./upgrade.py --exclude <filename-substring>
./upgrade.py --dry-run --exclude <filename-substring>

# List available backups
./upgrade.py --list-backups

# Rollback to a previous version
./upgrade.py --rollback

# Clean up old backups (keep last 5)
./upgrade.py --cleanup-backups
```

The script performs the following steps:
1. Checks current installed version and helmfile releases
2. Fetches latest version from Helm repository
3. Downloads target `Chart.yaml` and `values.yaml`
4. Shows `Chart.yaml` diff
5. Shows `values.yaml` diff
6. Checks `values/*.yaml` for breaking changes (removed/new top-level keys)
7. Backs up current files to `backup/<timestamp>/` and applies upgrade

Note: this component is ArgoCD-managed, so the version SSOT is `chart.version` in `argocd/<release>.yaml`. The files listed in `upgrade.py`'s `ARGOCD_PIN_FILES` are what gets bumped, and **all three releases are now included**.

🔴 **`old-build-deploy-image` is not a retired release.** It is the **only runner gitlab-old CI has**, run by ArgoCD app `infra-old-build-deploy-image` under `autoSync: true` — **do not delete it.**

Everything it had fallen behind on was caught up on 2026-08-31: the chart was brought in line with its sibling releases, the image raised to `alpine-v16.11.4` (tracking server 16.11.10), and the token reissued as a `glrt-` **instance runner**. That last part was mandatory: chart `0.91.0`'s entrypoint branches on the `glrt-` prefix and falls through to the registration path without it.

🔴 **That widened the scope from project to instance.** Only project 57 could use this runner before; now every project on gitlab-old can. A tag is a **routing label, not an authorization boundary** — anyone can put `tags: [build-deploy-image]` in their `.gitlab-ci.yml` and land here, and job pods run in the same namespace as `build-image` / `deploy-image`.

That removes any reason to pass `--exclude old-gitlab-runner`. The noise it avoided came from diffing a legacy values file against a current chart's keys, and all three releases now track the same chart.

**The image tag pin was dropped on 2026-09-01 as well.** All three releases now comment out `tag:` and follow the chart's `appVersion` (the effective tag is owned by `appVersion` in `Chart.yaml`), so the old runner no longer needs raising on its own. Until then the tag was hand-matched to the gitlab-old server version, but once HOP 16 put the server on 18.2.8 **keeping the pin was the wider gap of the two** — the pinned `alpine-v16.11.4` sits two majors behind, while the chart-tracked `alpine-v19.2.0` sits one major ahead. The two land on the same minor once the path reaches 19.2.5. See the "The k8s runner that has to move with the hops" section of [scripts/gitlab/old-upgrade/UPGRADE-PATH-en.md](../../scripts/gitlab/old-upgrade/UPGRADE-PATH.md).

`--exclude` patterns match as substrings against filenames, and multiple patterns can be supplied comma-separated (e.g., `--exclude test,legacy`). Matched files are also skipped from the backup directory copy.

<br/>

### Manual Upgrade

Without `upgrade.py`, edit `chart.version` in each marker file directly:

```yaml
# argocd/build-image.yaml
chart:
  repoURL: https://charts.gitlab.io
  name: gitlab-runner
  version: "<chart-version>"   # ← update to target version
```

The set of files must match `CONFIG.ARGOCD_PIN_FILES` in `upgrade.py`, and they move together. Commit and push, and ArgoCD applies it.

```bash
git add cicd/gitlab-runner/argocd
git commit -m "chore(gitlab-runner): bump chart"
git push
```

<br/>

## Build-job node isolation (build → k8s-compute-04)

Pin **CI build pods** to `k8s-compute-04` so that `docker buildx` / `dind` disk IO doesn't pummel the DB·etcd on the general workers (compute-01/02/03).

### Cluster-side prep (once)

```bash
kubectl taint node k8s-compute-04 dedicated=ci-build:NoSchedule
kubectl label node k8s-compute-04 role=ci-build
```

- `NoSchedule` taint: any pod without a matching toleration is pushed away → deploy runners / generic workloads automatically avoid compute-04.
- `role=ci-build` label: the build runner targets only this node via `node_selector`.

### `build.yaml` runners.config block

In [`values/build.yaml`](values/build.yaml) inside `runners.config`'s `[runners.kubernetes]` block:

```toml
[runners.kubernetes.node_selector]
  "role" = "ci-build"

[runners.kubernetes.node_tolerations]
  "dedicated=ci-build" = "NoSchedule"
```

- `node_selector` — schedule only on nodes labeled `role=ci-build` (i.e. compute-04).
- `node_tolerations` key format: `"<taint-key>=<taint-value>" = "<effect>"`.
  - taint `dedicated=ci-build:NoSchedule` → `"dedicated=ci-build" = "NoSchedule"`.

### `deploy.yaml` — no changes needed

The `NoSchedule` taint already keeps un-tolerated deploy pods off compute-04. No deploy-side config required.

### values.yaml top-level vs runners.config TOML

| Location | Target |
|---|---|
| `values.yaml` top-level `nodeSelector` / `tolerations` / `affinity` | The gitlab-runner **manager deployment pod** (the controller that picks up jobs and spawns build pods) |
| `runners.config` TOML's `[runners.kubernetes.node_selector]` / `node_tolerations` | The per-job **build pods** spawned by the manager |

This isolation only targets build pods, so only the latter is set. The manager pod has no toleration either, so the taint also keeps it off compute-04 — leaving it untouched is fine.

### Apply & verify

```bash
# Commit and push values/build.yaml; the infra-build-image app picks it up.
# To apply immediately, Sync infra-build-image from the ArgoCD UI.

# Run a CI build and watch where the spawned pod lands
kubectl -n gitlab-runner get pod -o wide -w
# build runner pods should land on k8s-compute-04; deploy pods should not.
```

<br/>

## Troubleshooting

1. **Runner not registering**
   - Verify `runnerToken` or `runnerRegistrationToken` is correct
   - Check GitLab URL is accessible from the cluster
   - Check pod logs: `kubectl logs -n gitlab-runner -l app=gitlab-runner`

2. **Permission denied in CI jobs**
   - Check runner's service account and RBAC settings
   - Verify PVC mounts if using shared storage

3. **Secret Checksum Changes**
   - It's normal to see secret checksum changes in `helmfile diff`
   - These changes don't affect the actual secret content
   - Safe to proceed with deployment

<br/>

## Security Notes

- Use dedicated runner tokens per runner instance
- Rotate runner tokens regularly
- Use `runnerToken` (new method) instead of deprecated `runnerRegistrationToken`
- Restrict runner tags to limit which jobs can run on each runner

<br/>

<details>
<summary>Install with Helm Directly</summary>

```bash
# Install
helm install -n gitlab-runner build-image -f values/build.yaml gitlab/gitlab-runner --create-namespace

# Upgrade
helm upgrade -n gitlab-runner build-image -f values/build.yaml gitlab/gitlab-runner
```

</details>

<br/>

## References

- https://gitlab.com/gitlab-org/charts/gitlab-runner
- https://docs.gitlab.com/runner/install/kubernetes.html
- https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md
