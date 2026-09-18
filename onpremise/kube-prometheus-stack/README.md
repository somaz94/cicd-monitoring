# kube-prometheus-stack

Manages the Kubernetes cluster monitoring stack. Delivery is ArgoCD pull, and the chart-version SSOT is `chart.version` in `argocd/kube-prometheus-stack.yaml`.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/kube-prometheus-stack.yaml`, bumped by `upgrade.py` via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of [docs/ci-upgrade.md](../../../docs/ci-upgrade.md).

<br/>

## Included Components

- **Prometheus** — Metrics collection and storage
- **Grafana** — Dashboard visualization
- **Alertmanager** — Alert routing (Slack integration)
- **node-exporter** — Node metrics (CPU, memory, disk)
- **kube-state-metrics** — K8s object metrics (Pod, Deployment status)

<br/>

## Directory Structure

```
kube-prometheus-stack/
├── Chart.yaml              # Version tracking
├── argocd/
│   └── kube-prometheus-stack.yaml  # ArgoCD release metadata (chart version SSOT)
├── values.yaml             # Upstream defaults (auto-managed by upgrade.py)
├── values/

│   ├── dev.yaml               # Grafana, Prometheus, node-exporter, kube-state-metrics
│   ├── dev-alertmanager.yaml  # Alertmanager routing, inhibit_rules, Slack receiver
│   ├── dev-alerts.yaml        # defaultRules.disabled + the cluster itself (node/pod/cilium/control-plane)
│   ├── dev-alerts-network.yaml # metallb, blackbox
│   ├── dev-alerts-apps.yaml   # argocd, gitlab-runner, harbor, keycloak, sealed-secrets, ES/redis/mysql
│   └── dev-alerts-backup.yaml # every backup Stale/Missing pair
├── scripts/                # Operational helper scripts
│   ├── sync-etcd-client-cert.sh  # Sync client cert Secret for etcd mTLS scrape
│   ├── watchdog-check.sh         # External Prometheus watchdog (bastion cron)
│   └── watchdog-rbac.yaml        # Minimal RBAC for the watchdog
├── docs/                   # Detailed guides
│   ├── external-watchdog-en.md
│   ├── slack-alert-format-en.md
│   └── troubleshooting-en.md
├── upgrade.py              # Version upgrade script
├── backup/                 # Auto backup on upgrade
└── README.md
```

> The custom Grafana dashboard JSON files moved to the [`../grafana-dashboards/`](../grafana-dashboards/) component. This component is deployed from a remote chart and therefore cannot carry in-repo templates, so the dashboards are rendered as ConfigMaps by that local chart and picked up by the Grafana sidecar. Grafana itself, the sidecar, and the chart's own default dashboards are still owned here.

<br/>

## Documentation

| Topic | Document |
|---|---|
| Slack alert message format | [docs/slack-alert-format-en.md](docs/slack-alert-format.md) |
| Troubleshooting | [docs/troubleshooting-en.md](docs/troubleshooting.md) |
| External Prometheus watchdog (bastion cron) | [docs/external-watchdog-en.md](docs/external-watchdog.md) |

Related external docs:
- ArgoCD ghost-alarm incident analysis and rationale for the `argocd-alerts` group: [cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23-en.md](../argocd/docs/ghost-alarm-incident-2026-04-23.md)
  - The `argocd-alerts` group in `dev-alerts-apps.yaml` and the ArgoCD inhibit rule in `dev-alertmanager.yaml` are configured based on the "Final architecture (Option B)" decision in that document.

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- ArgoCD access (delivery is ArgoCD pull)
- StorageClass (e.g., `nfs-client`)

<br/>

## Installation

ArgoCD pull-managed. The chart version SSOT is `chart.version` in `argocd/kube-prometheus-stack.yaml`, and `./upgrade.py` updates that file (there is no helmfile).

```bash
./upgrade.py --dry-run     # check for a newer chart
./upgrade.py               # bump the pin, re-sync Chart.yaml / values.yaml
```

Commit the pin and push to master; ArgoCD syncs that revision.


<br/>

## Upgrade

```bash
./upgrade.py                              # Check latest version and upgrade
./upgrade.py --version <VERSION>          # Upgrade to specific version
./upgrade.py --dry-run                    # Preview only
./upgrade.py --dry-run --version <VERSION>  # Combine flags
```

<br/>

## Access

- **Grafana**: `http://grafana.example.com`
- **Prometheus**: `http://prometheus.example.com`
- **Alertmanager**: `http://alertmanager.example.com`

### Grafana login (Keycloak OIDC since 2026-07-30)

Sign in with **"Sign in with Keycloak"**. Accounts originate in the Keycloak `example` realm.

| Keycloak group | Grafana role | Members |
|---|---|---|
| `global-admin` | **GrafanaAdmin** (server admin + org Admin) | 1 |
| `server` | **Admin** (org Admin) | 8 (GitLab `server` group members) |
| anything else | Viewer | — |

The two levels differ:

- **Admin** = the **org role**. Manages dashboards, folders, datasources, alert rules and org users. That is the scope the ops team needs; Editor stops at dashboards.
- **GrafanaAdmin** = org Admin plus the **server-admin flag (`isAdmin`)**. Only that flag reveals `Administration → Server Admin`: global users across orgs, org create/delete, server settings, LDAP, server stats, plugin install. It is withheld from the 8-member `server` group, which has no need to manage orgs or server settings.

`allow_assign_grafana_admin: true` is set, so the flag **syncs on every login** — leaving `global-admin` revokes server admin at the next sign-in; it is not sticky once granted.

