# ECK Operator Helm Chart

Manages the [ECK (Elastic Cloud on Kubernetes) Operator](https://www.elastic.co/guide/en/cloud-on-k8s/current/index.html) on a Kubernetes cluster via Helmfile.

ECK Operator is the official operator from Elastic that lets you run Elasticsearch, Kibana, APM Server, Beats, and related products declaratively through CRDs.

<br/>

## Directory Structure

```
eck-operator/
├── .helmignore
├── Chart.yaml                  # upstream chart metadata (maintained by upgrade.sh)
├── helmfile.yaml               # Helmfile release definition
├── values/
│   └── mgmt.yaml               # custom values (managedNamespaces, etc.)
├── upgrade.sh                  # external-standard version-tracking script
├── README.md
└── README-en.md
```

<br/>

## Prerequisites

- Kubernetes 1.21+
- Helm 3.2+
- Helmfile

<br/>

## Configuration Summary

- **Install namespace**: `elastic-system`
- **Managed namespaces**: `logging` (the scope where ECK watches Elastic CRs)
- **CRDs**: installed by the chart (`installCRDs: true`)

<br/>

## Quick Start

```bash
# Validate
helmfile lint

# Preview changes
helmfile diff

# Deploy (first time / reinstall)
helmfile sync

# Update
helmfile apply

# Uninstall
helmfile destroy
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
./upgrade.sh

# Dry-run
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 3.3.2

# Rollback
./upgrade.sh --rollback
```

<br/>

## Expanding managedNamespaces

If you need to deploy Elasticsearch/Kibana CRs in additional namespaces, add them to `managedNamespaces` in `values/mgmt.yaml`:

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
