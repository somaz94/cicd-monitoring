# Harbor Helm Chart

Manages Harbor container registry using Helmfile.

<br/>

## Directory Structure

```
harbor-helm/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── docs/               # Detailed guides (TLS, OIDC, etc.)
└── README.md
```

<br/>

## Documentation

| Document | Description |
|----------|-------------|
| [TLS Setup](docs/tls-setup-en.md) | Self-signed cert issuance, renewal, client trust configuration |
| [OIDC SSO](docs/oidc-setup-en.md) | GitLab OAuth integration, `server` group filter / admin promotion policy |

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Ingress controller (nginx)
- StorageClass (e.g., `nfs-client-server`)
- TLS Secret for HTTPS — see [`docs/tls-setup.md`](./docs/tls-setup.md) (self-signed, prepared before `helmfile apply`)

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

> **Note:** To use without the CRD, set `metrics.enabled: false` and `serviceMonitor.enabled: false` in `values/mgmt.yaml`.

<br/>

## Upgrade

Use `upgrade.sh` to perform version upgrades.

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only (no file modifications)
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 1.18.3

# Combine flags
./upgrade.sh --dry-run --version 1.18.3
```

upgrade.sh automatically performs the following:
1. Checks current/latest version
2. Downloads Chart.yaml, values.yaml and shows diff
3. Checks `values/*.yaml` for breaking changes
4. **Auto-updates image tags** (`tag: vX.X.X` in `values/*.yaml` updated to new appVersion)
5. Creates backup and updates files
6. Updates helmfile.yaml version

### Rollback

```bash
# List backups
./upgrade.sh --list-backups

# Restore from backup
./upgrade.sh --rollback

# Clean up old backups (keep last 5)
./upgrade.sh --cleanup-backups
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

## HTTPS (Self-Signed)

Harbor is exposed over HTTPS to satisfy OIDC SSO requirements and secure registry traffic.
This cluster does not run cert-manager → uses the same manual self-signed pattern as [Vaultwarden](../../security/vaultwarden/).

```bash
# Summary: register harbor-tls Secret (see docs for full procedure)
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout harbor-key.pem -out harbor-cert.pem \
  -subj "/CN=harbor.example.com" \
  -addext "subjectAltName=DNS:harbor.example.com"

kubectl create secret tls harbor-tls \
  --cert=harbor-cert.pem --key=harbor-key.pem -n harbor
```

Full procedure (issuance

<br/>

## SSO — GitLab OIDC

Harbor uses **GitLab OIDC** instead of `db_auth` (shares GitLab with ArgoCD, `server` group filter, admin manually promoted for `admin@example.com` only).

OIDC settings live in Harbor's core DB and cannot be declared via Helm values — they are injected via **Harbor REST API or Web UI**. The API injection procedure is the standard: **[`docs/oidc-setup-en.md`](./docs/oidc-setup-en.md)** ([한국어](./docs/oidc-setup.md)).

⚠️ Flipping `auth_mode: oidc_auth` is **irreversible**. Follow the pre-flight checks in `docs/oidc-setup-en.md`.

### Permissions Helper Script

User / promotion / project member / OIDC group mapping management lives in the top-level [`scripts/harbor/admin/`](../../scripts/harbor/admin/).

```bash
../../scripts/harbor/admin/harbor-admin-en.sh users
../../scripts/harbor/admin/harbor-admin-en.sh promote admin@example.com
../../scripts/harbor/admin/harbor-admin-en.sh add-member library group:server developer
../../scripts/harbor/admin/harbor-admin-en.sh config
```

The admin password is auto-extracted from this chart's `harborAdminPassword` by default; override with the `HARBOR_ADMIN_PASSWORD` environment variable. Full command list: [`scripts/harbor/admin/README-en.md`](../../scripts/harbor/admin/README-en.md).

<br/>

## Node Configuration (Recommended)

> **Current setup already works** — containerd follows the 308 redirect and `skip_verify: true` covers the self-signed cert. The config below is a **semantic cleanup recommendation** and is not urgent.

Reflected in [`kubespray/inventory-example-cluster/group_vars/all/containerd.yml`](../../kubespray/inventory-example-cluster/group_vars/all/containerd.yml):

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
cd ~/gitlab-project/kuberntes-infra/kubespray
ansible-playbook -i inventory-example-cluster/hosts.yaml \
  cluster.yml --tags container-engine -b
```

Details: [`docs/tls-setup.md`](./docs/tls-setup.md) §6 (Korean)

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
