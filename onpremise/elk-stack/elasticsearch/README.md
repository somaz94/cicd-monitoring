# Elasticsearch

This guide explains how to install and configure Elasticsearch in your Kubernetes cluster.

## Prerequisites

- Kubernetes cluster
- Helm v3.x
- kubectl configured to communicate with your cluster

## Installation Steps

### 1. Clone and Prepare Repository

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
helm install elasticsearch . -n monitoring -f ./values/mgmt.yaml --create-namespace --dry-run --debug >> dry-run-result

# Install Elasticsearch
helm install elasticsearch . -n monitoring -f ./values/mgmt.yaml --create-namespace

# Upgrade existing installation
helm upgrade elasticsearch . -n monitoring -f ./values/mgmt.yaml
```

### 4. Get Elasticsearch Password
```bash
kubectl get secrets --namespace=monitoring elasticsearch-master-credentials -ojsonpath='{.data.password}' | base64 -d
```

## Verification

### 1. Basic Health Check
You can verify the installation by accessing the Elasticsearch endpoint:
- URL: https://<elasticsearch_url>

```bash
curl -k -u "elastic:${PASSWORD}" "https://<elasticsearch_url>"
```

Example response:
```json
{
  "name" : "elasticsearch-master-0",
  "cluster_name" : "elasticsearch",
  "cluster_uuid" : "Aos3FIcvRkSktbdf_vU_2A",
  "version" : {
    "number" : "8.5.1",
    "build_flavor" : "default",
    "build_type" : "docker",
    "build_hash" : "c1310c45fc534583afe2c1c03046491efba2bba2",
    "build_date" : "2022-11-09T21:02:20.169855900Z",
    "build_snapshot" : false,
    "lucene_version" : "9.4.1",
    "minimum_wire_compatibility_version" : "7.17.0",
    "minimum_index_compatibility_version" : "7.0.0"
  },
  "tagline" : "You Know, for Search"
}
```

### 2. Cluster Health and Indices
After installation is complete, you can check

```bash
# Check Cluster Health
curl -k -u "elastic:${PASSWORD}" "https://<elasticsearch_url>/_cluster/health"

# Check Indices
curl -k -u "elastic:${PASSWORD}" "https://<elasticsearch_url>/_cat/indices"

# Check Nodes
curl -k -u "elastic:${PASSWORD}" "https://<elasticsearch_url>/_cat/nodes"

# Check Shards
curl -k -u "elastic:${PASSWORD}" "https://<elasticsearch_url>/_cat/shards"
```

## Configuration

The configuration values can be found in the `values/mgmt.yaml` file. Customize these values according to your requirements.

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Elasticsearch Documentation](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html)


This README provides a comprehensive guide for installing and configuring Elasticsearch, including preparation steps, installation commands, verification methods, and relevant references. The structure is clear and follows the actual installation process with all necessary commands and expected outputs.