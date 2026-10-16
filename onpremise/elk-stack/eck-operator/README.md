# ECK Operator Helm Chart

Manages the [ECK (Elastic Cloud on Kubernetes) Operator](https://www.elastic.co/guide/en/cloud-on-k8s/current/index.html) on a Kubernetes cluster via ArgoCD.

ECK Operator is the official operator from Elastic that lets you run Elasticsearch, Kibana, APM Server, Beats, and related products declaratively through CRDs.

> **ArgoCD-managed**: this component was migrated to the ArgoCD app-of-apps pull model. The chart-version SSOT is `chart.version` in `argocd/eck-operator.yaml`, bumped by `upgrade.py` via the `argocd-pin` template (not a helmfile). See the "argocd-pin" section of docs/ci-upgrade.md.

<br/>

## Directory Structure

```
eck-operator/
├── .helmignore
├── Chart.yaml                  # upstream chart metadata (maintained by upgrade.py)
├── argocd/
│   └── eck-operator.yaml       # ArgoCD marker — `chart.version` is the chart pin SSOT
├── values.yaml                 # upstream default values (auto-managed by upgrade.py — do not hand-edit)
├── values/
│   └── dev.yaml               # custom values (managedNamespaces, etc.)
├── upgrade.py                  # external-standard version-tracking script
├── backup/
│   └── helmfile.yaml           # retired (was the helmfile deploy path)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes 1.21+
- Helm 3.2+ (for local renders)
- ArgoCD (`infra-applicationset` in `argocd-applicationset`)

<br/>

## Apply Order

Operator + CR split pattern (G14). The operator (this component) and the CR components ([elasticsearch/](../elasticsearch/), [kibana/](../kibana/)) are separate ArgoCD Applications (`infra-eck-operator` / `infra-elasticsearch` / `infra-kibana`). All three share syncWave `"4"`, so **ArgoCD does not enforce an order between them.** Day to day the operator is already running and the order does not matter; it matters in two cases.

1. **Bootstrapping a new cluster**: sync `infra-elasticsearch` once `infra-eck-operator` is Healthy and its CRDs (`elasticsearch.k8s.elastic.co`, `kibana.k8s.elastic.co`, etc.) exist, then `infra-kibana` after Elasticsearch reaches HEALTH=green. A CR App synced first fails for lack of the CRD; sync it again once the operator is up.
2. **Delete in reverse**: remove the Apps (or markers) kibana → elasticsearch → eck-operator.

**Why this order**: the CR is reconciled by the operator; if the operator goes first, nothing is left to clear the CR's finalizer and it gets stuck — deletion must be reverse-ordered.

<br/>

## Configuration Summary

- **Install namespace**: `elastic-system`
- **Managed namespaces**: `logging` (the scope where ECK watches Elastic CRs)
- **CRDs**: installed by the chart (`installCRDs: true`)

<br/>

## Quick Start

ArgoCD deploys this as the Application `infra-eck-operator` (auto-sync, prune + selfHeal). Push a values or chart change to master and it lands on its own, so helmfile is not used. The retired `helmfile.yaml` survives in `backup/` as a record only.

```bash
# Check sync state
kubectl -n argocd get application infra-eck-operator -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

# Render before pushing (the same helm template ArgoCD runs)
helm template eck-operator eck-operator --repo https://helm.elastic.co \
  --version "$(yq '.chart.version' argocd/eck-operator.yaml)" -n elastic-system -f values/dev.yaml
```

<br/>

## Verification

```bash
# Operator pod status
kubectl -n elastic-system get pods

# Confirm CRDs installed
kubectl get crds | grep elastic.co

# Operator logs
kubectl -n elastic-system logs -l control-plane=elastic-operator -f
```

<br/>

## Version Upgrade

```bash
# Check latest version and upgrade
./upgrade.py

# Dry-run
./upgrade.py --dry-run

# Upgrade to a specific version (the current pin is `chart.version` in argocd/eck-operator.yaml)
./upgrade.py --version <X.Y.Z>

# Rollback
./upgrade.py --rollback
```

<br/>

## Expanding managedNamespaces

If you need to deploy Elasticsearch/Kibana CRs in additional namespaces, add them to `managedNamespaces` in `values/dev.yaml`:

```yaml
managedNamespaces:
  - logging
  - another-namespace
```

<br/>

## References

- https://github.com/elastic/cloud-on-k8s
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-install-helm.html
- https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-release-notes.html
