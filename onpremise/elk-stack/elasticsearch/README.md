# Elasticsearch (ECK CR, OCI chart consumer)

Manages an ECK-backed Elasticsearch CR deployed via Helmfile. **The chart templates are NOT in this repo** — the release consumes the public OCI chart [`oci://ghcr.io/somaz94/charts/elasticsearch-eck`](https://artifacthub.io/packages/helm/somaz94/elasticsearch-eck).

The ECK Operator watches this CR and reconciles the StatefulSet / Service / Secret resources.

<br/>

## Prerequisites

- [eck-operator](../eck-operator/) must be installed first and include `logging` in `managedNamespaces`.
- Permission to create the `logging` namespace.
- An NFS StorageClass (`nfs-client`) available.
- Helm 3.8+ (OCI chart pull support), helmfile.

<br/>

## Directory Structure

```
elasticsearch/
├── helmfile.yaml               # chart: oci://ghcr.io/somaz94/charts/elasticsearch-eck, version: <pin>
├── values/
│   └── mgmt.yaml               # Elasticsearch CR values (`version` = Stack version)
├── upgrade.sh                  # external-oci-cr-version based Stack version tracker
├── docs/
│   ├── upgrade-rollback.md     # Upgrade/rollback guide (Korean, shared with Kibana)
│   └── upgrade-rollback-en.md  # English mirror
├── README.md
└── README-en.md
```

There is **no local `Chart.yaml` or `templates/`** in this directory. The chart source is maintained in [somaz94/helm-charts](https://github.com/somaz94/helm-charts/tree/main/charts/elasticsearch-eck) and published on release to OCI (`ghcr.io/somaz94/charts/elasticsearch-eck`) + HTTP (`https://charts.somaz.blog`).

<br/>

## Documentation

| Document | Description |
|------|------|
| [Upgrade / Rollback Guide](docs/upgrade-rollback-en.md) | Stack version bump, OCI chart pin bump, webhook-bypass rollback, incident playbooks. Shared with Kibana |
| [HA Rolling Upgrade Verification](docs/ha-rolling-verification-en.md) | Zero-downtime rolling verification summary on HA topology (chart 0.1.1 / Stack 9.3.3) |

<br/>

## Two versions to manage (important)

After the OCI migration, **two independent version pins** live in this directory:

| Version | Where it lives | Tracks | Frequency | Who bumps | How |
|---|---|---|---|---|---|
| **Stack version** (Elasticsearch image) | `values/mgmt.yaml` `.version` | [Elastic GA releases](https://www.elastic.co/guide/en/elasticsearch/reference/current/release-notes.html) | 1–2× / month | consumer (this repo) | `./upgrade.sh` |
| **OCI chart version** (elasticsearch-eck chart) | `helmfile.yaml` `.releases[0].version` | [chart releases](https://github.com/somaz94/helm-charts/releases) | ~1× / quarter | consumer (this repo) | `./upgrade.sh --check-chart` / `--upgrade-chart` (publisher releases are auto-tracked) |

The two are **independent**: you can bump Stack to 9.3.4 without touching the chart pin, or vice versa.

**Note**: Bumping the chart's own `appVersion` (chart maintainer workflow) lives in a separate repo — [somaz94/helm-charts](https://github.com/somaz94/helm-charts/tree/main/charts/elasticsearch-eck). Not a concern in this repo.

<br/>

## Auto-generated Resources (owned by ECK)

With CR name `elasticsearch`, ECK creates:

| Kind | Name |
|------|------|
| Service (HTTP) | `elasticsearch-es-http` |
| Service (internal) | `elasticsearch-es-internal-http` |
| Service (transport) | `elasticsearch-es-transport` |
| Secret (HTTP certs) | `elasticsearch-es-http-certs-public` (key: `tls.crt`, `ca.crt`) |
| Secret (internal CA) | `elasticsearch-es-http-certs-internal` |
| Secret (credentials) | `elasticsearch-es-elastic-user` (key: `elastic`) |
| StatefulSet | `elasticsearch-es-default` |

<br/>

## Setting the elastic Password

The `elasticPassword` field in `values/mgmt.yaml` is rendered into the `{{ .Values.name }}-es-elastic-user` secret, which ECK consumes directly — no manual `kubectl` step required.

```yaml
# values/mgmt.yaml
elasticPassword: "exampleAdminPassword"
```

To rotate, edit `values/mgmt.yaml` and run `helmfile apply`. ECK detects the secret change and updates the `elastic` user on its next reconcile.

**Random password mode**: Set `elasticPassword: ""` to skip rendering the secret; ECK will then auto-generate one. Retrieve with:

```bash
kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d
```

<br/>

## Quick Start

```bash
# Preview changes (helmfile auto-pulls the OCI chart)
helmfile diff

# Deploy
helmfile sync

# Update (after Stack version bump)
helmfile apply

# Uninstall
helmfile destroy
```

<br/>

## Stack Version Upgrades

`upgrade.sh` queries the Elastic artifacts API (`https://artifacts-api.elastic.co/v1/versions`) and bumps the `version` field in `values/mgmt.yaml`. It is based on the `external-oci-cr-version` canonical template (see [scripts/upgrade-sync/README-en.md](../../../scripts/upgrade-sync/README-en.md)).

**Pinned to 9.x major line** (`MAJOR_PIN="9"`). Adjust `MAJOR_PIN` in `upgrade.sh` when ready to track 10.x.

```bash
# Check the latest 9.x GA and apply
./upgrade.sh

# Dry-run (no file changes, only show the latest)
./upgrade.sh --dry-run

# Pin to a specific version
./upgrade.sh --version 9.1.2

# Roll back using a previous backup (auto webhook handling)
./upgrade.sh --rollback
```

After the bump, run `helmfile diff` → `helmfile apply` to propagate. ECK performs a rolling StatefulSet upgrade.

**Always verify ECK Operator compatibility first** — the installed `eck-operator` must support the target Stack version. Consult the compatibility matrix:
- https://www.elastic.co/support/matrix

Keep Kibana on the **same Stack version** (bump `kibana/values/mgmt.yaml` `version` together).

**Safety features / incident response**: `upgrade.sh` includes image verification, cluster health pre-check, major bump warning, and automatic webhook handling for rollbacks. For behavior details and incident playbooks, see [docs/upgrade-rollback-en.md](docs/upgrade-rollback-en.md).

<br/>

## OCI chart pin bump

On top of Stack version tracking, `upgrade.sh` also tracks `helmfile.yaml`'s `version:` (the publisher's chart release tag). The `CHART_SOURCE_TYPE` / `CHART_SOURCE_REPO` / `CHART_NAME` variables in the CONFIG block activate the two sub-commands:

```bash
# Compare the current pin with the latest publisher release (read-only)
./upgrade.sh --check-chart

# Bump to the latest chart (dry-run): pulls both chart versions, renders each
# with the active values file, and shows a unified diff. No files touched.
./upgrade.sh --upgrade-chart --dry-run

# Apply: review the diff, confirm, then back up helmfile.yaml and update the pin
./upgrade.sh --upgrade-chart

# Pin to a specific chart version
./upgrade.sh --upgrade-chart --chart-version 0.1.2

# Roll back a chart pin (pick a backup/<TIMESTAMP>-chart/ entry)
./upgrade.sh --rollback
```

Key points:
- `--upgrade-chart` runs `helm template` on both the current and target chart with your active values file and diffs the rendered manifests. Values-schema breakage surfaces as a `helm template` failure on the target chart before any file is touched.
- Stack backups (`backup/<TIMESTAMP>/`) and chart backups (`backup/<TIMESTAMP>-chart/`) are stored separately. `--rollback` auto-detects the backup type and restores only the relevant file.
- Chart bumps may still carry **schema or feature changes** — skim the [chart changelog](https://github.com/somaz94/helm-charts/blob/main/charts/elasticsearch-eck/README.md) alongside the render diff.
- To survey chart-pin status across every managed chart at once, run `./scripts/upgrade-sync/check-versions.sh` from the repo root (see the secondary OCI chart pin table).

<br/>

## Verification

```bash
# CR status (HEALTH must be green; single-node clusters are yellow)
kubectl -n logging get elasticsearch

# Pod status
kubectl -n logging get pods -l common.k8s.elastic.co/type=elasticsearch

# Read the elastic password
kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d

# Cluster health
PASSWORD=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
curl -k -u "elastic:${PASSWORD}" "https://elasticsearch.example.com/_cluster/health"

# Index list
curl -k -u "elastic:${PASSWORD}" "https://elasticsearch.example.com/_cat/indices?v"
```

<br/>

## Troubleshooting

| Symptom | Cause / Action |
|---------|----------------|
| CR stays HEALTH=unknown | Check that ECK Operator watches `logging` ns (`kubectl -n elastic-system logs -l control-plane=elastic-operator`) |
| Pod Pending (PVC) | Check `kubectl get sc nfs-client`, confirm NFS reachability |
| mmap-related errors | Verify `nodeSets[*].config.node.store.allow_mmap: false` is reflected in the rendered CR |
| Reset elastic password | Delete `elasticsearch-es-elastic-user` secret; ECK recreates it |
| `helmfile diff` shows BackendTLSPolicy "removed" | **False alarm**. `helm-diff` is client-side and skips `lookup`; the real `helmfile apply` runs server-side so BackendTLSPolicy + CA ConfigMap render correctly. Verify with `helm upgrade --dry-run=server` |

<br/>

## References

- Chart source: https://github.com/somaz94/helm-charts/tree/main/charts/elasticsearch-eck
- OCI registry: `oci://ghcr.io/somaz94/charts/elasticsearch-eck`
- ArtifactHub: https://artifacthub.io/packages/helm/somaz94/elasticsearch-eck
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-elasticsearch-specification.html
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-deploy-elasticsearch.html
