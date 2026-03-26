# Thanos Helm Chart

Manages Thanos highly available metrics system using Helmfile.

<br/>

## Directory Structure

```
thanos/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   ├── mgmt.yaml               # Single-cluster mode (default)
│   ├── mgmt-multicluster.yaml  # Multi-cluster federation mode
│   └── objstore.yml            # Object store secret template
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old local chart files
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Ingress controller (nginx)
- StorageClass (e.g., `local-path`)
- Object store secret (`thanos-objstore`) for cross-cluster metrics

<br/>

## Values Files

| File | Description |
|------|-------------|
| `values/mgmt.yaml` | Single-cluster mode with query, queryFrontend, compactor, storegateway |
| `values/mgmt-multicluster.yaml` | Multi-cluster federation via gRPC TLS (queries dev/qa clusters) |
| `values/objstore.yml` | Template for creating `thanos-objstore` secret |

<br/>

## Quick Start

### Single-Cluster Mode (default)

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

### Multi-Cluster Federation Mode

To deploy the multicluster query federation, uncomment the `thanos-multicluster` release in `helmfile.yaml`, or use helmfile selectors:

```bash
# Deploy with multicluster values
helmfile -l name=thanos-multicluster apply
```

<br/>

### Object Store Secret

Create the object store secret before deploying:

```bash
# Edit values/objstore.yml with your S3-compatible endpoint credentials
kubectl create secret generic thanos-objstore \
  --from-file=objstore.yml=values/objstore.yml \
  -n monitoring
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 16.0.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://github.com/bitnami/charts/tree/main/bitnami/thanos
- https://thanos.io/
- https://thanos.io/tip/operating/cross-cluster-tls-communication.md/
