# ArgoCD Installation Guide(Helm)

<br/>

## Table of Contents
1. [Installing ArgoCD](#installing-argocd)
2. [Installing cert-manager and Let's Encrypt Settings](#installing-cert-manager-and-lets-encrypt-settings)
3. [Adding Git Source Repository](#adding-git-source-repository)
4. [Additional Notes](#additional-notes)

<br/>

## Installing ArgoCD
```bash

# Normal mode
helm install argocd . -n argocd -f ./values/mgmt-single.yaml --create-namespace

# Normal mode with TLS
helm install argocd . -n argocd -f ./values/mgmt-tls-single.yaml --create-namespace

# HA mode
helm install argocd . -n argocd -f ./values/mgmt-ha.yaml --create-namespace

# HA mode with TLS
helm install argocd . -n argocd -f ./values/mgmt-tls-ha.yaml --create-namespace
```

<br/>

## Installing cert-manager and Let's Encrypt Settings
For detailed instructions, follow the guide: [certmanager-letsencrypt](https://github.com/somaz94/certmanager-letsencrypt).

<br/>

## Adding Git Source Repository
Before registering the git source repo, generate the ssh key and register it with the repo:

```bash
ssh-keygen -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME] 	# rsa
ssh-keygen -m PEM -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]	# pem

kubectl apply -f repo-secret.yaml -n argocd
```

Note: When using a private Gitlab instance, you need to add the Gitlab server's SSH host key to ArgoCD's known_hosts configuration:
```bash
# Get your Gitlab host key
ssh-keyscan gitlab.your-domain.com

# Example output:
# gitlab.your-domain.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCwzyYtyGeO...
# gitlab.your-domain.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHA...
# gitlab.your-domain.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDB2NGVSx5...

# Edit ArgoCD known_hosts ConfigMap
kubectl edit cm -n argocd argocd-ssh-known-hosts-cm

# Add the output from ssh-keyscan to the end of ssh_known_hosts section in the ConfigMap
# Example structure:
# data:
#   ssh_known_hosts: |
#     [existing entries...]
#     gitlab.your-domain.com ssh-rsa AAAAB3NzaC1...
```

<br/>

## Additional Notes
Make sure to modify the `Domain`, `host`, and parts in all yaml files. Additionally, adjust the key details within the `repo-secret.yaml` file as necessary.

