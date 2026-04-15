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
├── docs/                   # Detailed guides
│   ├── dashboards-en.md
│   ├── slack-alert-format-en.md
│   └── troubleshooting-en.md
├── upgrade.sh              # Version upgrade script
├── backup/                 # Auto backup on upgrade
└── README.md
```

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

```bash
cd observability/monitoring/kube-prometheus-stack
for f in dashboards/*.json; do
  echo "Importing: $(basename $f)"
  cat "$f" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps({'dashboard':d,'overwrite':True}))" | \
    curl -s -X POST http://grafana.example.com/api/dashboards/db \
      -H "Content-Type: application/json" \
      -u admin:<password> -d @- | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))"
done
```

> Dashboards with same uid are overwritten. No duplicates.

Custom dashboard details: [Dashboard Guide](docs/dashboards-en.md)

<br/>

## Reference

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/kube-prometheus)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
