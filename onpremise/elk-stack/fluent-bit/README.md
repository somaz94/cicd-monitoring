# Fluent Bit Helm Chart

Manages the [Fluent Bit](https://fluentbit.io/) DaemonSet for Kubernetes log collection using Helmfile.

<br/>

## Directory Structure

```
fluent-bit/
├── Chart.yaml          # Local chart definition
├── helmfile.yaml       # Helmfile release definition (uses local chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── templates/          # Local Helm templates (synced with upstream)
├── ci/                 # CI test values (synced with upstream)
├── dashboards/         # Grafana dashboards (synced with upstream)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto-backup during upgrades
└── README.md
```

> **Note:** This chart uses the local chart (`chart: .`) approach, managing templates/ directly.

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
./upgrade.sh --version 0.57.0

# Exclude specific values files from comparison
./upgrade.sh --exclude old-release,test
```

upgrade.sh automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml, templates/ and shows diff comparison
3. Syncs ci/, dashboards/ directories
4. Inspects `values/*.yaml` for breaking changes
5. Detects custom templates (CUSTOM_TEMPLATES)
6. Creates backup then updates files

### Image tag policy

Do not set `image.tag` in `values/mgmt.yaml`. The chart default renders the tag from `Chart.AppVersion`, so running `./upgrade.sh` bumps the chart and the container image in lockstep. Unlike fluentd, the upstream fluent-bit image has no ES-specific variant that requires pinning. Override `image.tag` in values only when a variant other than the chart default is required.

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
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit
```

<br/>

## Configuration

Custom settings are managed in `values/mgmt.yaml`. Key settings:

- **config.inputs**: Log input sources
- **config.filters**: Log filtering/transformation
- **config.outputs**: Output destinations (Elasticsearch, etc.)
- **tolerations / nodeSelector**: Node scheduling

### Lua Scripts

You can filter logs using custom Lua scripts:

```yaml
luaScripts:
  filter_example.lua: |
    function filter_name(tag, timestamp, record)
        -- lua code here
    end

config:
  filters: |
    [FILTER]
        Name    lua
        Match   <your-tag>
        script  /fluent-bit/scripts/filter_example.lua
        call    filter_name
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
| Logs not being collected | Check DaemonSet Pod logs: `kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit` |

<br/>

## References

- https://github.com/fluent/helm-charts/tree/main/charts/fluent-bit
- https://fluentbit.io/
- https://docs.fluentbit.io/manual/
- [Grafana Dashboard 7752](https://grafana.com/grafana/dashboards/7752)
