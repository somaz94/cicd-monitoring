# Kibana

This guide explains how to install and configure Kibana in your Kubernetes cluster.

## Prerequisites

- Kubernetes cluster
- Helm v3.x
- Elasticsearch installed and running
- kubectl configured to communicate with your cluster

## Installation Steps

### 1. Prepare Repository
```bash
# Clone the helm-charts repository
git clone https://github.com/elastic/helm-charts.git
# Add Elastic helm repository
helm repo add elastic https://helm.elastic.co
helm repo update
helm dependency update .
```

### 2. Validate Configuration
```bash
# Lint the helm chart
helm lint --values ./values/mgmt.yaml
```

### 3. Installation
```bash
# Dry run to verify configuration
helm install kibana . -n monitoring -f ./values/mgmt.yaml --dry-run --debug >> dry-run-result

# Install Kibana
helm install kibana . -n monitoring -f ./values/mgmt.yaml

# Upgrade existing installation
helm upgrade kibana . -n monitoring -f ./values/mgmt.yaml
```

## Verification

### 1. Check Kibana Pod Status
```bash
# Check pod status
kubectl get pods -n monitoring | grep kibana

# Check logs
kubectl logs -f -n monitoring kibana-kibana-[POD_NAME]
```

### 2. Access Kibana
- URL: https://kibana.somaz.link
- Default credentials:
  - Username: elastic
  - Password: [Use Elasticsearch password]

### 3. Initial Setup

After logging in to Kibana, you can:

1. Create Index Patterns:
   - Navigate to Stack Management > Index Patterns
   - Create index pattern for your logs (e.g., `filebeat-*`)

2. Configure Security:
   - Navigate to Stack Management > Security
   - Set up roles and users as needed

3. Create Visualizations:
   - Navigate to Visualize
   - Create new visualizations based on your data

4. Create Dashboards:
   - Navigate to Dashboard
   - Combine visualizations into meaningful dashboards

## Common Issues and Troubleshooting

1. If Kibana can't connect to Elasticsearch:
```bash
# Check Kibana configuration
kubectl get configmap -n monitoring kibana-kibana-config -o yaml

# Check Kibana logs
kubectl logs -f -n monitoring kibana-kibana-[POD_NAME]
```

2. If you can't access Kibana UI:
```bash
# Check service status
kubectl get svc -n monitoring kibana-kibana

# Check ingress configuration
kubectl get ingress -n monitoring
```

## Configuration

The configuration values can be found in the `values/mgmt.yaml` file. Key configurations include:

- Elasticsearch connection settings
- Security settings
- Resource limits
- Ingress configuration

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Kibana Documentation](https://www.elastic.co/guide/en/kibana/current/index.html)
- [Kibana API Documentation](https://www.elastic.co/guide/en/kibana/current/api.html)


This README provides a comprehensive guide for installing and configuring Kibana, including installation steps, verification methods, initial setup procedures, troubleshooting tips, and relevant references. The structure follows a logical flow from installation to usage and maintenance.

