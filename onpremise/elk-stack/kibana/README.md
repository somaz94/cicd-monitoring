# Kibana (ECK CR)

Manages an ECK-backed Kibana CR wrapped as a Helmfile-deployed local Helm chart.

Using `elasticsearchRef` to point at the Elasticsearch CR in the same namespace lets ECK auto-inject the connection settings (hosts, credentials, CA certificate).

<br/>

## Prerequisites

- [eck-operator](../eck-operator/) installed.
- [elasticsearch](../elasticsearch/) CR deployed and HEALTH=green.
- `logging` namespace.

<br/>

## Directory Structure

```
kibana/
├── .helmignore
├── Chart.yaml                  # local dummy chart metadata (appVersion = Stack version)
├── helmfile.yaml               # needs: logging/elasticsearch
├── values/
│   └── mgmt.yaml               # values rendered into the Kibana CR (`version` is Stack version)
├── templates/
│   ├── kibana.yaml             # Kibana CR
│   └── ingress.yaml            # Ingress (temporary / production host)
├── upgrade.sh                  # local-cr-version based version tracker
├── docs/
│   └── upgrade-rollback-en.md  # Kibana-specific notes + link to shared guide
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Document | Description |
|------|------|
| [Upgrade / Rollback (Kibana-specific)](docs/upgrade-rollback-en.md) | ES dependency notes + link to shared guide |
| [Full Upgrade / Rollback Guide](../elasticsearch/docs/upgrade-rollback-en.md) | `upgrade.sh` safety features and incident response (primary doc) |

<br/>

## Version Upgrades

`upgrade.sh` uses the same [local-cr-version](../../../scripts/helm-upgrade/templates/local-cr-version.sh) canonical template as Elasticsearch: queries the Elastic artifacts API for the latest GA, then updates `values/mgmt.yaml` `version` and `Chart.yaml` `appVersion` (9.x major line pinned).

```bash
./upgrade.sh --dry-run              # show latest only
./upgrade.sh                         # bump to latest 9.x GA
./upgrade.sh --version 9.1.2        # pin to a specific version
./upgrade.sh --rollback              # restore from a previous backup
```

**Rule**: keep Kibana on the same Stack version as Elasticsearch. Upgrade order: **Elasticsearch first, Kibana second**. (Kibana against a newer ES is OK; the reverse breaks compatibility.)

Kibana's `upgrade.sh` enforces this via `DEPENDENCY_CR_KIND=elasticsearch` — Step 5 reads the ES CR version and **aborts automatically if Kibana target version > ES version**.

Apply the change:
```bash
helmfile diff && helmfile apply
```

**Safety features / incident response**: See [docs/upgrade-rollback-en.md](docs/upgrade-rollback-en.md). (Shared guide: [../elasticsearch/docs/upgrade-rollback-en.md](../elasticsearch/docs/upgrade-rollback-en.md))

<br/>

## Auto-generated Resources (owned by ECK)

With CR name `kibana`:

| Kind | Name |
|------|------|
| Service | `kibana-kb-http` (port 5601) |
| Secret (HTTP certs) | `kibana-kb-http-certs-public` |
| Deployment | `kibana-kb` |
| ConfigMap | `kibana-kb-config` |

`elasticsearchRef` makes ECK auto-inject `elasticsearch.hosts`, `elasticsearch.username/password`, and the CA — you should not set those manually in `values/mgmt.yaml`.

<br/>

## Quick Start

```bash
helmfile lint
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

# Ingress access (temporary host)
open https://kibana-eck.example.com
```

Initial login: user `elastic`, password from the `elastic` key in the `elasticsearch-es-elastic-user` secret.

<br/>

## Cutover (Temporary → Production host)

Change `ingress.host` in `values/mgmt.yaml` from `kibana-eck.example.com` to `kibana.example.com` and run `helmfile apply`.

If the legacy Helm-based Kibana still owns the domain, remove it first.

<br/>

## Troubleshooting

| Symptom | Cause / Action |
|---------|----------------|
| Kibana starts but can't reach ES | Check `kubectl -n logging describe kibana kibana` → `Associations` status. The ES CR name in the same ns must match `elasticsearchRef.name` |
| 403 / CORS errors | Verify the Ingress backend-protocol is set to HTTPS |
| NODE_OPTIONS not applied | Confirm env injection: `kubectl -n logging get pod kibana-kb-... -o yaml | grep NODE_OPTIONS` |

<br/>

## References

- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-kibana.html
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-connect-es.html
