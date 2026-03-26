# ELK Stack

<br/>

## Overview

ELK Stack deployment for Kubernetes using Helmfile with Elasticsearch, Kibana, Fluent Bit, and Fluentd.

<br/>

## Architecture

```
Log Pipeline:
  App Logs (NFS) -> Fluent Bit (collector) -> Fluentd (processor) -> Elasticsearch (storage) <- Kibana (visualization)
```

<br/>

## Components

| Component | Chart Version | App Version | Type |
|-----------|--------------|-------------|------|
| Elasticsearch | 8.5.1 | 8.5.1 | Local chart |
| Kibana | 8.5.1 | 8.5.1 | Local chart |
| Fluent Bit | 0.56.0 | 4.2.3 | Local chart (custom templates) |
| Fluentd | 0.5.3 | v1.17.1 | Remote chart |

<br/>

## Directory Structure

```
elk-stack/
├── elasticsearch/          # Elasticsearch search engine
│   ├── Chart.yaml
│   ├── helmfile.yaml
│   ├── upgrade.sh
│   ├── delete_old_indices.sh
│   ├── delete_old_indices_kr.sh
│   └── values/
│       └── mgmt.yaml
├── kibana/                 # Kibana visualization
│   ├── Chart.yaml
│   ├── helmfile.yaml
│   ├── upgrade.sh
│   └── values/
│       └── mgmt.yaml
├── fluent-bit/             # Fluent Bit log collector
│   ├── Chart.yaml
│   ├── helmfile.yaml
│   ├── upgrade.sh
│   └── values/
│       └── mgmt.yaml
├── fluentd/                # Fluentd log processor
│   ├── Chart.yaml
│   ├── helmfile.yaml
│   ├── upgrade.sh
│   └── values/
│       └── mgmt.yaml
├── _deprecated/            # Deprecated components
│   ├── logstash/
│   ├── filebeat/
│   ├── apm-server/
│   └── metricbeat/
└── README.md
```

<br/>

## Installation

Each component is managed independently via its own `helmfile.yaml`:

```bash
# Install Elasticsearch
cd elasticsearch && helmfile apply

# Install Kibana
cd kibana && helmfile apply

# Install Fluent Bit
cd fluent-bit && helmfile apply

# Install Fluentd
cd fluentd && helmfile apply
```

<br/>

## Upgrade

Each component has an `upgrade.sh` script for automated version management:

```bash
# Check and upgrade to latest version
./upgrade.sh

# Preview changes without applying
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 9.0.0

# Rollback to a previous version
./upgrade.sh --rollback

# List / cleanup backups
./upgrade.sh --list-backups
./upgrade.sh --cleanup-backups
```

<br/>

## Deprecated Components

The following components have been deprecated and moved to `_deprecated/`:

- **Logstash** - Replaced by Fluentd for log processing
- **Filebeat** - Replaced by Fluent Bit for log collection
- **APM Server** - No longer in active use
- **Metricbeat** - No longer in active use

<br/>

## Reference

- [Elastic Helm Charts](https://github.com/elastic/helm-charts)
- [Fluent Bit Helm Charts](https://github.com/fluent/helm-charts/tree/main/charts/fluent-bit)
- [Fluentd Helm Charts](https://github.com/fluent/helm-charts/tree/main/charts/fluentd)
