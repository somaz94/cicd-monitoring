## Installing ArgoCD

```bash
kubectl create ns argocd

# Normal mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# HA mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

## ADD Ingress

```bash
kubectl apply -f argocd-ingress.yaml -n argocd
```

## ADD Git Source Repo
- Before registering the git source repo, generate the ssh key and register with the repo

```bash
ssh-keygen -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME] 	# rsa
ssh-keygen -m PEM -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]	# pem

kubectl apply -f repo-secret.yaml -n argocd
```

#### In addition
Modify the Domain, host, part in all yaml files. It also modifies the key of the repo-secret.

#### Reference
<https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#google-cloud-load-balancers-with-kubernetes-ingress>
