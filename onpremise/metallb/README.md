## Create MetalLB Namespace

```bash
kubectl create ns metallb-system

```
 
## Install Manifest MetalLB

```bash
curl -O https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
kubectl apply -f metallb-native.yaml -n metallb-system

# If you want to deploy MetalLB using the FRR mode, apply the manifests
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-frr.yaml

```

## Install Helm MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb

helm install -n <네임스페이스> <릴리즈 이름> -f <브랜치별 helm values 파일명>.yaml metallb/metallb
```

## Note

- 'strictARP: true' setting is required when using ipvs mode of kube-proxy
```bash
kubectl edit configmap -n kube-system kube-proxy
...
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
ipvs:
  strictARP: true
```

- It encrypts communication between speakers by creating a memberlist secret.

```bash
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)" -o yaml > metallb-secret.yaml

cat metallb-secret.yaml
apiVersion: v1
data:
  secretkey: bmRzd3hQSWZDUX...
kind: Secret
metadata:
  creationTimestamp: null
  name: memberlist
  namespace: metallb-system
  
kubectl apply -f metallb-secret.yaml -n metallb-system
```

