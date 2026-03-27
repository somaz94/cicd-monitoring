# Kube Prometheus Stack GCP Helm Chart

Manages kube-prometheus-stack on GCP GKE using Helmfile. Includes Prometheus, Alertmanager, Prometheus Operator, node-exporter, and kube-state-metrics with nginx ingress (or GKE Ingress alternative) and Filestore/PD/NFS persistence options.

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
│   ├── gke-ingress.yaml               # GKE Ingress + ManagedCertificate + BackendConfig
│   ├── extra-scrape-configs-values.yaml  # Additional scrape config example
│   ├── pd-csi-pv-prometheus-*.yaml    # PD CSI PV examples
│   ├── fs-csi-pv-prometheus-*.yaml    # Filestore CSI PV examples
│   ├── fs-csi-sc.yaml                 # Filestore CSI StorageClass
│   ├── fs-csi-sc-shared-vpc.yaml      # Filestore CSI SC for Shared VPC
│   ├── nfs-pv-prometheus-*.yaml       # NFS PV examples
│   └── nfs-sc-README.md               # NFS Provisioner setup guide
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (standalone prometheus chart)
└── README.md
```

<br/>

## Prerequisites

- GCP GKE cluster
- Helm 3
- Helmfile
- Nginx Ingress Controller (or GKE Ingress)
- Filestore CSI driver, PD CSI driver, or NFS provisioner for persistence

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

| Storage | Driver | Access Mode | Use Case |
|---------|--------|-------------|----------|
| Filestore CSI | `filestore.csi.storage.gke.io` | ReadWriteMany | Multi-node, shared access, recommended |
| PD CSI | `pd.csi.storage.gke.io` | ReadWriteOnce | Single-node, better IOPS |
| NFS | `nfs-client` | ReadWriteMany | Manual NFS server setup |

<br/>

## GKE-Specific Settings

Some Kubernetes control plane components are not accessible on GKE:

```yaml
kubeControllerManager:
  enabled: false    # Not accessible on GKE
kubeScheduler:
  enabled: false    # Not accessible on GKE
kubeEtcd:
  enabled: false    # Not accessible on GKE
kubeDns:
  enabled: true     # GKE uses kube-dns (not CoreDNS)
```

<br/>

## Quick Start

```bash
helmfile lint     # Validate
helmfile diff     # Preview
helmfile apply    # Deploy
helmfile destroy  # Delete
```

<br/>

## Connecting Grafana

- **URL**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Type**: Prometheus

<br/>

## Upgrade

```bash
./upgrade.sh              # Upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --rollback   # Restore from backup
```

<br/>

## Migration from Standalone Prometheus

This chart replaces the standalone `prometheus-community/prometheus` chart. Old files are in `_backup/`.

| Feature | Standalone Prometheus | kube-prometheus-stack |
|---------|----------------------|----------------------|
| Prometheus Operator | No | Yes (CRD-based) |
| ServiceMonitor CRDs | No | Yes |
| Alertmanager | Separate sub-chart | Integrated |
| Recording Rules | Manual ConfigMap | PrometheusRule CRD |

<br/>

## References

- https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- https://prometheus.io/docs/
- https://github.com/prometheus-operator/kube-prometheus
