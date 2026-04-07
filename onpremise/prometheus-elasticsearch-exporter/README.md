# prometheus-elasticsearch-exporter

Exports Elasticsearch cluster metrics to Prometheus.

<br/>

## Collected Metrics

- Cluster health status (green/yellow/red)
- Index count, document count, store size
- JVM heap usage and GC activity
- Thread pool queue and rejection counts
- Node-level CPU, memory, and disk usage

<br/>

## Directory Structure

```
prometheus-elasticsearch-exporter/
├── Chart.yaml
├── helmfile.yaml
├── values/
│   └── mgmt.yaml           # ES connection info, ServiceMonitor settings
├── upgrade.sh
├── backup/
└── README.md
```

<br/>

## Prerequisites

- kube-prometheus-stack must be installed first (ServiceMonitor CRD required)
- Elasticsearch cluster accessible within the K8s cluster
- Elasticsearch credentials stored as a K8s secret:

```bash
kubectl create secret generic elasticsearch-credentials \
  --from-literal=username=elastic \
  --from-literal=password=YOUR_PASSWORD \
  -n monitoring
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
2. Dashboard ID: `5969` (Elasticsearch Exporter Quickstart and Dashboard)
3. Data source: **Prometheus** → Import

Or use the custom dashboard in `../kube-prometheus-stack/dashboards/elasticsearch-dashboard.json`

<br/>

## Reference

- [prometheus-elasticsearch-exporter Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-elasticsearch-exporter)
- [elasticsearch_exporter](https://github.com/prometheus-community/elasticsearch_exporter)
- [Grafana Dashboard 5969](https://grafana.com/grafana/dashboards/5969)
