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

## Directory Structure

```
kibana/
├── helmfile.yaml               # chart: oci://ghcr.io/somaz94/charts/kibana-eck, version: <pin>
├── values/
│   └── mgmt.yaml               # Kibana CR values (`version` = Stack version)
├── upgrade.sh                  # external-oci-cr-version based Stack version tracker
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
| [Upgrade / Rollback (Kibana-specific)](docs/upgrade-rollback-en.md) | ES dependency notes + link to shared guide |
| [Full Upgrade / Rollback Guide](../elasticsearch/docs/upgrade-rollback-en.md) | `upgrade.sh` safety features, OCI chart pin bump, webhook-bypass rollback (primary doc) |
| [HA Rolling Upgrade Verification](../elasticsearch/docs/ha-rolling-verification-en.md) | Zero-downtime rolling verification summary (ES + Kibana shared) |

<br/>

## Two versions to manage

Same structure as Elasticsearch — see the [Two versions to manage section in the ES README](../elasticsearch/README-en.md#two-versions-to-manage-important).

| Version | Where it lives | How to bump |
|---|---|---|
| **Stack version** | `values/mgmt.yaml` `.version` | `./upgrade.sh` |
| **OCI chart version** | `helmfile.yaml` `.releases[0].version` | manual edit (per chart release cadence) |

<br/>

## Stack Version Upgrades

`upgrade.sh` is based on the [external-oci-cr-version](../../../scripts/upgrade-sync/templates/external-oci-cr-version.sh) canonical template. It queries the Elastic artifacts API for the latest GA and updates `values/mgmt.yaml` `version` (9.x major line pinned).

```bash
./upgrade.sh --dry-run              # show latest only
./upgrade.sh                         # bump to latest 9.x GA
./upgrade.sh --version 9.1.2        # pin to a specific version
./upgrade.sh --rollback              # restore from backup (auto webhook handling)
```

**Rule**: keep Kibana on the same Stack version as Elasticsearch. Upgrade order: **Elasticsearch first, Kibana second**. (Kibana against a newer ES is OK; the reverse breaks compatibility.)

Kibana's `upgrade.sh` enforces this via `DEPENDENCY_CR_KIND=elasticsearch` — Step 5 reads the ES CR version and **aborts automatically if Kibana target version > ES version**.

Apply the change:
```bash
helmfile diff && helmfile apply
```

**Safety features / incident response**: See [docs/upgrade-rollback-en.md](docs/upgrade-rollback-en.md). (Shared guide: [../elasticsearch/docs/upgrade-rollback-en.md](../elasticsearch/docs/upgrade-rollback-en.md))

<br/>

## OCI chart pin bump

```bash
# Check the latest chart version
helm show chart oci://ghcr.io/somaz94/charts/kibana-eck | grep '^version:'

# Edit helmfile.yaml (version: "0.1.1" → new version) → diff → apply
helmfile diff
helmfile apply
```

**Note**: Keep Kibana's chart pin **≤ Elasticsearch chart pin** for Stack compatibility. Bumping both charts together is the safest workflow.

<br/>

## Auto-generated Resources (owned by ECK)

With CR name `kibana`:

| Kind | Name |
|------|------|
| Service | `kibana-kb-http` (port 5601) |
| Secret (HTTP certs) | `kibana-kb-http-certs-public` |
| Deployment | `kibana-kb` |
| ConfigMap/Secret (config) | `kibana-kb-config` |

`elasticsearchRef` makes ECK auto-inject `elasticsearch.hosts`, `elasticsearch.username/password`, and the CA — you should not set those manually in `values/mgmt.yaml`.

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
