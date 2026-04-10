# Elasticsearch Helm Chart

Manages [Elasticsearch](https://www.elastic.co/elasticsearch/) on a Kubernetes cluster using Helmfile.

<br/>

## Directory Structure

```
elasticsearch/
├── .helmignore                 # Files excluded from Helm packaging
├── Chart.yaml                  # Local chart definition
├── helmfile.yaml               # Helmfile release definition (uses local chart)
├── values.yaml                 # Upstream default values
├── values/
│   └── mgmt.yaml               # Custom values (manually managed)
├── templates/                  # Local Helm templates
│   ├── NOTES.txt
│   ├── _helpers.tpl
│   ├── configmap.yaml
│   ├── ingress.yaml
│   ├── networkpolicy.yaml
│   ├── poddisruptionbudget.yaml
│   ├── podsecuritypolicy.yaml
│   ├── role.yaml
│   ├── rolebinding.yaml
│   ├── secret-cert.yaml
│   ├── secret.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   ├── statefulset.yaml
│   └── test/
│       └── test-elasticsearch-health.yaml
├── README.md
└── README-en.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- StorageClass (for PVC usage)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Destroy
helmfile destroy
```

<br/>

## Verification

### Check Password

```bash
kubectl get secrets --namespace=monitoring elasticsearch-master-credentials -ojsonpath='{.data.password}' | base64 -d
```

### Health Check

```bash
# Cluster status
curl -k -u "elastic:${PASSWORD}" "http://elasticsearch.example.com/_cluster/health"

# Index list
curl -k -u "elastic:${PASSWORD}" "http://elasticsearch.example.com/_cat/indices"

# Node list
curl -k -u "elastic:${PASSWORD}" "http://elasticsearch.example.com/_cat/nodes"

# Shard status
curl -k -u "elastic:${PASSWORD}" "http://elasticsearch.example.com/_cat/shards"
```

<br/>

## Configuration

Custom settings are managed in `values/mgmt.yaml`. Key settings:

- Ingress configuration
- Resource limits/requests
- PVC StorageClass and size
- Replicas

<br/>

## Helmfile Commands Reference

```bash
helmfile lint           # Validate configuration
helmfile diff           # Preview changes
helmfile apply          # Apply
helmfile destroy        # Destroy
helmfile status         # Check status
```

<br/>

## Troubleshooting

| Error | Solution |
|-------|----------|
| PVC not bound | Check StorageClass with `kubectl get sc` |
| Pod CrashLoopBackOff | Check `kubectl logs -n monitoring elasticsearch-master-0` |
| Secret checksum changed | Normal behavior, regenerated during Helm rendering |

<br/>

<details>
<summary>Install with Helm Directly</summary>

```bash
# Clone & prepare
git clone https://github.com/elastic/helm-charts.git
helm repo add elastic https://helm.elastic.co
helm repo update
helm dependency update .

# Install
helm install elasticsearch . -n monitoring -f ./values/mgmt.yaml --create-namespace

# Upgrade
helm upgrade elasticsearch . -n monitoring -f ./values/mgmt.yaml
```

</details>

<br/>

## References

- https://github.com/elastic/helm-charts
- https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
