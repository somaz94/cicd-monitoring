# Kibana Helm Chart

Manages [Kibana](https://www.elastic.co/kibana/) on a Kubernetes cluster using Helmfile.

<br/>

## Directory Structure

```
kibana/
├── .helmignore                         # Files excluded from Helm packaging
├── Chart.yaml                          # Local chart definition
├── helmfile.yaml                       # Helmfile release definition (uses local chart)
├── values.yaml                         # Upstream default values
├── values/
│   └── mgmt.yaml                       # Custom values (manually managed)
├── templates/                          # Local Helm templates
│   ├── NOTES.txt
│   ├── _helpers.tpl
│   ├── configmap-helm-scripts.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── ingress.yaml
│   ├── post-delete-job.yaml
│   ├── post-delete-role.yaml
│   ├── post-delete-rolebinding.yaml
│   ├── post-delete-serviceaccount.yaml
│   ├── pre-install-job.yaml
│   ├── pre-install-role.yaml
│   ├── pre-install-rolebinding.yaml
│   ├── pre-install-serviceaccount.yaml
│   └── service.yaml
├── README.md
└── README-en.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Elasticsearch (required - installed in the same namespace)

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

## Access

- URL: http://kibana.example.com
- Username: `elastic`
- Password: Use the Elasticsearch password

```bash
# Check Elasticsearch password
kubectl get secrets --namespace=monitoring elasticsearch-master-credentials -ojsonpath='{.data.password}' | base64 -d
```

<br/>

## Initial Setup

1. **Index Patterns**: Stack Management > Index Patterns > Create `filebeat-*`, etc.
2. **Security**: Stack Management > Security > Configure roles/users
3. **Visualizations**: Visualize > Create data-driven visualizations
4. **Dashboards**: Dashboard > Create dashboards combining visualizations

<br/>

## Configuration

Custom settings are managed in `values/mgmt.yaml`. Key settings:

- Elasticsearch connection settings
- Ingress configuration
- Resource limits/requests

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

| Symptom | Solution |
|---------|----------|
| Elasticsearch connection failure | Check `kubectl get configmap -n monitoring kibana-kibana-config -o yaml` |
| UI not accessible | Check `kubectl get svc,ingress -n monitoring` |
| Pod not starting | Check `kubectl logs -n monitoring -l app=kibana` |

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
helm install kibana . -n monitoring -f ./values/mgmt.yaml

# Upgrade
helm upgrade kibana . -n monitoring -f ./values/mgmt.yaml
```

</details>

<br/>

## References

- https://github.com/elastic/helm-charts
- https://www.elastic.co/guide/en/kibana/current/index.html
