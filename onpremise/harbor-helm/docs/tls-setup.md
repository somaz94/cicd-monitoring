# Harbor TLS Setup

Harbor must be exposed over HTTPS for OIDC SSO and secure registry traffic.
This document covers where TLS is terminated today, plus the self-signed certificate approach on the Ingress path that was retired on 2026-04-17.

<br/>

## Current TLS Termination (NGF Gateway)

HTTPS is terminated by the NGF `ngf` Gateway in the `nginx-gateway` namespace using the `wildcard-example-tls` certificate.
Harbor only attaches to that Gateway through an HTTPRoute — **this component owns no certificate.**

- `expose.type: route` in [`values/dev.yaml`](../values/dev.yaml) — the chart generates the `harbor-route` HTTPRoute
- `expose.tls.secret.secretName` is dead config in route mode; it is kept only for values schema compatibility
- The self-signed `harbor-tls` Secret was removed on 2026-04-17 as unused (consolidated into `wildcard-example-tls`)
- The HTTP→HTTPS redirect HTTPRoute and the ClientSettingsPolicy, which the chart does not generate, stay as raw manifests in [`manifests/httproutes.yaml`](../manifests/httproutes.yaml)
- Certificate issuance/renewal belongs to `network/nginx-gateway-fabric` — see [TLS Wildcard Setup](../../../network/nginx-gateway-fabric/docs/tls-wildcard-setup.md)

The wildcard certificate is self-signed too, so the client trust configuration in §6 still applies as-is.
The `harbor-tls` procedures in §1, §2 and §5, by contrast, matter **only when rolling back to the Ingress path.**

<br/>

## Overview (rollback — Ingress path)

1. Generate a self-signed certificate (with SAN, 10-year validity) via openssl
2. Register the `harbor-tls` TLS Secret in the `harbor` namespace
3. Switch `values/dev.yaml` back to `expose.type: ingress` and run `helmfile apply`
4. Configure client (containerd, docker) trust for the self-signed cert
5. Renew when needed

<br/>

## 1. Issue the Self-Signed Certificate (rollback only)

```bash
# Self-signed certificate for harbor.example.com (10-year validity)
# SAN is required for Go clients (containerd, kaniko, docker) to verify
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout harbor-key.pem -out harbor-cert.pem \
  -subj "/CN=harbor.example.com" \
  -addext "subjectAltName=DNS:harbor.example.com"
```

<br/>

## 2. Register the Kubernetes TLS Secret (rollback only)

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

## 3. Apply values/dev.yaml

Current configuration — the `expose` block in [`values/dev.yaml`](../values/dev.yaml):

```yaml
expose:
  type: route
  tls:
    enabled: true
    certSource: secret
    secret:
      # Not rendered in route mode (dead config). Real Secret must be recreated on rollback.
      secretName: harbor-tls
  route:
    hosts:
      - harbor.example.com
    parentRefs:
      - name: ngf
        namespace: nginx-gateway
        sectionName: https

externalURL: https://harbor.example.com
```

To roll back, switch to `type: ingress` and restore the `ingress:` block preserved as comments in the values file (`className: "nginx"` plus the `force-ssl-redirect` / `ssl-passthrough` / `proxy-body-size` annotations).
The full rollback order is documented in the header comments of the values file.

```bash
helmfile diff
helmfile apply
kubectl rollout status -n harbor deploy/harbor-core
```

<br/>

## 4. Verification

### Secret / Certificate

```bash
# The certificate at the real termination point lives in the Gateway namespace
kubectl get secret wildcard-example-tls -n nginx-gateway

# Subject / Issuer / Validity / SAN
kubectl get secret wildcard-example-tls -n nginx-gateway -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### HTTP → HTTPS Redirect

```bash
# Should return 301 Moved Permanently (harbor-https-redirect HTTPRoute)
curl -sI --resolve harbor.example.com:80:192.0.2.55 http://harbor.example.com/ | head -3

# HTTPS should return 200
curl -skI --resolve harbor.example.com:443:192.0.2.55 https://harbor.example.com/ | head -3
```

### HTTPRoute Binding

```bash
# Both the chart-generated harbor-route and the raw harbor-https-redirect must be Accepted
kubectl get httproute -n harbor
kubectl describe httproute harbor-route -n harbor | grep -A5 "Parents:"
```

<br/>

## 5. Renewal (before expiration) — rollback path only

The certificate on the current request path is `wildcard-example-tls`; renew it with the [TLS Wildcard Setup](../../../network/nginx-gateway-fabric/docs/tls-wildcard-setup.md) procedure.
The steps below renew `harbor-tls` and apply only after rolling back to the Ingress path.

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

# In the rolled-back state the ingress controller auto-reloads on Secret change.
# If not reflected, restart core/portal:
kubectl rollout restart -n harbor deploy/harbor-core deploy/harbor-portal
```

<br/>

## 6. Client Trust (Recommended)

> **Current state**: the existing containerd config (`plain_http: true` + `skip_verify: true`) continues to work — containerd follows the 301 redirect to HTTPS and `skip_verify` accepts the self-signed cert.
> The config below is a **semantic cleanup recommendation** and is not urgent.

### Kubespray (recommended)

Already reflected in [`kubespray/inventory-example-cluster/group_vars/all/containerd.yml`](../../../bootstrap/kubespray/inventory-example-cluster/group_vars/all/containerd.yml):

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
cd kubespray
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

### Docker CLI

```bash
# Distribute the CA certificate (use the wildcard cert from the current termination point)
sudo mkdir -p /etc/docker/certs.d/harbor.example.com
sudo cp .certs/harbor-cert.pem /etc/docker/certs.d/harbor.example.com/ca.crt

docker login harbor.example.com
```

### Kaniko (GitLab CI)

Kaniko can be handled with `--skip-tls-verify` + `--skip-tls-verify-pull`. The current project uses `--insecure-pull`, which works because go-containerregistry probes HTTPS(skip-verify) first, so swapping the pipeline flags is optional.

<br/>

## 7. cert-manager Alternative (reference)

If you have a public DNS provider with API-based validation (Cloudflare, Route53, etc.), you can automate with cert-manager + Let's Encrypt. Wix DNS does not support API validation, so the current self-signed approach is the practical choice here.

See the "cert-manager + Let's Encrypt" section of [`security/vaultwarden/docs/tls-setup-en.md`](../../vaultwarden/docs/tls-setup.md).

<br/>

## References

- Upstream Harbor `values.yaml` `expose.tls` schema: top comments of [`../values.yaml`](../values.yaml)
- NGF migration record: [`docs/ngf-migration/status.md`](../../../docs/ngf-migration/status.md)
- Harbor TLS docs: https://goharbor.io/docs/latest/install-config/configure-https/
