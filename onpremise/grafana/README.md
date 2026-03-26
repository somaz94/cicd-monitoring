# Grafana

<br/>

## Overview

Grafana deployment using Helmfile with the official [grafana](https://github.com/grafana/helm-charts/tree/main/charts/grafana) Helm chart.

<br/>

## Components

| Component | Version |
|-----------|---------|
| Helm Chart | `grafana` v8.5.1 |
| Grafana | v11.2.0 |

<br/>

## Directory Structure

```
grafana/
├── Chart.yaml          # Chart metadata
├── helmfile.yaml       # Helmfile release configuration
├── values/
│   └── mgmt.yaml       # Management cluster values
├── dashboards/         # Custom dashboard JSON files
│   ├── custom-dashboard.json
│   ├── 12019_rev2.json
│   └── 13770_rev1.json
├── upgrade.sh          # Automated upgrade script
├── _backup/            # Previous bundled chart files
└── README.md
```

<br/>

## Features

- **Persistence**: PVC-based storage (10Gi)
- **Ingress**: Nginx ingress with SSL redirect
- **Monitoring**: Prometheus ServiceMonitor integration
- **Security**: Container security context with dropped capabilities
- **Dashboards**: Custom JSON dashboards for Kubernetes and Prometheus metrics

<br/>

## Installation

```bash
# Install with Helmfile
helmfile apply
```

<br/>

## Upgrade

```bash
# Check and upgrade to latest version
./upgrade.sh

# Preview changes without applying
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 9.0.0

# Rollback to a previous version
./upgrade.sh --rollback
```

<br/>

## Values Configuration

The `values/mgmt.yaml` file contains the full configuration including:

- Ingress with Nginx class
- Persistence with PVC
- ServiceMonitor for Prometheus
- Node selector and tolerations
- Datasource configuration (commented examples)

> **Note**: Sensitive values (admin password, domains) are replaced with example placeholders. Update them before deploying.

<br/>

## Dashboards

Custom dashboards are stored in the `dashboards/` directory:

| Dashboard | Description |
|-----------|-------------|
| `12019_rev2.json` | Kubernetes metrics dashboard |
| `13770_rev1.json` | Prometheus metrics dashboard |
| `custom-dashboard.json` | Placeholder for custom dashboards |

<br/>

## Reference

- [Grafana Helm Charts](https://github.com/grafana/helm-charts)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
