# prometheus-mysql-exporter

Exports MySQL instance (projectm-db) metrics to Prometheus.

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
├── helmfile.yaml
├── values/
│   └── projectm.yaml       # ProjectM DB connection info, ServiceMonitor settings
│   # └── projectb.yaml     # Add new project values file here
├── upgrade.sh
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

```bash
# First install (CRDs not yet present)
helmfile sync

# Subsequent updates
helmfile apply
```

<br/>

## Grafana Dashboard

1. Grafana → **Dashboards** → **New** → **Import**
2. Dashboard ID: `14057` (MySQL Overview — mysqld_exporter)
3. Data source: **Prometheus** → Import

<br/>

## Adding New Projects

To monitor MySQL for a new project:

1. Create a new values file in `values/` (e.g., `projectb.yaml`)
2. Add a new release entry in `helmfile.yaml`
3. Run `helmfile apply`

<br/>

## Reference

- [prometheus-mysql-exporter Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-mysql-exporter)
- [mysqld_exporter](https://github.com/prometheus/mysqld_exporter)
- [Grafana Dashboard 14057](https://grafana.com/grafana/dashboards/14057)
