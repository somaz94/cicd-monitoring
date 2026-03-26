# GitLab Runner Helm Chart

Manages GitLab Runner on Kubernetes using Helmfile. Supports multiple runner instances with different configurations.

<br/>

## Directory Structure

```
gitlab-runner/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   ├── build.yaml              # Build runner (3 replicas)
│   ├── deploy.yaml             # Deploy runner (2 replicas)
│   └── old-gitlab-runner.yaml  # Legacy runner (v0.70.3, 1 replica)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- GitLab instance with runner registration token

<br/>

## Runner Instances

| Release | Values File | Tags | Replicas | Version |
|---------|-------------|------|----------|---------|
| build-image | `values/build.yaml` | build-image | 3 | 0.87.0 |
| deploy-image | `values/deploy.yaml` | build-image | 2 | 0.87.0 |
| old-build-deploy-image | `values/old-gitlab-runner.yaml` | build-deploy-image | 1 | 0.70.3 |

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy all runners
helmfile apply

# Deploy specific runner only
helmfile -l name=build-image sync

# Delete specific runner
helmfile -l name=old-build-deploy-image destroy

# Delete all runners
helmfile destroy
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 0.88.0

# Rollback from backup
./upgrade.sh --rollback
```

> **Note:** The upgrade script updates releases matching the current Chart.yaml version.
> Releases with different versions (e.g., `old-build-deploy-image` at 0.70.3) are not affected.

<br/>

## Security Notes

- Use dedicated runner tokens per runner instance
- Rotate runner tokens regularly
- Use `runnerToken` (new method) instead of deprecated `runnerRegistrationToken`
- Restrict runner tags to limit which jobs can run on each runner

<br/>

## References

- https://gitlab.com/gitlab-org/charts/gitlab-runner
- https://docs.gitlab.com/runner/install/kubernetes.html
- https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md
