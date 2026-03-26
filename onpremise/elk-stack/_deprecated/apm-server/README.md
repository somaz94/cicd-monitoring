# APM Server

APM Server receives application performance data from APM agents and transforms them into Elasticsearch documents.

## Prerequisites

- Kubernetes cluster
- Helm 3.x
- Elasticsearch and Kibana installed
- Applications instrumented with APM agents

## Installation Steps

1. Clone the Elastic Helm Charts repository:

```bash
git clone https://github.com/elastic/helm-charts.git
```

2. Add the Elastic Helm repository:

```bash
helm repo add elastic https://helm.elastic.co
helm repo update
helm dependency update .
```

3. Validate the chart configuration:
```bash
helm lint --values ./values/mgmt.yaml
```

4. Test the installation (dry-run):
```bash
helm install apm-server . -n monitoring -f ./values/mgmt.yaml --create-namespace --dry-run --debug >> dry-run-result
```

5. Install APM Server:
```bash
helm install apm-server . -n monitoring -f ./values/mgmt.yaml --create-namespace
```

6. To upgrade an existing installation:
```bash
helm upgrade apm-server . -n monitoring -f ./values/mgmt.yaml
```

## Features

- Receives performance metrics from APM agents
- Processes and transforms APM data
- Supports distributed tracing
- Monitors application errors and transactions
- Provides service maps and dependencies

## Configuration

The configuration is managed through `values/mgmt.yaml`. Key settings include:
- Elasticsearch connection settings
- APM Server settings
- Resource allocation
- TLS/SSL configuration
- Index management

## Verification

To verify the installation:

1. Check if pods are running:
```bash
kubectl get pods -n monitoring | grep apm-server
```

2. Check APM indices in Elasticsearch:
```bash
curl -k -u "elastic:<password>" "https://<elasticsearch_url>/_cat/indices/apm-*?v"
```

3. View APM data in Kibana:
- Navigate to Kibana
- Go to Observability → APM

## APM Agent Configuration

Example APM agent configuration:
```yaml
apm_server_url: "http://apm-server:8200"
service_name: "your-service-name"
environment: "production"
```

## Troubleshooting

Common issues and solutions:
- Connection issues: Verify network policies and service accessibility
- Authentication errors: Check APM Server token/secret configuration
- Missing data: Verify APM agent configuration and connectivity
- Performance issues: Check resource allocation and scaling settings

## Reference

- [Official APM Documentation](https://www.elastic.co/guide/en/apm/guide/current/index.html)
- [APM Agents Documentation](https://www.elastic.co/guide/en/apm/agent/index.html)
- [Elastic Helm Charts](https://github.com/elastic/helm-charts)


