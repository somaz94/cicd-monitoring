# Pinned Harbor internal Secrets

Why the internal secrets the chart used to generate are pinned to SealedSecrets, how they are laid out, how they were sealed, and how to rotate them.

<br/>

## Why pin them

The chart generates these values while rendering.

| Value | How the chart generates it |
|---|---|
| core secret, CSRF key, jobservice secret, registry HTTP secret | `lookup` of the existing Secret, else `randAlphaNum` |
| Token signing key and certificate | `genCA` — no `lookup`, regenerated on every render |
| Registry htpasswd | the `htpasswd` function — a different string on every render because of the bcrypt salt |

- `helm upgrade` renders against the cluster, so `lookup` works and the first four survive. The token key and htpasswd changed on every upgrade, though, restarting core and registry each time.
- ArgoCD renders without a cluster, so `lookup` is always empty. Unpinned, every value above changes on every sync, and while the pods restart the components can disagree on a secret and fail image pulls and pushes.
- Once pinned, two renders with the same values are byte-identical.

<br/>

## Layout

| Secret | Keys | Referenced by (`values/dev.yaml`) |
|---|---|---|
| `harbor-internal-secrets` | `secret`, `CSRF_KEY`, `JOBSERVICE_SECRET`, `REGISTRY_HTTP_SECRET`, `REGISTRY_PASSWD`, `REGISTRY_HTPASSWD` | `core.existingSecret`, `core.existingXsrfSecret`, `jobservice.existingSecret`, `registry.existingSecret`, `registry.credentials.existingSecret` |
| `harbor-core-token` (`kubernetes.io/tls`) | `tls.crt`, `tls.key` | `core.secretName` |

- **The chart fixes the key names.** `core.existingSecret` reads `secret`, `registry.credentials.existingSecret` reads `REGISTRY_PASSWD` and `REGISTRY_HTPASSWD`, and the rest follow the chart defaults of `existingXsrfSecretKey` / `jobservice.existingSecretKey` / `registry.existingSecretKey`. Renaming a key means setting the matching values key too.
- **Location**: `secret/harbor-internal/` in the `argocd-applicationset` repo. The `harbor` element of `infra-sealedsecret-applicationset` deploys it as the Application `infra-sealedsecret-harbor`. Both Secrets are `strict` scope, bound to the `harbor` namespace.
- **Never write the values into values files.** That keeps plaintext secrets out of git (leave inline keys such as `core.secret` and `core.tokenKey` empty).
- **`secretKey` is not part of this set.** It encrypts credentials Harbor stores in its database (replication endpoints and the like), comes from the chart default, and does not change between renders. Changing it makes the stored credentials undecryptable, so leave it alone.

<br/>

## How they were sealed

At the first pinning on 2026-10-14 the values were **copied verbatim** from the Secrets the chart had generated (`harbor-core`, `harbor-jobservice`, `harbor-registry`, `harbor-registry-htpasswd`). No new value was created, so nothing changed functionally. After pinning, those chart Secrets no longer carry these keys, so a later re-seal (for example after a controller key rotation) reads `harbor-internal-secrets` / `harbor-core-token` themselves and follows [Sealing a live Secret](../../sealed-secrets/README.md#sealing-a-live-secret-a-value-already-in-the-cluster).

The commands used for the first pinning. Plaintext lives only in a locked-down temporary directory and is deleted right after sealing.

```bash
umask 077; T=$(mktemp -d)
K="kubectl --context onprem-dev -n harbor"
g() { $K get secret "$1" -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['$2'])"; }

cat > "$T/internal.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: harbor-internal-secrets
  namespace: harbor
type: Opaque
data:
  secret: $(g harbor-core secret)
  CSRF_KEY: $(g harbor-core CSRF_KEY)
  JOBSERVICE_SECRET: $(g harbor-jobservice JOBSERVICE_SECRET)
  REGISTRY_HTTP_SECRET: $(g harbor-registry REGISTRY_HTTP_SECRET)
  REGISTRY_PASSWD: $(g harbor-core REGISTRY_CREDENTIAL_PASSWORD)
  REGISTRY_HTPASSWD: $(g harbor-registry-htpasswd REGISTRY_HTPASSWD)
EOF

cat > "$T/token.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: harbor-core-token
  namespace: harbor
type: kubernetes.io/tls
data:
  tls.crt: $(g harbor-core tls.crt)
  tls.key: $(g harbor-core tls.key)
EOF

S="--context onprem-dev --controller-namespace sealed-secrets --controller-name sealed-secrets"
OUT=<argocd-applicationset>/secret/harbor-internal
kubeseal $S --format yaml < "$T/internal.yaml" > "$OUT/harbor-internal-secrets-sealedsecret.yaml"
kubeseal $S --format yaml < "$T/token.yaml"    > "$OUT/harbor-core-token-sealedsecret.yaml"
kubeseal $S --validate < "$OUT/harbor-internal-secrets-sealedsecret.yaml"
kubeseal $S --validate < "$OUT/harbor-core-token-sealedsecret.yaml"
rm -rf "$T"
```

Commit only the two files under `secret/harbor-internal/`.

<br/>

## Apply order

1. **Deploy the SealedSecrets first.** A push to `argocd-applicationset` makes `infra-sealedsecret-harbor` create both Secrets. Nothing references them yet, so Harbor is unaffected.
2. **Then change the values and apply the chart.** The chart Secrets change shape and their checksum annotations move, so core / jobservice / registry restart once.

In the other order the values reference Secrets that do not exist yet, and the three pods fail with `CreateContainerConfigError`.

<br/>

## Rotation

Pods do not re-read a changed Secret on their own (env comes from `secretKeyRef`, key files from `subPath` mounts). After changing a value, seal and push the new Secret, confirm it has landed, then restart the affected Deployments. Once pinned, the chart's checksum annotations no longer cover these values, so applying the chart does not restart anything by itself.

| Key | Must stay in step with | Effect of rotating |
|---|---|---|
| `secret` | core / jobservice / registry (registryctl) share it | restart all three Deployments together |
| `CSRF_KEY` | — | web UI users log in again |
| `JOBSERVICE_SECRET` | core and jobservice | restart both Deployments |
| `REGISTRY_HTTP_SECRET` | registry | in-flight uploads fail |
| `REGISTRY_PASSWD` / `REGISTRY_HTPASSWD` | **a pair.** The htpasswd entry must be the bcrypt hash of `REGISTRY_PASSWD`, for the user `registry.credentials.username` | restart core / jobservice / registry |
| `tls.key` / `tls.crt` | — | tokens already issued (30-minute lifetime) become invalid; restart core |

```bash
# Build REGISTRY_HTPASSWD (the user is registry.credentials.username)
htpasswd -nbB harbor_registry_user '<REGISTRY_PASSWD>'

# Restart
kubectl --context onprem-dev -n harbor rollout restart deploy/harbor-core deploy/harbor-jobservice deploy/harbor-registry
```

<br/>

## Token certificate expiry does not matter

The `tls.crt` in `harbor-core-token` is the 365-day certificate the chart generated, but its expiry has no effect, so its renewal is not automated.

- The registry authenticates with htpasswd, not tokens (`auth.htpasswd` in the `harbor-registry` ConfigMap). It never reads the token certificate.
- `tls.crt` is mounted into no pod. Core mounts only `tls.key`, as `/etc/core/private_key.pem`.
- Harbor core signs and verifies tokens with the private key alone (`src/core/service/token/authutils.go` and `src/pkg/token/options.go` in the Harbor source). A private key does not expire.
- Token lifetime itself is governed separately by the JWT `exp` claim.
