## ADD Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

## Creating NAMESPACE & PV & StorageClass
- Choose PV or Storage Class

```bash
kubectl create ns prometheus

# Select Disk 
kubectl apply -f pd-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f pd-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f pd-csi-sc.yaml -n prometheus

kubectl apply -f fs-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f fs-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f fs-csi-sc.yaml -n prometheus

kubectl apply -f fs-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f fs-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f fs-csi-sc-shared-vpc.yaml -n prometheus

# Read nfs-sc-Readme.md if use nfs-pv
kubectl apply -f nfs-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f nfs-pv-prometheus-server.yaml -n prometheus

```

## Installing Grafana

```bash
helm install prometheus prometheus-community/prometheus -f values.yaml -n prometheus

helm Upgrade prometheus prometheus-community/prometheus -f values.yaml -n prometheus # Upgrade Method
```

## Modifying a Service

```bash
kubectl edit svc -n prometheus prometheus-server
...
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/backend-config: '{"ports": {"http":"prometheus-backend-config"}}'
```

## ADD Ingress and Certificate

```bash
kubectl apply -f prometheus-ingress.yaml -n monitoring

kubectl apply -f prometheus-certificate.yaml -n monitoring
```

#### In addition
Modify the Domain, host, static-ip part in all yaml files. 

#### Reference
<https://github.com/prometheus-community/helm-charts>

