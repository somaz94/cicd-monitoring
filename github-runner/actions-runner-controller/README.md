# Actions Runner Controller (ARC) Helm Chart

Manages GitHub Actions self-hosted runners on Kubernetes using Helmfile. Uses the legacy summerwind/actions-runner-controller chart.

<br/>

## Directory Structure

```
actions-runner-controller/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── runner.yaml     # Controller configuration
├── examples/
│   └── runner-cr.yaml  # RunnerDeployment CR example
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (CRDs, etc.)
└── README.md
```

<br/>

## GitHub Actions Runner Helm Chart Components

There are three main Helm chart components for managing GitHub Actions runners on Kubernetes:

| Component | Role | Key Features | Use Case |
|-----------|------|--------------|----------|
| `actions-runner-controller` | Automates runner deployment and management on Kubernetes | Controls runner creation/deletion, dynamic scaling via Kubernetes HPA | Managing runners dynamically across multiple repositories |
| `gha-runner-scale-set-controller` | Implements GitHub Scale Set Runner in Kubernetes | Manages runners in scale set units, optimizes efficiency | Unified runner management in large-scale CI/CD environments |
| `gha-runner-scale-set` | Defines specific configuration and deployment resources for Scale Set Runners | Integrates with Scale Set API for detailed runner group configuration and scaling | Grouping and efficiently scaling runners based on workflow request volume |

<br/>

### actions-runner-controller (This Chart)

- Manages GitHub Actions runners on Kubernetes clusters
- Handles automatic provisioning and lifecycle management
- Supports repository, organization, and enterprise level deployments
- Supports auto-scaling using Kubernetes HPA

<br/>

### gha-runner-scale-set-controller

- Manages large-scale runner deployments
- Leverages Scale Set Runners feature
- Provides efficient runner management through a single endpoint
- Integrates with GitHub's Scale Set Runners API

<br/>

### gha-runner-scale-set

- Configures and deploys runner scale sets
- Controls scaling and lifecycle through GitHub Actions API
- Optimizes communication between workflows and runners

> **Summary:** `actions-runner-controller` is the general-purpose Kubernetes runner controller.
> `gha-runner-scale-set-controller` and `gha-runner-scale-set` target large-scale environments using Scale Sets for more efficient management.
> For small-scale environments, `actions-runner-controller` is sufficient.

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- GitHub PAT or GitHub App credentials

<br/>

## Authentication Setup

Choose **one** of the following authentication methods. GitHub App is recommended for better security and permission management.

<br/>

### Option 1: GitHub PAT (Personal Access Token)

1. Go to GitHub **Settings** > **Developer settings** > **Personal Access Tokens**
2. Create a token with the required scopes:

| Level | Required Scopes |
|-------|----------------|
| Repository | `repo`, `workflow` |
| Organization | `read:org`, `admin:org`, `workflow` |
| Enterprise | `admin:enterprise`, `workflow` |

3. Set the token in `values/runner.yaml`:

```yaml
authSecret:
  enabled: true
  create: true
  github_token: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Option 2: GitHub App (Recommended)

1. Go to GitHub **Settings** > **Developer settings** > **GitHub Apps** > **New GitHub App**
2. Configure the app with the following **Repository permissions**:
   - **Actions**: Read & Write
   - **Administration**: Read & Write
   - **Metadata**: Read-only
3. After creation, note the **App ID** from the "About" section
4. Click **Install App** and install it to your organization/account
5. Note the **Installation ID** from the URL: `https://github.com/organizations/YOUR-ORG/settings/installations/INSTALLATION_ID`
6. Generate a **Private Key** from the app settings page
7. Set the credentials in `values/runner.yaml`:

```yaml
authSecret:
  enabled: true
  create: true
  github_app_id: "123456"
  github_app_installation_id: "987654321"
  github_app_private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA....
    -----END RSA PRIVATE KEY-----
```

<br/>

## Quick Start

<br/>

### 1. Deploy the Controller

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy controller
helmfile apply
```

<br/>

### 2. Deploy Runner Instances

After installing the controller, create runner instances using the RunnerDeployment CR:

```bash
# Apply runner CR
kubectl apply -f examples/runner-cr.yaml

# Check controller status
kubectl get pods -n actions-runner-system

# Check runner status
kubectl get runners -n actions-runner-system
kubectl get runnerdeployments -n actions-runner-system
```

<br/>

### 3. Use in GitHub Actions Workflow

```yaml
jobs:
  build:
    # Use self-hosted runner
    runs-on: self-hosted
    # Or specify labels
    # runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner"
```

<br/>

### 4. Verify Runner Connection

Go to your repository **Settings** > **Actions** > **Runners** to confirm the runner is registered and online.

<br/>

## Cleanup

```bash
# Delete runner CR first
kubectl delete -f examples/runner-cr.yaml

# Delete controller
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
./upgrade.sh --version 0.23.7

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## Migration Note

This chart uses the **legacy ARC (summerwind)**, which is no longer actively developed.
GitHub now maintains the official [actions-runner-controller](https://github.com/actions/actions-runner-controller) with the `gha-runner-scale-set` chart.
Consider migrating to the new ARC for active support and new features.

<br/>

## References

- https://github.com/actions/actions-runner-controller
- https://github.com/actions/actions-runner-controller/releases
- https://docs.github.com/en/actions/hosting-your-own-runners
