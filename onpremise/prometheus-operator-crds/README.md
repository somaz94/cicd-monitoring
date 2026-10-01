# prometheus-operator-crds

The **CRD foundation component** that installs the `monitoring.coreos.com` CRDs (ServiceMonitor / PodMonitor / PrometheusRule / Prometheus / Alertmanager / ScrapeConfig / Probe / ThanosRuler / PrometheusAgent / AlertmanagerConfig) into the cluster.

These CRDs are cluster-scoped resources, **shared cluster-wide** rather than owned by the single kube-prometheus-stack component. They are therefore managed as a standalone component with a lifecycle decoupled from the monitoring stack, and deployed first (`wave_0`).

<br/>

## Why a standalone component

Bundling the CRDs in kube-prometheus-stack's (`wave_4`) `crds` subchart causes two problems:

1. **Ordering** — the dependent components below deploy in earlier waves and need the CRDs to already exist. With the CRDs trapped in `wave_4`, a clean bootstrap fails at `wave_0` when metallb creates a ServiceMonitor: `no matches for kind "ServiceMonitor"`.
2. **Lifecycle coupling** — when a cluster-wide foundation depends on one component, reworking/removing the stack breaks every other CR consumer at the same time.

> This was the exact root cause of the 2026-06-12 Prometheus outage — the CRDs were deleted out-of-band and nothing reconciled them, while the stack's own chicken-and-egg (it needs the CRDs present to even render its Prometheus/Alertmanager CRs) blocked self-heal. Separation + `wave_0` first-deploy prevents recurrence.

<br/>

## Dependents

Components that consume the CRDs this foundation provides. All of them require this component to be deployed **first**.

| Wave | Component | CRs created |
|------|-----------|-------------|
| wave_0 | `network/metallb` | ServiceMonitor, PrometheusRule |
| wave_1 | `network/nginx-gateway-fabric` | ServiceMonitor |
| wave_1 | `cicd/argo-cd` | ServiceMonitor |
| wave_1 | `cicd/harbor-helm` | ServiceMonitor |
| wave_3 | `db-redis/valkey` | ServiceMonitor |
| wave_4 | `observability/logging/eck-operator` | ServiceMonitor |
| wave_4 | `observability/logging/fluent-bit` | ServiceMonitor, PrometheusRule |
| wave_4 | `observability/logging/fluentd` | ServiceMonitor |
| wave_4 | `observability/monitoring/kube-prometheus-stack` | Prometheus, Alertmanager, PrometheusRule, ... |
| wave_4 | `observability/monitoring/prometheus-elasticsearch-exporter` | ServiceMonitor |
| wave_4 | `observability/monitoring/prometheus-mysql-exporter` | ServiceMonitor |
| wave_5 | `tools/ghost` | ServiceMonitor |

> When a new component creates a ServiceMonitor / PodMonitor / PrometheusRule, add it to this table.

<br/>

## Relationship to kube-prometheus-stack (LOCKSTEP)

- A CRD's schema is tied to the **Prometheus Operator version**. Keep this chart's `appVersion` equal to the operator `appVersion` that kube-prometheus-stack runs; at the least it must **not trail** it — an operator ahead of its CRDs is the schema skew.
- kube-prometheus-stack sets `crds.enabled: false` to disable its bundled CRD subchart, making this component the single owner of the CRDs.
- The invariant is enforced by `scripts/ci/check-crds-lockstep.py` under `make lint-governance` (hence `make ci`). The helmfile pin's `# lockstep-appversion-match:` annotation names the component whose `Chart.yaml appVersion` this component's `appVersion` must not be lower than; CI fails when it is (CRDs leading is allowed).
- **On upgrade**: bump this component **first, in its own MR**, to the CRD chart whose appVersion equals the operator appVersion of the kube-prometheus-stack chart you are about to take. Merge it, click `deploy:wave_0_bootstrap` (it applies every wave_0 component at master, so read the job's diff for the siblings too), confirm the CRDs, and only then merge the kube-prometheus-stack MR — kube-prometheus-stack is ArgoCD `autoSync: true`, so its merge is the deploy, and landing the CRDs first leaves no window where the operator runs ahead of them. C1 lets the CRDs lead, so the CRD MR passes on its own; the kube-prometheus-stack MR's `validate:upgrade_mr` runs C1 as well, so it passes only once the CRD bump is on master (rebase it if it was opened earlier). (Deliberately NOT in an auto-upgrade tier — the auto-bump would take the newest CRD chart, not the one matching the operator.)

<br/>

## Directory Structure

```
prometheus-operator-crds/
├── Chart.yaml          # vendored metadata (appVersion = operator version)
├── helmfile.yaml       # single release (namespace: monitoring), lockstep annotation
├── values.yaml         # upstream defaults (auto-managed by upgrade.py)
├── upgrade.py          # chart version bump (external-standard template)
├── backup/             # upgrade.py rollback trail
└── README.md
```

<br/>

## Upgrade

```bash
cd observability/monitoring/prometheus-operator-crds
./upgrade.py --dry-run --version <X.Y.Z>   # preview the appVersion-matched version, often not the latest
./upgrade.py --version <X.Y.Z>             # apply it (updates Chart.yaml + helmfile pin)
```

Pick `<X.Y.Z>` so the new `appVersion` equals the operator `appVersion` of the kube-prometheus-stack chart you will take next (`helm search repo prometheus-community/kube-prometheus-stack --versions` shows it; `helm search repo prometheus-community/prometheus-operator-crds --versions` shows which CRD chart carries that appVersion). CRDs that trail the component named in the helmfile pin's `# lockstep-appversion-match:` annotation fail `make lint-governance`.

<br/>

## Operational notes

- The CRDs carry a `helm.sh/resource-policy: keep` annotation to protect them from accidental deletion by helm (a safety belt added after the 2026-06-12 outage).
- Recovery if the CRDs disappear: `helmfile sync` this component first — `helmfile apply` diffs the stored release, sees no change and skips it — (or `helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds --version <ver> -n monitoring`), then Sync kube-prometheus-stack in ArgoCD to recreate the Prometheus/Alertmanager CRs. The data PVCs are preserved.
