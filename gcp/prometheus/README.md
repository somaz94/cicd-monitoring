# Prometheus Setup Guide

<br/>

## Table of Contents
- [Add Helm Repo](#add-helm-repo)
- [Creating Namespace, PV & StorageClass](#creating-namespace-pv--storageclass)
- [Installing Prometheus](#installing-prometheus)
- [Modifying a Service](#modifying-a-service)
- [Setting Up Ingress and Certificate](#setting-up-ingress-and-certificate)
- [Application Monitoring](#application-monitoring)
- [Additional Configuration](#additional-configuration)
- [Reference](#reference)

<br/>

## Add Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

<br/>

## Creating Namespace, PV & StorageClass
Before starting, choose between PV or Storage Class.
```bash
kubectl create ns prometheus

# Disk Selection 
kubectl apply -f pd-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f pd-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f pd-csi-sc.yaml -n prometheus

kubectl apply -f fs-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f fs-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f fs-csi-sc.yaml -n prometheus

kubectl apply -f fs-csi-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f fs-csi-pv-prometheus-server.yaml -n prometheus
kubectl apply -f fs-csi-sc-shared-vpc.yaml -n prometheus

# If using NFS PV, refer to nfs-sc-Readme.md
kubectl apply -f nfs-pv-prometheus-alertmanager.yaml -n prometheus
kubectl apply -f nfs-pv-prometheus-server.yaml -n prometheus
```

<br/>

## Installing Prometheus
```bash
helm install prometheus prometheus-community/prometheus -f values.yaml -n prometheus
helm upgrade prometheus prometheus-community/prometheus -f values.yaml -n prometheus # For upgrades
```

<br/>

## Modifying a Service
```bash
kubectl edit svc -n prometheus prometheus-server
```

Ensure the following annotation is added:
```bash
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/backend-config: '{"ports": {"http":"prometheus-backend-config"}}'
```

<br/>

## Setting Up Ingress and Certificate
```bash
kubectl apply -f prometheus-ingress.yaml -n prometheus
kubectl apply -f prometheus-certificate.yaml -n prometheus
```

<br/>

## Application Monitoring
```bash
helm upgrade prometheus prometheus-community/prometheus -f extra-scrape-configs-values.yaml -f values.yaml -n prometheus
```

<br/>

## Additional Configuration
Ensure you modify the `Domain`, `host`, and `static-ip` sections in all the provided yaml files.

<br/>

## Reference
- [Prometheus Helm Charts GitHub Repository](https://github.com/prometheus-community/helm-charts)
