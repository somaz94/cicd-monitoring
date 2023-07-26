## ADD Helm Repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```

## Creating NAMESPACE & PV & StorageClass
- Choose PV or Storage Class

```bash
kubectl create ns monitoring

# Select Disk 
kubectl apply -f pd-csi-pv.yaml -n monitoring
kubectl apply -f pd-csi-sc.yaml -n monitoring 

kubectl apply -f fs-csi-pv.yaml -n monitoring
kubectl apply -f fs-csi-sc.yaml -n monitoring

kubectl apply -f fs-csi-pv.yaml -n monitoring
kubectl apply -f fs-csi-sc-shared-vpc.yaml -n monitoring

# Read nfs-sc-Readme.md if use nfs-pv 
kubectl apply -f nfs-pv.yaml -n monitoring
```

## Installing Loki

```bash
helm install loki  grafana/loki --version 2.16.0 -n monitoring -f values.yaml

helm upgrade loki  grafana/loki --version 2.16.0 -n monitoring -f values.yaml # Upgrade Method
```

## Modifying a Service

```bash
kubectl edit svc -n monitoring loki
...
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/backend-config: '{"ports": {"http":"loki-backend-config"}}'
```

## ADD Ingress and Certificate

```bash
kubectl apply -f loki-ingress.yaml -n monitoring

kubectl apply -f loki-certificate.yaml -n monitoring
```

#### In addition
Modify the Domain, host, static-ip part in all yaml files. 

#### Reference
<https://github.com/grafana/helm-charts>

