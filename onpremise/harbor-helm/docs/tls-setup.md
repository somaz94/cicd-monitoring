# Harbor TLS Setup (Self-Signed)

Harbor must be exposed over HTTPS for OIDC SSO and secure registry traffic.
This cluster does not run cert-manager, so it uses the same manual self-signed pattern as [Vaultwarden](../../../security/vaultwarden/docs/tls-setup-en.md).

<br/>

## Overview

1. Generate a self-signed certificate (with SAN, 10-year validity) via openssl
2. Register the `harbor-tls` TLS Secret in the `harbor` namespace
3. Apply `expose.tls` / `externalURL` in `values/mgmt.yaml` and run `helmfile apply`
4. Configure client (containerd, docker) trust for the self-signed cert
5. Renew when needed

<br/>

## 1. Issue the Self-Signed Certificate

```bash
# Self-signed certificate for harbor.example.com (10-year validity)
# SAN is required for Go clients (containerd, kaniko, docker) to verify
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout harbor-key.pem -out harbor-cert.pem \
  -subj "/CN=harbor.example.com" \
  -addext "subjectAltName=DNS:harbor.example.com"
```

<br/>

## 2. Register the Kubernetes TLS Secret

```bash
# Create the Secret
kubectl create secret tls harbor-tls \
  --cert=harbor-cert.pem --key=harbor-key.pem \
  -n harbor

# Keep the public cert for node trust distribution (do NOT commit)
mkdir -p .certs
mv harbor-cert.pem .certs/harbor-cert.pem
rm harbor-key.pem
```

> `.certs/` is already listed in `.gitignore`.

<br/>

## 3. Apply values/mgmt.yaml

`expose` block in [`values/mgmt.yaml`](../values/mgmt.yaml):

```yaml
expose:
  type: ingress
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: harbor-tls
  ingress:
    hosts:
      core: harbor.example.com
    className: "nginx"
    annotations:
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      nginx.ingress.kubernetes.io/ssl-passthrough: "false"
      nginx.ingress.kubernetes.io/proxy-body-size: "0"

externalURL: https://harbor.example.com
```

```bash
helmfile diff
helmfile apply
kubectl rollout status -n harbor deploy/harbor-core
```

<br/>

## 4. Verification

### Secret / Certificate

```bash
# Secret existence + type
kubectl get secret harbor-tls -n harbor
# NAME         TYPE                DATA   AGE
# harbor-tls   kubernetes.io/tls   2      ...

# Subject / Issuer / Validity / SAN
kubectl get secret harbor-tls -n harbor -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### HTTP → HTTPS Redirect

```bash
# Should return 308 Permanent Redirect
curl -sI --resolve harbor.example.com:80:192.168.1.55 http://harbor.example.com/ | head -3

# HTTPS should return 200
curl -skI --resolve harbor.example.com:443:192.168.1.55 https://harbor.example.com/ | head -3
```

### Ingress TLS Binding

```bash
kubectl describe ingress -n harbor | grep -A3 TLS
# TLS:
#   harbor-tls terminates harbor.example.com
```

<br/>

## 5. Renewal (before expiration)

```bash
# Delete existing Secret and recreate
kubectl delete secret harbor-tls -n harbor

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout harbor-key.pem -out harbor-cert.pem \
  -subj "/CN=harbor.example.com" \
  -addext "subjectAltName=DNS:harbor.example.com"

kubectl create secret tls harbor-tls \
  --cert=harbor-cert.pem --key=harbor-key.pem -n harbor

rm harbor-key.pem
mv harbor-cert.pem .certs/harbor-cert.pem

# ingress-nginx auto-reloads on Secret change.
# If not reflected, restart core/portal:
kubectl rollout restart -n harbor deploy/harbor-core deploy/harbor-portal
```

<br/>

## 6. Client Trust (Recommended)

> **Current state**: the existing containerd config (`plain_http: true` + `skip_verify: true`) continues to work — containerd follows the 308 redirect to HTTPS and `skip_verify` accepts the self-signed cert.
> The config below is a **semantic cleanup recommendation** and is not urgent.

### Kubespray (recommended)

Already reflected in [`kubespray/inventory-example-cluster/group_vars/all/containerd.yml`](../../../kubespray/inventory-example-cluster/group_vars/all/containerd.yml):

```yaml
containerd_registries_mirrors:
  - prefix: harbor.example.com
    mirrors:
      - host: https://harbor.example.com   # http → https
        capabilities: ["pull", "resolve", "push"]
        skip_verify: true                  # skip TLS verify for self-signed
        # plain_http: true  ← removed (HTTPS now)
```

Roll out to nodes when convenient:

```bash
cd ~/gitlab-project/kuberntes-infra/kubespray
ansible-playbook -i inventory-example-cluster/hosts.yaml \
  cluster.yml --tags container-engine -b
```

### Single-node Manual Edit (reference)

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.example.com".tls]
  insecure_skip_verify = true
```

```bash
sudo systemctl restart containerd
sudo crictl pull harbor.example.com/library/<image>:<tag>
```

> ⚠️ Manual edits get overwritten on the next Kubespray run. Keep `containerd.yml` as the source of truth.

### GitLab CI (Kaniko) Note

The Kaniko template (`gitlab-ci-templates/templates/build/kaniko-harbor.yml`) combining `--skip-tls-verify` + `--insecure-pull` **continues to work** — go-containerregistry probes HTTPS(skip-verify) first in insecure mode.

Replacing `--insecure-pull` with `--skip-tls-verify-pull` is semantically cleaner but not required.

<br/>

## 7. cert-manager Alternative (reference)

If you have a public DNS provider with API-based validation (Cloudflare, Route53, etc.), you can automate with cert-manager + Let's Encrypt. Wix DNS does not support API validation, so this self-signed approach is the practical choice here.

See the "cert-manager + Let's Encrypt" section of [`security/vaultwarden/docs/tls-setup-en.md`](../../../security/vaultwarden/docs/tls-setup-en.md).

<br/>

## References

- Upstream Harbor `values.yaml` `expose.tls` schema: top comments of [`../values.yaml`](../values.yaml)
- Harbor TLS docs: https://goharbor.io/docs/latest/install-config/configure-https/
