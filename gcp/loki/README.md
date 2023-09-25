# Loki Installation and Configuration Guide using Helm

<br/>

## 1. Add the Grafana Helm Repository:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```

<br/>

## 2. Creating Namespace, Persistent Volumes (PV), and StorageClass:

Firstly, create a namespace for monitoring:
```bash
kubectl create ns monitoring
```

Next, choose and apply the appropriate PV and StorageClass configuration:

- For Persistent Disk CSI:
```bash
kubectl apply -f pd-csi-pv.yaml -n monitoring
kubectl apply -f pd-csi-sc.yaml -n monitoring 
```

- For Filestore CSI:
```bash
kubectl apply -f fs-csi-pv.yaml -n monitoring
kubectl apply -f fs-csi-sc.yaml -n monitoring
```

- For Filestore CSI with Shared VPC:
```bash
kubectl apply -f fs-csi-pv.yaml -n monitoring
kubectl apply -f fs-csi-sc-shared-vpc.yaml -n monitoring
```

- For NFS PV (Refer to nfs-sc-Readme.md if using this):
```bash
kubectl apply -f nfs-pv.yaml -n monitoring
```

<br/>

## 3. Install or Upgrade Loki:

To install Loki:
```bash
helm install loki grafana/loki --version 2.16.0 -n monitoring -f values.yaml
```

To upgrade Loki:
```bash
helm upgrade loki grafana/loki --version 2.16.0 -n monitoring -f values.yaml
```

<br/>

## 4. Modify the Loki Service:

Use kubectl edit to modify the Loki service and add the backend-config annotation:
```bash
kubectl edit svc -n monitoring loki
```

Add the following annotation under `metadata`:
```bash
annotations:
  cloud.google.com/backend-config: '{"ports": {"http":"loki-backend-config"}}'
```

<br/>

## 5. Add Ingress and Certificate for Loki:
```bash
kubectl apply -f loki-ingress.yaml -n monitoring
kubectl apply -f loki-certificate.yaml -n monitoring
```

<br/>

### Additional Notes:
- Remember to modify the `Domain`, `host`, and `static-ip` portions in all the provided yaml files.

<br/>

### Reference:
- [Grafana Helm Charts GitHub Repository](https://github.com/grafana/helm-charts)
