# Fluentd Helm Chart

Manages the [Fluentd](https://www.fluentd.org/) **StatefulSet** — the aggregator stage of the Kubernetes log-collection pipeline (the workload kind is `kind` in `values/dev.yaml`). It receives logs from the node-level fluent-bit DaemonSet, buffers them on the `fluentd-buffer` PVC, and forwards them to Elasticsearch.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/fluentd.yaml`, bumped by `upgrade.py` via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of [docs/ci-upgrade.md](../../../docs/ci-upgrade.md).

<br/>

## Directory Structure

```
fluentd/
├── Chart.yaml          # Version tracking (no local templates)
├── argocd/
│   └── fluentd.yaml    # ArgoCD marker — `chart.version` is the chart pin SSOT
├── values.yaml         # Upstream default values (auto-managed by upgrade.py)
├── values/
│   └── dev.yaml       # Custom values (manually managed)
├── upgrade.py          # Version upgrade script
├── docs/               # Topic guides (KO+EN pairs) — listed in the Documentation table below
├── backup/             # Auto-backup during upgrades (holds the retired helmfile.yaml)
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Document | Description |
|----------|-------------|
| [zlogger normalization](docs/zlogger-normalization.md) | Work log + operational guide for normalizing the JSON schema changed by the ZLogger migration (`dev-example-project-battle`) in fluentd's `02_filters.conf` |

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

Use `upgrade.py` to perform version upgrades.

```bash
# Check latest version and upgrade
./upgrade.py

# Preview changes only (no file modifications)
./upgrade.py --dry-run

# Upgrade to a specific version (the current pin is `chart.version` in argocd/fluentd.yaml)
./upgrade.py --version <X.Y.Z>

# Combine flags
./upgrade.py --dry-run --version <X.Y.Z>

# Exclude specific values files from comparison
./upgrade.py --exclude old-release,test
```

upgrade.py automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml and shows diff comparison
3. Inspects `values/*.yaml` for breaking changes (removed/new top-level keys)
4. Creates backup then updates files (Chart.yaml, values.yaml, argocd/fluentd.yaml)

### Two-track version management (chart vs image.tag)

This chart manages the **chart version** and the **container image tag** separately.

| Target | Managed by | Reason |
|---|---|---|
| Helm chart version (`fluent/fluentd`) | `./upgrade.py` (automated) | Standard flow |
| Container image (`fluent/fluentd-kubernetes-daemonset:<tag>`) | `image.tag` in `values/dev.yaml` (manual) | Upstream chart's default image uses `-elasticsearch7-*` / `-elasticsearch8-*` variants; ES 9 operation requires a specific compatible image. `-elasticsearch9-*` variant is not yet published upstream. |

**image.tag upgrade procedure** (manual):
1. Check new tag — [Docker Hub tags](https://hub.docker.com/r/fluent/fluentd-kubernetes-daemonset/tags) or [GitHub releases](https://github.com/fluent/fluentd-kubernetes-daemonset/releases).
2. Edit `image.tag` (and `variant` if applicable) in `values/dev.yaml`.
3. `helmfile diff` → `helmfile apply`.

**When to bump**:
- Upgrade variant + tag once fluentd publishes an official `-elasticsearch9-*` variant.
- Bump tag for security/patch-level releases (e.g., `...-elasticsearch8-1.5`).
- `./upgrade.py` chart upgrade and image upgrade can be performed **independently**.

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

```bash
# Review changes
helmfile diff

# Apply
helmfile apply

# Check Pod status
kubectl get pods -n logging -l app.kubernetes.io/name=fluentd
```

<br/>

## Configuration

Custom settings are managed in `values/dev.yaml`. Key settings:

- **fileConfigs**: Fluentd pipeline configuration (sources → filters → outputs)
- **volumeMounts / volumes**: Log path mounts
- **elasticsearch**: Output destination settings

Upstream default values can be referenced in `values.yaml`.

<br/>

### `authorization` redaction (02_filters.conf Step 4)

`data.requestHeader.authorization` carries `Basic base64(accountId:sessionId)` — a live credential, since the game server authenticates by comparing that `sessionId` against the Redis session. Step 4 masks it while serializing the nested `data` JSON: only the scheme token (`Basic` / `Bearer` / `Digest` / `Negotiate`) is kept, the rest becomes `[REDACTED]`, and anything not matching a known scheme is redacted whole (fail-closed). Header lookup is case-insensitive.

Ported from the AWS prod pipeline ([`fluentd-aws/values/prod.yaml`](../fluentd-aws/values/prod.yaml)); the expression is byte-identical, only the tag namespace differs.

- ⚠️ Applies to **new records only**. Records already in `dev-example-project-game` / `qa-example-project-game` still hold the plaintext credential — and unlike prod these indices are **not ILM-managed**, so nothing ages them out on its own.
- ⚠️ Covers **only** `authorization` inside `data.requestHeader`. Sibling headers such as `cookie` / `x-api-key`, and the `data.requestBody` / `data.responseBody` payloads, are blind spots. The battle pipeline carries no auth header at all.
- `data.traceId` is retained on-prem and in prod alike. AWS prod briefly ran a Step 7 that deleted the field; it was reverted on 2026-08-05 — with the value left only in `_id`, which has no `.keyword` sub-field and no fielddata, the `terms` aggregations and `wildcard` / `prefix` searches became impossible, and those are precisely the queries the field exists for (a UUID the app issues per request and shares with the battle server, so one request can be followed across both). On-prem there was never a saving to chase anyway: the whole index is a few hundred MB and never rolls.

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
| Elasticsearch connection failure | Check host/port/credentials in `values/dev.yaml` |
| Logs not being collected | Check StatefulSet Pod logs: `kubectl logs -n logging -l app.kubernetes.io/name=fluentd` |

<br/>

## References

- https://github.com/fluent/helm-charts/tree/main/charts/fluentd
- https://www.fluentd.org/
- https://docs.fluentd.org/
- [Grafana Dashboard 7752](https://grafana.com/grafana/dashboards/7752)
