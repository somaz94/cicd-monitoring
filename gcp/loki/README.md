# Loki GCP Helm Chart

Manages Grafana Loki on GCP GKE using Helmfile. Configured with SingleBinary deployment mode, nginx ingress (or GKE Ingress alternative), and Filestore/PD/NFS persistence options.

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

## Deployment Modes

Currently configured for **SingleBinary** mode.

| Mode | Description | Use Case |
|------|-------------|----------|
| **SingleBinary** | All components in a single process (current) | Small to medium workloads |
| **SimpleScalable** | Read/Write/Backend separation | Medium to large workloads |
| **Distributed** | Full microservices deployment | Large-scale production |

<br/>

## Storage Options

| Storage | Driver | Access Mode | Use Case |
|---------|--------|-------------|----------|
| Filestore CSI | `filestore.csi.storage.gke.io` | ReadWriteMany | Multi-node, shared access, recommended |
| PD CSI | `pd.csi.storage.gke.io` | ReadWriteOnce | Single-node, better IOPS |
| NFS | `nfs-client` | ReadWriteMany | Manual NFS server setup |

<br/>

## Quick Start

```bash
helmfile lint     # Validate
helmfile diff     # Preview
helmfile apply    # Deploy
helmfile destroy  # Delete
```

<br/>

## Connecting Grafana to Loki

- **URL**: `http://loki-gateway.monitoring.svc.cluster.local`
- **Type**: Loki

<br/>

## Upgrade

```bash
./upgrade.sh              # Upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --rollback   # Restore from backup
```

<br/>

## References

- https://github.com/grafana/loki
- https://grafana.com/docs/loki/latest/
- https://grafana.github.io/helm-charts
