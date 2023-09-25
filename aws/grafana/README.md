# Grafana Installation Guide

<br/>

## Table of Contents
- [ADD Helm Repo](#add-helm-repo)
- [Creating NAMESPACE & PV & StorageClass](#creating-namespace--pv--storageclass)
- [Installing Grafana](#installing-grafana)
- [In addition](#in-addition)
- [Reference](#reference)

<br/>

## ADD Helm Repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```

<br/>

## Creating NAMESPACE & PV & StorageClass

Choose PV or Storage Class:

```bash
kubectl create ns monitoring

# Select Disk 
kubectl apply -f efs-csi-pv.yaml -n monitoring
kubectl apply -f efs-csi-sc.yaml -n monitoring

kubectl apply -f ebs-csi-pv.yaml -n monitoring
kubectl apply -f ebs-csi-sc.yaml -n monitoring
```

<br/>

## Installing Grafana

```bash
helm install grafana grafana/grafana -n monitoring -f values.yaml

helm upgrade grafana grafana/grafana -n monitoring -f values.yaml # Upgrade Method
```

<br/>

## In addition
Modify the `Domain`, `host` in all yaml files.

<br/>

## Reference
[Grafana Helmet Charts](https://github.com/grafana/helm-charts)

