# Grafana AWS Helm Chart

Manages Grafana on AWS EKS using Helmfile. Configured with AWS ALB ingress (shared ALB) and EFS/EBS persistence options.

<br/>

## Directory Structure

```
grafana/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── examples/
│   ├── efs-storage.yaml  # EFS StorageClass + PV example
│   └── ebs-storage.yaml  # EBS StorageClass + PV example
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
- EFS CSI driver or EBS CSI driver for persistence

<br/>

## Storage Options

Grafana requires persistent storage for dashboards and settings. Choose one:

| Storage | Driver | Access Mode | Use Case |
|---------|--------|-------------|----------|
| EFS | `efs.csi.aws.com` | ReadWriteMany | Multi-AZ, shared access, recommended for HA |
| EBS | `ebs.csi.aws.com` | ReadWriteOnce | Single-AZ, better IOPS performance |

### Setup Storage (if not using dynamic provisioning)

```bash
# Option A: EFS (default)
kubectl apply -f examples/efs-storage.yaml

# Option B: EBS
kubectl apply -f examples/ebs-storage.yaml
```

Then set the matching `storageClassName` in `values/mgmt.yaml`:

```yaml
# EFS
persistence:
  storageClassName: efs-sc
  accessModes:
    - ReadWriteMany

# EBS
persistence:
  storageClassName: ebs-sc
  accessModes:
    - ReadWriteOnce
```

<br/>

## Configuration

### AWS ALB Ingress (Shared ALB)

Grafana shares an ALB with other services using Ingress Group:

```yaml
ingress:
  enabled: true
  annotations:
    alb.ingress.kubernetes.io/group.name: example-shared-alb
    alb.ingress.kubernetes.io/group.order: "20"
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
  ingressClassName: "alb"
  hosts:
    - grafana.example.com
```

| Annotation | Description |
|-----------|-------------|
| `group.name` | Same name as other services to share one ALB |
| `group.order` | Rule priority (ArgoCD: 10, Grafana: 20, etc.) |
| `healthcheck-path` | Grafana health endpoint: `/api/health` |

> **Note:** Update `certificate-arn` with your ACM certificate ARN.

<br/>

## Quick Start

<br/>

### 1. Deploy Grafana

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

The default admin password is set in `values/mgmt.yaml`:

```yaml
adminUser: admin
adminPassword: exampleAdminPassword
```

> **Important:** Change `adminPassword` before deploying to production.

<br/>

### 3. Access Grafana UI

Open `https://grafana.example.com` in your browser (replace with your actual domain).

<br/>

### 4. Add Data Sources

After deployment, configure data sources in Grafana UI:
- **Prometheus**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Loki**: `http://loki-gateway.monitoring.svc.cluster.local`

<br/>

## Cleanup

```bash
# Delete Grafana
helmfile destroy

# Note: PV/PVC and storage resources must be cleaned up separately
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 10.6.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://grafana.com/docs/grafana/latest/
- https://github.com/grafana-community/helm-charts
- https://github.com/grafana-community/helm-charts/releases
