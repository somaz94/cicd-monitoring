
```bash
k create ns nfs-provisioner

helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
"nfs-subdir-external-provisioner" has been added to your repositories


helm install --kubeconfig=$KUBE_CONFIG  nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --set nfs.server=<nfs-server-ip> --set nfs.path=<nfs-path> -n nfs-provisioner

kubectl --kubeconfig=$KUBE_CONFIG get storageclass
NAME                        PROVISIONER                                     RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
enterprise-multishare-rwx   filestore.csi.storage.gke.io                    Delete          WaitForFirstConsumer   true                   5d3h
enterprise-rwx              filestore.csi.storage.gke.io                    Delete          WaitForFirstConsumer   true                   5d3h
nfs-client                  cluster.local/nfs-subdir-external-provisioner   Delete          Immediate              true                   30s
premium-rwo                 pd.csi.storage.gke.io                           Delete          WaitForFirstConsumer   true                   5d3h
premium-rwx                 filestore.csi.storage.gke.io                    Delete          WaitForFirstConsumer   true                   5d3h
standard                    kubernetes.io/gce-pd                            Delete          Immediate              true                   5d3h
standard-rwo (default)      pd.csi.storage.gke.io                           Delete          WaitForFirstConsumer   true                   5d3h
standard-rwx                filestore.csi.storage.gke.io                    Delete          WaitForFirstConsumer   true                   5d3h

k get po -n nfs-provisioner
NAME                                               READY   STATUS    RESTARTS   AGE
nfs-subdir-external-provisioner-5577c5d8ff-gm9p8   1/1     Running   0          16
```
