# Fluent Bit AWS Helm Chart

Manages Fluent Bit on AWS EKS using Helmfile. Deployed as a Deployment (not DaemonSet) to collect application logs from EFS volumes and forward them to Fluentd.

<br/>

## Directory Structure

```
fluent-bit-aws/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (local chart templates, etc.)
└── README.md
```

<br/>

## Prerequisites

- AWS EKS cluster
- Helm 3
- Helmfile
- EFS CSI driver installed on the cluster
- EFS file systems with access points for log storage

<br/>

## Architecture

```
Application Pods → EFS Volumes → Fluent Bit (tail) → Fluentd (forward) → Elasticsearch
```

- **Fluent Bit** runs as a Deployment (not DaemonSet) and reads logs from EFS-mounted volumes
- Logs are parsed using custom JSON parser and forwarded to Fluentd on port 24224
- Each application environment/component gets its own EFS PV/PVC pair

<br/>

## Configuration

### EFS Volume Setup

Each log source requires a PersistentVolume and PersistentVolumeClaim pair:

```yaml
persistentVolumes:
  enabled: true
  items:
    - name: example-app-logs-pv-fluentbit
      storage: 5Gi
      storageClassName: efs-sc
      efs:
        fileSystemId: "fs-0xxxxxxxxxxxxxxxxxxxx"
        accessPointId: "fsap-0xxxxxxxxxxxxxxxxxxxx"

persistentVolumeClaims:
  enabled: true
  items:
    - name: example-app-logs-pvc-fluentbit
      storageClassName: efs-sc
      storage: 5Gi
      selector:
        volumeName: example-app-logs-pv-fluentbit
```

<br/>

### Fluent Bit Pipeline

```yaml
config:
  inputs: |
    [INPUT]
        Name tail
        Path /fluent-bit/logs/app/env/component/*
        Tag app.env.component
        Parser custom_json

  filters: |
    [FILTER]
        Name modify
        Match app.env.component
        Set environment env
        Set app app
        Set component component

  outputs: |
    [OUTPUT]
        Name forward
        Match app.*
        Host fluentd
        Port 24224
```

<br/>

## Quick Start

<br/>

### 1. Deploy Fluent Bit

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply
```

<br/>

### 2. Verify Deployment

```bash
# Check pods
kubectl get pods -n fluent-bit

# Check logs
kubectl logs -n fluent-bit -l app.kubernetes.io/name=fluent-bit --tail=50

# Verify EFS volumes are mounted
kubectl describe pod -n fluent-bit -l app.kubernetes.io/name=fluent-bit
```

<br/>

### 3. Adding New Log Sources

To add a new log source:

1. Create EFS file system and access point in AWS
2. Add PV/PVC entries in `values/mgmt.yaml` under `persistentVolumes` and `persistentVolumeClaims`
3. Add volume mount under `extraVolumeMounts`
4. Add INPUT, FILTER entries in `config` section
5. Run `helmfile apply`

<br/>

## Cleanup

```bash
# Delete Fluent Bit
helmfile destroy

# Note: EFS volumes and access points must be cleaned up separately in AWS
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 0.57.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://fluentbit.io/
- https://github.com/fluent/helm-charts
- https://docs.fluentbit.io/manual
- https://github.com/fluent/helm-charts/releases
