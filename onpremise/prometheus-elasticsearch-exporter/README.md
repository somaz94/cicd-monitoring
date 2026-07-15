# prometheus-elasticsearch-exporter

Exports ECK-managed Elasticsearch metrics (in the logging namespace) to Prometheus.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/prometheus-elasticsearch-exporter.yaml`, bumped by `upgrade.py` via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of [docs/ci-upgrade.md](../../../docs/ci-upgrade.md).

<br/>

## Collected Metrics

- Cluster health and node status
- Index statistics (docs, store size, indices_settings/mappings)
- Shard allocation and status
- Snapshot statistics
- JVM heap and GC usage

<br/>

## Directory Structure

```
prometheus-elasticsearch-exporter/
├── Chart.yaml
├── helmfile.yaml
├── values/
│   └── dev.yaml                # ES connection info (es.uri), ServiceMonitor settings
├── upgrade.py
├── backup/
└── README.md
```

<br/>

## Prerequisites

- kube-prometheus-stack must be installed first (ServiceMonitor CRD required)
- The ECK-managed Elasticsearch (`../../logging/elasticsearch/`) must be running in the logging namespace
- The connection user is fixed to the ECK superuser `elastic`, with the password sourced from the ECK-generated secret:

```yaml
extraEnvSecrets:
  ES_PASSWORD:
    secret: elasticsearch-es-elastic-user
    key: elastic
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
2. Dashboard ID: `2322` (Elasticsearch — elasticsearch_exporter)
3. Data source: **Prometheus** → Import

<br/>

## Reference

- [prometheus-elasticsearch-exporter Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-elasticsearch-exporter)
- [elasticsearch_exporter](https://github.com/prometheus-community/elasticsearch_exporter)
- [Grafana Dashboard 2322](https://grafana.com/grafana/dashboards/2322)