- The role is decided from the token's `groups` claim, so a membership change only takes effect **after a re-login**.
- Do not create users or edit roles inside Grafana — the next login reverts them to whatever `role_attribute_path` evaluates to. Adjust access via **Keycloak group membership** instead.
- `server` → Editor only became meaningful on 2026-07-30. Before that the Keycloak IdP mapper placed **every** brokered GitLab user into `server` — background in [security/keycloak/docs/gitlab-brokering-en.md](../keycloak/docs/gitlab-brokering.md).

**Break-glass (local admin)** — only for when the OIDC chain (Grafana → Keycloak → GitLab) is broken. The login form is deliberately left enabled: this component runs with ArgoCD `autoSync: true`, so a bad change reaches the cluster with no manual gate and this is then the only way back in.

```bash
kubectl -n monitoring get secret grafana-auth -o jsonpath='{.data.admin-password}' | base64 -d
```

The password and the OIDC client secret are sealed into the SealedSecret under `grafana.extraObjects` in `values/dev.yaml`. Changing a value means **resealing**, not editing — `--scope strict` binds the ciphertext to `monitoring/grafana-auth`.

> ⚠️ This work moved the password **out of git; it did not rotate it.** The sealed value is the very password the cluster was already using (kept identical on purpose so git, the live cluster, and this doc agree), and it is still the **shared** password that also appears in `security/vaultwarden`, `security/keycloak`, and `bootstrap/vm`.
> Grafana applies `admin_password` only when it first **creates** the admin user, and that user has existed since 2026-04-07, so an env change alone can never take effect. Rotating it requires `grafana-cli admin reset-admin-password <new>` inside the pod plus a reseal — decided against as of 2026-07-30.

<br/>

## Configuration

### Slack Alert

Set Slack webhook URL in `values/dev-alertmanager.yaml`:

```yaml
alertmanager:
  config:
    receivers:
      - name: 'slack-infra-alerts'
        slack_configs:
          - api_url: "https://hooks.slack.com/services/YOUR_WEBHOOK_URL"
            channel: "#infra-alerts"
```

Alert message format details: [Slack Alert Format Guide](docs/slack-alert-format.md)

### Slack Alert Test

```bash
# Send test alert
amtool alert add test-alert severity=warning \
  --annotation=summary="Test alert" \
  --annotation=description="Testing Slack integration" \
  --alertmanager.url=http://alertmanager.example.com

# Expire test alert
amtool alert expire test-alert \
  --alertmanager.url=http://alertmanager.example.com
```

Install `amtool`:
```bash
go install github.com/prometheus/alertmanager/cmd/amtool@latest
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bash_profile
source ~/.bash_profile
```

Or use curl directly:

```bash
# Send test alert
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning"},"annotations":{"summary":"Test alert","description":"Testing Slack integration"}}]'

# Expire test alert (set endsAt to past time)
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning"},"annotations":{"summary":"Test alert","description":"Testing Slack integration"},"endsAt":"2024-01-01T00:00:00Z"}]'
```

If `#infra-alerts` channel receives the alert, the full pipeline (Prometheus → Alertmanager → Slack) is working.

<br/>

### Physical Server Monitoring

Install node-exporter on target servers, then add IPs to `values/dev.yaml` `additionalScrapeConfigs`:

```yaml
- targets:
    - "192.0.2.10:9100"
```

Verify: `http://prometheus.example.com/targets` → `physical-servers` group

### Grafana Dashboard Import

| Target | Dashboard ID | Name |
|--------|-------------|------|
| Physical servers / K8s nodes | `1860` | [Node Exporter Full](https://grafana.com/grafana/dashboards/1860) |
| MySQL | `14057` | [MySQL Overview](https://grafana.com/grafana/dashboards/14057) |
| Redis | `11835` | [Redis Dashboard](https://grafana.com/grafana/dashboards/11835) |

Import: Grafana → **Dashboards** → **New** → **Import** → Enter ID → Data source: **Prometheus** → Import

> Physical server dashboard: after import, select `physical-servers` in the `job` dropdown

### Custom Dashboards

Custom dashboards are no longer imported manually from this component. They are GitOps-provisioned by the [`../grafana-dashboards/`](../grafana-dashboards/) local chart, which renders one labelled ConfigMap per dashboard JSON for the Grafana sidecar to load automatically.

Details: [Dashboard Guide](../grafana-dashboards/docs/dashboards.md)

<br/>

### etcd Client Cert Sync (mTLS scrape)

The `kubeEtcd` ServiceMonitor scrapes etcd metrics on port 2379 over mTLS, which requires the `etcd-client-cert` Secret in the monitoring namespace. This Secret is built from the kubespray-managed certs on the control-plane node via `scripts/sync-etcd-client-cert.sh`.

**Re-run when**

- the etcd cert is approaching expiry (kubespray default: 365 days)
- the cluster is rebuilt or the control-plane node IP changes
- the admin / CA cert files on the control plane are regenerated

```bash
cd observability/monitoring/kube-prometheus-stack

# Default — pull from control-01 (192.0.2.17), refresh monitoring/etcd-client-cert
./scripts/sync-etcd-client-cert.sh

# Different node / SSH user
./scripts/sync-etcd-client-cert.sh -H 192.0.2.18 -u ubuntu

# Render the manifest only, do not apply
./scripts/sync-etcd-client-cert.sh --dry-run
```

See `./scripts/sync-etcd-client-cert.sh --help` for the full option list.

> Prerequisite: the host running the script must be able to `ssh + sudo cat` against the target node (use the same account as kubespray's `ansible_user`). After refreshing the secret, run `kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus` or wait for the next ArgoCD sync to remount the cert.

<br/>

## Reference

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/kube-prometheus)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
