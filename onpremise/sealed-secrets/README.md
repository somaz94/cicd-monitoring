# Sealed Secrets (helmfile + bitnami/sealed-secrets chart)

Deploys the [Sealed Secrets](https://github.com/bitnami/sealed-secrets) controller into the `sealed-secrets` namespace via Helmfile. The controller holds an asymmetric key pair: a **public cert** the `kubeseal` CLI uses to encrypt, and a **private key** kept in-cluster to decrypt. Operators commit only the encrypted `SealedSecret` CR to git; the controller reconciles it into a plain `Secret` in-cluster.

This lets registry credentials — notably the **Harbor robot `dockerconfigjson`** consumed by the sibling [`argocd-applicationset`](https://gitlab.example.com/server/argocd-applicationset) repo — live in git without plaintext exposure, replacing the raw committed `Secret` manifest.

> ⚠️ The controller private key is the **single decryption root**. Back it up out of band (see [Key backup](#key-backup)). Losing it makes every committed `SealedSecret` permanently undecryptable.

<br/>

## Directory layout

```
security/sealed-secrets/
├── Chart.yaml             # upstream chart vendoring (drift-detection reference)
├── values.yaml            # upstream chart vendoring (default values reference)
├── helmfile.yaml          # single release: sealed-secrets @ sealed-secrets ns
├── values/
│   └── dev.yaml          # dev (example dev) overrides (resources, metrics)
├── upgrade.py             # external-standard template (tracks bitnami chart version)
├── backup/                # rollback trail written by upgrade.py --rollback
├── README.md              # Korean version
└── README-en.md           # (this file)
```

<br/>

## Prerequisites

- Kubernetes 1.16+
- Helm 3
- Helmfile
- [`kubeseal`](https://github.com/bitnami/sealed-secrets/releases) CLI (match the controller `appVersion` in `Chart.yaml`)
- on-prem dev cluster kubeconfig context active (`kubectl config use-context onprem-dev`)

<br/>

## Configuration summary

- **Install namespace**: `sealed-secrets`
- **Release / controller name**: `sealed-secrets` (so `kubeseal` targets `--controller-namespace sealed-secrets --controller-name sealed-secrets`)
- **CRD**: `sealedsecrets.bitnami.com` (shipped with the chart)
- **RBAC**: cluster-scoped `secrets-unsealer` ClusterRole (chart default)
- **Metrics**: ServiceMonitor enabled — kube-prometheus-stack scrapes the `sealed-secrets-metrics` Service (:8081). No discovery label is needed because the Prometheus CR runs `serviceMonitorSelector: {}`. The metrics that matter are `sealed_secrets_controller_condition_info` (per-SealedSecret Synced state, 1/0/-1) and `sealed_secrets_controller_unseal_requests_total`. The chart's own PrometheusRule stays off — alert rules live only in kube-prometheus-stack's `values/dev-alerts*.yaml` (this group is in `dev-alerts-apps.yaml`)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply        # ⚠️ Cluster change — user approval required

# Verify
kubectl -n sealed-secrets get pods,deploy
kubectl get crd sealedsecrets.bitnami.com
```

<br/>

## Sealing a Secret (Harbor robot example)

Once the controller is running, convert a plain `Secret` manifest into a `SealedSecret` with `kubeseal`. The example below seals a Harbor robot `dockerconfigjson` pull secret.

```bash
# 1. (Optional) fetch the public cert once — lets you seal offline afterwards.
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --fetch-cert > pub-sealed-secrets.pem

# 2. Seal a plain Secret manifest into a SealedSecret (encrypts the data in place).
#    harbor-robot-secret.yaml = kubernetes.io/dockerconfigjson Secret (NOT committed).
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --format yaml < harbor-robot-secret.yaml > harbor-robot-sealedsecret.yaml

# 3. Commit ONLY harbor-robot-sealedsecret.yaml. The controller decrypts it into the
#    real Secret in-cluster on apply.
```

### How the encryption works (why it is safe to commit)

`kubeseal` encrypts the `data` with the **controller's public certificate** (the one `--fetch-cert` returns). It is asymmetric — **public key encrypts, only the private key decrypts** — and the private key lives only in the `sealedsecrets.bitnami.com/sealed-secrets-key` labelled Secret in the `sealed-secrets` namespace and never leaves the cluster. So `encryptedData` **can be produced by anyone with the public key but reversed only by that cluster's controller** — which is why it is safe in git. `--scope strict` (the default) binds the ciphertext to `<namespace>/<name>`, so the controller refuses to decrypt it under a different ns/name (prevents value theft). **A sealed value is cluster-specific and cannot be unsealed on another cluster.**

### Sealing a live Secret (a value already in the cluster)

The example above seals a hand-written Secret manifest, but in practice you usually seal a **plaintext Secret that already exists in the cluster** (e.g. one applied by hand earlier). Extract the live Secret, strip it down to seal-relevant metadata, and pipe it to `kubeseal`.

```bash
kubectl -n <ns> get secret <name> -o json \
  | jq 'del(
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations["meta.helm.sh/release-name"],
        .metadata.annotations["meta.helm.sh/release-namespace"],
        .metadata.labels["app.kubernetes.io/managed-by"],
        .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid,
        .metadata.ownerReferences, .metadata.generation, .status)' \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
      --scope strict --format yaml > <name>-sealedsecret.yaml

# Validate the sealed value decrypts under the current controller key (no plaintext exposure)
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --validate < <name>-sealedsecret.yaml
```

> **Why the `jq del`**: a live Secret carries `last-applied-configuration` (the full plaintext original embedded verbatim — not stripping it defeats the purpose), `resourceVersion` / `uid` / `creationTimestamp` (cluster-instance-specific), and `meta.helm.sh/*` / `managed-by=Helm` (misleading once the SealedSecret owns it). Delete those for a clean `SealedSecret`. `kubeseal` encrypts only `data` and preserves `metadata.name` / `namespace` / `type` verbatim in the `template`.

### Scope and multi-namespace pull secrets

A `SealedSecret` is, by default, locked to one `namespace` + `name` (`strict` scope). An `imagePullSecret` that must exist in several namespaces under the same name needs a wider scope:

| Scope | Flag | Use when |
|-------|------|----------|
| `strict` (default) | — | secret bound to one namespace + name |
| `namespace-wide` | `--scope namespace-wide` | same name reusable anywhere in one namespace |
| `cluster-wide` | `--scope cluster-wide` | same secret applied to any namespace (multi-ns pull secret) |

For the Harbor robot pull secret used across the `*-example-project` / `*-secondary-project` namespaces, seal it `cluster-wide` so one `SealedSecret` can be applied per target namespace without re-sealing.

> 🔑 If you are migrating from a previously committed plaintext secret, **rotate the Harbor robot token first** — the old value already exists in git history and must be treated as compromised.

**Consumer — `argocd-applicationset`**: the Harbor robot pull secret is sealed `cluster-wide` and committed to that repo at `secret/harbor-robot/harbor-robot-sealedsecret.yaml`, then applied to the `dev-example-project` / `qa-example-project` / `dev1-secondary-project` and tools namespaces by its `appsets/onprem/infra/harbor-pull-secret-applicationset.yaml`. The `base` chart references the materialised Secret by name and never generates it (`imageCredentials.enabled: false`).

<br/>

## SealedSecret placement rule (so it stays clear)

Where a `SealedSecret` lives is decided by **the nature of the workload that consumes it**. There are only two kinds.

| Kind | Examples | Placement | Deployed by |
|------|----------|-----------|-------------|
| **App secret** (owns its own code repo) | `account-tool`, `git-bridge`, `example-hub`, `slack-qr-bot` | the app's own `k8s/` directory | the app's directory-type ArgoCD Application syncs the whole manifest set |
| **Infra-component secret** (no own repo — OCI-chart consumer / helmfile-managed) | `ghost`, `unity-mcp-server`, `nginx-gateway-fabric`, Harbor robot | `argocd-applicationset` repo under `secret/<group>/` | a dedicated ApplicationSet delivers it automatically |

**Why the split**: an app like `account-tool` *is its own deploy unit*, so its secret belongs in its repo. By contrast `ghost` / `unity-mcp-server` have their chart at `ghcr.io/somaz94/charts` (OCI) with no own code repo, and their ArgoCD Application is a **single chart source** with no room for a raw `SealedSecret`. `nginx-gateway-fabric` is deployed via helmfile. So this group's secrets are centralised under `argocd-applicationset/secret/` and delivered by a dedicated ApplicationSet — being structured differently from apps is expected precisely *because they are not apps*.

**Infra-component secret consumer table**:

| Secret | Group directory | Target ns | Consumed via | Delivered by |
|--------|-----------------|-----------|--------------|--------------|
| `harbor-robot-secret` | `secret/harbor-robot/` | example-project/secondary-project + several tools | `imagePullSecrets` name reference | `harbor-pull-secret-applicationset` (cluster-wide) |
| `wildcard-example-tls`, `server-tls` | `secret/nginx-gateway-tls/` | `nginx-gateway` | Gateway `tls.secretName` reference | `infra-sealedsecret-applicationset` |
| `ghost-db-secret` | `secret/ghost-db/` | `blog` | ghost chart `existingSecret` | `infra-sealedsecret-applicationset` |
| `unity-mcp-api-key` | `secret/unity-mcp/` | `mcp-server` | unity chart `apiKey.existingSecret` | `infra-sealedsecret-applicationset` |

Everything except `harbor-robot` is pinned to a single namespace, so it is sealed with `strict` scope and delivered by the dedicated AppProject `infra-sealedsecret` (admin-only, sibling of `infra-pullsecret`). The seal/apply procedure matches [Sealing a secret](#sealing-a-secret-harbor-robot-example) above, only using `strict` (the default) scope.

> ⚠️ When you first deploy a SealedSecret into a namespace that already holds a hand-applied plaintext Secret, the controller may fail to adopt it with `already exists and is not managed by SealedSecret`. The fix (back up → delete → restart the controller, back-to-back) is under [Troubleshooting](#troubleshooting) below — `kubectl delete` alone then waiting leaves the Secret briefly empty and causes an outage, so always run delete and restart together.

<br/>

## Upgrade

```bash
./upgrade.py --dry-run                          # Preview (chart diff + breaking-key check)
./upgrade.py                                    # Apply (rewrites helmfile.yaml version + values)
./upgrade.py --rollback                         # Restore from backup/<timestamp>/
```

> The body of `upgrade.py` is kept in sync with [`scripts/upgrade-sync/templates/external-standard.py`](../../scripts/upgrade-sync/templates/external-standard.py). Edit the canonical and run `scripts/upgrade-sync/sync.py --apply` — never edit this file's body directly.

<br/>

## Key backup

The signing key pair lives in a Secret labelled `sealedsecrets.bitnami.com/sealed-secrets-key` in the `sealed-secrets` namespace. Back it up after the first install (and after any key rotation) so the cluster can be rebuilt without losing access to committed `SealedSecret`s:

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
```

Store the backup in a secure offline location — **never commit it to git**.

<br/>

## Troubleshooting

- **`SealedSecret` decrypts to nothing / `no key could decrypt`** — the controller key changed (re-install / restored without the original key). Restore the key backup, then `kubectl delete pod` the controller to reload.
- **`kubeseal` cannot reach the controller** — pass `--controller-namespace sealed-secrets --controller-name sealed-secrets`, or seal offline with `--cert pub-sealed-secrets.pem`.
- **`Secret` not created after apply** — check controller logs: `kubectl -n sealed-secrets logs deploy/sealed-secrets -f`.
- **First SealedSecret deploy into a namespace that already holds a plaintext `Secret` → `already exists and is not managed by SealedSecret`** — the controller cannot adopt a Secret it did not create (the Application stays `Degraded` while the workload is `Healthy`). **Proven order = back up → delete → restart the controller, run back-to-back**:
  ```bash
  kubectl -n <ns> get secret <name> -o yaml > /tmp/backup-<name>.yaml   # always back up first
  kubectl -n <ns> delete secret <name>                                  # one at a time if several
  kubectl -n sealed-secrets rollout restart deployment sealed-secrets   # restart immediately
  ```
  - **Always run delete and restart back-to-back.** Do not just delete and wait — the controller only watches Secrets it owns, so deleting an unowned Secret may raise no event at all (it may already have logged `Error updating, giving up`), leaving the Secret empty and apps/Gateway without access. The restart forces a full resync, and with the old Secret gone the path is a **create**, not an update.
  - What does not work: adding the `sealedsecrets.bitnami.com/managed="true"` annotation to the live Secret or the SealedSecret — an annotation is metadata, not spec, so the controller logs `update suppressed, no changes in spec` and never retries.
  > App secrets use the **exact same procedure**. For detail/background see `argocd-applicationset` [`docs/internal-app-gitops.md`](https://gitlab.example.com/server/argocd-applicationset/-/blob/master/docs/internal-app-gitops.md) "Adopting a hand-made Secret into a SealedSecret". (Hit for real on 2026-07-24 by deleting several at once while introducing infra-sealedsecret — the order above prevents it.)

<br/>

## References

- [bitnami/sealed-secrets](https://github.com/bitnami/sealed-secrets) — upstream project + CLI releases
- [Chart values reference](https://github.com/bitnami/sealed-secrets/tree/main/helm/sealed-secrets) — chart parameters
- [`scripts/upgrade-sync/`](../../scripts/upgrade-sync/) — upgrade.py canonical management
