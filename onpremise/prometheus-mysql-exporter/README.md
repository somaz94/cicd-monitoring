# prometheus-mysql-exporter

Exports MySQL instance (example-project-db) metrics to Prometheus.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/example-project-mysql-exporter.yaml`, bumped by `upgrade.py` via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of [docs/ci-upgrade.md](../../../docs/ci-upgrade.md).

<br/>

## Collected Metrics

- Slow query statistics
- Connection count and status
- Query performance (QPS, Latency)
- InnoDB buffer pool usage
- Table lock wait time

<br/>

## Directory Structure

```
prometheus-mysql-exporter/
├── Chart.yaml
├── argocd/
│   └── example-project-mysql-exporter.yaml  # ArgoCD release metadata (chart version SSOT)
├── values.yaml                 # Upstream defaults (auto-managed by upgrade.py)
├── values/
│   └── dev-example-project.yaml       # ExampleProject DB connection info, ServiceMonitor settings
│   # └── dev-projectb.yaml # Add new project values file here
├── upgrade.py

├── backup/
└── README.md
```

<br/>

## Prerequisites

- kube-prometheus-stack must be installed first (ServiceMonitor CRD required)
- Create a read-only exporter user in MySQL:

```sql
CREATE USER 'exporter'@'%' IDENTIFIED BY 'password';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
FLUSH PRIVILEGES;
```

<br/>

## Installation

ArgoCD pull-managed. The chart version SSOT is `chart.version` in `argocd/example-project-mysql-exporter.yaml`, and `./upgrade.py` updates that file (there is no helmfile).

```bash
./upgrade.py --dry-run     # check for a newer chart
./upgrade.py               # bump the pin, re-sync Chart.yaml / values.yaml
```

Commit the pin and push to master; ArgoCD syncs that revision.


<br/>

## Grafana Dashboard

1. Grafana → **Dashboards** → **New** → **Import**
2. Dashboard ID: `14057` (MySQL Overview — mysqld_exporter)
3. Data source: **Prometheus** → Import

<br/>

## Adding New Projects

To monitor MySQL for a new project:

1. Create `values/dev-<project>.yaml` (e.g., `values/dev-projectb.yaml`)
2. Add one release marker file under `argocd/` — set `releaseName` / `chart` / `valueFile` to the new values file (use the existing `argocd/example-project-mysql-exporter.yaml` as the shape reference)
3. Commit and push to master; the ApplicationSet generates an `infra-<releaseName>` App


<br/>

## Reference

- [prometheus-mysql-exporter Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-mysql-exporter)
- [mysqld_exporter](https://github.com/prometheus/mysqld_exporter)
- [Grafana Dashboard 14057](https://grafana.com/grafana/dashboards/14057)
