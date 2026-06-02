# Kibana (ECK CR, OCI chart consumer)

Manages an ECK-backed Kibana CR deployed via Helmfile. **The chart templates are NOT in this repo** — the release consumes the public OCI chart [`oci://ghcr.io/somaz94/charts/kibana-eck`](https://artifacthub.io/packages/helm/somaz94/kibana-eck).

Using `elasticsearchRef` to point at the Elasticsearch CR in the same namespace lets ECK auto-inject the connection settings (hosts, credentials, CA certificate).

<br/>

## Prerequisites

- [eck-operator](../eck-operator/) installed.
- [elasticsearch](../elasticsearch/) CR deployed and HEALTH=green.
- `logging` namespace.
- Helm 3.8+ (OCI chart pull support), helmfile.

<br/>

## Apply Order

Operator + CR are split into separate helmfiles (G14). This component is the last CR; follow this order:

1. [eck-operator](../eck-operator/) `helmfile sync` — install CRDs + operator first.
2. [elasticsearch](../elasticsearch/) `helmfile sync` — deploy Elasticsearch and wait for HEALTH=green.
3. **kibana** (this component) `helmfile sync` — create the `Kibana` CR; `elasticsearchRef` wires it to the sibling Elasticsearch automatically.
4. Destroy in reverse: kibana → elasticsearch → eck-operator.

**Why this order**: the Kibana CR needs a healthy Elasticsearch plus the operator to reconcile both; reverse-order destroy prevents stuck finalizers (operator must still run to clear them).

<br/>

## Directory Structure

```
kibana/
├── helmfile.yaml               # chart: oci://ghcr.io/somaz94/charts/kibana-eck, version: <pin>
├── values/
│   └── dev.yaml               # Kibana CR values (`version` = Stack version)
├── upgrade.py                  # external-oci-cr-version based Stack version tracker
├── dashboards/                 # Saved Objects (Lens + Dashboard) NDJSON + apply/export scripts
│   ├── apply.sh                # repo NDJSON → live Kibana
│   ├── export.sh               # live Kibana → repo NDJSON
│   └── *.ndjson                # Saved Object definitions
├── docs/
│   ├── upgrade-rollback.md     # Kibana-specific notes + link to shared guide (Korean)
│   └── upgrade-rollback-en.md  # English mirror
├── README.md
└── README-en.md
```

There is **no local `Chart.yaml` or `templates/`** in this directory. The chart source is maintained in [somaz94/helm-charts](https://github.com/somaz94/helm-charts/tree/main/charts/kibana-eck).

<br/>

## Documentation

| Document | Description |
|------|------|
| [Upgrade / Rollback (Kibana-specific)](docs/upgrade-rollback.md) | ES dependency notes + link to shared guide |
| [Full Upgrade / Rollback Guide](../elasticsearch/docs/upgrade-rollback.md) | `upgrade.py` safety features, OCI chart pin bump, webhook-bypass rollback (primary doc) |
| [HA Rolling Upgrade Verification](../elasticsearch/docs/ha-rolling-verification.md) | Zero-downtime rolling verification summary (ES + Kibana shared) |
| [Dashboards (Saved Objects management)](dashboards/README.md) | Lens/Dashboard kept as NDJSON. `apply.sh` (repo→Kibana), `export.sh` (Kibana→repo) bidirectional sync |
| [Dashboards Saved Objects workflow](docs/dashboards-saved-objects.md) | NDJSON schema, API endpoints, division of responsibility between the two `apply.sh`, data view automation, etc. |
| [User Metrics Catalog](docs/user-metrics-catalog.md) | 10-panel definitions of `Game User Matric & Retention` (slug `dev-pm-retention-dashboard`
| [pm-retention-dashboard — Prod templating guide](docs/pm-retention-dashboard-template.md) | Structure / data sources / template parameters / qa-example-project-game validation / automation strategy / prod migration recipe |
| [Timezone toggle (Space split, KST / CST)](docs/timezone-toggle.md) | Present the same dashboards as KST + CST(UTC+8) views. `setup-spaces.sh` + `apply.sh --space-id` mechanics, extensibility (adding JST/PST/UTC), live URLs, verification, Kibana API quick reference |

<br/>

## Two versions to manage

Same structure as Elasticsearch — see the [Two versions to manage section in the ES README](../elasticsearch/README.md#two-versions-to-manage-important).

| Version | Where it lives | How to bump |
|---|---|---|
| **Stack version** | `values/dev.yaml` `.version` | `./upgrade.py` |
| **OCI chart version** | `helmfile.yaml` `.releases[0].version` | `./upgrade.py --check-chart` / `--upgrade-chart` (publisher releases are auto-tracked) |

<br/>

## Stack Version Upgrades

`upgrade.py` is based on the [external-oci-cr-version](../../../scripts/upgrade-sync/templates/external-oci-cr-version.py) canonical template. It queries the Elastic artifacts API for the latest GA and updates `values/dev.yaml` `version` (9.x major line pinned).

```bash
./upgrade.py --dry-run              # show latest only
./upgrade.py                         # bump to latest 9.x GA
./upgrade.py --version 9.1.2        # pin to a specific version
./upgrade.py --rollback              # restore from backup (auto webhook handling)
```

**Rule**: keep Kibana on the same Stack version as Elasticsearch. Upgrade order: **Elasticsearch first, Kibana second**. (Kibana against a newer ES is OK; the reverse breaks compatibility.)

Kibana's `upgrade.py` enforces this via `DEPENDENCY_CR_KIND=elasticsearch` — Step 5 reads the ES CR version and **aborts automatically if Kibana target version > ES version**.

Apply the change:
```bash
helmfile diff && helmfile apply
```

**Safety features / incident response**: See [docs/upgrade-rollback-en.md](docs/upgrade-rollback.md). (Shared guide: [../elasticsearch/docs/upgrade-rollback-en.md](../elasticsearch/docs/upgrade-rollback.md))

<br/>

## OCI chart pin bump

On top of Stack version tracking, `upgrade.py` also tracks `helmfile.yaml`'s `version:` (publisher chart release tag):

```bash
# Compare the current pin with the latest publisher release (read-only)
./upgrade.py --check-chart

# Dry-run bump: pull both charts, render each with the active values file,
# show a unified diff. No files touched.
./upgrade.py --upgrade-chart --dry-run

# Apply: review the diff, confirm, back up helmfile.yaml, bump the pin
./upgrade.py --upgrade-chart

# Pin to a specific chart version
./upgrade.py --upgrade-chart --chart-version 0.1.2

# Roll back a chart pin (pick a backup/<TIMESTAMP>-chart/ entry)
./upgrade.py --rollback
```

**Note**: Keep Kibana's chart pin **≤ Elasticsearch chart pin** for Stack compatibility. When bumping both charts, **bump Elasticsearch first, Kibana second**.

Values-schema breakage surfaces as a `helm template` failure on the target chart before any file is touched. Chart backups (`backup/<TIMESTAMP>-chart/`) are stored separately from Stack backups and auto-detected by `--rollback`. To survey chart-pin status across every managed chart, run `./scripts/upgrade-sync/check-versions.py` from the repo root.

<br/>

## Auto-generated Resources (owned by ECK)

With CR name `kibana`:

| Kind | Name |
|------|------|
| Service | `kibana-kb-http` (port 5601) |
| Secret (HTTP certs) | `kibana-kb-http-certs-public` |
| Deployment | `kibana-kb` |
| ConfigMap/Secret (config) | `kibana-kb-config` |

`elasticsearchRef` makes ECK auto-inject `elasticsearch.hosts`, `elasticsearch.username/password`, and the CA — you should not set those manually in `values/dev.yaml`.

<br/>

## Quick Start

```bash
helmfile diff
helmfile sync
helmfile apply
helmfile destroy
```

<br/>

## Verification

```bash
# CR status
kubectl -n logging get kibana

# Pod status
kubectl -n logging get pods -l common.k8s.elastic.co/type=kibana

# Access (via HTTPRoute)
open https://kibana.example.com
```

Initial login: user `elastic`, password from the `elastic` key in the `elasticsearch-es-elastic-user` secret.

<br/>

## Troubleshooting

| Symptom | Cause / Action |
|---------|----------------|
| Kibana starts but can't reach ES | Check `kubectl -n logging describe kibana kibana` → `Associations` status. The ES CR name in the same ns must match `elasticsearchRef.name` |
| Plain-HTTP mode (`http.tls.selfSignedCertificate.disabled: true`): login session not preserved | The new OCI chart auto-injects `spec.config.xpack.security.secureCookies: false` + `sameSiteCookies: Lax`. If not injected, your chart pin is too old — verify via `helm show chart oci://.../kibana-eck` |
| NODE_OPTIONS not applied | Confirm env injection: `kubectl -n logging get pod kibana-kb-... -o yaml \| grep NODE_OPTIONS` |

<br/>

## References

- Chart source: https://github.com/somaz94/helm-charts/tree/main/charts/kibana-eck
- OCI registry: `oci://ghcr.io/somaz94/charts/kibana-eck`
- ArtifactHub: https://artifacthub.io/packages/helm/somaz94/kibana-eck
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-kibana.html
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-connect-es.html
