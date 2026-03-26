# ArgoCD

<br/>

## Overview

ArgoCD deployment using Helmfile with the official [argo-cd](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd) Helm chart.

<br/>

## Components

| Component | Version |
|-----------|---------|
| Helm Chart | `argo-cd` v9.4.15 |
| ArgoCD | v3.3.4 |
| Redis HA | v4.34.11 (dependency) |

<br/>

## Directory Structure

```
argocd/
├── Chart.yaml          # Chart metadata and dependencies
├── helmfile.yaml       # Helmfile release configuration
├── .helmignore         # Helm ignore patterns
├── values/
│   └── mgmt.yaml       # Management cluster values
├── upgrade.sh          # Automated upgrade script
└── README.md
```

<br/>

## Features

- **HA Mode**: Redis HA with 3 replicas for high availability
- **SSO**: GitLab Dex connector for single sign-on
- **Notifications**: Slack integration with 7 notification templates
- **Performance Tuning**: Optimized reconciliation, status processors, and kubectl parallelism
- **RBAC**: Role-based access control with org-admin policies

<br/>

## Installation

```bash
# Add Helm repositories
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add dandydeveloper https://dandydeveloper.github.io/charts/
helm repo update

# Install with Helmfile
helmfile apply
```

<br/>

## Upgrade

Use the automated upgrade script:

```bash
# Check and upgrade to latest version
./upgrade.sh

# Preview changes without applying
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 10.0.0

# List available backups
./upgrade.sh --list-backups

# Rollback to a previous version
./upgrade.sh --rollback

# Clean up old backups (keeps last 5)
./upgrade.sh --cleanup-backups
```

<br/>

## Values Configuration

The `values/mgmt.yaml` file contains the full configuration for the management cluster, including:

- Server ingress with TLS
- Dex SSO configuration (GitLab connector)
- Controller resource limits and performance tuning
- Slack notification templates and triggers
- RBAC policies

> **Note**: Sensitive values (domains, tokens, SSH keys, passwords) are replaced with example placeholders. Update them before deploying.

<br/>

## Helm Lint

```bash
# Basic lint
helm lint . -f values/mgmt.yaml

# Strict mode
helm lint . -f values/mgmt.yaml --strict

# Debug mode
helm lint . -f values/mgmt.yaml --debug

# Lint all values files
for f in values/*.yaml; do
  echo "=== Linting $f ==="
  helm lint . -f "$f" --strict
done
```
