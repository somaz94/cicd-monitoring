# Keycloak (helmfile + somaz94 OCI charts)

Deploys a Keycloak instance with a dedicated PostgreSQL into the `keycloak` namespace via Helmfile.

Mirroring the ECK operator/CR split, the **Operator + CRDs must be installed first** via the sibling [`security/keycloak-operator/`](../keycloak-operator) component.

<br/>

## Documentation

| Doc | Topic |
|---|---|
| [docs/architecture-en.md](docs/architecture-en.md) | Auth flow Before/After + LDAP migration path + user impact table + scenario comparison (read before cutover) |
| [docs/realm-setup-en.md](docs/realm-setup-en.md) | Phase 3 — create the `example` realm + groups + clients (argocd, harbor, oauth2-proxy, vaultwarden) |
| [docs/gitlab-brokering-en.md](docs/gitlab-brokering-en.md) | Phase 3 — register GitLab as an Identity Provider (preserve existing GitLab SSO) |
| [docs/harbor-migration-en.md](docs/harbor-migration-en.md) | Phase 4 — switch the Harbor OIDC endpoint to Keycloak (moved ahead of ArgoCD in plan) |
| [docs/argocd-migration-en.md](docs/argocd-migration-en.md) | Phase 6 — replace the ArgoCD dex GitLab connector with Keycloak OIDC + `argocd-https-redirect` HTTPRoute |
| [docs/vaultwarden-migration-en.md](docs/vaultwarden-migration-en.md) | Switch vaultwarden's SSO authority from GitLab → Keycloak |
| [docs/operator-cr-relationship-en.md](docs/operator-cr-relationship-en.md) | Why the Operator (sibling component) and the CR + DB (this component) are split |
| [docs/backup-restore-en.md](docs/backup-restore-en.md) | PostgreSQL backup/restore + realm export procedure |

<br/>

## Directory layout

```
security/keycloak/
├── Chart.yaml                          # Component metadata
├── helmfile.yaml                       # 2 releases: keycloak-postgresql + keycloak (needs)
├── values-postgresql.yaml              # OCI chart vendoring — somaz94/postgresql defaults
├── values-postgresql.schema.json       # Same chart's Draft-07 schema
├── values-keycloak-cr.yaml             # OCI chart vendoring — somaz94/keycloak-cr defaults
├── values-keycloak-cr.schema.json      # Same chart's Draft-07 schema
├── values/
│   ├── mgmt-postgresql.yaml            # PostgreSQL overrides (image, PVC, auth, secretKeys)
│   └── mgmt-keycloak.yaml              # Keycloak CR overrides (hostname, db, HTTPRoute)
├── manifests/
│   └── realm-example.json              # Phase 3 realm export placeholder (--set-file target)
├── scripts/
│   ├── restore.sh                      # pg_dump restore (-h)
│   ├── realm-export.sh                 # kc.sh export → manifests/realm-example.json (-h)
│   ├── kcadm-bootstrap.sh              # realm + groups + clients + GitLab IdP + master admin (-h)
│   └── kcadm-verify.sh                 # read-only verification of all of the above (-h, exit 1 on fail)
├── docs/                               # Korean / English pairs
├── upgrade.sh                          # external-oci template (tracks somaz94/keycloak-cr)
├── backup/                             # upgrade.sh rollback trail
├── README.md                           # Korean version
└── README-en.md                        # (this file)
```

<br/>

## Prerequisites

- Kubernetes 1.25+
- Helm 3.8+ (OCI support)
- Helmfile
- mgmt cluster kubeconfig context active
- **Required first**: [`security/keycloak-operator/`](../keycloak-operator) applied so the CRDs (`Keycloak`, `KeycloakRealmImport`) are registered
- NGF Gateway `ngf` (in `nginx-gateway` ns) running — the chart's HTTPRoute attaches here for `auth.example.com` traffic

<br/>

## Configuration summary

| Item | Value |
|---|---|
| Install namespace | `keycloak` |
| Hostname | `auth.example.com` (NGF `ngf` Gateway https listener, wildcard-example-tls) |
| Keycloak instances | 1 (single-instance, dev) |
| PostgreSQL | `postgres:17-alpine` (latest officially supported by Keycloak 26.x) |
| PVC | NFS (`nfs-client-server`), 20Gi |
| DB credentials | chart-managed Secret `keycloak-postgresql` (keys: `username`, `password`) |
| Realm import | Disabled (enabled after Phase 3 export) |

<br/>

## Quick usage

### Preview changes

```bash
helmfile -f helmfile.yaml -e mgmt diff
```

### Apply

```bash
helmfile -f helmfile.yaml -e mgmt apply        # ⚠️ Cluster change — user approval required
```

A successful apply produces (within ~1–2 minutes):
- `keycloak-postgresql` Deployment + PVC + Secret + Service
- `keycloak` Keycloak CR → operator reconciles → `keycloak-0` StatefulSet Pod
- `keycloak` HTTPRoute (NGF https listener) + `keycloak-https-redirect` HTTPRoute
- Initial admin credentials: operator auto-renders the `keycloak-initial-admin` Secret

