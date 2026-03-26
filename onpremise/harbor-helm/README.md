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
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Ingress controller (nginx)
- StorageClass (e.g., `nfs-client-server`)

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

## Node Configuration (HTTP Registry)

When using Harbor over HTTP, containerd configuration is required (`/etc/containerd/config.toml`):

```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.your-domain.com"]
  endpoint = ["http://harbor.your-domain.com"]
[plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.your-domain.com".tls]
  insecure_skip_verify = true
```

```bash
sudo systemctl restart containerd
```

> **Warning:** Using HTTPS with certificates is recommended for production environments.

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
