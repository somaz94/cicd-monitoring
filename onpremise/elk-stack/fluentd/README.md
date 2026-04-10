# Fluentd Helm Chart

Manages the [Fluentd](https://www.fluentd.org/) DaemonSet for Kubernetes log collection using Helmfile.

<br/>

## Directory Structure

```
fluentd/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto-backup during upgrades
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Elasticsearch (log destination)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Destroy
helmfile destroy
```

<br/>

## Upgrade

Use `upgrade.sh` to perform version upgrades.

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only (no file modifications)
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 0.6.0

# Combine flags
./upgrade.sh --dry-run --version 0.6.0

# Exclude specific values files from comparison
./upgrade.sh --exclude old-release,test
```

upgrade.sh automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml and shows diff comparison
3. Inspects `values/*.yaml` for breaking changes (removed/new top-level keys)
4. Creates backup then updates files (Chart.yaml, values.yaml, helmfile.yaml)

### Rollback

```bash
# List backups
./upgrade.sh --list-backups

# Restore from backup
./upgrade.sh --rollback

# Clean up old backups (keep only the latest 5)
./upgrade.sh --cleanup-backups
```

### Deploy After Upgrade

```bash
# Review changes
helmfile diff

# Apply
helmfile apply

# Check Pod status
kubectl get pods -n monitoring -l app.kubernetes.io/name=fluentd
```

<br/>

## Configuration

Custom settings are managed in `values/mgmt.yaml`. Key settings:

- **fileConfigs**: Fluentd pipeline configuration (sources → filters → outputs)
- **volumeMounts / volumes**: Log path mounts
- **elasticsearch**: Output destination settings

Upstream default values can be referenced in `values.yaml`.

```bash
# Check upstream default values
helm show values fluent/fluentd
```

<br/>

## Helmfile Commands Reference

```bash
helmfile lint           # Validate configuration
helmfile diff           # Preview changes
helmfile apply          # Apply
helmfile destroy        # Destroy
helmfile status         # Check status
```

<br/>

## Troubleshooting

| Error | Solution |
|-------|----------|
| `no repository definition for https://fluent.github.io/helm-charts` | `helm repo add fluent https://fluent.github.io/helm-charts` |
| Elasticsearch connection failure | Check host/port/credentials in `values/mgmt.yaml` |
| Logs not being collected | Check DaemonSet Pod logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=fluentd` |

<br/>

## References

- https://github.com/fluent/helm-charts/tree/main/charts/fluentd
- https://www.fluentd.org/
- https://docs.fluentd.org/
- [Grafana Dashboard 7752](https://grafana.com/grafana/dashboards/7752)
