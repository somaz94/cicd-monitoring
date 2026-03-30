# Kube Prometheus Stack On-Premise Helm Chart

Manages kube-prometheus-stack on an on-premise Kubernetes cluster using Helmfile. Includes Prometheus, Alertmanager, Prometheus Operator, node-exporter, and kube-state-metrics with nginx Ingress and Thanos sidecar for long-term metrics storage.

<br/>

## Directory Structure

```
kube-prometheus-stack/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
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
| Alertmanager | Yes | Alert routing and notifications |
| Prometheus Operator | Yes | Manages Prometheus lifecycle via CRDs |
| kube-state-metrics | Yes | Kubernetes object metrics |
| node-exporter | Yes | Node-level metrics |
| kube-controller-manager | Yes | Control plane metrics (accessible on-premise) |
| kube-scheduler | Yes | Scheduler metrics |
| kube-etcd | Yes | etcd metrics |
| kube-proxy | Yes | kube-proxy metrics |
| Grafana | No | Managed separately (see `../grafana/`) |

> Unlike AWS/GCP managed clusters, all control plane components are accessible on-premise.

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

## Configuration

### Ingress

HTTP ingress is active by default:

```yaml
prometheus:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
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

### Node scheduling (dedicated monitoring nodes)

Uncomment tolerations and nodeSelector in `values/mgmt.yaml` to pin workloads to dedicated monitoring nodes:

```yaml
prometheusSpec:
  tolerations:
    - key: "monitoring"
      operator: "Equal"
      effect: "NoSchedule"
  nodeSelector:
    local-path: enabled
```

The same pattern applies to `alertmanager`, `prometheusOperator`, and `serviceMonitor`.

### External labels

Labels attached to all metrics for multi-cluster identification in Thanos:

```yaml
prometheusSpec:
  externalLabels:
    provider: example
    region: seoul1
    cluster: mgmt
    cluster_id: example-seoul1-mgmt
```

### Metrics retention

```yaml
prometheusSpec:
  retention: 10d   # Local retention before Thanos takes over
```

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

## Connecting Grafana

Add Prometheus as a data source in Grafana:

- **URL**: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Type**: Prometheus

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 83.0.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- https://prometheus.io/docs/
- https://github.com/thanos-io/thanos
