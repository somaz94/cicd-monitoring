# ArgoCD AWS Helm Chart

Manages ArgoCD on AWS EKS using Helmfile. Configured with AWS ALB ingress, performance tuning, and Slack notifications.

<br/>

## Directory Structure

```
argocd/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── examples/
│   └── repo-secret.yaml  # Git repository Secret example
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (manual manifests)
└── README.md
```

<br/>

## Prerequisites

- AWS EKS cluster
- Helm 3
- Helmfile
- AWS ALB Ingress Controller (aws-load-balancer-controller)
- ACM certificate for HTTPS

<br/>

## Key Features

| Feature | Configuration |
|---------|--------------|
| Ingress | AWS ALB with HTTPS (ACM certificate) |
| Performance | Optimized controller processors, kubectl parallelism, repo server timeouts |
| Notifications | Slack integration (deploy, degraded, sync-failed, out-of-sync) |
| SSO | GitHub Dex connector (commented, ready to enable) |
| RBAC | org-admin role with full access |

<br/>

## Configuration

### AWS ALB Ingress

The ingress is configured to use AWS Application Load Balancer:

```yaml
server:
  ingress:
    enabled: true
    annotations:
      alb.ingress.kubernetes.io/backend-protocol: HTTPS
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
    ingressClassName: "alb"
```

> **Note:** Update `certificate-arn` with your ACM certificate ARN.

<br/>

### Git Repository Registration

Register private Git repositories for ArgoCD to access:

```bash
# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/argocd-repo-key -C "argocd"

# Register the public key in your Git provider (GitHub/GitLab)

# Apply repository secret
kubectl apply -f examples/repo-secret.yaml -n argocd
```

<br/>

### Slack Notifications

Notifications are pre-configured for the following events:

| Trigger | Description |
|---------|-------------|
| `on-deployed` | Application synced and healthy |
| `on-health-degraded` | Application health degraded |
| `on-sync-failed` | Sync operation failed |
| `on-sync-status-out-of-sync` | Application out of sync |

Update the Slack bot token in `values/mgmt.yaml`:

```yaml
notifications:
  secret:
    items:
      slack-token: "xoxb-your-slack-bot-token"
```

<br/>

## Quick Start

<br/>

### 1. Deploy ArgoCD

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply
```

<br/>

### 2. Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

<br/>

### 3. Access ArgoCD UI

Open `https://argocd.somaz.example.com` in your browser (replace with your actual domain).

<br/>

### 4. Register Git Repository

```bash
kubectl apply -f examples/repo-secret.yaml -n argocd
```

<br/>

## Cleanup

```bash
# Delete ArgoCD
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
./upgrade.sh --version 9.5.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://argo-cd.readthedocs.io/en/stable/
- https://github.com/argoproj/argo-helm
- https://github.com/argoproj/argo-cd/releases
- https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#aws-application-load-balancers-albs-and-classic-elb-http-mode
