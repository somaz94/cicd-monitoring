# Metricbeat

Metricbeat is a lightweight shipper for metrics. It collects system and service metrics and ships them to Elasticsearch.

## Prerequisites

- Kubernetes cluster
- Helm 3.x
- Elasticsearch and Kibana installed

## Installation Steps

1. Clone the Elastic Helm Charts repository:

```bash
git clone https://github.com/elastic/helm-charts.git
```

2. Add the Elastic Helm repository:

```bash
helm repo add elastic https://helm.elastic.co
```

3. Validate the chart configuration:

```bash
helm lint --values ./values/mgmt.yaml
```

4. Test the installation (dry-run):

```bash
helm install metricbeat . -n monitoring -f ./values/mgmt.yaml --create-namespace --dry-run --debug >> dry-run-result
```

5. Install Metricbeat:

```bash
helm install metricbeat . -n monitoring -f ./values/mgmt.yaml --create-namespace
```

6. To upgrade an existing installation:

```bash
helm upgrade metricbeat . -n monitoring -f ./values/mgmt.yaml
```

## Features

- System metrics collection (CPU, memory, network, etc.)
- Kubernetes metrics monitoring
- Includes kube-state-metrics for enhanced cluster monitoring
- Uses Data Streams for efficient time-series data management

## Configuration

The configuration is managed through `values/mgmt.yaml`. Key features include:
- Elasticsearch connection settings
- Metric collection intervals
- Kubernetes monitoring settings
- Data Stream and index management

## Verification

To verify the installation:

1. Check if pods are running:

```bash
kubectl get pods -n monitoring | grep metricbeat
```

2. Check Metricbeat indices in Elasticsearch:

```bash
curl -k -u "elastic:<password>" "https://<elasticsearch_url>/_cat/indices/.ds-metricbeat-*?v"
```

3. View metrics in Kibana:
- Navigate to Kibana
- Go to Observability → Metrics

## Troubleshooting

Common issues and solutions:
- DNS resolution issues: Check node DNS configuration
- Connection errors: Verify Elasticsearch credentials and SSL settings
- Missing metrics: Check metricbeat modules configuration

## Reference

- [Official Metricbeat Documentation](https://www.elastic.co/guide/en/beats/metricbeat/current/index.html)
- [Elastic Helm Charts](https://github.com/elastic/helm-charts)


