# Elasticsearch (ECK CR)

Manages an ECK-backed Elasticsearch CR wrapped as a Helmfile-deployed local Helm chart.

The ECK Operator watches this CR and reconciles the StatefulSet / Service / Secret resources.

<br/>

## Prerequisites

- [eck-operator](../eck-operator/) must be installed first and include `logging` in `managedNamespaces`.
- Permission to create the `logging` namespace.
- An NFS StorageClass (`nfs-client`) available.

<br/>

## Directory Structure

```
elasticsearch/
├── .helmignore
├── Chart.yaml                  # local dummy chart metadata (appVersion = Stack version)
├── helmfile.yaml               # Helmfile release definition (namespace: logging)
├── values/
│   └── mgmt.yaml               # values rendered into the Elasticsearch CR (`version` is Stack version)
├── templates/
│   ├── elasticsearch.yaml      # Elasticsearch CR
│   ├── elastic-user-secret.yaml # elastic account secret (rendered when values sets a password)
│   └── ingress.yaml            # Ingress (temporary / production host)
├── upgrade.sh                  # local-cr-version based version tracker
├── docs/
│   └── upgrade-rollback-en.md  # Upgrade/rollback guide (shared with Kibana)
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Document | Description |
|------|------|
| [Upgrade / Rollback Guide](docs/upgrade-rollback-en.md) | `upgrade.sh` safety features (image verification, health check, dependency CR, downgrade handling) and incident response. Shared with Kibana |

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
# Validate
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile sync

# Update (version bump, etc.)
helmfile apply

# Uninstall
helmfile destroy
```

<br/>

## Version Upgrades

`upgrade.sh` queries the Elastic artifacts API (`https://artifacts-api.elastic.co/v1/versions`) and bumps the `version` field in `values/mgmt.yaml` and the `appVersion` in `Chart.yaml`. It is based on the `local-cr-version` canonical template (see [scripts/upgrade-sync/README-en.md](../../../scripts/upgrade-sync/README-en.md)).

**Pinned to 9.x major line** (`MAJOR_PIN="9"`). Adjust `MAJOR_PIN` in `upgrade.sh` when ready to track 10.x.

```bash
# Check the latest 9.x GA and apply
./upgrade.sh

# Dry-run (no file changes, only show the latest)
./upgrade.sh --dry-run

# Pin to a specific version
./upgrade.sh --version 9.1.2

# Roll back using a previous backup
./upgrade.sh --rollback
```

After the bump, run `helmfile apply` to propagate to the cluster. ECK performs a rolling StatefulSet upgrade.

**Always verify ECK Operator compatibility first** — the installed `eck-operator` must support the target Stack version. Consult the compatibility matrix:
- https://www.elastic.co/support/matrix

Keep Kibana on the **same Stack version** (bump `kibana/values/mgmt.yaml` `version` together).

**Safety features / incident response**: `upgrade.sh` includes image verification, cluster health pre-check, major bump warning, and automatic webhook handling for rollbacks. For behavior details and incident playbooks, see [docs/upgrade-rollback-en.md](docs/upgrade-rollback-en.md).

<br/>

## Verification

```bash
# CR status (HEALTH must be green)
kubectl -n logging get elasticsearch

# Pod status
kubectl -n logging get pods -l common.k8s.elastic.co/type=elasticsearch

# Read the elastic password
kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d

# Cluster health
PASSWORD=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
curl -k -u "elastic:${PASSWORD}" "https://elasticsearch-eck.example.com/_cluster/health"

# Index list
curl -k -u "elastic:${PASSWORD}" "https://elasticsearch-eck.example.com/_cat/indices?v"
```

<br/>

## Cutover (Temporary → Production host)

Change `ingress.host` in `values/mgmt.yaml` from `elasticsearch-eck.example.com` to `elasticsearch.example.com` and run `helmfile apply`.

If the legacy Helm-based Elasticsearch (in the `monitoring` namespace) still owns the domain, remove it or delete its Ingress first.

<br/>

## Troubleshooting

| Symptom | Cause / Action |
|---------|----------------|
| CR stays HEALTH=unknown | Check that ECK Operator watches `logging` ns (`kubectl -n elastic-system logs -l control-plane=elastic-operator`) |
| Pod Pending (PVC) | Check `kubectl get sc nfs-client`, confirm NFS reachability |
| mmap-related errors | Verify `nodeStore.allowMmap: false` is reflected in the rendered CR |
| Reset elastic password | Delete `elasticsearch-es-elastic-user` secret; ECK recreates it |

<br/>

## References

- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-elasticsearch-specification.html
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-deploy-elasticsearch.html
