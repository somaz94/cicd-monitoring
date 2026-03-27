# GitLab Runner AWS Helm Chart

Manages GitLab Runner on AWS EKS using Helmfile. Configured with ARM64 helper image and EKS node group selector.

<br/>

## Directory Structure

```
gitlab-runner-aws/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── build.yaml      # Build runner for AWS EKS (ARM64)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- AWS EKS cluster
- Helm 3
- Helmfile
- GitLab instance with runner registration token
- EKS node group with ARM64 instances (e.g., Graviton)

<br/>

## ARM64 Configuration

This runner is configured for ARM64 (Graviton) nodes on AWS EKS:

```yaml
# Node group selector
nodeSelector:
  eks.amazonaws.com/nodegroup: Example-NodeGroup-worker-node

# ARM64 helper image in runners config
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        helper_image = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.3.0"
        helper_image_flavor = "arm64"
```

> **Note:** When upgrading GitLab Runner, update the `helper_image` tag version accordingly.

<br/>

## Runner Token Setup

GitLab Runner requires a **runner authentication token** to register with the GitLab instance.

1. Go to GitLab **Admin Area** > **CI/CD** > **Runners** > **New instance runner**
   - Or for project-level: **Settings** > **CI/CD** > **Runners** > **New project runner**
2. Configure the runner (tags, description, etc.) and click **Create runner**
3. Copy the runner authentication token (starts with `glrt-`)
4. Set in `values/build.yaml`:

```yaml
runnerToken: "glrt-xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

<br/>

## Quick Start

<br/>

### 1. Deploy Runner

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply
```

<br/>

### 2. Verify Runner Registration

```bash
# Check runner pods
kubectl get pods -n gitlab-runner

# Check runner logs
kubectl logs -n gitlab-runner -l app=gitlab-runner --tail=50
```

Then go to GitLab **Admin Area** > **CI/CD** > **Runners** to confirm the runner is registered and online.

<br/>

### 3. Use in `.gitlab-ci.yml`

```yaml
build:
  stage: build
  tags:
    - build-image-aws    # Matches runner tag
  script:
    - echo "Running on AWS EKS self-hosted GitLab Runner (ARM64)"
    - docker build -t myimage .
```

<br/>

## Cleanup

```bash
# Delete runner
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

<br/>

## References

- https://gitlab.com/gitlab-org/charts/gitlab-runner
- https://docs.gitlab.com/runner/install/kubernetes.html
- https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md
