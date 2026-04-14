# GitLab Runner Installation Guide

This guide describes how to install and configure GitLab Runner on Kubernetes using Helmfile.

<br/>

## Directory Structure

```
gitlab-runner/
├── Chart.yaml
├── helmfile.yaml
├── values.yaml
├── values/
│   ├── build.yaml
│   ├── deploy.yaml
│   ├── old-gitlab-runner.yaml
│   └── backup/
├── upgrade.sh
├── backup/
├── README.md
└── README-en.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
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
runnerToken: "your-runner-token"

## Or legacy registration token (deprecated)
# runnerRegistrationToken: "your-registration-token"

runners:
  tags: "build-image"
```

<br/>

### 3. Configure Helmfile

```yaml
repositories:
  - name: gitlab
    url: https://charts.gitlab.io

releases:
  - name: build-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner
    version: 0.81.0
    values:
      - values/build.yaml

  - name: deploy-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner
    version: 0.81.0
    values:
      - values/deploy.yaml
```

<br/>

### 4. Deploy with Helmfile

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy all runners
helmfile apply

# Deploy specific runner only
helmfile -l name=build-image sync
```

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

### Using upgrade.sh (Recommended)

An automated upgrade script that handles version checking, backup, diff, and rollback.

```bash
# Show help
./upgrade.sh -h

# Preview upgrade (no files changed)
./upgrade.sh --dry-run

# Upgrade to latest version (auto backup + apply)
./upgrade.sh

# Upgrade to a specific version
./upgrade.sh --version 0.82.0

# Exclude legacy values file (old-gitlab-runner.yaml targets the old chart 0.70.3)
./upgrade.sh --exclude old-gitlab-runner
./upgrade.sh --dry-run --exclude old-gitlab-runner

# List available backups
./upgrade.sh --list-backups

# Rollback to a previous version
./upgrade.sh --rollback

# Clean up old backups (keep last 5)
./upgrade.sh --cleanup-backups
```

The script performs the following steps:
1. Checks current installed version and helmfile releases
2. Fetches latest version from Helm repository
3. Downloads target `Chart.yaml` and `values.yaml`
4. Shows `Chart.yaml` diff
5. Shows `values.yaml` diff
6. Checks `values/*.yaml` for breaking changes (removed/new top-level keys)
7. Backs up current files to `backup/<timestamp>/` and applies upgrade

Note: The script updates all helmfile releases that match the current version. Releases pinned to a different version (e.g., `old-build-deploy-image`, chart `0.70.3`) are automatically skipped by the helmfile version substitution.

However, the Step 6 breaking-change check compares every file under `values/*.yaml`, so the legacy values file `values/old-gitlab-runner.yaml` will produce noisy false positives against the new chart's keys. Pass `--exclude` to skip it during upgrade:

```bash
./upgrade.sh --exclude old-gitlab-runner
```

`--exclude` patterns match as substrings against filenames, and multiple patterns can be supplied comma-separated (e.g., `--exclude old-gitlab-runner,test`). Matched files are also skipped from the backup directory copy.

<br/>

### Manual Upgrade

Update the `version` field for each release in `helmfile.yaml`:

```yaml
releases:
  - name: build-image
    chart: gitlab/gitlab-runner
    version: 0.82.0  # ← update to target version
```

```bash
helmfile diff
helmfile apply
```

<br/>

## Helmfile Commands Reference

```bash
helmfile lint                          # Check syntax
helmfile diff                          # Show differences
helmfile apply                         # Apply changes to all releases
helmfile -l name=build-image sync      # Sync specific release
helmfile -l name=old-release destroy   # Delete specific release
helmfile destroy                       # Delete all releases
helmfile status                        # Show status
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
