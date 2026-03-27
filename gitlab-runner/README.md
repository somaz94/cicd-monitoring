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

## Runner Token Setup

GitLab Runner requires a **runner authentication token** to register with the GitLab instance.

<br/>

### Option 1: Runner Token (Recommended, GitLab 15.10+)

1. Go to GitLab **Admin Area** > **CI/CD** > **Runners** > **New instance runner**
   - Or for project-level: **Settings** > **CI/CD** > **Runners** > **New project runner**
2. Configure the runner (tags, description, etc.) and click **Create runner**
3. Copy the runner authentication token (starts with `glrt-`)
4. Set in values file:

```yaml
runnerToken: "glrt-xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

<br/>

### Option 2: Registration Token (Deprecated)

> **Warning:** Registration tokens are deprecated since GitLab 15.6 and will be removed in future versions.

1. Go to GitLab **Admin Area** > **CI/CD** > **Runners** and copy the registration token
2. Set in values file:

```yaml
runnerRegistrationToken: "GR1348941xxxxxxxxxxxxxxxxxxxxxx"
```

<br/>

## Runner Configuration

Each runner instance is configured via its values file under `values/`. Key configuration options:

```yaml
# GitLab server URL
gitlabUrl: http://gitlab.example.com/

# Runner token
runnerToken: "glrt-xxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Number of runner pods
replicas: 2

# Maximum concurrent jobs
concurrent: 10

# Runner tags (used in .gitlab-ci.yml)
runners:
  tags: "build-image"

# Kubernetes executor configuration
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "{{.Release.Namespace}}"
        image = "alpine"
```

<br/>

## Quick Start

<br/>

### 1. Deploy Runners

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

### 2. Verify Runner Registration

```bash
# Check runner pods
kubectl get pods -n gitlab-runner

# Check runner logs
kubectl logs -n gitlab-runner -l app=gitlab-runner --tail=50
```

Then go to GitLab **Admin Area** > **CI/CD** > **Runners** to confirm the runners are registered and online.

<br/>

### 3. Use in `.gitlab-ci.yml`

```yaml
build:
  stage: build
  tags:
    - build-image    # Matches runner tag
  script:
    - echo "Running on self-hosted GitLab Runner"
    - docker build -t myimage .

deploy:
  stage: deploy
  tags:
    - build-image
  script:
    - kubectl apply -f manifests/
```

<br/>

### 4. Manage Individual Runners

```bash
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
