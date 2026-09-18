# Harbor Helm Chart

Manages Harbor container registry using Helmfile.

<br/>

## Directory Structure

```
harbor-helm/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.py)
├── values/
│   └── dev.yaml       # Custom values (manually managed)
├── upgrade.py          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── manifests/          # Resources the upstream chart does not render (HTTPRoute, DB backup)
├── scripts/            # Operational scripts (admin, image-cleanup)
├── docs/               # Detailed guides (TLS, OIDC, DB backup, etc.)
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Document | Description |
|----------|-------------|
| [TLS Setup](docs/tls-setup.md) | Where TLS terminates today (the NGF Gateway wildcard certificate), verification, client trust configuration. Includes the self-signed procedure for the Ingress rollback |
| [OIDC SSO — Keycloak (current standard)](docs/oidc-setup-keycloak.md) | Keycloak OIDC integration, `server` group filter / admin promotion policy. Automated by `harbor-admin.sh set-oidc` |
| [OIDC SSO — GitLab (legacy, pre-Phase 4)](docs/legacy/oidc-setup-gitlab.md) | Full GitLab-direct procedure preserved (rollback / fresh-environment reproduction) |
| [Database Backup](docs/db-backup.md) | Daily `registry` DB dump CronJob, retention, restore procedure. Why the 85G registry blob store is deliberately excluded |
| [Garbage Collection](docs/garbage-collection.md) | Weekly GC schedule (Sun 05:00 KST), capacity analysis, retention still unset. GC is a DB-stored runtime setting, so it is not in git |

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- A Gateway API implementation (nginx-gateway-fabric) — assumed by `expose.type: route` in `values/dev.yaml` and by `manifests/httproutes.yaml`
- StorageClass (e.g., `nfs-client-server`)
- TLS certificate for HTTPS — terminated by the NGF `ngf` Gateway in the `nginx-gateway` namespace with `wildcard-example-tls`. This component owns no certificate, so nothing needs preparing here — see [`docs/tls-setup-en.md`](./docs/tls-setup.md)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Delete
helmfile destroy
```

<br/>

## CRD Considerations

### ServiceMonitor CRD

To use `metrics.enabled: true` or `serviceMonitor.enabled: true`, the `monitoring.coreos.com/v1` CRD **must** be installed first.

Enabling ServiceMonitor without the CRD will result in the following error:

```
Error: UPGRADE FAILED: unable to build kubernetes objects from current release manifest:
resource mapping not found for name: "harbor" namespace: "harbor" from "":
no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
ensure CRDs are installed first
```

**Solutions:**

```bash
# Option 1: Install ServiceMonitor CRD only
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

# Option 2: Install all prometheus-operator CRDs
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus-operator-crds -n monitoring prometheus-community/prometheus-operator-crds --create-namespace

# Verify CRD installation
kubectl get crd | grep monitoring
```

> **Note:** To use without the CRD, set `metrics.enabled: false` and `serviceMonitor.enabled: false` in `values/dev.yaml`.

<br/>

## Upgrade

Use `upgrade.py` to perform version upgrades.

```bash
# Check latest version and upgrade
./upgrade.py

# Preview changes only (no file modifications)
./upgrade.py --dry-run

# Upgrade to a specific version
./upgrade.py --version <chart-version>

# Combine flags
./upgrade.py --dry-run --version <chart-version>
```

upgrade.py automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml and shows diff
3. Checks `values/*.yaml` for breaking changes
4. **Auto-updates image tags** (`tag: vX.X.X` in `values/*.yaml` updated to new appVersion)
5. Creates backup and updates files
6. Updates helmfile.yaml version

### Rollback

```bash
# List backups
./upgrade.py --list-backups

# Restore from backup
./upgrade.py --rollback

# Clean up old backups (keep last 5)
./upgrade.py --cleanup-backups
```

### Post-Upgrade Deployment

```bash
# Review changes
helmfile diff

# Apply
helmfile apply

# Check pod status
kubectl get pods -n harbor
```

<br/>

## Secret Checksums

It is normal for secret checksums to change when running `helmfile diff`:

```diff
- checksum/secret: 961ab1d45c1d006f72c3720cb946d39f95a3e1baecc960d0399f3cf731c6eb04
+ checksum/secret: bdb925c0ced69d79c5dbec3efd3c594c3361ae6eab7bd2cdf70feac20ee6cb24
```

These are regenerated each time Helm renders templates, and the actual secret content remains unchanged.

<br/>

## Robot Account

After creating a robot account in Harbor, register it as a Kubernetes secret:

```bash
kubectl create secret docker-registry harbor-robot-secret \
  --docker-server=<HARBOR_URL> \
  --docker-username='<ROBOT_USERNAME>' \
  --docker-password=<ROBOT_TOKEN> \
  -n <NAMESPACE>
```

Usage in a Pod:

```yaml
spec:
  imagePullSecrets:
    - name: harbor-robot-secret
```

<br/>

## HTTPS (NGF Gateway Termination)

