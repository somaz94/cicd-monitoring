# ArgoCD Installation Guide

This guide describes how to install and configure ArgoCD in a Kubernetes cluster using Helmfile.

<br/>

## Directory Structure

```
argo-cd/
├── Chart.yaml
├── helmfile.yaml
├── values.yaml
├── values/
│   ├── mgmt.yaml               # global, configs (cm/params/ssh/rbac/secrets)
│   ├── mgmt-server.yaml        # controller, dex, server, repoServer, applicationSet
│   ├── mgmt-redis.yaml         # redis, redis-ha, redisSecretInit
│   └── mgmt-notifications.yaml # notifications controller (Slack templates/triggers)
├── upgrade.sh
├── backup/
├── docs/
│   ├── ghost-alarm-incident-2026-04-23.md      # 2026-04-23 ghost-alarm incident analysis + Notification rules design
│   ├── ghost-alarm-followup-prompt.md          # Prompt template for asking Claude when similar symptoms recur
│   └── notification-rule-change-playbook.md    # Playbook for minimizing resends when changing notification rules
├── scripts/
│   └── notify-rule-change.sh                   # Rule-change helper (check/pre/post/status)
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Topic | Document |
|---|---|
| SSO — Keycloak OIDC migration (Phase 6, 2026-04-29). dex.config replacement / argocd-https-redirect HTTPRoute / 5 pitfalls lessons learned | [security/keycloak/docs/argocd-migration-en.md](../../security/keycloak/docs/argocd-migration-en.md) |
| 2026-04-23 ghost-alarm incident analysis, Notification rules (Option A/B) design, Alertmanager role split | [docs/ghost-alarm-incident-2026-04-23-en.md](docs/ghost-alarm-incident-2026-04-23-en.md) |
| Playbook for minimizing one-time resends when changing notification rules (also see `scripts/notify-rule-change.sh`) | [docs/notification-rule-change-playbook-en.md](docs/notification-rule-change-playbook-en.md) |
| Prompt template to re-ask Claude when similar notification issues recur | [docs/ghost-alarm-followup-prompt-en.md](docs/ghost-alarm-followup-prompt-en.md) |
| Upstream issue submission template (English) | [docs/upstream-issue-template-en.md](docs/upstream-issue-template-en.md) |

Related external files:
- Alertmanager `argocd-alerts` rule group: [observability/monitoring/kube-prometheus-stack/values/mgmt-alerts.yaml](../../observability/monitoring/kube-prometheus-stack/values/mgmt-alerts.yaml)
- Alertmanager inhibit/routing config: [observability/monitoring/kube-prometheus-stack/values/mgmt-alertmanager.yaml](../../observability/monitoring/kube-prometheus-stack/values/mgmt-alertmanager.yaml)

<br/>

## Prerequisites

- Kubernetes cluster (>= 1.25)
- Helm 3
- Helmfile
- Ingress controller (nginx)
- Domain for ArgoCD (e.g., argocd.example.com)

<br/>

## Installation

<br/>

### 1. Configure values

Create `values/mgmt.yaml` with the following configuration (adjust according to your needs):

```yaml
global:
  domain: argocd.your-domain.com

configs:
  params:
    create: true
    server.insecure: true # TODO: If you want to use SSL, please set this to false

  ssh:
    extraHosts: |
      # Add your SSH known hosts here
      # Get keys with: ssh-keyscan gitlab.your-domain.com
      gitlab.example.com ssh-rsa AAAAB3N...
      gitlab.example.com ecdsa-sha2-nistp256...
      gitlab.example.com ssh-ed25519 AAAA..

controller:
  replicas: 1

dex:
  enabled: true

redis:
  enabled: true

server:
  replicas: 1
  ingress:
    enabled: true
    annotations:
      nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
      nginx.ingress.kubernetes.io/ssl-passthrough: "false"
    ingressClassName: "nginx"
    path: /
    pathType: Prefix

repoServer:
  replicas: 1

applicationSet:
  replicas: 1

notifications:
  enabled: true
```

<br/>

### 2. Deploy with Helmfile

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply
```

