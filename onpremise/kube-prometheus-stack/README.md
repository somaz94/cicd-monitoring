# Kube Prometheus Stack On-Premise Helm Chart

Manages kube-prometheus-stack on an on-premise Kubernetes cluster using Helmfile. Includes Prometheus, Grafana, Alertmanager, Prometheus Operator, node-exporter, and kube-state-metrics with nginx Ingress, Slack alerting, and Thanos sidecar for long-term metrics storage.

<br/>

## Directory Structure

```
kube-prometheus-stack/
├── Chart.yaml              # Version tracking (no local templates)
├── helmfile.yaml           # Helmfile release definition (uses remote chart)
├── values.yaml             # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml           # Management environment configuration
├── dashboards/             # Custom Grafana dashboard JSON files
├── docs/                   # Documentation (dashboards, alerts, troubleshooting)
├── upgrade.sh              # Version upgrade script
├── backup/                 # Auto backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- On-premise Kubernetes cluster (>=1.25)
- Helm 3
- Helmfile
- ingress-nginx controller
- `local-path` StorageClass (or equivalent)
- Thanos object storage secret (if using Thanos sidecar)

<br/>

## Included Components

| Component | Enabled | Description |
|-----------|---------|-------------|
| Prometheus | Yes | Metrics collection and storage |
| Grafana | Yes | Dashboard visualization |
| Alertmanager | Yes | Alert routing (Slack integration) |
| Prometheus Operator | Yes | Manages Prometheus lifecycle via CRDs |
| kube-state-metrics | Yes | Kubernetes object metrics (Pod, Deployment status) |
| node-exporter | Yes | Node-level metrics (CPU, memory, disk) |
| kube-controller-manager | Yes | Control plane metrics (accessible on-premise) |
| kube-scheduler | Yes | Scheduler metrics |
| kube-etcd | Yes | etcd metrics |
| kube-proxy | Yes | kube-proxy metrics (disable if using Cilium) |

> Unlike AWS/GCP managed clusters, all control plane components are accessible on-premise.

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

Set Slack webhook URL in `values/mgmt.yaml`:

```yaml
alertmanager:
  config:
    receivers:
      - name: 'slack-alerts'
        slack_configs:
          - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
            channel: "#alerts"
```

Alert message format details: [Slack Alert Format Guide](docs/slack-alert-format.md)

### Slack Alert Test

```bash
# Send test alert
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning"},"annotations":{"summary":"Test alert","description":"Testing Slack integration"}}]'

# Expire test alert
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning"},"annotations":{"summary":"Test alert","description":"Testing Slack integration"},"endsAt":"2024-01-01T00:00:00Z"}]'
```

<br/>

### Physical Server Monitoring

Install node-exporter on target servers (see [../node-exporter/](../node-exporter/)), then add IPs to `values/mgmt.yaml` `additionalScrapeConfigs`:

```yaml
- targets:
    - "10.0.0.1:9100"
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
cd kube-prometheus-stack
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

Custom dashboard details: [Dashboard Guide](docs/dashboards.md)

<br/>

### Ingress

HTTP ingress is active by default:

```yaml
prometheus:
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - prometheus.example.com
```

To enable HTTPS with cert-manager:

```yaml
prometheus:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      cert-manager.io/cluster-issuer: "cloudflare-issuer"
    hosts:
      - prometheus.example.com
    tls:
      - secretName: prometheus-tls
        hosts:
          - prometheus.example.com
```

<br/>

## Storage

Prometheus uses `local-path` StorageClass with a 100Gi PVC:

```yaml
prometheusSpec:
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: local-path
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

<br/>

## Thanos Sidecar

Prometheus is configured with a Thanos sidecar for long-term metrics storage.

### Create object storage secret

```bash
kubectl create secret generic thanos-objstore \
  --from-file=objstore.yml=./objstore.yml \
  -n monitoring
```

Example `objstore.yml` (S3-compatible):

```yaml
type: S3
config:
  bucket: your-thanos-bucket
  endpoint: s3.example.com
  access_key: YOUR_ACCESS_KEY
  secret_key: YOUR_SECRET_KEY
```

### Thanos services

| Service | Type | Description |
|---------|------|-------------|
| `thanosService` | ClusterIP | Internal gRPC for Thanos Query |
| `thanosServiceMonitor` | ServiceMonitor | Scrape sidecar metrics |
| `thanosServiceExternal` | NodePort | External access for Thanos Query |

See [../thanos/](../thanos/) for the Thanos Query/Store deployment.

<br/>

## Connecting Grafana

Add Prometheus as a data source in Grafana:

- **URL**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Type**: Prometheus

<br/>

## Documentation

- [Dashboard Guide](docs/dashboards.md) — Custom dashboard import and management
- [Slack Alert Format](docs/slack-alert-format.md) — Alert message format reference
- [Troubleshooting](docs/troubleshooting.md) — Known issues and solutions

<br/>

## References

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/kube-prometheus)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
- [Thanos](https://github.com/thanos-io/thanos)
