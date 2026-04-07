# prometheus-redis-exporter

Exports Redis instance metrics to Prometheus.

<br/>

## Collected Metrics

- Memory usage (used_memory, maxmemory)
- Connection count (connected_clients)
- Command throughput (commands/sec)
- Key hit/miss ratio (keyspace_hits, keyspace_misses)
- Replication status

<br/>

## Directory Structure

```
prometheus-redis-exporter/
├── Chart.yaml
├── helmfile.yaml
├── values/
│   └── example-project.yaml   # Project Redis connection info, ServiceMonitor settings
│   # └── another-project.yaml # Add new project values file here
├── upgrade.sh
├── backup/
└── README.md
```

<br/>

## Prerequisites

- kube-prometheus-stack must be installed first (ServiceMonitor CRD required)

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
2. Dashboard ID: `11835` (Redis Dashboard for Prometheus — redis_exporter)
3. Data source: **Prometheus** → Import

Or use the custom dashboard in `../kube-prometheus-stack/dashboards/redis-dashboard.json`

<br/>

## Adding New Projects

To monitor Redis for a new project:

1. Create a new values file in `values/` (e.g., `another-project.yaml`)
2. Add a new release entry in `helmfile.yaml`
3. Run `helmfile apply`

<br/>

## Reference

- [prometheus-redis-exporter Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-redis-exporter)
- [redis_exporter](https://github.com/oliver006/redis_exporter)
- [Grafana Dashboard 11835](https://grafana.com/grafana/dashboards/11835)
