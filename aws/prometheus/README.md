## ADD Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

## Creating NAMESPACE & PV & StorageClass
- Choose PV or Storage Class

```bash
kubectl create ns monitoring

# Select Disk 
kubectl apply -f efs-csi-pv-prometheus-server.yaml -n monitoring
kubectl apply -f efs-csi-pv-prometheus-alertmanager.yaml -n monitoring
kubectl apply -f efs-csi-sc.yaml -n monitoring

kubectl apply -f ebs-csi-pv-prometheus-server.yaml -n monitoring
kubectl apply -f ebs-csi-pv-prometheus-alertmanager.yaml -n monitoring
kubectl apply -f ebs-csi-sc.yaml -n monitoring

```

## Installing Prometheus

```bash
helm install prometheus prometheus-community/prometheus -f values.yaml -n prometheus

helm Upgrade prometheus prometheus-community/prometheus -f values.yaml -n prometheus # Upgrade Method
```

## ADD Application Monitoring
```bash
helm upgrade prometheus prometheus-community/prometheus -f extra-scrape-configs-values.yaml -f values.yaml -n prometheus
```

#### In addition
Modify the Domain, host part in all yaml files. 

#### Reference
<https://github.com/prometheus-community/helm-charts>


