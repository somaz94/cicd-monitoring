# Fluent Bit Helm Chart

Manages the [Fluent Bit](https://fluentbit.io/) DaemonSet for Kubernetes log collection.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The deploy marker is `argocd-local/fluent-bit.yaml` with `autoSync: true` (prune + selfHeal), so a push to master is what reaches the cluster. Because the chart is vendored locally the marker carries only `chartPath`: the chart-version SSOT is the in-repo `Chart.yaml`, bumped by `upgrade.py` via the `local-with-templates` template — this is NOT the argocd-pin pattern. See the "ArgoCD-migrated components" section of [docs/ci-upgrade.md](../../../docs/ci-upgrade.md).

<br/>

## Directory Structure

```
fluent-bit/
├── Chart.yaml          # Local chart definition — chart-version SSOT (bumped by upgrade.py)
├── argocd-local/
│   └── fluent-bit.yaml # ArgoCD marker (vendored chart → `chartPath`-based, no chart.* fields)
├── values.yaml         # Upstream default values (auto-managed by upgrade.py)
├── values/
│   └── dev.yaml       # Custom values (manually managed)
├── templates/          # Local Helm templates (synced with upstream)
├── ci/                 # CI test values (synced with upstream)
├── dashboards/         # Grafana dashboards (synced with upstream)
├── upgrade.py          # Version upgrade script
├── backup/             # Auto-backup during upgrades (holds the retired helmfile.yaml)
├── docs/               # Topic-specific guides (Korean + English mirror)
├── README.md
└── README-en.md
```

> **Note:** This chart uses the local chart (`chart: .`) approach, managing templates/ directly.

<br/>

## Documentation

| Document | Description |
|---|---|
| [Recommended prod-tail settings](docs/prod-tail-config.md) | `Read_from_Head`, `DB` checkpoint, `Ignore_Older` and related tail input recommendations for prod. dev vs prod comparison + migration guide + current dev Phase 1a state |
| [Index re-ingest procedure](docs/reingest-procedure.md) | Replay logs from NFS into ES after index loss. DB ≠ ES asynchrony background, full/partial re-ingest, Phase 1a vs 1b behavior |
| [Deployment → DaemonSet migration record](docs/deployment-to-daemonset.md) | Record of the swap from the NFS-aggregator Deployment to a per-node stdout DaemonSet (2026-05-19). Step-by-step commands, gap measurement (~10s), helm-auto cleanup scope + one manual state PV cleanup, lessons learned |
| [pino-pretty removal guide](docs/pino-pretty-removal.md) | Lines to drop from `values/dev.yaml` when the game team turns off pino-pretty in application stdout (lua/parser filter chain + custom parser + luaScripts). Partial-switch scenario + verification procedure |

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Elasticsearch (log destination)

<br/>

## Quick Start

> 🔴 **The live deploy path is ArgoCD auto-sync** (`argocd-local/fluent-bit.yaml`). The `helmfile` commands below are **retired, reference-only** — `helmfile.yaml` lives in `backup/`. Pushing to master is what reaches the cluster.

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

Use `upgrade.py` to perform version upgrades.

```bash
# Check latest version and upgrade
./upgrade.py

# Preview changes only (no file modifications)
./upgrade.py --dry-run

# Upgrade to a specific version (the current chart version is `version` in Chart.yaml)
./upgrade.py --version <X.Y.Z>

# Exclude specific values files from comparison
./upgrade.py --exclude old-release,test
```

upgrade.py automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml, templates/ and shows diff comparison
3. Syncs ci/, dashboards/ directories
4. Inspects `values/*.yaml` for breaking changes
5. Detects custom templates (CUSTOM_TEMPLATES)
6. Creates backup then updates files

### Image tag policy

Do not set `image.tag` in `values/dev.yaml`. The chart default renders the tag from `Chart.AppVersion`, so running `./upgrade.py` bumps the chart and the container image in lockstep. Unlike fluentd, the upstream fluent-bit image has no ES-specific variant that requires pinning. Override `image.tag` in values only when a variant other than the chart default is required.

### Rollback

```bash
# List backups
./upgrade.py --list-backups

# Restore from backup
./upgrade.py --rollback

# Clean up old backups (keep only the latest 5)
./upgrade.py --cleanup-backups
```

### Deploy After Upgrade

> Retired, reference-only. In practice you commit + push the bump and ArgoCD auto-syncs it (only the pod-status command below still applies as-is).

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

Custom settings are managed in `values/dev.yaml`. Key settings:

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

## Helmfile Commands Reference (retired, reference-only)

> `helmfile.yaml` was retired to `backup/`. The commands below are kept as a reference to the helmfile era.

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
| Elasticsearch connection failure | Check host/port/credentials in `values/dev.yaml` |
| Logs not being collected | Check DaemonSet Pod logs: `kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit` |

<br/>

## References

- https://github.com/fluent/helm-charts/tree/main/charts/fluent-bit
- https://fluentbit.io/
- https://docs.fluentbit.io/manual/
- [Grafana Dashboard 7752](https://grafana.com/grafana/dashboards/7752)
