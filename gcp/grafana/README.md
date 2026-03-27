# Grafana GCP Helm Chart

Manages Grafana on GCP GKE using Helmfile. Configured with nginx ingress (or GKE Ingress alternative) and Filestore/PD/NFS persistence options.

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
│   ├── gke-ingress.yaml        # GKE Ingress + ManagedCertificate + BackendConfig
│   ├── pd-csi-pv.yaml          # PD CSI PersistentVolume example
│   ├── pd-csi-sc.yaml          # PD CSI StorageClass example
│   ├── fs-csi-pv.yaml          # Filestore CSI PersistentVolume example
│   ├── fs-csi-sc.yaml          # Filestore CSI StorageClass example
│   ├── fs-csi-sc-shared-vpc.yaml  # Filestore CSI StorageClass for Shared VPC
│   ├── nfs-pv.yaml             # NFS PersistentVolume example
│   └── nfs-sc-README.md        # NFS Provisioner setup guide
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (manual manifests)
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

## Storage Options

| Storage | Driver | Access Mode | Use Case |
|---------|--------|-------------|----------|
| Filestore CSI | `filestore.csi.storage.gke.io` | ReadWriteMany | Multi-node, shared access, recommended |
| PD CSI | `pd.csi.storage.gke.io` | ReadWriteOnce | Single-node, better IOPS |
| NFS | `nfs-client` | ReadWriteMany | Manual NFS server setup |

### Setup Storage

```bash
# Option A: Filestore CSI (default)
kubectl apply -f examples/fs-csi-sc.yaml

# Option B: PD CSI
kubectl apply -f examples/pd-csi-sc.yaml

# Option C: NFS (see examples/nfs-sc-README.md for provisioner setup)
```

<br/>

## Quick Start

```bash
# Deploy
helmfile apply

# Get initial admin password (set in values/mgmt.yaml)
# Default: admin / exampleAdminPassword

# Access: https://grafana.somaz.example.com
```

<br/>

### Add Data Sources

- **Prometheus**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Loki**: `http://loki-gateway.monitoring.svc.cluster.local`

<br/>

## Upgrade

```bash
./upgrade.sh              # Upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --rollback   # Restore from backup
```

<br/>

## References

- https://grafana.com/docs/grafana/latest/
- https://github.com/grafana-community/helm-charts
