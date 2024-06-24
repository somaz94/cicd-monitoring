# ArgoCD Guide

This guide will take you through the process of installing ArgoCD, 
adding ingress, and registering a git source repository.

## Table of Contents

- [Installing ArgoCD](#installing-argocd)
- [Adding Ingress](#adding-ingress)
- [Adding Git Source Repository](#adding-git-source-repo)
- [Additional Notes](#in-addition)
- [Reference](#reference)

## Installing ArgoCD

Install ArgoCD using the following commands:

```bash
kubectl create ns argocd

# Normal mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# HA mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

## Adding Ingress

Add ingress for ArgoCD with:

```bash
kubectl apply -f argocd-ingress.yaml -n argocd
```

## Adding Git Source Repo

Before registering the git source repo, 
generate the ssh key and register it with the repo:

```bash
ssh-keygen -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]  # rsa format
ssh-keygen -m PEM -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]  # pem format

kubectl apply -f repo-secret.yaml -n argocd
```

## In addition

Make sure to modify the `Domain`, `host`, and parts in all yaml files. 
Also, adjust the key details within the `repo-secret.yaml` file as necessary.

## Reference

- [ArgoCD Ingress Operator Manual](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#aws-application-load-balancers-albs-and-classic-elb-http-mode)

