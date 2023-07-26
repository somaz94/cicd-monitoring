# ArgoCD

## ArgoCD Install

```bash
kubectl create ns argocd

# Normal mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# HA mode
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

## Disable internal TLS

```bash
kubectl edit cm -n argocd argocd-cmd-params-cm
...
data:
  redis.server: argocd-redis-ha-haproxy:6379
  server.insecure: "true" # ADD server.insecure

# Pod Restart
kubectl delete po -n argocd argocd-server-xxxxxxxx-xxxxxx-xxxxxxx
```

## Modifying a Service

```bash
k edit svc -n argocd argocd-server 
...
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/backend-config: '{"ports": {"http":"argocd-backend-config"}}' # ADD backend-config annotation
```

## ADD Ingress and Certificate

```bash
kubectl apply -f argocd-ingress.yaml -n argocd

kubectl apply -f argocd-certificate.yaml -n argocd
```

## ADD Git Source Repo
- Before registering the git source repo, generate the ssh key and register with the repo

```bash
ssh-keygen -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME] 	# rsa
ssh-keygen -m PEM -t rsa -f ~/.ssh/[KEY_FILENAME] -C [USERNAME]	# pem

kubectl apply -f repo-secret.yaml -n argocd
```

#### In addition
Modify the Domain, host, static-ip part in all yaml files. It also modifies the key of the repo-secret.

#### Reference
<https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#google-cloud-load-balancers-with-kubernetes-ingress>

