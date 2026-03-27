# NFS Provisioner Installation and Configuration Guide

<br>

## 1. Create a Namespace for NFS Provisioner

```bash
kubectl create ns nfs-provisioner
```

<br>

## 2. Add the NFS Provisioner Helm Repo

```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
```

You should see a confirmation message:
```bash
"nfs-subdir-external-provisioner" has been added to your repositories
```

<br/>

## 3. Install NFS Provisioner using Helm

Replace <nfs-server-ip> and <nfs-path> with your NFS server's IP and path respectively:
```bash
helm install --kubeconfig=$KUBE_CONFIG  nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --set nfs.server=<nfs-server-ip> --set nfs.path=<nfs-path> -n nfs-provisioner
```

<br/>

## 4. Verify the Storage Classes in your Cluster

Run the following command and ensure nfs-client is listed among the storage classes:
```bash
kubectl --kubeconfig=$KUBE_CONFIG get storageclass
```

<br/>

## 5. Check the NFS Provisioner Pod Status

Ensure that the NFS Provisioner pod is running:
```bash
k get po -n nfs-provisioner
NAME                                               READY   STATUS    RESTARTS   AGE
nfs-subdir-external-provisioner-5577c5d8ff-gm9p8   1/1     Running   0          16
```

You should see a pod named similar to nfs-subdir-external-provisioner-XXXXXXXXX-XXXXX with a status of Running.
- **Note**: Make sure to replace placeholders like `<nfs-server-ip>` and `<nfs-path>` with actual values when executing the commands.

