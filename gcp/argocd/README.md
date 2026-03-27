# ArgoCD GCP Helm Chart

Manages ArgoCD on GCP GKE using Helmfile. Configured with nginx ingress (or GKE Ingress alternative) and Slack notifications.

<br/>

## Directory Structure

```
argocd/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Management environment configuration
├── examples/
│   └── gke-ingress.yaml  # GKE Ingress + ManagedCertificate + BackendConfig
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old files (manual manifests)
└── README.md
```

<br/>

## Prerequisites

- GCP GKE cluster
- Helm 3
- Helmfile
- Nginx Ingress Controller (or GKE Ingress)

<br/>

## Configuration

### Ingress Options

**Option A: Nginx Ingress (default)**

Pre-configured in `values/mgmt.yaml`. Works out of the box with nginx-ingress-controller.

**Option B: GKE Ingress**

Requires additional resources. Apply before deployment:

```bash
kubectl apply -f examples/gke-ingress.yaml
```

Then switch to the GKE ingress section in `values/mgmt.yaml`.

> **Note:** GKE Ingress requires a reserved static IP. Create one with:
> ```bash
> gcloud compute addresses create example-gke-argocd-lb-ip --global
> ```

<br/>

### Initial Admin Password

```bash
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

<br/>

### Git Repository Registration

Generate an SSH key and create a Kubernetes secret:

```bash
ssh-keygen -t rsa -f ~/.ssh/argocd-repo-key -C argocd
kubectl create secret generic example-repo-secret -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:example-org/example-repo.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd-repo-key
kubectl label secret example-repo-secret -n argocd argocd.argoproj.io/secret-type=repository
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

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 9.5.0

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## References

- https://argo-cd.readthedocs.io/en/stable/
- https://github.com/argoproj/argo-helm
- https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#google-cloud-load-balancers-with-kubernetes-ingress
