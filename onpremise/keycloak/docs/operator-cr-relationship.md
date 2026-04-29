# Operator vs CR component split (security/keycloak-operator + security/keycloak)

This component (`security/keycloak/`) and the sibling [`security/keycloak-operator/`](../../keycloak-operator) split a single Keycloak system into **two helmfile components**. Same pattern as ECK's [`observability/logging/eck-operator/`](../../../observability/logging/eck-operator) + [`observability/logging/elasticsearch/`](../../../observability/logging/elasticsearch).

<br/>

## Why split?

| Aspect | Combined (one helmfile, CRDs + instance) | Split (two helmfiles, this pattern) |
|---|---|---|
| CRD lifecycle | Tied to the instance chart — accidental chart uninstall removes the CRDs and every Keycloak/Realm CR is garbage-collected | CRDs are owned by the operator chart with `crds.keep: true`; survive chart uninstall |
| Permission boundary | Operator's cluster-scoped RBAC and instance's namespace-scoped RBAC mix in one release | Operator namespace (`keycloak-system`) and instance namespace (`keycloak`) are separate |
| Upgrade cadence | Operator + instance + DB locked to a single chart bump | Operator (CRDs/compat), keycloak-cr (Keycloak server version), postgresql (DB) cycle independently |
| Multi-instance | Implicitly assumes one operator per instance | One operator reconciles Keycloak CRs across namespaces (`watchNamespaces: JOSDK_WATCH_ALL`) |

<br/>

## Component responsibilities

### `security/keycloak-operator/`

- Namespace: `keycloak-system`
- Owns:
  - CRDs `keycloaks.k8s.keycloak.org`, `keycloakrealmimports.k8s.keycloak.org` with `helm.sh/resource-policy: keep`
  - Operator Deployment + ServiceAccount + ClusterRole/ClusterRoleBinding (cluster-scoped) + Role/RoleBinding (namespace-scoped, operator namespace)
  - Operator metrics Service (target for kube-prometheus-stack ServiceMonitor)
- Change trigger: new keycloak-k8s-resources upstream release (CRD schema / RBAC / image)

### `security/keycloak/` (this component)

- Namespace: `keycloak`
- Owns:
  - PostgreSQL Deployment + Service + PVC + Secret (chart-managed `keycloak-postgresql`)
  - Keycloak CR (`Keycloak`) — the operator reconciles this into StatefulSet `keycloak`
  - KeycloakRealmImport CR (optional, post Phase 3)
  - HTTPRoute (attached to the NGF Gateway)
- Change triggers:
  - keycloak-cr chart bump (HTTPRoute / Keycloak CR template improvements)
  - postgresql chart bump (DB image / config)
  - `mgmt-keycloak.yaml` / `mgmt-postgresql.yaml` overrides

<br/>

## Dependency / apply order

```
1. Apply keycloak-operator
   ↓ CRDs registered + operator Pod Ready
2. Apply keycloak
   ↓ helmfile `needs:` enforces keycloak-postgresql → keycloak ordering
   ↓ Keycloak CR admitted; operator creates StatefulSet `keycloak`
   ↓ Once Ready, the `keycloak-initial-admin` Secret is auto-rendered
3. (Phase 3) Realm + groups + clients + GitLab IdP setup (UI / kcadm.sh)
```

Helmfile does not enforce cross-component dependencies — order is documented in the README. Apply each component with explicit user approval.

<br/>

## Troubleshooting decision tree

| Issue | Which component? |
|---|---|
| Keycloak CR not reconciled, no events | Operator (`security/keycloak-operator/`) — check Pod logs / RBAC |
| Keycloak Pod starts but admin console redirect-loops | This component — review `keycloak.hostname.hostname` / `proxy.headers` (`values/mgmt-keycloak.yaml`) |
| HTTPRoute does not attach to the NGF Gateway | This component — `httproute.parentRefs` (Gateway name/namespace) |
| `pg_dump: connection refused` | This component — PostgreSQL Pod / Secret / Service |
| Operator: `forbidden: cannot list resource "keycloaks"` | Operator component — check RBAC ClusterRole |
| New CRD field missing after chart upgrade | Operator component — bump via `./upgrade.sh` |

<br/>

## See also

- ECK same pattern: [`observability/logging/eck-operator/README-en.md`](../../../observability/logging/eck-operator/README-en.md) + [`observability/logging/elasticsearch/README-en.md`](../../../observability/logging/elasticsearch/README-en.md)
- [Keycloak Operator official installation guide](https://www.keycloak.org/operator/installation)
