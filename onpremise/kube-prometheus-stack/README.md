# kube-prometheus-stack

Manages the Kubernetes cluster monitoring stack using Helmfile.

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
├── helmfile.yaml           # Helmfile release definition
├── values/
│   ├── dev.yaml               # Grafana, Prometheus, node-exporter, kube-state-metrics
│   ├── dev-alertmanager.yaml  # Alertmanager routing, inhibit_rules, Slack receiver
│   └── dev-alerts.yaml        # defaultRules.disabled + custom PrometheusRule groups
├── dashboards/             # Custom Grafana dashboard JSON files
├── scripts/                # Operational helper scripts
│   ├── import-dashboards.sh
│   └── sync-etcd-client-cert.sh
├── docs/                   # Detailed guides
│   ├── dashboards-en.md
│   ├── slack-alert-format-en.md
│   └── troubleshooting-en.md
├── upgrade.py              # Version upgrade script
├── backup/                 # Auto backup on upgrade
└── README.md
```

<br/>

## Documentation

| Topic | Document |
|---|---|
| Grafana dashboard layout | [docs/dashboards-en.md](docs/dashboards.md) |
| Slack alert message format | [docs/slack-alert-format-en.md](docs/slack-alert-format.md) |
| Troubleshooting | [docs/troubleshooting-en.md](docs/troubleshooting.md) |

Related external docs:
- ArgoCD ghost-alarm incident analysis and rationale for the `argocd-alerts` group: [cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23.md](../argocd/docs/ghost-alarm-incident-2026-04-23.md) (KR)
  - The `argocd-alerts` group in `dev-alerts.yaml` and the ArgoCD inhibit rule in `dev-alertmanager.yaml` are configured based on the "Final architecture (Option B)" decision in that document.

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- StorageClass (e.g., `nfs-client`)

<br/>

## Installation

```bash
# First install (CRDs not yet present)
helmfile sync

# Subsequent updates
helmfile apply
```

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
    - "192.168.1.10:9100"
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

### Import All Custom Dashboards

Use `scripts/import-dashboards.sh` to POST JSON files under `dashboards/` through the Grafana HTTP API. Re-runs are idempotent because dashboards with the same uid are overwritten (`overwrite: true`).

```bash
cd observability/monitoring/kube-prometheus-stack

# Bulk import — password resolved from the in-cluster secret
./scripts/import-dashboards.sh --all --from-secret

# Bulk import — password via environment variable
GRAFANA_PASSWORD=<password> ./scripts/import-dashboards.sh --all

# Specific files (repeat -f)
./scripts/import-dashboards.sh -f dashboards/mysql-dashboard.json -f dashboards/redis-dashboard.json -p <password>

# Skip specific files (substring match, comma-separated)
./scripts/import-dashboards.sh --all --except ingress-nginx,metallb --from-secret

# Dry-run — list targets without POSTing
./scripts/import-dashboards.sh --all --dry-run

# Different Grafana endpoint
./scripts/import-dashboards.sh --all -u http://grafana.example.com -U admin -p <password>
```

See `./scripts/import-dashboards.sh --help` for the full option list.

> Only JSON files directly under `dashboards/` are processed — sub-directories such as `dashboards/_deprecated/` are skipped automatically.
> `--from-secret` reads the Grafana password from a Kubernetes secret via `kubectl`. The default target is `monitoring/kube-prometheus-stack-grafana` (key `admin-password`); override with `--secret-namespace / --secret-name / --secret-key` or the `GRAFANA_SECRET_NS / GRAFANA_SECRET_NAME / GRAFANA_SECRET_KEY` environment variables. The current kubectl context must point at the target cluster.

Custom dashboard details: [Dashboard Guide](docs/dashboards.md)

<br/>

### etcd Client Cert Sync (mTLS scrape)

The `kubeEtcd` ServiceMonitor scrapes etcd metrics on port 2379 over mTLS, which requires the `etcd-client-cert` Secret in the monitoring namespace. This Secret is built from the kubespray-managed certs on the control-plane node via `scripts/sync-etcd-client-cert.sh`.

**Re-run when**

- the etcd cert is approaching expiry (kubespray default: 365 days)
- the cluster is rebuilt or the control-plane node IP changes
- the admin / CA cert files on the control plane are regenerated

```bash
cd observability/monitoring/kube-prometheus-stack

# Default — pull from control-01 (192.168.1.17), refresh monitoring/etcd-client-cert
./scripts/sync-etcd-client-cert.sh

# Different node / SSH user
./scripts/sync-etcd-client-cert.sh -H 192.168.1.18 -u ubuntu

# Render the manifest only, do not apply
./scripts/sync-etcd-client-cert.sh --dry-run
```

See `./scripts/sync-etcd-client-cert.sh --help` for the full option list.

> Prerequisite: the host running the script must be able to `ssh + sudo cat` against the target node (use the same account as kubespray's `ansible_user`). After refreshing the secret, run `kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus` or wait for the next helmfile sync to remount the cert.

<br/>

## Reference

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/kube-prometheus)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