<br/>

### 3. Verify Installation

```bash
kubectl get po -n argocd
```

<br/>

### 4. Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

<br/>

## Post-Installation Configuration

<br/>

### 1. Install ArgoCD CLI

```bash
brew install argocd
```

<br/>

### 2. Login to ArgoCD

```bash
argocd login argocd.your-domain.com
```

<br/>

### 3. Add Cluster to ArgoCD

```bash
argocd cluster add your-context@your-cluster --name your-cluster-name --system-namespace argocd
```

<br/>

### 4. Configure CI/CD User

1. Create a CI/CD user account in your Git provider
2. Generate SSH key for CI/CD:
```bash
ssh-keygen -t rsa -b 4096 -C "cicd@your-domain.com" -f ~/.ssh/id_rsa_cicd
```

3. Add the public key to the CI/CD user's SSH keys in your Git provider

<br/>

### 5. Create Repository Secret

Create a secret for Git repository access:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-appset-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@gitlab.your-domain.com:your-group/your-repo.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    [Your private key content here]
    -----END OPENSSH PRIVATE KEY-----
```

```bash
kubectl apply -f gitlab-appset-repo-secret.yaml -n argocd
```

<br/>

## SSO — Keycloak OIDC (Phase 6, 2026-04-29+)

ArgoCD authenticates via a **Keycloak OIDC connector** instead of the legacy GitLab dex connector (Phase 6 cutover). Keycloak's Identity Provider brokers GitLab, so user accounts and groups are preserved (`server` group → `role:server-admin`, `admin@example.com` → `role:global-admin`).

OIDC config is managed in two blocks of [`values/mgmt.yaml`](values/mgmt.yaml): `configs.cm.dex.config` + `extraObjects.argocd-https-redirect` HTTPRoute. The legacy GitLab dex connector block is preserved as comments in the same file (rollback reference).

- **Migration procedure + 5 pitfalls lessons learned**: [`security/keycloak/docs/argocd-migration-en.md`](../../security/keycloak/docs/argocd-migration-en.md) ([Korean](../../security/keycloak/docs/argocd-migration.md))
- **Realm/Client/Mapper setup (kcadm-bootstrap.sh automation + 38/38 verify)**: [`security/keycloak/docs/realm-setup-en.md`](../../security/keycloak/docs/realm-setup-en.md) ([Korean](../../security/keycloak/docs/realm-setup.md))

### 5 Pitfalls (discovered during Phase 6 cutover, all fixed)

1. **Dex boots with `no signing key found`** — argo-cd chart 9.x secrets path is `configs.secret.extra` (not legacy `configs.secrets`). Worked around by inlining client secret as plaintext in dex.config.
2. **HTTP→HTTPS 301 redirect not working** — chart-native `argocd-server` HTTPRoute attaches to both listeners. Force HTTPS-only via `server.httproute.parentRefs[0].sectionName: https`.
3. **Keycloak rejects `Invalid scopes: openid openid profile email groups`** — dex auto-prepends `openid` to connector scopes → duplicate. Omit `scopes:` block + add `groups` client-scope to realm.
4. **Token missing groups claim (silent)** — bootstrap's `-s 'config."key"=value'` syntax partially failed for nested config → mapper config created with `{}` empty. Fixed by JSON file (`-f`) approach + 6-field explicit spec.
5. **Dex receives `groups=[]` only** — dex `oidc` connector ignores groups claim by default. Set `insecureEnableGroups: true` + `getUserInfo: true`.

### RBAC enforcement verification (recommended after every cutover)

1. Comment out `g, admin@example.com, role:global-admin` temporarily → apply → user logout/login → verify it still works via server-admin only (proves server group claim works)
2. Comment out `secondary-project/*` 4 permission lines temporarily → apply → verify secondary-project apps disappear from UI immediately (proves server-admin policy enforcement)
3. Restore both immediately after verification — **NEVER commit temporary policy.csv changes**

<br/>

## Upgrade

<br/>

### Check Latest Version

```bash
# Add/update Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Check latest available version
helm search repo argo/argo-cd
# NAME          CHART VERSION  APP VERSION  DESCRIPTION
# argo/argo-cd  9.4.15         v3.3.4       A Helm chart for Argo CD, a declarative, GitOps...

# Compare with currently installed version
helm list -n argocd
# NAME    NAMESPACE  REVISION  UPDATED                              STATUS    CHART          APP VERSION
# argocd  argocd     11        2026-01-05 16:32:22.27862 +0900 KST  deployed  argo-cd-9.2.4  v3.2.3
```

<br/>

### Using upgrade.sh (Recommended)

An automated upgrade script that handles version checking, backup, diff, and rollback.

```bash
# Show help
./upgrade.sh -h

# Preview upgrade (no files changed)
./upgrade.sh --dry-run

# Upgrade to latest version (auto backup + apply)
./upgrade.sh

# Upgrade to a specific version
./upgrade.sh --version 9.3.0

# List available backups
./upgrade.sh --list-backups

# Rollback to a previous version
./upgrade.sh --rollback

# Clean up old backups (keep last 5)
./upgrade.sh --cleanup-backups
```

The script performs the following steps:
1. Checks current installed version
2. Fetches target version from GitHub
3. Downloads latest `Chart.yaml` and `values.yaml`
4. Shows `Chart.yaml` diff
5. Shows `values.yaml` diff
6. Checks `values/*.yaml` for breaking changes (removed/new top-level keys)
7. Backs up current files to `backup/<timestamp>/` and applies upgrade

<br/>

### Manual Upgrade

Update the `version` field in `helmfile.yaml`:

```yaml
releases:
  - name: argocd
    ...
    version: 9.4.15  # ← update to target version
```

```bash
helmfile diff
helmfile apply
```

<br/>

## Helmfile Commands Reference

```bash
helmfile lint           # Check syntax
helmfile diff           # Show differences
helmfile apply          # Apply changes
helmfile sync -l name=argocd  # Sync specific release
helmfile destroy        # Delete deployment
helmfile status         # Show status
```

<br/>

## Troubleshooting

1. **Dependency Error**
   ```
   Error: no repository definition for https://dandydeveloper.github.io/charts/
   ```
   Solution:
   ```bash
   helm repo add dandydeveloper https://dandydeveloper.github.io/charts/
   ```

2. **Timeout Error**
   ```
   Error: release argocd failed, and has been rolled back due to atomic being set: timed out waiting for the condition
   ```
   Solution: Increase timeout in helmDefaults
   ```yaml
   helmDefaults:
     timeout: 900  # Increase to 15 minutes
   ```

3. **Secret Checksum Changes**
   - It's normal to see secret checksum changes in `helmfile diff`
   - These changes don't affect the actual secret content
   - Safe to proceed with deployment

<br/>

## Security Notes

- Change the default admin password immediately after installation
- Configure SSL/TLS for secure access
- Review and update SSH known hosts as needed
- Store SSH keys and secrets securely
- Use dedicated CI/CD accounts with limited permissions
- Regularly rotate SSH keys and credentials

<br/>

## Appendix: Install with Helm Directly

<details>
<summary>Click to expand</summary>

```bash
# Clone repository
git clone https://github.com/argoproj/argo-helm.git
helm repo add argo https://argoproj.github.io/argo-helm

# Copy and prepare files
cp -r argo-helm/charts/argo-cd .
cd argo-cd/
mkdir -p values
cp values.yaml values/mgmt.yaml
helm dependency update
rm -rf argo-helm

# Install
helm install argocd . -n argocd -f ./values/mgmt.yaml --create-namespace

# Upgrade
helm upgrade argocd . -n argocd -f ./values/mgmt.yaml
```

</details>

<br/>

## Grafana Dashboard

Grafana → **Dashboards** → **New** → **Import** → ID: `14584` → Data source: **Prometheus** → Import

<br/>

## References

- https://argo-cd.readthedocs.io/en/stable/getting_started/
- https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd
- https://argo-cd.readthedocs.io/en/stable/operator-manual/security/
- https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- [Grafana Dashboard 14584](https://grafana.com/grafana/dashboards/14584)
