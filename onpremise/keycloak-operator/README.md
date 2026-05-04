# Keycloak Operator (helmfile + somaz94/keycloak-operator OCI chart)

Deploys the Keycloak Operator into the `keycloak-system` namespace via Helmfile. Manages only the CRDs (`Keycloak`, `KeycloakRealmImport`) and the operator Pod — the actual Keycloak instance, database and realm live in the sibling [`security/keycloak/`](../keycloak) component.

Mirrors the operator/CR split used by ECK (`observability/logging/eck-operator/` + `observability/logging/elasticsearch/`).

<br/>

## Directory layout

```
security/keycloak-operator/
├── Chart.yaml             # OCI chart vendoring (drift-detection reference)
├── values.yaml            # OCI chart vendoring (default values reference)
├── values.schema.json     # OCI chart vendoring (Draft-07 schema reference)
├── helmfile.yaml          # single release: keycloak-operator @ keycloak-system ns
├── values/
│   └── mgmt.yaml          # mgmt (example dev) overrides (watchNamespaces, resources)
├── upgrade.sh             # external-oci template (tracks somaz94 OCI chart version)
├── backup/                # rollback trail written by upgrade.sh
├── README.md              # Korean version
└── README-en.md           # (this file)
```

<br/>

## Prerequisites

- Kubernetes 1.25+
- Helm 3.8+ (OCI support)
- Helmfile
- mgmt cluster kubeconfig context active

<br/>

## Apply Order

Operator + CR are kept in separate helmfiles (G14). Operator lives here; the CR component lives under [keycloak/](../keycloak/). Follow this order:

1. **keycloak-operator** (this component) `helmfile sync` first — installs CRDs (`Keycloak`, `KeycloakRealmImport`) and the operator Deployment.
2. [keycloak](../keycloak/) `helmfile sync` — creates the `Keycloak` CR + a dedicated PostgreSQL; the operator reconciles them into StatefulSet/Service/Ingress.
3. Destroy in reverse: keycloak (CR + DB) first → keycloak-operator last.

**Why this order**: the CR is reconciled by the operator; if the operator is removed first the CR's finalizer cannot be cleared and gets stuck — destroy must be reverse-ordered.

<br/>

## Configuration summary

- **Install namespace**: `keycloak-system`
- **CRDs**: shipped with the chart (`crds.install: true`, `crds.keep: true` so CRDs survive chart uninstall)
- **Watch scope**: `JOSDK_WATCH_ALL` — reconciles `Keycloak` / `KeycloakRealmImport` CRs in every namespace (the real Keycloak instance lives in the `keycloak` namespace)
- **Image source**: `quay.io/keycloak/keycloak-operator:26.6.1` (chart default, anonymous pull allowed)

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

### Track new chart versions

```bash
./upgrade.sh --dry-run                         # Preview (chart diff + breaking-key check)
./upgrade.sh                                   # Apply (rewrites helmfile.yaml version + values)
./upgrade.sh --rollback                        # Restore from backup/<timestamp>/
```

> The body of `upgrade.sh` is kept in sync with [`scripts/upgrade-sync/templates/external-oci.sh`](../../scripts/upgrade-sync/templates/external-oci.sh). Edit the canonical, not this file.

<br/>

## Verification

```bash
# Operator Pod status
kubectl -n keycloak-system get pods,deploy

# CRD registration
kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org

# Operator logs
kubectl -n keycloak-system logs deploy/keycloak-operator -f
```

<br/>

## Next step

Once the operator + CRDs are registered, deploy the actual Keycloak instance (PostgreSQL + Keycloak CR + realm) via the sibling [`security/keycloak/`](../keycloak) component:

```bash
# After this component is applied
helmfile -f ../keycloak/helmfile.yaml -e mgmt apply
```

<br/>

## References

- [PrivateWork/helm-charts/charts/keycloak-operator/README.md](https://github.com/somaz94/helm-charts/tree/main/charts/keycloak-operator) — chart values reference
- [Keycloak Operator Documentation](https://www.keycloak.org/operator/installation)
- [`security/keycloak/`](../keycloak) — sibling component (Keycloak CR + DB + realm)
- [`scripts/upgrade-sync/`](../../scripts/upgrade-sync/) — upgrade.sh canonical management
