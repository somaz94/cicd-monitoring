# Loki Helm Chart

Manages Grafana Loki log aggregation system using Helmfile.

<br/>

## Directory Structure

```
loki/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old chart files and previous versions
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- StorageClass (e.g., `local-path`)

<br/>

## Deployment Modes

This chart supports multiple deployment modes. Currently configured for **SingleBinary** mode.

Available modes:
- **SingleBinary** - All components in a single process (current)
- **SimpleScalable** - Read/Write/Backend separation
- **Distributed** - Full microservices deployment

See `_backup/` for example values files of each mode.

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

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 6.30.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://github.com/grafana/loki
- https://grafana.com/docs/loki/latest/
- https://grafana.github.io/helm-charts
