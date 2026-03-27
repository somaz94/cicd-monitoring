# Loki AWS Helm Chart

Manages Grafana Loki on AWS EKS using Helmfile. Configured with AWS ALB ingress (shared ALB), SingleBinary deployment mode, and EFS/EBS persistence options.

<br/>

## Directory Structure

```
loki/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── examples/
│   └── efs-storage.yaml  # EFS StorageClass + PV example
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

## Deployment Modes

This chart supports multiple deployment modes. Currently configured for **SingleBinary** mode.

| Mode | Description | Use Case |
|------|-------------|----------|
| **SingleBinary** | All components in a single process (current) | Small to medium workloads |
| **SimpleScalable** | Read/Write/Backend separation | Medium to large workloads |
| **Distributed** | Full microservices deployment | Large-scale production |

<br/>

## Storage Options

Loki requires persistent storage for log data. Choose one:

| Storage | Driver | Access Mode | Use Case |
|---------|--------|-------------|----------|
| EFS | `efs.csi.aws.com` | ReadWriteMany | Multi-AZ, shared access, recommended for HA |
| EBS | `ebs.csi.aws.com` | ReadWriteOnce | Single-AZ, better IOPS performance |

### Setup Storage (if not using dynamic provisioning)

```bash
# EFS
kubectl apply -f examples/efs-storage.yaml
```

Then set the matching `storageClassName` in `values/mgmt.yaml`:

```yaml
# EFS (default)
singleBinary:
  persistence:
    storageClass: "efs-sc"
    accessModes:
      - ReadWriteMany

# EBS alternative
singleBinary:
  persistence:
    storageClass: "ebs-sc"
    accessModes:
      - ReadWriteOnce
```

<br/>

## Configuration

### AWS ALB Ingress (Shared ALB)

Loki gateway shares an ALB with other services using Ingress Group:

```yaml
gateway:
  ingress:
    enabled: true
    annotations:
      alb.ingress.kubernetes.io/group.name: example-shared-alb
      alb.ingress.kubernetes.io/group.order: "30"
      alb.ingress.kubernetes.io/healthcheck-path: /
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
    ingressClassName: "alb"
    hosts:
      - host: loki.example.com
```

| Annotation | Description |
|-----------|-------------|
| `group.name` | Same name as other services to share one ALB |
| `group.order` | Rule priority (ArgoCD: 10, Grafana: 20, Loki: 30, Prometheus: 40) |
| `healthcheck-path` | Loki gateway health endpoint: `/` |

> **Note:** Update `certificate-arn` with your ACM certificate ARN.

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Delete
helmfile destroy
```

<br/>

## Connecting Grafana to Loki

Add Loki as a data source in Grafana:

- **URL**: `http://loki-gateway.monitoring.svc.cluster.local`
- **Type**: Loki

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 6.60.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://github.com/grafana/loki
- https://grafana.com/docs/loki/latest/
- https://grafana.github.io/helm-charts
