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
│   ├── mgmt.yaml               # Grafana, Prometheus, node-exporter, kube-state-metrics
│   ├── mgmt-alertmanager.yaml  # Alertmanager routing, inhibit_rules, Slack receiver
│   └── mgmt-alerts.yaml        # defaultRules.disabled + custom PrometheusRule groups
├── dashboards/             # Custom Grafana dashboard JSON files
├── scripts/                # Operational helper scripts
│   └── import-dashboards.sh
├── docs/                   # Detailed guides
│   ├── dashboards-en.md
│   ├── slack-alert-format-en.md
│   └── troubleshooting-en.md
├── upgrade.sh              # Version upgrade script
├── backup/                 # Auto backup on upgrade
└── README.md
```

<br/>

## Documentation

| Topic | Document |
|---|---|
| Grafana dashboard layout | [docs/dashboards-en.md](docs/dashboards-en.md) |
| Slack alert message format | [docs/slack-alert-format-en.md](docs/slack-alert-format-en.md) |
| Troubleshooting | [docs/troubleshooting-en.md](docs/troubleshooting-en.md) |

Related external docs:
- ArgoCD ghost-alarm incident analysis and rationale for the `argocd-alerts` group: [cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23.md](../../../cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23.md) (KR)
  - The `argocd-alerts` group in `mgmt-alerts.yaml` and the ArgoCD inhibit rule in `mgmt-alertmanager.yaml` are configured based on the "Final architecture (Option B)" decision in that document.

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
./upgrade.sh                              # Check latest version and upgrade
./upgrade.sh --version <VERSION>          # Upgrade to specific version
./upgrade.sh --dry-run                    # Preview only
./upgrade.sh --dry-run --version <VERSION>  # Combine flags
```

<br/>

## Access

- **Grafana**: `http://grafana.example.com`
- **Prometheus**: `http://prometheus.example.com`
- **Alertmanager**: `http://alertmanager.example.com`

<br/>

## Configuration

### Slack Alert

Set Slack webhook URL in `values/mgmt-alertmanager.yaml`:

```yaml
alertmanager:
  config:
    receivers:
      - name: 'slack-infra-alerts'
        slack_configs:
          - api_url: "https://hooks.slack.com/services/YOUR_WEBHOOK_URL"
            channel: "#infra-alerts"
```

Alert message format details: [Slack Alert Format Guide](docs/slack-alert-format-en.md)

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

Install node-exporter on target servers, then add IPs to `values/mgmt.yaml` `additionalScrapeConfigs`:

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

Custom dashboard details: [Dashboard Guide](docs/dashboards-en.md)

<br/>

## Reference

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/kube-prometheus)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
