# ArgoCD On-Premise Helm Chart

Manages ArgoCD on on-premise Kubernetes using Helmfile. Configured with nginx ingress, GitLab SSO (Dex), Slack notifications, and Redis HA.

<br/>

## Directory Structure

```
argocd/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (local chart templates, dependencies)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Nginx Ingress Controller

<br/>

## Features

- **HA Mode**: Redis HA with 3 replicas for high availability
- **SSO**: GitLab Dex connector for single sign-on
- **Notifications**: Slack integration with 7 notification templates
- **Performance Tuning**: Optimized reconciliation, status processors, and kubectl parallelism
- **RBAC**: Role-based access control with org-admin policies

<br/>

## Quick Start

```bash
helmfile lint     # Validate
helmfile diff     # Preview
helmfile apply    # Deploy
helmfile destroy  # Delete
```

<br/>

## Upgrade

```bash
./upgrade.sh              # Upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --version 10.0.0  # Specific version
./upgrade.sh --rollback   # Restore from backup
```

<br/>

## Values Configuration

The `values/mgmt.yaml` contains:

- Server ingress with TLS
- Dex SSO configuration (GitLab connector)
- Controller resource limits and performance tuning
- Slack notification templates and triggers
- RBAC policies

> **Note**: Sensitive values (domains, tokens, SSH keys, passwords) are replaced with example placeholders. Update them before deploying.

<br/>

## References

- https://argo-cd.readthedocs.io/en/stable/
- https://github.com/argoproj/argo-helm
