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
- [`kubeseal`](https://github.com/bitnami/sealed-secrets/releases) CLI (match the controller appVersion, currently `0.38.1`)
- on-prem dev cluster kubeconfig context active (`kubectl config use-context onprem-dev`)

<br/>

## Configuration summary

- **Install namespace**: `sealed-secrets`
- **Release / controller name**: `sealed-secrets` (so `kubeseal` targets `--controller-namespace sealed-secrets --controller-name sealed-secrets`)
- **CRD**: `sealedsecrets.bitnami.com` (shipped with the chart)
- **RBAC**: cluster-scoped `secrets-unsealer` ClusterRole (chart default)
- **Metrics**: ServiceMonitor / PrometheusRule off by default — enable out-of-band once the kube-prometheus-stack discovery label is wired in (see `values/dev.yaml`)

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

### Scope and multi-namespace pull secrets

A `SealedSecret` is, by default, locked to one `namespace` + `name` (`strict` scope). An `imagePullSecret` that must exist in several namespaces under the same name needs a wider scope:

| Scope | Flag | Use when |
|-------|------|----------|
| `strict` (default) | — | secret bound to one namespace + name |
| `namespace-wide` | `--scope namespace-wide` | same name reusable anywhere in one namespace |
| `cluster-wide` | `--scope cluster-wide` | same secret applied to any namespace (multi-ns pull secret) |

For the Harbor robot pull secret used across the `*-example-project` / `*-secondary-project` namespaces, seal it `cluster-wide` so one `SealedSecret` can be applied per target namespace without re-sealing.

> 🔑 If you are migrating from a previously committed plaintext secret, **rotate the Harbor robot token first** — the old value already exists in git history and must be treated as compromised.

**Consumer — `argocd-applicationset`**: the Harbor robot pull secret is sealed `cluster-wide` and committed to that repo at `secret/harbor-robot/harbor-robot-sealedsecret.yaml`, then applied to the `dev-example-project` / `qa-example-project` / `dev1-secondary-project` namespaces by its `appsets/harbor-pull-secret-applicationset.yaml`. The `base` chart references the materialised Secret by name and never generates it (`imageCredentials.enabled: false`).

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

<br/>

## References

- [bitnami/sealed-secrets](https://github.com/bitnami/sealed-secrets) — upstream project + CLI releases
- [Chart values reference](https://github.com/bitnami/sealed-secrets/tree/main/helm/sealed-secrets) — chart parameters
- [`scripts/upgrade-sync/`](../../scripts/upgrade-sync/) — upgrade.py canonical management
