# Filebeat

This guide explains how to install and configure Filebeat in your Kubernetes cluster for log collection.

## Prerequisites

- Kubernetes cluster
- Helm v3.x
- Elasticsearch and Logstash installed and running
- kubectl configured to communicate with your cluster

## Installation Steps

### 1. Prepare Repository

```bash
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
helm install filebeat . -n monitoring -f ./values/mgmt.yaml --dry-run --debug >> dry-run-result

# Install Filebeat
helm install filebeat . -n monitoring -f ./values/mgmt.yaml

# Upgrade existing installation
helm upgrade filebeat . -n monitoring -f ./values/mgmt.yaml
```

## Verification

### 1. Check Filebeat Status

```bash
# Check pod status
kubectl get pods -n monitoring | grep filebeat

# Check logs
kubectl logs -f -n monitoring filebeat-filebeat-[POD_NAME]

# Check Filebeat version
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat version
```

### 2. Test Filebeat Configuration

```bash
# Test configuration file
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat test config

# Test output connectivity
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat test output
```

## Configuration Examples

### Basic Configuration in values/mgmt.yaml

```

  filebeatConfig:
    filebeat.yml: |
      filebeat.inputs:
      - type: container
        paths:
          - /var/log/containers/*.log
        processors:
        - add_kubernetes_metadata:
            host: ${NODE_NAME}
            matchers:
            - logs_path:
                logs_path: "/var/log/containers/"

      output.logstash:
        hosts: ["logstash-logstash:5044"]

      # output.elasticsearch:
      #   host: '${NODE_NAME}'
      #   hosts: '["https://${ELASTICSEARCH_HOSTS:elasticsearch-master:9200}"]'
      #   username: '${ELASTICSEARCH_USERNAME}'
      #   password: '${ELASTICSEARCH_PASSWORD}'
      #   protocol: https
      #   ssl.certificate_authorities: ["/usr/share/filebeat/certs/ca.crt"]
```

### Common Input Types

1. Container Logs:
```

filebeat.inputs:
- type: container
  paths:
    - /var/log/containers/*.log
```

2. System Logs:
```

filebeat.inputs:
- type: log
  paths:
    - /var/log/*.log
```

3. Journal Logs:
```

filebeat.inputs:
- type: journald
  id: journald
```

## Monitoring and Troubleshooting

### 1. Check Filebeat Status

```bash
# Check Filebeat status
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat status

# List enabled modules
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat modules list
```

### 2. Common Issues

1. If logs are not being collected:

```bash
# Check Filebeat configuration
kubectl get configmap -n monitoring filebeat-filebeat-config -o yaml

# Verify log paths
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- ls -l /var/log/containers/
```

2. If connection to Logstash fails:

```bash
# Test network connectivity
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- curl -v telnet://logstash-logstash:5044
```

## Useful Commands

### Monitor Harvester Status

```bash
# Check harvester status
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- filebeat harvester status
```

### Reset Registry

```bash
# If needed to force re-reading of files
kubectl exec -it -n monitoring filebeat-filebeat-[POD_NAME] -- rm -rf /var/lib/filebeat/registry
```

## Configuration

Key configurations in `values/mgmt.yaml`:

- Input configurations
- Output settings (Logstash/Elasticsearch)
- Kubernetes metadata settings
- Resource limits
- DaemonSet settings

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Filebeat Documentation](https://www.elastic.co/guide/en/beats/filebeat/current/index.html)
- [Filebeat Kubernetes Reference](https://www.elastic.co/guide/en/beats/filebeat/current/running-on-kubernetes.html)
- [Filebeat Input Configuration](https://www.elastic.co/guide/en/beats/filebeat/current/configuration-filebeat-options.html)



This README provides comprehensive information about installing, configuring, and maintaining Filebeat in a Kubernetes environment. It includes configuration examples, troubleshooting steps, and common commands that are useful for day-to-day operations. The structure follows a logical progression from installation to advanced usage and maintenance.