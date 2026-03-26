# Logstash

This guide explains how to install and configure Logstash in your Kubernetes cluster.

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
helm install logstash . -n monitoring -f ./values/mgmt.yaml --dry-run --debug >> dry-run-result

# Install Logstash
helm install logstash . -n monitoring -f ./values/mgmt.yaml

# Upgrade existing installation
helm upgrade logstash . -n monitoring -f ./values/mgmt.yaml
```

## Verification

### 1. Check Logstash Status
```bash
# Check pod status
kubectl get pods -n monitoring | grep logstash

# Check logs
kubectl logs -f -n monitoring logstash-logstash-0
```

### 2. Test Pipeline Configuration
```bash
# Get shell access to Logstash pod
kubectl exec -it -n monitoring logstash-logstash-0 -- /bin/bash

# Test Logstash pipeline configuration
bin/logstash -t

# Check Logstash version
bin/logstash --version
```

### 3. Monitor Pipeline Health
```bash
# Check Logstash API endpoints
curl -XGET 'localhost:9600/?pretty'

# Check pipeline stats
curl -XGET 'localhost:9600/_node/stats/pipelines?pretty'
```

## Pipeline Configuration

Logstash pipelines are configured in `values/mgmt.yaml`. Example pipeline structure:

```yaml
logstashConfig:
  logstash.yml: |
    http.host: 0.0.0.0
    xpack.monitoring.enabled: false

logstashPipeline:
  uptime.conf: |
    input { exec { command => "uptime" interval => 30 } }
    output {
      elasticsearch {
        hosts => ["https://elasticsearch-master:9200"]
        user => '${ELASTICSEARCH_USERNAME}'
        cacert => '/usr/share/logstash/config/certs/ca.crt'
        password => '${ELASTICSEARCH_PASSWORD}'
        index => "logstash-%{+YYYY.MM.dd}"   
      }
    }
```

## Common Issues and Troubleshooting

1. Pipeline Issues:
```bash
# Check pipeline configuration
kubectl get configmap -n monitoring logstash-logstash-pipeline -o yaml

# Check Logstash logs for pipeline errors
kubectl logs -f -n monitoring logstash-logstash-0
```

2. Connection Issues:
```bash
# Test Elasticsearch connectivity from Logstash pod
kubectl exec -it -n monitoring logstash-logstash-0 -- curl -k https://elasticsearch-master:9200

# Check Logstash service
kubectl get svc -n monitoring logstash-logstash
```

## Monitoring Logstash

### 1. Check Metrics
```bash
# Basic node info
curl -XGET 'localhost:9600/_node?pretty'

# JVM stats
curl -XGET 'localhost:9600/_node/stats/jvm?pretty'

# Process stats
curl -XGET 'localhost:9600/_node/stats/process?pretty'
```

### 2. Monitor Events
```bash
# Get events stats
curl -XGET 'localhost:9600/_node/stats/events?pretty'
```

## Configuration

Key configurations in `values/mgmt.yaml`:

- Pipeline configurations
- Resource limits
- Persistence settings
- Security settings
- Input/Output plugins

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Logstash Documentation](https://www.elastic.co/guide/en/logstash/current/index.html)
- [Logstash Pipeline Configuration](https://www.elastic.co/guide/en/logstash/current/configuration.html)
- [Logstash Monitoring APIs](https://www.elastic.co/guide/en/logstash/current/monitoring-logstash.html)


This README provides comprehensive information about installing, configuring, and maintaining Logstash, including pipeline configuration examples, monitoring commands, and troubleshooting steps. The structure follows a logical progression from installation to advanced usage and maintenance.