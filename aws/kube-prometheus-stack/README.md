# Kube Prometheus Stack AWS Helm Chart

Manages kube-prometheus-stack on AWS EKS using Helmfile. Includes Prometheus, Alertmanager, Prometheus Operator, node-exporter, and kube-state-metrics with AWS ALB ingress (shared ALB) and EFS/EBS persistence options.

<br/>

## Directory Structure

```
kube-prometheus-stack/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── examples/
│   ├── efs-storage.yaml        # EFS StorageClass + PV example
│   └── extra-scrape-configs.yaml  # Additional scrape config example
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (standalone prometheus chart)
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

## Included Components

| Component | Enabled | Description |
|-----------|---------|-------------|
| Prometheus | Yes | Metrics collection and storage |
| Alertmanager | Yes | Alert routing and notifications |
| Prometheus Operator | Yes | Manages Prometheus lifecycle via CRDs |
| kube-state-metrics | Yes | Kubernetes object metrics |
| node-exporter | Yes | Node-level metrics |
| Grafana | No | Managed separately (see `../grafana/`) |

<br/>

## Storage Options

Prometheus requires persistent storage for metrics data. Choose one:

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
prometheusSpec:
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: efs-sc
        accessModes: ["ReadWriteMany"]

# EBS alternative
prometheusSpec:
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: ebs-sc
        accessModes: ["ReadWriteOnce"]
```

<br/>

## Configuration

### AWS ALB Ingress (Shared ALB)

Prometheus shares an ALB with other services using Ingress Group:

```yaml
prometheus:
  ingress:
    enabled: true
    annotations:
      alb.ingress.kubernetes.io/group.name: example-shared-alb
      alb.ingress.kubernetes.io/group.order: "40"
      alb.ingress.kubernetes.io/healthcheck-path: /-/healthy
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
    ingressClassName: "alb"
    hosts:
      - prometheus.somaz.example.com
```

| Annotation | Description |
|-----------|-------------|
| `group.name` | Same name as other services to share one ALB |
| `group.order` | Rule priority (ArgoCD: 10, Grafana: 20, Loki: 30, Prometheus: 40) |
| `healthcheck-path` | Prometheus health endpoint: `/-/healthy` |

> **Note:** Update `certificate-arn` with your ACM certificate ARN.

<br/>

### EKS-Specific Settings

Some Kubernetes control plane components are not accessible on EKS:

```yaml
kubeControllerManager:
  enabled: false    # Not accessible on EKS
kubeScheduler:
  enabled: false    # Not accessible on EKS
kubeEtcd:
  enabled: false    # Not accessible on EKS
```

<br/>

### Additional Scrape Configs

To monitor custom application metrics, see `examples/extra-scrape-configs.yaml`:

```yaml
prometheusSpec:
  additionalScrapeConfigs:
    - job_name: 'api-prometheus'
      metrics_path: /metrics
      static_configs:
        - targets: ['api.somaz.example.com']
```

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

## Connecting Grafana

Add Prometheus as a data source in Grafana:

- **URL**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Type**: Prometheus

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 83.0.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## Migration from Standalone Prometheus

This chart replaces the standalone `prometheus-community/prometheus` chart. Old configuration files are preserved in `_backup/`. Key differences:

| Feature | Standalone Prometheus | kube-prometheus-stack |
|---------|----------------------|----------------------|
| Prometheus Operator | No | Yes (CRD-based) |
| ServiceMonitor CRDs | No | Yes |
| Alertmanager | Separate sub-chart | Integrated |
| Recording Rules | Manual ConfigMap | PrometheusRule CRD |
| Grafana Dashboards | Manual | Auto-provisioned (if enabled) |

<br/>

## References

- https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- https://prometheus.io/docs/
- https://github.com/prometheus-operator/kube-prometheus
