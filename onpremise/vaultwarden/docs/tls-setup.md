# TLS Setup for Vaultwarden

Vaultwarden Web Vault requires HTTPS (Secure Context) for the browser's SubtleCrypto API.
This document covers the self-signed certificate approach used in this deployment.

<br/>

## Self-Signed Certificate (Current Setup)

### Generate and Apply

```bash
# 1. Generate self-signed certificate (valid for 10 years)
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout vw-key.pem -out vw-cert.pem \
  -subj "/CN=vault.example.com"

# 2. Create Kubernetes TLS secret
kubectl create secret tls vaultwarden-tls \
  --cert=vw-cert.pem --key=vw-key.pem \
  -n vaultwarden

# 3. Clean up local files
rm vw-key.pem vw-cert.pem
```

<br/>

### Verify

```bash
# Check secret exists
kubectl get secret vaultwarden-tls -n vaultwarden

# Check certificate details
kubectl get secret vaultwarden-tls -n vaultwarden -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -subject -dates
```

<br/>

### Renew (before expiration)

```bash
# Delete old secret and recreate
kubectl delete secret vaultwarden-tls -n vaultwarden

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout vw-key.pem -out vw-cert.pem \
  -subj "/CN=vault.example.com"

kubectl create secret tls vaultwarden-tls \
  --cert=vw-cert.pem --key=vw-key.pem \
  -n vaultwarden

rm vw-key.pem vw-cert.pem

# Restart to pick up new cert
kubectl rollout restart statefulset vaultwarden -n vaultwarden
```

<br/>

### Browser Warning

Self-signed certificates will show a browser warning on first access.
Accept the warning to proceed. This is expected behavior and does not affect security
of the encrypted vault data (encryption happens client-side).

<br/>

## Alternative: cert-manager + Let's Encrypt

If you have a DNS provider that supports API-based validation (e.g., Cloudflare, Route53, Google Cloud DNS),
you can use cert-manager for automatic certificate management.

> **Note**: Wix DNS does NOT support API-based DNS validation, so cert-manager with DNS01 challenge is not available.
> HTTP01 challenge requires the domain to be publicly accessible.

```bash
# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 2. Create ClusterIssuer (example: Cloudflare)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cloudflare-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

# 3. Update values/mgmt.yaml ingress annotations
# ingress:
#   additionalAnnotations:
#     cert-manager.io/cluster-issuer: "cloudflare-issuer"
#   tlsSecret: "vaultwarden-tls"
```
