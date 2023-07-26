## ADD Helm Repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```

## Creating NAMESPACE & PV & StorageClass
- Choose PV or Storage Class

```bash
kubectl create ns monitoring

# Select Disk 
kubectl apply -f pd-csi-pv.yaml pd-csi-sc.yaml -n monitoring 

kubectl apply -f fs-csi-pv.yaml fs-csi-sc.yaml -n monitoring

kubectl apply -f fs-csi-pv-shared-vpc.yaml fs-csi-sc-shared-vpc.yaml -n monitoring

# Read nfs-sc-Readme.md if use nfs-pv 
kubectl apply -f nfs-pv -n monitoring
```

## Installing Grafana

```bash
helm install grafana grafana/grafana -n monitoring -f values.yaml

helm upgrade grafana grafana/grafana -n monitoring -f values.yaml # Upgrade Method
```

## Modifying a Service

```bash
kubectl edit svc -n monitoring grafana
...
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/backend-config: '{"ports": {"http":"grafana-backend-config"}}'
```

## ADD Ingress and Certificate

```bash
kubectl apply -f grafana-ingress.yaml -n monitoring

kubectl apply -f grafana-certificate.yaml -n monitoring
```

#### In addition
Modify the Domain, host, static-ip part in all yaml files. 

#### Reference
<https://github.com/grafana/helm-charts>

