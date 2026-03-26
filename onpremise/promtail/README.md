# Promtail Helm Chart

Manages Promtail log collector agent using Helmfile. Promtail ships log contents to a Loki instance.

> **Note:** Promtail is deprecated by Grafana in favor of [Grafana Alloy](https://grafana.com/docs/alloy/). Consider migrating to Alloy for new deployments.

<br/>

## Directory Structure

```
promtail/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Loki instance (log destination)

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
./upgrade.sh --version 6.17.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://github.com/grafana/helm-charts/tree/main/charts/promtail
- https://grafana.com/docs/loki/latest/send-data/promtail/
- https://grafana.com/docs/alloy/ (successor)