Next: [docs/realm-setup-en.md](docs/realm-setup-en.md) for Phase 3 realm setup.

### Track new chart versions

`upgrade.sh` tracks the **keycloak-cr chart only** (postgresql is on its own cycle).

```bash
./upgrade.sh --dry-run                         # Preview
./upgrade.sh                                   # Apply (rewrites helmfile.yaml version)
./upgrade.sh --rollback                        # Restore from backup/<timestamp>/
```

For the PostgreSQL chart version, edit the `keycloak-postgresql` release `version:` in `helmfile.yaml` directly, then `helmfile diff` → `apply`.

<br/>

## How to verify PostgreSQL version compatibility

Keycloak refreshes its supported PostgreSQL matrix with every major release. **Always verify before bumping the chart or PostgreSQL version.**

### 1. Keycloak's official supported-DB matrix

[Keycloak Server > Database Configuration](https://www.keycloak.org/server/db).

```bash
open "https://www.keycloak.org/server/db"
```

| Keycloak version | Officially supported PostgreSQL |
|---|---|
| 26.x (current) | 14, 15, 16, **17** |
| 25.x | 14, 15, 16 |
| 24.x | 13, 14, 15, 16 |
| 23.x | 12, 13, 14, 15 |

> JDBC compatibility means out-of-matrix versions (e.g. PostgreSQL 18) usually work. They are **not officially guaranteed** — prefer in-matrix versions to keep Keycloak support viable when issues arise.

### 2. What the chart defaults to

```bash
helm show chart oci://ghcr.io/somaz94/charts/postgresql --version 0.1.0 | grep ^appVersion
# appVersion: 18-alpine     # chart default
```

### 3. What this component actually pins

```bash
grep -A2 'image:' values/mgmt-postgresql.yaml
# image:
#   repository: postgres
#   tag: "17-alpine"
```

### 4. The image running in the cluster

```bash
kubectl -n keycloak get pod -l app.kubernetes.io/instance=keycloak-postgresql -o jsonpath='{.items[0].spec.containers[0].image}'
# postgres:17-alpine
```

### 5. PostgreSQL's reported `server_version`

```bash
kubectl -n keycloak exec deploy/keycloak-postgresql -- psql -U keycloak -d keycloak -c 'SHOW server_version'
#  server_version
# ----------------
#  17.4
```

### 6. The version Keycloak's JDBC driver detected

```bash
kubectl -n keycloak logs sts/keycloak | grep -i "PostgreSQL\|database product"
# Database product: PostgreSQL 17.4 (Debian ...)
```

### Procedure to change the PostgreSQL version

1. Verify support on the [Keycloak DB matrix](https://www.keycloak.org/server/db)
2. Edit `values/mgmt-postgresql.yaml` `image.tag` (e.g. `17-alpine` → `18-alpine`)
3. **For major upgrades**, take a backup first:
   ```bash
   kubectl -n keycloak exec deploy/keycloak-postgresql -- pg_dump -U keycloak -d keycloak > backup/$(date +%Y%m%d)-keycloak-pre-pg-bump.sql
   ```
4. `helmfile diff` → `apply` (user approval)
5. `kubectl -n keycloak rollout status deploy/keycloak-postgresql`
6. Major bumps (e.g. 17 → 18) require a PostgreSQL catalog upgrade — a plain image bump is **not** sufficient. Use `pg_upgrade` or a dump/restore. Minor bumps (17.3 → 17.4) are direct.

> Risk is zero on a fresh dev install — production environments require the steps above.

<br/>

## Verification

```bash
# Pod / workload status
kubectl -n keycloak get pods,statefulset,deploy,svc

# Keycloak CR status (operator-reconciled)
kubectl -n keycloak get keycloak,keycloakrealmimport

# Keycloak server logs
kubectl -n keycloak logs sts/keycloak -f

# HTTPRoute attached
kubectl -n keycloak get httproute

# External reachability (admin console)
curl -kI https://auth.example.com/realms/master    # expect HTTP 200
```

<br/>

## Next steps

1. [docs/realm-setup-en.md](docs/realm-setup-en.md) — Create the `example` realm + groups + clients (Phase 3)
2. [docs/gitlab-brokering-en.md](docs/gitlab-brokering-en.md) — Register GitLab as an Identity Provider
3. [docs/harbor-migration-en.md](docs/harbor-migration-en.md) — Replace Harbor OIDC (Phase 4)
4. [docs/argocd-migration-en.md](docs/argocd-migration-en.md) — Replace ArgoCD dex (Phase 6)

<br/>

## References

- [PrivateWork/helm-charts/charts/keycloak-cr/README.md](https://github.com/somaz94/helm-charts/tree/main/charts/keycloak-cr) — chart values reference
- [PrivateWork/helm-charts/charts/postgresql/README.md](https://github.com/somaz94/helm-charts/tree/main/charts/postgresql) — postgres chart reference
- [Keycloak Operator Documentation](https://www.keycloak.org/operator/installation)
- [Keycloak DB Configuration](https://www.keycloak.org/server/db) — official PostgreSQL support matrix
- [`security/keycloak-operator/`](../keycloak-operator) — sibling component (Operator + CRDs)
