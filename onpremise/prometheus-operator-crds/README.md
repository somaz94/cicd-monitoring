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

- A CRD's schema is tied to the **Prometheus Operator version**. This chart's `appVersion` **MUST equal** the operator `appVersion` that kube-prometheus-stack runs.
- kube-prometheus-stack sets `crds.enabled: false` to disable its bundled CRD subchart, making this component the single owner of the CRDs.
- The invariant is enforced by [`scripts/ci/check-crds-lockstep.py`](../../../scripts/ci/check-crds-lockstep.py) under `make lint-governance` (hence `make ci`). The helmfile pin's `# lockstep-appversion-match:` annotation names the component whose `Chart.yaml appVersion` must equal this component's `appVersion`; CI fails on mismatch.
- **On upgrade**: when you bump kube-prometheus-stack, bump this component to the CRD chart version whose appVersion matches, **in the same MR**. (Deliberately NOT in an auto-upgrade tier — an independent auto-bump would break the lockstep.)

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
./upgrade.py --check-chart              # check for a newer version
./upgrade.py --upgrade-chart --dry-run  # preview + render diff
./upgrade.py --upgrade-chart            # apply (updates Chart.yaml + helmfile pin)
```

After upgrading, confirm the new `appVersion` matches the `appVersion` of the kube-prometheus-stack component named in the helmfile pin's `# lockstep-appversion-match:` annotation. A mismatch fails `make lint-governance`.

<br/>

## Operational notes

- The CRDs carry a `helm.sh/resource-policy: keep` annotation to protect them from accidental deletion by helm (a safety belt added after the 2026-06-12 outage).
- Recovery if the CRDs disappear: apply this component first (or `helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds --version <ver> -n monitoring`), then apply kube-prometheus-stack to recreate the Prometheus/Alertmanager CRs. The data PVCs are preserved.
