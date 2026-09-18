# grafana-dashboards

Manages the **custom Grafana dashboards** of the on-prem `example-cluster` through GitOps. The dashboard JSON is rendered into labelled ConfigMaps, which the kube-prometheus-stack Grafana sidecar picks up and pushes into Grafana over its API.

The AWS counterpart is [`grafana-dashboards-aws`](../grafana-dashboards-aws/), which proved this design first.

<br/>

## Why this exists

`kube-prometheus-stack` is deployed as a **2-source** App: a remote chart (prometheus-community) plus repo values referenced via `$values`. Templates cannot be added to a remote chart, so `kube-prometheus-stack/dashboards/*.json` was an **inert file set — loaded by no chart at all**.

As a result every custom dashboard was **manually imported** (`meta.provisioned=False`), leaving the repo and Grafana free to drift apart silently in both directions. This component takes over that path: **edit the repo JSON → ArgoCD sync → ConfigMap → sidecar → Grafana**.

<br/>

## How it works

The chart globs `dashboards/*.json`, emits one ConfigMap per file, and applies the label the sidecar watches for.

- Sidecar selector: `LABEL=grafana_dashboard`, `LABEL_VALUE=1`, `NAMESPACE=ALL` — the `grafana-sc-dashboard` container of the `kube-prometheus-stack-grafana` Deployment. **It is already running, so there is no new infrastructure to stand up.**
- ConfigMap name: `grafana-dashboards-<filename>`; the data key is the original filename.
- The glob only looks **directly under** `dashboards/` → `dashboards/_deprecated/` is excluded automatically.

The JSON ships **verbatim** (`.Files.Get`). Not using Helm's `tpl` is the important part — Grafana's `legendFormat` uses placeholders such as `{{pod}}`, which `tpl` would mistake for Helm template actions and fail on. This chart injects no values into the dashboards, so `tpl` would carry all of the risk and none of the benefit. (The `fluent-bit` chart does use `tpl` because it must inject the release name and its upstream pre-escapes legendFormat — a different situation.)

<br/>

## Dependencies

- **`kube-prometheus-stack` (wave_4)** — provides Grafana and its sidecar. It is this component's only consumer.
- **The `monitoring` namespace** — already in use by kube-prometheus-stack, hence `createNamespace: false`.

The dashboards reference their datasource by fixed uid, so no wiring is needed. All 11 use the single `prometheus` uid, which kube-prometheus-stack already provisions.

<br/>

## Directory Structure

```
grafana-dashboards/
├── Chart.yaml                              # pure-local, no dependencies, no upstream
├── values.yaml                             # dashboards.enabled: false (off by default)
├── values/dev.yaml                         # dashboards.enabled: true
├── dashboards/                             # 11 custom dashboard JSONs (one ConfigMap per file)
│   ├── argocd-dashboard.json
│   ├── cilium-dashboard.json
│   ├── control-plane-health-dashboard.json
│   ├── elasticsearch-dashboard.json
│   ├── fluentbit-fluentd-dashboard.json
│   ├── gitlab-runner-dashboard.json
│   ├── harbor-dashboard.json
│   ├── metallb-dashboard.json
│   ├── mysql-dashboard.json
│   ├── nginx-gateway-dashboard.json
│   ├── redis-dashboard.json
│   └── _deprecated/                        # retired dashboards (outside the glob)
│       └── ingress-nginx-dashboard.json
├── templates/
│   ├── _helpers.tpl
│   └── configmap-dashboards.yaml           # one ConfigMap per file (no tpl)
├── scripts/
│   └── import-dashboards.sh                # helper tool (dev/rollback only — not the delivery path)
├── docs/
│   ├── dashboards.md                       # dashboard guide (KO)
│   └── dashboards-en.md                    # dashboard guide (EN)
├── argocd-local/
│   └── grafana-dashboards.yaml             # ArgoCD metadata (wave_4)
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Topic | Document |
|---|---|
| Grafana dashboard layout and delivery flow | [docs/dashboards-en.md](docs/dashboards.md) |

<br/>

## The workflow changes

A provisioned dashboard becomes **`provisioned=True` in Grafana, which disables the UI Save button**. The edit path changes permanently.

| Before | After |
|---|---|
| Edit in the Grafana UI → Save | Edit `dashboards/*.json` → commit → ArgoCD sync |

Exploring and experimenting in the UI still works; to keep the result, **export the JSON → overwrite the file → commit**. `allowUiUpdates: true` would re-enable UI saves, but that resurrects the drift this component exists to remove, so **it is not used**.

<br/>

## Where it sits in governance

This chart has no upstream, so no `upgrade.py`, and it is ArgoCD-pull, so no helmfile. That places it against the repo's checks as follows.

- `make lint` / `lint-governance` / `readme-check` / `sync-check` / `shell-lint` — **all pass**. The chart is outside every helmfile- and shell-driven scope.
- `sync.py --status` — lists it under "Unmanaged chart directories", which is **informational only** and does not affect `--check`.
- `ci/components.yml` — **not registered.** That file requires a helmfile.yaml or an `upgrade.sh`.
- **Not linked from the top-level `README.md` chart table.** `render-readme.py` only counts a directory as an active chart if it ships a helmfile or `upgrade.py`, so linking it would break `readme-check` with a `stale_in_readme` drift.

<br/>

## Deploy and verify

The on-prem `infra-local-applicationset` picks up `argocd-local/*.yaml` and generates the `infra-grafana-dashboards` Application. Dropping the marker file is enough — it is discovered automatically, and the appset needs no change.

> The AWS counterpart generates an App with the same name (`infra-grafana-dashboards`), but on a **different cluster**, and the two appsets read different marker dirs (`argocd-local/` vs `argocd-local-aws/`), so they never collide. `fluent-bit` already ships this same shape.

**Current state: 11 dashboards migrated, flipped to `autoSync: true` (2026-07-20).** The flip followed a hand-verified first sync. As measured at migration time (2026-07-16):

- All 11 exist in Grafana as manually-imported copies (`provisioned=False`, folder `General`).
- **Live ↔ repo drift is zero** — all 11 match exactly after normalisation, confirming a sync cannot overwrite a UI edit.
- `helm template` renders 11 ConfigMaps labelled `grafana_dashboard=1`, and all 11 uids are unique.

```bash
# Confirm the ConfigMaps exist (11)
kubectl -n monitoring get cm -l grafana_dashboard=1

# Sidecar pickup logs
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=20

# Confirm the provisioning flip (provisioned should turn True)
# Grafana API: GET /api/dashboards/uid/<uid> → meta.provisioned
```

For the per-dashboard uid list and the delivery flow, see [docs/dashboards-en.md](docs/dashboards.md).

<br/>

## Adding a dashboard

Drop the JSON into `dashboards/` — that is all. The template globs the directory, so the chart needs no change.

```bash
# Before overwriting, compare against live (residue from the period when UI edits were possible)
# Grafana API: GET /api/dashboards/uid/<uid>, then diff against the repo copy

helm template grafana-dashboards . -f values/dev.yaml -n monitoring   # check the render
```

Keep the `uid` in the JSON — bookmarked URLs depend on it.
