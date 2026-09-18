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

The dashboards resolve their datasource themselves, so no wiring is needed. Most pin the `prometheus` uid that kube-prometheus-stack already provisions; the rest select it through a `$datasource` template variable.

<br/>

## Layout

The dashboard JSON lives directly under `dashboards/`; retired ones move to `dashboards/_deprecated/`, which the glob does not reach. For the set currently shipped, read `dashboards/`.

`templates/configmap-dashboards.yaml` does the rendering (one ConfigMap per file), and the switch is `dashboards.enabled` — off in `values.yaml`, turned on by `values/dev.yaml`. The marker file under `argocd-local/` enrolls the chart in the on-prem appset, and `scripts/import-dashboards.sh` is a dev/rollback helper rather than the delivery path.

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

**Current state: migration complete, flipped to `autoSync: true` (2026-07-20).** The flip followed a hand-verified first sync. Measured at migration time (2026-07-16) across every dashboard then in the repo:

- All of them existed in Grafana as manually-imported copies (`provisioned=False`, folder `General`).
- **Live ↔ repo drift was zero** — every one matched exactly after normalisation, confirming a sync could not overwrite a UI edit.
- `helm template` rendered one ConfigMap per dashboard labelled `grafana_dashboard=1`, and every uid was unique.

```bash
# Confirm the ConfigMaps exist (one per dashboard file)
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