Harbor is exposed over HTTPS to satisfy OIDC SSO requirements and secure registry traffic.
HTTPS is terminated by the NGF `ngf` Gateway in the `nginx-gateway` namespace using the `wildcard-example-tls` certificate, and **this component owns no certificate**. Harbor only attaches to that Gateway through the HTTPRoute generated by `expose.type: route` in [`values/dev.yaml`](values/dev.yaml).

- The HTTP→HTTPS 301 redirect HTTPRoute and the ClientSettingsPolicy, which the chart does not render, stay as raw manifests in [`manifests/httproutes.yaml`](manifests/httproutes.yaml)
- `expose.tls.secret.secretName` is dead config that route mode never renders — the real self-signed `harbor-tls` Secret was removed on 2026-04-17 and consolidated into `wildcard-example-tls`
- Certificate issuance/renewal belongs to `network/nginx-gateway-fabric` — see [TLS Wildcard Setup](../../network/nginx-gateway-fabric/docs/tls-wildcard-setup.md)

**Rollback (Ingress path)**: this cluster does not run cert-manager, so the manual self-signed pattern shared with [Vaultwarden](../vaultwarden/) is preserved as the rollback path. Restoring it means reviving the `ingress:` block commented at the top of `values/dev.yaml` and recreating the `harbor-tls` Secret; the openssl issuance steps are kept in the document below for rollback only.

Full procedure (current termination point / verification / client trust / self-signed rollback): **[`docs/tls-setup-en.md`](./docs/tls-setup.md)**.

<br/>

## SSO — Keycloak OIDC (Phase 4, 2026-04-28+)

Harbor uses **Keycloak OIDC** instead of `db_auth` (Phase 4 replaced the previous GitLab-direct setup). Keycloak's Identity Provider brokers to GitLab, so existing user accounts/groups are preserved (`server` group filter, admin manually promoted for `admin@example.com` only).

OIDC settings live in Harbor's core DB and cannot be declared via Helm values — they are injected via **Harbor REST API or Web UI**. The standard procedure:
- **Current standard (Keycloak)**: [`docs/oidc-setup-keycloak-en.md`](./docs/oidc-setup-keycloak.md)
- **Phase 4 migration procedure**: [`security/keycloak/docs/harbor-migration-en.md`](../keycloak/docs/harbor-migration.md)
- **Legacy GitLab-direct (rollback reference)**: [`docs/legacy/oidc-setup-gitlab-en.md`](./docs/legacy/oidc-setup-gitlab.md)

⚠️ Flipping `auth_mode: oidc_auth` is **irreversible**. This cluster already flipped during the GitLab-direct era — no extra flip needed for the Keycloak switch.

### Permissions Helper Script

User / promotion / project member / OIDC group mapping management lives in [`scripts/admin/`](scripts/admin/).

```bash
scripts/admin/harbor-admin.sh users
scripts/admin/harbor-admin.sh promote admin@example.com
scripts/admin/harbor-admin.sh add-member library group:server developer
scripts/admin/harbor-admin.sh config
```

The admin password is auto-extracted from `harborAdminPassword` in [`values/dev.yaml`](values/dev.yaml) by default; override with the `HARBOR_ADMIN_PASSWORD` environment variable. Full command list: [`scripts/admin/README-en.md`](scripts/admin/README.md).

<br/>

## Node Configuration (Recommended)

> **Current setup already works** — containerd follows the 301 redirect and `skip_verify: true` covers the self-signed cert. The config below is a **semantic cleanup recommendation** and is not urgent.

Reflected in [`kubespray/inventory-example-cluster/group_vars/all/containerd.yml`](../../bootstrap/kubespray/inventory-example-cluster/group_vars/all/containerd.yml):

```yaml
containerd_registries_mirrors:
  - prefix: harbor.example.com
    mirrors:
      - host: https://harbor.example.com    # http → https
        capabilities: ["pull", "resolve", "push"]
        skip_verify: true                   # skip TLS verify for self-signed
        # plain_http: true  ← removed (HTTPS now)
```

Apply to nodes when convenient:

```bash
cd kubespray
ansible-playbook -i inventory-example-cluster/hosts.yaml \
  cluster.yml --tags container-engine -b
```

Details: [`docs/tls-setup-en.md`](./docs/tls-setup.md) §6

<br/>

## Troubleshooting

| Error | Solution |
|-------|----------|
| `no repository definition for https://helm.goharbor.io` | `helm repo add harbor https://helm.goharbor.io` |
| `timed out waiting for the condition` | Add `timeout: 900` to helmDefaults |
| `Persistent volume claim is not bound` | Check StorageClass with `kubectl get sc` |
| `no matches for kind "ServiceMonitor"` | See [CRD Considerations](#servicemonitor-crd) above |

<br/>

## References

- https://goharbor.io/docs
- https://github.com/goharbor/harbor-helm
- [Grafana Dashboard 14930](https://grafana.com/grafana/dashboards/14930)
