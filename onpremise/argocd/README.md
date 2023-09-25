# ArgoCD Installation Guide

<br/>

## Table of Contents
1. [Installing ArgoCD](#installing-argocd)
2. [Installing cert-manager and Let's Encrypt Settings](#installing-cert-manager-and-lets-encrypt-settings)
3. [Adding Ingress](#adding-ingress)
4. [Adding Git Source Repository](#adding-git-source-repository)
5. [Additional Notes](#additional-notes)

<br/>

## Installing ArgoCD
```bash
kubectl create ns argocd

# Normal mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# HA mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

<br/>

## Installing cert-manager and Let's Encrypt Settings
For detailed instructions, follow the guide: [certmanager-letsencrypt](https://github.com/somaz94/certmanager-letsencrypt).

<br/>

## Adding Ingress
```bash
kubectl apply -f argocd-ingress.yaml -n argocd
```

<br/>

## Adding Git Source Repository
Before registering the git source repo, generate the ssh key and register it with the repo:

```bash
ssh-keygen -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME] 	# rsa
ssh-keygen -m PEM -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]	# pem

kubectl apply -f repo-secret.yaml -n argocd
```

<br/>

## Additional Notes
Make sure to modify the `Domain`, `host`, and parts in all yaml files. Additionally, adjust the key details within the `repo-secret.yaml` file as necessary.
