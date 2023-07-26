## ADD Helm Repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```

## Creating NAMESPACE & PV & StorageClass
- Choose PV or Storage Class

```bash
kubectl create ns monitoring

# Select Disk 
kubectl apply -f efs-csi-pv.yaml -n monitoring
kubectl apply -f efs-csi-sc.yaml -n monitoring

kubectl apply -f ebs-csi-pv.yaml -n monitoring
kubectl apply -f ebs-csi-sc.yaml -n monitoring

```

## Installing Loki

```bash
helm install loki  grafana/loki --version 2.16.0 -n monitoring -f values.yaml

helm upgrade loki  grafana/loki --version 2.16.0 -n monitoring -f values.yaml # Upgrade Method
```

#### In addition
Modify the Domain, host part in all yaml files. 

#### Reference
<https://github.com/grafana/helm-charts>


