# upgrade-sync

Canonical templates and a sync tool for the per-component `upgrade.{sh,py}` scripts.

Each component directory (`cicd/argo-cd/`, `observability/monitoring/kube-prometheus-stack/`, `observability/monitoring/node-exporter/`, etc.) has an `upgrade.py` for version upgrades. Every consumer is Python regardless of the template it uses (the `.sh` → `.py` flip is complete). Most components are Helm charts, but Ansible-deployed components (e.g. node-exporter) use the same sync system. The script bodies are nearly identical, so they are managed in one place (this directory) and propagated to every component via [sync.py](sync.py).

To survey which charts have an upstream upgrade available before touching any `upgrade.py`, use [check-versions.py](check-versions.py) (read-only).

To inspect or bulk-clean the `backup/` directories across every chart at once, use [manage-backups.py](manage-backups.py).

<br/>

## Table of contents

1. [Directory layout](#directory-layout)
2. [Key concepts](#key-concepts)
3. [Architecture](#architecture)
4. [Canonical templates](#canonical-templates)
5. [sync.py usage](#syncpy-usage)
6. [check-versions.py usage](#check-versionspy-usage)
7. [manage-backups.py usage](#manage-backupspy-usage)
8. [How it works (internals)](#how-it-works-internals)
9. [Adding a new chart](#adding-a-new-chart)
10. [Adding a new canonical variant](#adding-a-new-canonical-variant)
11. [Worked examples](#worked-examples)
12. [Troubleshooting](#troubleshooting)
13. [Compatibility](#compatibility)
14. [Safety guards](#safety-guards)
15. [FAQ](#faq)
16. [See also](#see-also)

<br/>

## Directory layout

Three tools — `sync.py` · `check-versions.py` · `manage-backups.py` — plus the `templates/` canonical directory (docs are `README.md` in Korean + `README-en.md`, this file).

```
scripts/upgrade-sync/templates/
├── external-standard.py           # external chart (helm repo) + default flow
├── external-with-image-tag.py     # external + values image tag auto-update
├── external-oci.py                # external OCI chart + GitHub Releases tracking
├── external-oci-cr-version.py     # external OCI chart consumer (CR wrapper) + values.version tracking
├── external-oci-with-mirror.py    # external OCI chart + Harbor image mirror (library base)
├── local-with-templates.py        # local chart (Chart.yaml in repo) + custom templates
├── local-cr-version.py            # local chart (CR wrapper) + values.version + Chart.yaml.appVersion
├── ansible-github-release.py     # Ansible-deployed component + GitHub Releases tracking
└── argocd-pin.py                  # bumps chart.version in the ArgoCD metadata file (delegates to a base template)
```

> All canonicals are Python. The body lives in `scripts/python/upgrade_core/<template>.py`; each `templates/<name>.py` canonical is a thin wrapper around the placeholder dict + ancestor walk.

<br/>

## Key concepts

### The problem

Previously, 16 chart directories each carried a near-identical copy of `upgrade.py`. Fixing a single line in `usage()` required 16 separate Edits, and drift between charts accumulated over time.

### The solution

Each chart's `upgrade.py` is split into two regions:

```python
#!/usr/bin/env python3
# upgrade-template: external-standard   <-- header: declares which canonical to follow

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "ArgoCD Helm Chart Upgrade Script",
    "HELM_REPO_NAME": "argo",
    "HELM_REPO_URL":  "https://argoproj.github.io/argo-helm",
    "HELM_CHART":     "argo/argo-cd",
    "CHANGELOG_URL":  "https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd",
    "CHART_TYPE":     "local",  # "local" or "external"
}
# ============================================================

# ── canonical body (sync-managed, do not edit below) ────────
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
for _anc in [_here, *_here.parents]:
    if (_anc / "scripts" / "python" / "upgrade_core").is_dir():
        sys.path.insert(0, str(_anc / "scripts" / "python"))
        break

from upgrade_core.external_standard import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
```

That is the **whole** of `cicd/argo-cd/upgrade.py` (32 lines, nothing elided). The bash-era `set -euo pipefail` and the inline 7-step flow are gone — every consumer is Python, the real upgrade logic is owned by `scripts/python/upgrade_core/external_standard.py`, and the consumer is a thin entry point that calls its `run()`.

- **CONFIG block** (between the three `# ===` markers): per-chart, hand-edited
- **Body** (after the third `# ===`): shared across all charts, propagated from canonical via sync

`sync.py --apply` keeps each file's CONFIG block intact and replaces only the body with the canonical's body.

### Impact

| Aspect | Before | After |
|---|---|---|
| Edit one line in `usage()` | 16 Edits | 1 Edit + `sync.py --apply` |
| Detect drift between charts | Manual grep | `sync.py --check` (CI-friendly) |
| Add a new chart | Copy nearest file → risk of editing body | Copy canonical → edit only CONFIG |
| Canonical divergence | Implicit, hard to track | Header makes it explicit |

### Responsibility split (who edits what)

| Action | Who | Where |
|---|---|---|
| Add a new chart | User | Copy canonical → **fill in the CONFIG block variables only** |
| Chart version upgrade | `upgrade.py` automatically | Run `./upgrade.py` or `./upgrade.py --version X.Y.Z` |
| Common logic change (e.g., usage text) | User edits once + sync propagates | `vim canonical → commit → ./scripts/upgrade-sync/sync.py --apply` |
| Add a per-chart placeholder | User edits both canonical and each chart's CONFIG | Add placeholder to canonical + real value to each chart |
| Edit body directly | ❌ Don't | Will be overwritten by next sync (see [FAQ](#faq)) |

**Key rule**: CONFIG block (markers 1~3) = user-owned, body (after marker 3) = canonical-owned. sync.py never touches CONFIG.

<br/>

## Architecture

### Overall structure

```
                ┌─────────────────────────────────────────────┐
                │  scripts/upgrade-sync/templates/            │
                │  ┌────────────────────────────────────────┐ │
                │  │ external-standard.py         (CANONICAL)│ │
                │  │ external-with-image-tag.py   (CANONICAL)│ │
                │  │ local-with-templates.py      (CANONICAL)│ │
                │  └────────────────────────────────────────┘ │
                └─────────────────┬───────────────────────────┘
                                  │
                                  │  sync.py --apply
                                  │  (copy body, preserve CONFIG)
                                  │
        ┌─────────┬──────────┬────┴───┬──────────┬──────────┐
        ↓         ↓          ↓        ↓          ↓          ↓
   argo-cd/   gitlab-    harbor-   valkey/   fluent-     kube-prom-
   upgrade.py runner/    helm/     upgrade   bit/        stack/
              upgrade    upgrade   .py       upgrade     upgrade
              .py        .py                 .py         .py
```

### Per-file sync flow

```
   target file: cicd/argo-cd/upgrade.py
   ┌────────────────────────────────────────┐
   │ #!/usr/bin/env python3                 │     1. read line 2 → "external-standard"
   │ # upgrade-template: external-standard  │ ───────────────────────┐
   │                                        │                        │
   │ # ============================         │     2. extract CONFIG  │
   │ # Configuration                        │ ───┐  (markers 1~3)    │
   │ # ============================         │    │                   │
   │ CONFIG = {                              │    │                   │
   │     "SCRIPT_NAME":    "ArgoCD ...",    │    │                   │
   │     "HELM_REPO_NAME": "argo",          │    │                   │
   │     ...                                │    │                   │
   │ }                                       │    │                   │
   │ # ============================         │ ───┘                   │
   │                                        │                        │
   │ import sys                             │     3. body (replaced) │
   │ ... (ancestor walk)                    │                        │
   │ from upgrade_core.external_standard    │                        │
   │     import run                         │                        │
   └────────────────────────────────────────┘                        │
                                                                     ↓
                  ┌──────────────────────────────────────────────────┘
                  │
                  ↓
   canonical: scripts/upgrade-sync/templates/external-standard.py
   ┌────────────────────────────────────────┐
   │ #!/usr/bin/env python3                 │
   │ # CANONICAL TEMPLATE — DO NOT RUN ...  │
   │                                        │
   │ # ============================         │
   │ # Configuration (placeholders)         │
   │ # ============================         │
   │ CONFIG = {                              │
   │     "SCRIPT_NAME": "__SCRIPT_NAME__",  │     ★ placeholders only, not used
   │     ...                                │
   │ }                                       │
   │ # ============================         │
   │                                        │
   │ import sys                             │     ★ this body is copied to target
   │ ... (ancestor walk)                    │
   │ from upgrade_core.external_standard    │
   │     import run                         │
   └────────────────────────────────────────┘

   build_expected(target):                          # scripts/python/upgrade_sync/extract.py
     header  := "#!/usr/bin/env python3"            # .py branch — no set -euo pipefail
              + "# upgrade-template: external-standard"
              + ""
     CONFIG  := extract_config_block(target)        # from target
     body    := extract_body(canonical)             # from canonical
     return header + CONFIG + body

   --check  : diff(build_expected(target), target)
   --apply  : write build_expected(target) → target
```

> The body above is not the upgrade logic — it is the entry point that imports `scripts/python/upgrade_core/external_standard.py`, which owns the 7-step flow.
>
> `build_expected()` still carries a `.sh` branch that emits a `#!/bin/bash` + `set -euo pipefail` header (kept for forward-compat), but with zero `.sh` consumers it is currently unreachable.

### 3-marker layout

Each `upgrade.py` and canonical uses the same 3-marker structure:

```python
# ============================================================  ← marker 1: doc opens
# Configuration (per-chart, sync-managed body below)
# ============================================================  ← marker 2: doc closes / CONFIG opens
CONFIG = {
    "SCRIPT_NAME":    "...",
    "HELM_REPO_NAME": "...",
    ...
}
# ============================================================  ← marker 3: CONFIG closes / body opens
import sys
from pathlib import Path
...
```

- **CONFIG block** = marker 1 ~ marker 3 (all inclusive)
- **body** = everything after marker 3

`scripts/python/upgrade_sync/extract.py` matches markers via regex to find precise boundaries.

<br/>

## Canonical templates

### Naming convention

```
<chart-type>-<feature>.py
   │              │
   │              └── standard | with-image-tag | with-templates | (future...)
   └── external (helm repo) | local (Chart.yaml in repo)
```

New variants must follow the same convention (e.g., `external-multi-release.py`, `local-bare.py`).

### Current canonicals (see the sections below)

#### 1. [external-standard.py](templates/external-standard.py) — external helm repo chart (most common, Python)

- **Use**: Receives a chart from an external helm repo and deploys via helmfile
- **Language**: Python. Body lives in `scripts/python/upgrade_core/external_standard.py`; the canonical is a thin wrapper.
- **Flow**: 7 steps (current → fetch latest → download → diff Chart → diff values → check breaking → apply + backup)
- **Consumers**: the `external-standard` row of `sync.py --status` is the SSOT for the count; the `[external-standard]` rows of `sync.py --check` are the SSOT for the list. Representative consumers: `cicd/argo-cd`, `network/metallb`, `security/vaultwarden`.

#### 2. [external-with-image-tag.py](templates/external-with-image-tag.py) — external + image tag auto-update

- **Use**: Same as external-standard but values files contain `tag: vX.Y.Z` patterns that should auto-update to match the new appVersion
- **Flow**: external-standard's 7 steps + an image tag rewriting block at the end of step 7 (~16 lines)
- **Difference (vs external-standard)**:
  ```bash
  # Update image tags in values files (appVersion based)
  if [ -n "$LATEST_APP_VERSION" ]; then
    for values_file in "$VALUES_DIR"/*.yaml; do
      VALUES_TAG=$(grep -oE 'tag: v[0-9]+\.[0-9]+\.[0-9]+' "$values_file" | head -1 | ...)
      if [ -n "$VALUES_TAG" ] && [ "$VALUES_TAG" != "$LATEST_APP_VERSION" ]; then
        # rewrite tag: vX.Y.Z → tag: vNEW.NEW.NEW
      fi
    done
  fi
  ```
- **Consumers**: `harbor-helm` (count/list per `sync.py --status`)

#### 3. [local-with-templates.py](templates/local-with-templates.py) — local chart + custom templates

- **Use**: Local charts that keep `Chart.yaml` and `templates/` in the repo. Fetches the upstream chart, preserves custom templates (e.g., `pv.yaml`, `pvc.yaml`), and re-applies a `_pod.tpl` PVC patch
- **Flow**: 8 steps (current → fetch → download upstream → diff Chart → diff values + templates → check pod patch → check breaking → apply + backup + preserve customs + patch _pod.tpl)
- **Extra variables**: `CUSTOM_TEMPLATES`, `CUSTOM_POD_PATCH`, `EXTRA_DIRS`
- **Two upstream source modes** (selected via CONFIG block):
  - **helm repo mode** (default): set `HELM_REPO_NAME`/`HELM_REPO_URL`/`HELM_CHART`, leave `CHART_GIT_REPO` empty
  - **git source mode**: set `CHART_GIT_REPO`/`CHART_GIT_PATH` (for charts not published to any helm repo). Latest version is auto-detected from git tags and the chart is fetched via git clone.
- **Consumers** (per `sync.py --status`):
  - `fluent-bit`, `fluent-bit-aws` (helm repo mode)

#### 4. [local-cr-version.py](templates/local-cr-version.py) — local chart (CR wrapper) + version field tracking

- **Use**: Local charts whose `templates/` directory contains Custom Resource (CR) YAML, with the component version stored in a `values/*.yaml` field (e.g. `version`). **No upstream Helm chart exists** (we are the sole owner). Only the value field needs bumping — no chart sync.
- **Flow**: 6 steps (read current version from values → fetch latest from source feed → **verify container image exists** → compatibility reminder → backup → update values + Chart.yaml appVersion)
- **Extra variables**:
  - `COMPONENT_LABEL`: label shown in output (e.g., `elasticsearch`, `kibana`)
  - `VERSION_SOURCE`: version feed type (supported values listed below)
  - `VALUES_FILE`: path to the values file holding the version (e.g., `values/dev.yaml`)
  - `VERSION_KEY`: top-level YAML key name (usually `version`)
  - `MAJOR_PIN`: major line lock (e.g., `"9"` → track 9.x only). Empty = track all majors
  - `CHANGELOG_URL`
  - `CONTAINER_IMAGE`: container image to verify before upgrading (e.g., `docker.elastic.co/elasticsearch/elasticsearch`). Leave empty to skip verification
  - `CR_WEBHOOK_NAME`: admission webhook name that blocks version downgrades (e.g., `elastic-operator.elastic-system.k8s.elastic.co`). Set together with the two variables below to enable automatic rollback handling
  - `CR_OPERATOR_NS`: namespace where the operator is deployed (e.g., `elastic-system`)
  - `CR_OPERATOR_STS`: operator StatefulSet name (e.g., `elastic-operator`)
- **Safety features**:
  - **Image verification (Step 3)**: Checks via Docker Registry v2 API that the target version's container image actually exists. Prevents upgrades to versions listed in the artifacts API whose Docker images have not been published yet
  - **Smart rollback**: On `--rollback`, compares the cluster CR's current version with the backup version to detect downgrades. When a downgrade is detected, offers automatic webhook handling (scale down operator → delete webhook → helmfile apply → recreate webhook → scale up operator)
- **Supported VERSION_SOURCE values**:
  - `elastic-artifacts`: queries `https://artifacts-api.elastic.co/v1/versions`. All Elastic Stack components (Elasticsearch, Kibana, APM Server, Logstash, Beats) share a single Stack version. `VERSION_SOURCE_ARG` not needed.
  - `github-releases`: queries the GitHub Releases API (`api.github.com/repos/<owner>/<repo>/releases`). Excludes prereleases/drafts, strips leading `v`, then keeps only strict `X.Y.Z`. Requires `VERSION_SOURCE_ARG="<owner>/<repo>"` (e.g. `cloudnative-pg/cloudnative-pg`).
  - `docker-hub-tags`: queries the Docker Hub API (`hub.docker.com/v2/repositories/<namespace>/<repository>/tags`). Strips leading `v`, then keeps only strict `X.Y.Z` (suffixed tags like `-debian` are not matched). Requires `VERSION_SOURCE_ARG="<namespace>/<repository>"` (e.g. `library/redis`).
  - Adding a new source: the implementation is split in two, so a new backend needs a branch in **both** — `fetch_ga_versions_source()` in `scripts/python/upgrade_sync/fetchers.py` (the check-versions.py path) and `fetch_ga_versions()` in `scripts/python/upgrade_core/_common_cr.py` (the consumer `upgrade.py` path). The canonical templates contain neither (they are placeholders + an import).
- **Extending to other operators**: `local-cr-version` is not ECK-specific. Populating `CR_WEBHOOK_NAME`, `CR_OPERATOR_NS`, `CR_OPERATOR_STS`, and `CR_OPERATOR_CHART_DIR` correctly enables reuse for CloudNativePG, Strimzi Kafka, Redis Operator, and others. Example: for CNPG use `CR_OPERATOR_CHART_DIR="cnpg-operator"`, `VERSION_SOURCE="github-releases"`, `VERSION_SOURCE_ARG="cloudnative-pg/cloudnative-pg"`.
- **Differences vs other templates**:
  - Does not fetch Chart.yaml from upstream (we are the sole owner)
  - Does not sync `templates/` (CR definitions are owned locally)
  - Backup targets: `Chart.yaml` + `$VALUES_FILE` only
- **0 charts (historical)**: `elasticsearch` and `kibana` (ECK CR) previously used this template; after migrating to OCI charts they now use `external-oci-cr-version`. Still available for operator-wrapper charts that keep a local Chart.yaml.

#### 5. [external-oci-cr-version.py](templates/external-oci-cr-version.py) — external OCI chart consumer (CR wrapper) + version field tracking

- **Use**: Consumer components that deploy CRs via a **public OCI chart** (e.g. `oci://ghcr.io/...`). The consumer does NOT own `Chart.yaml` or `templates/`; those live in a separate publishing repo (e.g. `somaz94/helm-charts`). Only `helmfile.yaml` (with the chart pinned by version) and `values/*.yaml` are managed here.
- **vs `local-cr-version` (key differences)**:
  - No `Chart.yaml` / `templates/` (chart lives upstream)
  - `MIRROR_CHART_VERSION` removed (no local Chart.yaml to mirror)
  - Backup targets: `$VALUES_FILE` only
  - No Chart.yaml restore path on rollback
  - Step 1 prints `helmfile.yaml.version` informationally ("bump manually if needed")
- **Design intent**: **Separate the management concerns** of Stack/component version (image tag) and OCI chart version (template version). The chart pin is a manual bump (operator judgment), the Stack version is auto-tracked by this script.
- **Flow**: 7 steps (read current → health check → fetch latest → **verify container image** → compatibility + dependency + major bump warning → backup `$VALUES_FILE` → update `$VALUES_FILE.<VERSION_KEY>`)
- **Extra variables** (same as local-cr-version, **except `MIRROR_CHART_VERSION` is removed**):
  - `COMPONENT_LABEL`, `VERSION_SOURCE`, `VERSION_SOURCE_ARG`
  - `VALUES_FILE`, `VERSION_KEY`, `MAJOR_PIN`, `CHANGELOG_URL`
  - `CONTAINER_IMAGE`
  - `CR_WEBHOOK_NAME`, `CR_OPERATOR_NS`, `CR_OPERATOR_STS`, `CR_OPERATOR_CHART_DIR` (downgrade webhook auto-handling)
  - `DEPENDENCY_CR_KIND`, `DEPENDENCY_CR_NAME` (e.g., Kibana → Elasticsearch version constraint)
- **Safety features** (shared with local-cr-version):
  - Image registry verification with fallback auto-search
  - Downgrade detection + operator webhook auto-handling
  - Helm failed-release recovery
  - Operator / CR Ready waits
- **OCI chart pin automation (`--check-chart` / `--upgrade-chart`)**: on top of Stack version tracking, the script can also track `helmfile.yaml.version` (the publisher's chart release tag). Setting all three CONFIG variables below activates the two sub-commands:
  - `CHART_SOURCE_TYPE`: currently only `"github-releases"` is supported (empty disables chart-pin tracking)
  - `CHART_SOURCE_REPO`: `"<owner>/<repo>"` that publishes the chart (e.g. `"somaz94/helm-charts"`)
  - `CHART_NAME`: release tag prefix (e.g. `"elasticsearch-eck"` → version is extracted from tags like `elasticsearch-eck-0.1.2`)
- **`--check-chart`**: compares current pin with the latest publisher release (read-only). Prints release notes URL and suggests next commands if an update is available.
- **`--upgrade-chart [--chart-version X.Y.Z] [--dry-run]`**: `helm pull`s both the current and target charts into a scratch directory, runs `helm template` on each with the active values file, and shows a unified diff of the rendered manifests. On confirmation, backs up `helmfile.yaml` to `backup/<TIMESTAMP>-chart/` and bumps the pin. Values-schema breakage surfaces as a `helm template` failure on the target chart before any file is touched.
- **Chart vs Stack backups**: Stack upgrades write `backup/<TIMESTAMP>/<values-file>`; chart upgrades write `backup/<TIMESTAMP>-chart/helmfile.yaml`. `--rollback` auto-detects the backup type and restores only the relevant file. Chart-pin rollback skips the operator webhook handling path since no live CR version changes.
- **Consumers** (per `sync.py --status`): `observability/logging/elasticsearch` + `elasticsearch-aws` (elasticsearch-eck OCI chart consumer), `observability/logging/kibana` + `kibana-aws` (kibana-eck OCI chart consumer)

#### 6. [external-oci.py](templates/external-oci.py) — external OCI chart + GitHub Releases tracking

- **Use**: OCI-registry-distributed charts where the chart version itself needs tracking. Bumps `helmfile.yaml.version` via GitHub Releases API.
- **Differences vs external-standard**: `helm search repo` is unavailable for OCI → use GitHub Releases instead.
- **Extra variables**: `HELM_CHART` (oci://... URL), `GITHUB_REPO` (owner/repo), `GITHUB_TAG_PREFIX`
- **Consumers** (per `sync.py --status`): `compute/karpenter`, `network/nginx-gateway-fabric` (NGF OCI chart), `security/keycloak`, `security/keycloak-operator`, `storage/local-path-provisioner` (Rancher upstream OCI chart)

#### 7. [ansible-github-release.py](templates/ansible-github-release.py) — Ansible-deployed (non-Helm) component + GitHub Releases tracking (Python)

- **Use**: Components **deployed via Ansible**, not Helm, where the version lives in a single YAML file (e.g. `group_vars/all.yml`) and the upstream source is a GitHub Releases feed. No `Chart.yaml` / `helmfile.yaml`.
- **Language**: Python. Body lives in `scripts/python/upgrade_core/ansible_github_release.py`; the canonical is a thin wrapper.
- **Flow**: 5 steps (current → fetch latest from GitHub → diff preview + major-bump warning → backup → update VERSION_FILE)
- **Specific variables**:
  - `COMPONENT_NAME`: human-readable name (e.g. `node_exporter`)
  - `GITHUB_REPO`: `<owner>/<repo>` (e.g. `prometheus/node_exporter`)
  - `VERSION_FILE`: path to the YAML file holding the version (e.g. `ansible/group_vars/all.yml`)
  - `VERSION_KEY`: top-level YAML key name (e.g. `node_exporter_version`)
  - `ANSIBLE_DIR` / `ANSIBLE_INVENTORY` / `ANSIBLE_UPGRADE_PLAYBOOK`: used only for the "next steps" guidance
  - `MAJOR_PIN`: pin to a major line (empty = track any major)
  - `CHANGELOG_URL`
- **Differences vs other templates**:
  - No Helm concepts (`Chart.yaml`, `helmfile.yaml`, `values/`)
  - Backup target: just `$VERSION_FILE`
  - Does not apply upstream — prints `ansible-playbook upgrade.yml` as the next-step hint (same pattern as Helm templates pointing at `helmfile apply`)
- **Consumers**: `observability/monitoring/node-exporter` (count/list per `sync.py --status`)

#### 8. [argocd-pin.py](templates/argocd-pin.py) — component migrated to the ArgoCD app-of-apps (version-pin write target redirected)

- **Use**: Components migrated to the ArgoCD app-of-apps, where the chart-version SSOT moved out of `helmfile.yaml` (retired to `backup/`) and into the nested `chart.version` field of the per-release ArgoCD metadata file `<component>/argocd[-aws]/<release>.yaml`. The infra-applicationset git-files generator reads that field and ArgoCD syncs it, so **bumping that field IS the cluster upgrade**.
- **How it works**: A thin dispatcher. It reuses the fetch / diff / breaking-change logic of `external_standard` (helm repo charts) or `external_oci_with_mirror` (OCI charts + Harbor image mirror) as-is, and swaps **only the version-pin write target** through the `pin_write_hook` extension point — writing `chart.version` into the ArgoCD metadata file instead of a helmfile.
- **Specific variables** (**in addition to** the chosen base template's keys):
  - `BASE`: `"standard"` (helm repo — wraps external-standard) or `"oci"` (OCI + Harbor mirror — wraps external-oci-with-mirror)
  - `ARGOCD_PIN_FILES`: list of ArgoCD metadata files to bump, each path relative to the component directory (where `upgrade.py` lives), e.g. `["argocd/build-image.yaml", "argocd/deploy-image.yaml"]`. Lists **only the tracked releases**; deliberately pinned releases are omitted so they are never auto-bumped (e.g. `argocd/old-build-deploy-image.yaml` in `cicd/gitlab-runner`).
  - The base template's keys are still required: `BASE="standard"` → `HELM_REPO_NAME` / `HELM_REPO_URL` / `HELM_CHART` / `CHANGELOG_URL` / `CHART_TYPE`; `BASE="oci"` → `GITHUB_REPO` / `GITHUB_TAG_PREFIX` / `HELM_CHART` (+ optional `do_mirror` / `print_values_summary`).
- **The local `Chart.yaml` is an optional derived mirror, not the SSOT**:
  - Components that ship a mirror (22) have it refreshed by the base flow.
  - **Pin-only** components that ship none (`security/cert-manager-aws`, `observability/tracing/tempo-aws`, `observability/tracing/opentelemetry-operator-aws` — 3) keep none going forward: the `skip_missing_chart_mirror` flag suppresses mirror creation.
  - For pin-only components, Step 1 resolves the current version through `current_version_hook`, which reads the ArgoCD marker file directly — so it agrees with `check-versions.py`, which reads the same file. (Introduced in commit `18a09bd`; before that the current version came back empty, silently disabling the values diff and the breaking-change scan.)
- **Consumers**: the most consumers of any canonical. For the exact count see `sync.py --status`; for the list see the `[argocd-pin]` rows of `sync.py --check`.

#### 9. [external-oci-with-mirror.py](templates/external-oci-with-mirror.py) — external OCI chart + Harbor image mirror (library base)

- **Use**: OCI charts whose upstream images must be mirrored to a private registry (Harbor) **before** the chart upgrade is applied. An 8-step flow that thinly extends `external-oci`.
- **Differences (vs external-oci)**: `pre_apply_hook` runs as `[Step 7/8]` and drives the mirror stage; a non-zero return aborts the upgrade with no files modified (SKIPPED in dry-run). `values_summary_hook` surfaces per-values-file `image.tag` overrides at the tail of Step 1.
- **Specific variables**: `do_mirror` (per-chart mirror function — calls `crane copy`), `print_values_summary` (optional)
- **0 charts — this is not a dead template.** No `upgrade.py` declares this canonical in its `# upgrade-template:` header, but it is the **library base wrapped by `argocd-pin` with `BASE="oci"`**. Deleting it breaks those argocd-pin consumers.

<br/>

## sync.py usage

Run `./scripts/upgrade-sync/sync.py --help` for the full inline help.

### `--status` — show current state

```bash
./scripts/upgrade-sync/sync.py --status
```

```
Managed upgrade.{sh,py} files: 49
  ansible-github-release:  1
  argocd-pin:              25
  external-oci:            5
  external-oci-cr-version: 4
  external-standard:       11
  external-with-image-tag: 1
  local-with-templates:    2

Available canonicals:
  ansible-github-release
  argocd-pin
  external-oci
  external-oci-cr-version
  external-oci-with-mirror
  external-standard
  external-with-image-tag
  local-cr-version
  local-with-templates

Unmanaged chart directories (have Chart.yaml but no upgrade.{sh,py}):
  - observability/monitoring/grafana-dashboards
  - ...
```

> The output above is an example — it goes stale as components are added or removed. **Every number in every pasted output in this README — including the managed total (`Managed: N`) — is illustrative and drifts the moment a component is added. Always confirm the current values with `sync.py --status`.** The distribution list shows only canonicals with at least one consumer; zero-consumer canonicals (`external-oci-with-mirror`, `local-cr-version`) appear under `Available canonicals` only.

**Unmanaged charts** are directories that have `Chart.yaml` but no `upgrade.{sh,py}`. The list changes as components are added or removed, so it is not maintained here — read the current one off `sync.py --status`. They can be onboarded with the [Adding a new chart](#adding-a-new-chart) procedure.

<br/>

### `--check` — drift verification (CI-friendly)

```bash
./scripts/upgrade-sync/sync.py --check
```

Verifies that every file matches its canonical bytewise. Exits non-zero on drift. Recommended in CI / pre-commit hooks.

```
  OK    [external-standard] cicd/argo-cd/upgrade.py
  OK    [external-standard] cicd/gitlab-runner/upgrade.py
  OK    [external-with-image-tag] cicd/harbor-helm/upgrade.py
  ...
```

<br/>

### `--apply` — propagate canonical → all files

```bash
# Working tree must be clean (safety guard)
./scripts/upgrade-sync/sync.py --apply

# Force-apply even when working tree is dirty
./scripts/upgrade-sync/sync.py --apply --force
```

For each file:
1. Read the canonical name from the header
2. Extract the CONFIG block (from target)
3. Extract the body (from canonical)
4. Write the combined result and ensure `chmod +x`

**Guard**: Aborts if the working tree is dirty. Prevents accidentally clobbering manual edits. Use `--force` to override.

<br/>

### `--print-expected <file>` — preview a single file

```bash
# What would the file look like after sync? (stdout)
./scripts/upgrade-sync/sync.py --print-expected cicd/argo-cd/upgrade.py

# Compare against the current file
./scripts/upgrade-sync/sync.py --print-expected cicd/argo-cd/upgrade.py | diff - cicd/argo-cd/upgrade.py
```

Useful for debugging when a single file shows drift.

<br/>

> **Note**: The bash `sync.sh` once shipped a one-shot migration command `--insert-headers` and a verification mode `--check --no-header`. Both were retired — every consumer now carries the `# upgrade-template:` header (see `sync.py --status` for the current count), so the commands were dead code. If you need content-based template auto-detection, call `detect_template()` from `scripts/python/upgrade_sync/detect.py` directly.

<br/>

## check-versions.py usage

A read-only preflight tool. Before running the per-chart `upgrade.py` one by one, use this to scan every managed chart and see which ones have an upstream upgrade available. It does not modify any files — it only prints a summary table.

Each template uses the same upstream lookup logic its `upgrade.py` already relies on:

| Template | Current version | Latest version |
|---|---|---|
| `external-standard` / `external-with-image-tag` | `Chart.yaml` → `version` | `helm search repo <HELM_CHART>` (top entry) |
| `local-with-templates` (helm mode) | `Chart.yaml` → `version` | `helm search repo <HELM_CHART>` (top entry) |
| `local-with-templates` (git mode, `CHART_GIT_REPO` set) | `Chart.yaml` → `version` | Highest semver tag from `git ls-remote --tags` |
| `local-cr-version` | `<VALUES_FILE>` → `<VERSION_KEY>` | `VERSION_SOURCE` feed (e.g. elastic-artifacts), respecting `MAJOR_PIN` |
| `external-oci-cr-version` | `<VALUES_FILE>` → `<VERSION_KEY>` (plus `helmfile.yaml.version` chart pin, shown in a separate table) | `VERSION_SOURCE` feed, respecting `MAJOR_PIN` (no Chart.yaml). Chart pin looked up against `CHART_SOURCE_REPO`'s GitHub Releases filtered by `<CHART_NAME>-X.Y.Z` prefix |
| `external-oci` / `external-oci-with-mirror` | `Chart.yaml` → `version` | GitHub Releases API (`<GITHUB_REPO>`), stripping `<GITHUB_TAG_PREFIX>` (the mirror stage runs at apply time only) |
| `ansible-github-release` | `<VERSION_FILE>` → `<VERSION_KEY>` | GitHub Releases API (`<GITHUB_REPO>`), respecting `MAJOR_PIN` |
| `argocd-pin` | `argocd[-aws]/<release>.yaml` → `chart.version` (first pin in filename sort order) | Selected by `BASE` — `"oci"` uses the GitHub Releases API (`<GITHUB_REPO>`, stripping `<GITHUB_TAG_PREFIX>`), anything else uses `helm search repo <HELM_CHART>` (top entry) |

<br/>

### Default run

```bash
./scripts/upgrade-sync/check-versions.py
```

```
Collecting managed upgrade.py configs...
  Managed: 49  Skipped (no header): 0
Registering 13 helm repo(s)...
Running 'helm repo update'...

  STATUS   TEMPLATE                  CURRENT          LATEST           PATH
  -------  ------------------------  ---------------  ---------------  ----
  UPDATE   external-standard         9.4.15           9.5.0            cicd/argo-cd/upgrade.py
  OK       external-standard         0.87.1           0.87.1           cicd/gitlab-runner/upgrade.py
  ...
  UPDATE   external-oci-cr-version   9.0.0            9.4.0            observability/logging/elasticsearch/upgrade.py
  ...

Summary: OK=42  UPDATE=7  ERROR=0  (total=49)
Upgrades are available. Run 'cd <path> && ./upgrade.py --dry-run' in each directory above.

OCI chart pin status (external-oci-cr-version consumers):

  STATUS   CHART                 CURRENT     LATEST      PATH
  -------  --------------------  ----------  ----------  ----
  OK       elasticsearch-eck     0.1.2       0.1.2       observability/logging/elasticsearch/upgrade.py
  OK       kibana-eck            0.1.1       0.1.1       observability/logging/kibana/upgrade.py

Chart summary: OK=2  UPDATE=0  ERROR=0  (total=2)
```

> The output above is an example — it drifts as components are added or removed and as upstreams cut releases. **Always run `check-versions.py` yourself for the current values.**

STATUS column (main table = Stack/component version):
- `OK`: current version matches the upstream latest
- `UPDATE`: a higher upstream version exists → `cd` into the chart dir and run `./upgrade.py --dry-run`
- `NO_IMG`: upstream feed lists a new version but the container image has not been published yet (common for Elastic etc.)
- `ERROR`: upstream lookup failed, CONFIG missing, current version could not be read, etc. (reason printed on the next line as `-> ...`)

**OCI chart pin table** (secondary table, shown at the bottom): only rows using the `external-oci-cr-version` template with `CHART_SOURCE_*` CONFIG set appear here. This reports drift on `helmfile.yaml.version` (chart pin) independently of the Stack/component version. When `UPDATE` is shown, run `./upgrade.py --check-chart` and `--upgrade-chart --dry-run` in the listed directory before applying.

<br/>

### Options

```bash
# Only print rows that have an upgrade or an error
./scripts/upgrade-sync/check-versions.py --updates-only

# Restrict by path substring (repeatable, OR-matched)
./scripts/upgrade-sync/check-versions.py --only observability/monitoring
./scripts/upgrade-sync/check-versions.py --only argo-cd --only valkey

# Skip `helm repo update` (faster if you just updated)
./scripts/upgrade-sync/check-versions.py --no-update

# Combine
./scripts/upgrade-sync/check-versions.py --updates-only --only observability
```

<br/>

### Exit codes

- `0`: all lookups succeeded, regardless of whether any UPDATE was found.
- `1`: one or more rows ended up as ERROR (network issue, `helm` missing, CONFIG missing, etc). Treat as a CI failure if desired.

<br/>

### Prerequisites

The following tools must be on `PATH` (CI runner installs them automatically via `.gitlab/ci/shared.yml`'s `.install_tools`; local users install manually):

| Tool | Purpose | Used by |
|---|---|---|
| `bash` (>= 3.2 / 4+) **or** `zsh` | the interactive shell you type commands into (the scripts themselves are all Python) | always |
| `helm` | helm-repo lookups, OCI chart pull | `check-versions.py` + every helm-based `upgrade.py` |
| `helmfile` | helmfile sync/diff/apply | component deploys (CI `apply-components.py`, local `helmfile apply`) |
| `kubectl` | cluster apply / context management | invoked by helmfile, CI `helmfile-apply-component.py` |
| `git` | git-tags lookups, automated commit/push | `local-with-templates` (git mode), CI `auto-upgrade.py` |
| `curl` | upstream metadata fetch | `check-versions.py`, every version-source template |
| `python3` (>= 3.10) | runs every sync/upgrade script (`sync.py`, `check-versions.py`, `manage-backups.py`, each `upgrade.py`) | always |
| `jq` | JSON processing | some helm plugins (auto-upgrade's `jq` usage was replaced with python stdlib `json`) |
| `yq` | YAML processing | CI `helmfile-apply-component.py`, `apply-components.py` |
| `crane` | OCI image mirror (upstream → private registry) | `external-oci-with-mirror` template Step 7 mirror stage |
| `tar`, `gzip` | archive handling | `helm pull --untar`, OCI chart downloads |

Same portability as sync.py: Python 3.10+ (helmfile-tools image's 3.12, Homebrew Mac 3.13+, Linux distro 3.10+). Active wrapper `*.sh` files (run.sh, setup-tools.sh) carry the `#!/usr/bin/env bash` shebang plus a zsh re-exec guard.

To verify the entire toolchain in one shot, run `scripts/setup-tools.sh --check` (use `--install` to attempt automatic installation via Homebrew on macOS, `apt` on Debian/Ubuntu, `apk` on Alpine, or `dnf` on Rocky/RHEL).

<br/>

### Recommended workflow

```bash
# 1. Survey upstream versions across every managed chart
./scripts/upgrade-sync/check-versions.py --updates-only

# 2. For each chart with an upgrade, inspect the detailed diff
cd observability/monitoring/kube-prometheus-stack
./upgrade.py --dry-run

# 3. Apply when satisfied
./upgrade.py

# 4. Roll out via helmfile
helmfile diff
helmfile apply
```

<br/>

## manage-backups.py usage

Each chart's `upgrade.py` copies current files to `<chart>/backup/<TIMESTAMP>/` on every run. These accumulate over time — `manage-backups.py` provides cross-chart visibility and bulk cleanup.

<br/>

### Governance rules

| Topic | Rule |
|---|---|
| **Naming** | `backup/` (no leading underscore). Distinct from `_optional/` and `_deprecated/` — those are git-tracked meta dirs, this is a transient artifact with no gitignore |
| **Location** | Always a child of the chart dir — `<chart>/backup/<TIMESTAMP>/` |
| **Creator** | `upgrade.py` (canonical template) only. No manual backups — use `~/tmp/` etc. outside the repo for ad-hoc snapshots |
| **Git tracking** | Untracked by default (not in `.gitignore`). Users may selectively `git add` a specific backup as a preserved rollback point |
| **Retention** | `KEEP_BACKUPS` policy (default 5). Auto-pruned via `auto_prune_backups` on every successful `upgrade.py` run |
| **Override** | Tune per-run via env: `KEEP_BACKUPS=1 ./upgrade.py` |
| **Bulk ops** | `scripts/upgrade-sync/manage-backups.py` — `--list` / `--cleanup` / `--total-size` / `--purge` |
| **Sync exclusion** | `sync.py`, `check-versions.py`, `manage-backups.py`, and external publishing tools all skip `backup/` — backups never sync to other repos |

<br/>

### Backup retention policy

- **Default**: keep the latest 5 per chart (`KEEP_BACKUPS=5`)
- **Auto-cleanup**: after a successful `upgrade.py` run, `auto_prune_backups` silently trims anything beyond the retention limit
- **Override**: set via env on invocation — `KEEP_BACKUPS=1 ./upgrade.py` keeps only the newest one

<br/>

### `--list` — summary of all backups

```bash
./scripts/upgrade-sync/manage-backups.py --list
```

```
  CHART                                  COUNT  SIZE   OLDEST          NEWEST
  cicd/argo-cd                           2      380K   20260325_161008 20260416_113552
  observability/logging/elasticsearch    2      16K    20260416_115115 20260416_140134
  observability/logging/kibana           2      16K    20260416_115117 20260416_140521
  ...

  Total: 23 backup(s) across all charts, 1.7M
```

Shows the backup count, total size, and oldest/newest timestamp per chart.

<br/>

### `--cleanup [--keep N]` — bulk prune across all charts

```bash
# Default: keep the latest 5 per chart
./scripts/upgrade-sync/manage-backups.py --cleanup

# Everything stable: keep just the latest one
./scripts/upgrade-sync/manage-backups.py --cleanup --keep 1

# Keep 3
./scripts/upgrade-sync/manage-backups.py --cleanup --keep 3
```

Example output:
```
Pruning backups across all charts (keep last 1 per chart)...

  cicd/argo-cd                         removed=1, freed=184K
  observability/logging/elasticsearch  removed=1, freed=8K
  ...

Removed 9 backup(s) total, freed 712K.
```

<br/>

### `--total-size` — disk usage

```bash
./scripts/upgrade-sync/manage-backups.py --total-size
# Total: 23 backup(s) in 14 chart(s), 1.7M
```

Suitable for CI / cron monitoring.

<br/>

### `--purge` — delete everything (destructive)

```bash
./scripts/upgrade-sync/manage-backups.py --purge
# WARNING: This will REMOVE ALL backups under every managed chart's backup/ directory.
#          Existing rollback snapshots will be lost.
#
# Type 'PURGE' to confirm: _
```

Requires typing `PURGE` verbatim — `y` is not accepted. All rollback snapshots vanish, so use with care.

<br/>

### Recommended workflow

```bash
# Day-to-day
./scripts/upgrade-sync/manage-backups.py --list        # see current state
./upgrade.py                                            # upgrade (auto-prunes at end)

# Periodic housekeeping (e.g. weekly)
./scripts/upgrade-sync/manage-backups.py --cleanup     # keep=5 bulk prune

# Stable state — aggressive cleanup
./scripts/upgrade-sync/manage-backups.py --cleanup --keep 1
```

<br/>

## How it works (internals)

### Package fan-out — `scripts/python/upgrade_sync/`

`sync.py` / `check-versions.py` / `manage-backups.py` are thin orchestrators. The actual logic lives in the package below.

| Module | Role | Key symbols |
|---|---|---|
| `cli.py` | sync entry point — hand-written parser + dispatch (deliberately not argparse, to keep byte parity with the bash usage text; the usage banner is the `_USAGE` literal) | `main()` |
| `commands.py` | `--check` / `--apply` / `--status` / `--print-expected` implementations | `cmd_check()`, `cmd_apply()`, `cmd_status()`, `cmd_print_expected()` |
| `discovery.py` | repo walker — managed + unmanaged chart discovery | `find_managed_files()`, `find_unmanaged_charts()`, `parse_template_header()` |
| `detect.py` | auto-detect the canonical type for headerless files | `detect_template()` |
| `extract.py` | split CONFIG/body blocks + synthesize expected result | `extract_config_block()`, `extract_body()`, `build_expected()` |
| `config_parse.py` | CONFIG block parser (KEY=VAL → `ConfigVars` dataclass) | `parse_config_block()`, `ConfigVars` |
| `fetchers.py` | upstream version lookup (helm repo / GitHub API / OCI registry) | `fetch_latest_helm_repo()`, `fetch_latest_git_tags()`, `fetch_latest_chart_version_gh()`, `verify_image_exists()` |
| `table.py` | check-versions result table rendering | `Row`, `ChartRow`, `resolve_row()`, `print_main_table()`, `print_chart_table()` |
| `yaml_helpers.py` | values.yaml / helmfile.yaml value extraction (stdlib-only mini parser) | `read_yaml_value()`, `read_helmfile_chart_pin()` |
| `manage_backups.py` | `backup/` directory list/cleanup/purge implementation | `cmd_list()`, `cmd_cleanup()`, `cmd_purge()` |
| `paths.py` | target repo-root resolution — precedence chain over the embedded layout / `$UPGRADE_SYNC_REPO_ROOT` / git root. Owns the `--repo-root` contract all three entry points expose | `resolve_repo_root()`, `extract_repo_root_flag()`, `is_embedded()` |

`scripts/upgrade-sync/{sync.py, check-versions.py, manage-backups.py}` are launchers that import the modules above and dispatch.

<br/>

### Three core functions — `upgrade_sync.extract`

#### `extract_config_block(path: Path) -> str`

```python
# scripts/python/upgrade_sync/extract.py
# Returns marker 1 through marker 3 (inclusive) of the three `# ===` markers — the user-owned region.
```

#### `extract_body(path: Path) -> str`

Everything after the third marker — the canonical-owned region.

#### `build_expected(target, template, templates_dir) -> str`

Combines the target's CONFIG with the canonical's body to synthesize the expected result. `--check` byte-diffs this against the target; `--apply` writes it back to the target.

### `upgrade_sync.detect.detect_template(upgrade_script: Path) -> str`

For legacy files without the `# upgrade-template: <name>` header, classifies the canonical type using deterministic patterns in the CONFIG block variables (`GITHUB_REPO=`, `VERSION_SOURCE=`, `CUSTOM_TEMPLATES=`, etc.). Add a branch here when introducing a new canonical.

### `upgrade_sync.discovery` — managed + unmanaged chart discovery

- `find_managed_files(repo_root)` — walks `upgrade.py` files and excludes `backup/`, `_deprecated/`, `_optional/`, `scripts/upgrade-sync/`.
- `find_unmanaged_charts(repo_root)` — directories that have `Chart.yaml` but no `upgrade.py`. Surfaced in `--status` output so onboarding gaps stay visible.

<br/>

## Adding a new chart

### Case 1: external helm repo chart (most common)

Candidates: `storage/nfs-subdir-external-provisioner`, `storage/static-file-server`

```bash
# 1. Copy the canonical to the new chart directory
cp scripts/upgrade-sync/templates/external-standard.py storage/new-chart/upgrade.py
chmod +x storage/new-chart/upgrade.py

# 2. Fill in the CONFIG block placeholders with real values
vim storage/new-chart/upgrade.py
```

What to edit (the `CONFIG` dict):
```python
CONFIG = {
    "SCRIPT_NAME":    "New Chart Helm Upgrade Script",
    "HELM_REPO_NAME": "vendor",
    "HELM_REPO_URL":  "https://charts.vendor.example/stable",
    "HELM_CHART":     "vendor/new-chart",
    "CHANGELOG_URL":  "https://github.com/vendor/new-chart/releases",
    "CHART_TYPE":     "external",
}
```

```bash
# 3. Verify drift (the header is already in place from the canonical copy)
./scripts/upgrade-sync/sync.py --check

# 4. Verify dry-run behavior
cd storage/new-chart && ./upgrade.py --dry-run
```

<br/>

### Case 2: local chart + custom templates (e.g., fluent-bit)

```bash
cp scripts/upgrade-sync/templates/local-with-templates.py \
   observability/logging/new-chart/upgrade.py
chmod +x observability/logging/new-chart/upgrade.py
vim observability/logging/new-chart/upgrade.py
```

What to edit (the `CONFIG` dict — see `observability/logging/fluent-bit/upgrade.py` for a real one):
```python
CONFIG = {
    "SCRIPT_NAME":      "New Chart Helm Upgrade Script (Local Chart)",
    "HELM_REPO_NAME":   "vendor",
    "HELM_REPO_URL":    "https://charts.vendor.example/stable",
    "HELM_CHART":       "vendor/new-chart",
    "CHANGELOG_URL":    "https://github.com/vendor/new-chart/releases",
    # helm repo mode — leave the git source empty
    "CHART_GIT_REPO":   "",
    "CHART_GIT_PATH":   "",
    # Custom templates to preserve (not in upstream)
    "CUSTOM_TEMPLATES": ["pv.yaml", "pvc.yaml"],
    # _pod.tpl patch (PVC volume injection) — define it as a module constant above CONFIG, inside the marker region, as fluent-bit does
    "CUSTOM_POD_PATCH": CUSTOM_POD_PATCH,
}
```

```bash
./scripts/upgrade-sync/sync.py --check
cd observability/logging/new-chart && ./upgrade.py --dry-run
```

<br/>

### Case 3: external chart + image tag auto-update

```bash
cp scripts/upgrade-sync/templates/external-with-image-tag.py new-chart/upgrade.py
# Assumes values/*.yaml uses `tag: vX.Y.Z` pattern
./scripts/upgrade-sync/sync.py --check
```

Precondition: `values/*.yaml` image tags must follow the `tag: v2.14.3` form. Other formats (SHA, quoted, etc.) won't match.

<br/>

### Case 4: local chart with no helm repo (git source mode)

For charts that are not published to any helm repo and only available in a git repository. Use the `local-with-templates` canonical's git source mode.

```bash
cp scripts/upgrade-sync/templates/local-with-templates.py new-chart/upgrade.py
chmod +x new-chart/upgrade.py
vim new-chart/upgrade.py
```

What to edit (the `CONFIG` dict):
```python
CONFIG = {
    "SCRIPT_NAME":      "My Chart Upgrade Script (git source)",
    "HELM_REPO_NAME":   "",  # ★ leave empty
    "HELM_REPO_URL":    "",  # ★ leave empty
    "HELM_CHART":       "",  # ★ leave empty
    "CHANGELOG_URL":    "https://github.com/owner/repo/releases",
    # git source mode (this triggers git clone instead of helm pull)
    "CHART_GIT_REPO":   "https://github.com/owner/repo.git",
    "CHART_GIT_PATH":   "path/to/chart",  # e.g., "deploy/chart/my-chart"
    "CUSTOM_TEMPLATES": ["custom1.yaml", "custom2.yaml"],
    "CUSTOM_POD_PATCH": "",  # empty if not used
}
```

```bash
./scripts/upgrade-sync/sync.py --check
cd new-chart && ./upgrade.py --dry-run
```

Behavior:
- Step 2: latest semver tag is auto-detected via `git ls-remote --tags`
- Step 3: `git clone --depth 1 --branch v<VERSION>` (`v` prefix tried first, then plain version)
- Step 5+: same templates/values diff + breaking-change check + custom preservation as helm repo mode

<br/>

### Case 5: external OCI chart (`oci://...`)

Candidates: `network/nginx-gateway-fabric`, `storage/local-path-provisioner` (already adopted). Used to consume charts published to an OCI registry where `helm search repo` is unavailable; the GitHub Releases API supplies the latest tag instead.

```bash
cp scripts/upgrade-sync/templates/external-oci.py new-chart/upgrade.py
chmod +x new-chart/upgrade.py
vim new-chart/upgrade.py
```

What to edit (the `CONFIG` dict):
```python
CONFIG = {
    "SCRIPT_NAME":            "My OCI Chart Upgrade Script",
    "HELM_REPO_NAME":         "vendor",                                 # informational only for OCI
    "HELM_REPO_URL":          "oci://ghcr.io/vendor/charts",            # informational only for OCI
    "HELM_CHART":             "oci://ghcr.io/vendor/charts/my-chart",
    "GITHUB_REPO":            "vendor/my-chart",                        # for Releases API (latest tag)
    "GITHUB_TAG_PREFIX":      "v",                                      # tags: vX.Y.Z -> X.Y.Z
    "CHANGELOG_URL":          "https://github.com/vendor/my-chart/releases",
    "CHART_TYPE":             "external",                               # set "local" to compare against local Chart.yaml + values.yaml as source of truth
    "WRAPPER_CHART_YAML":     False,                                    # the default is fine
    "HELMFILE_TRACKED_CHART": "",                                       # the default is fine
}
```

```bash
./scripts/upgrade-sync/sync.py --check
cd new-chart && ./upgrade.py --dry-run
```

Behavior:
- Step 2: latest tag is read from `api.github.com/repos/$GITHUB_REPO/releases/latest` and `GITHUB_TAG_PREFIX` is stripped
- Step 3: chart metadata is fetched via `helm show chart/values` + `helm pull --untar`
- Apply: refreshes `Chart.yaml` + `values.yaml` (+ `values.schema.json` if present) from upstream and bumps `helmfile.yaml.version`

<br/>

## Adding a new canonical variant

When the existing canonicals don't cover a new pattern.

### Example scenarios

- **multi-release**: helmfile deploys multiple releases of the same chart in different namespaces and each needs separate version tracking → `external-multi-release.py`
- **CRD compatibility check**: charts that need CRD compatibility checks before upgrade → `external-with-crd-check.py`
- **bare local chart**: `local-with-templates` minus the custom template management → `local-bare.py`

### Procedure

```bash
# 1. Copy the closest existing canonical
cp scripts/upgrade-sync/templates/external-standard.py \
   scripts/upgrade-sync/templates/external-multi-release.py

# 2. Modify the new canonical's body (keep CONFIG block placeholders)
vim scripts/upgrade-sync/templates/external-multi-release.py

# 3. Update the chart's upgrade.py header to the new variant
#    sync.py resolves templates/<name>.py from this header, so there is no separate registration step
#    (detect_template() in detect.py is a diagnostic helper for headerless files and plays no part in sync)
vim path/to/chart/upgrade.py
# line 2: # upgrade-template: external-multi-release

# 4. Verify
./scripts/upgrade-sync/sync.py --check
./scripts/upgrade-sync/sync.py --status

# 5. Update the "Canonical templates" table in this README
vim scripts/upgrade-sync/README-en.md
```

<br/>

## Worked examples

### Example 1: Update one line in usage() across all charts

**Scenario**: Make the `--exclude` option description clearer.

```bash
# 1. Edit canonicals
vim scripts/upgrade-sync/templates/external-standard.py
# (modify the --exclude description in usage())

vim scripts/upgrade-sync/templates/external-with-image-tag.py
# (modify the same section)

vim scripts/upgrade-sync/templates/local-with-templates.py
# (modify the same section)

# 2. Preview impact
./scripts/upgrade-sync/sync.py --check
# Should show DRIFT for every file following that canonical

# 3. Propagate — --apply refuses a dirty working tree, so commit the edit first
git commit -am "<message>"
./scripts/upgrade-sync/sync.py --apply

# 4. Verify
./scripts/upgrade-sync/sync.py --check
# All managed file(s) are in sync.

# 5. Verify behavior in one chart
cd cicd/argo-cd && ./upgrade.py --help
```

### Example 2: Onboard a new chart (local-with-templates)

```bash
# 0. Precondition: the chart should be unmanaged
./scripts/upgrade-sync/sync.py --status | grep new-chart
#   - observability/logging/new-chart

# 1. Copy the canonical
cp scripts/upgrade-sync/templates/local-with-templates.py \
   observability/logging/new-chart/upgrade.py
chmod +x observability/logging/new-chart/upgrade.py

# 2. Fill the CONFIG block
vim observability/logging/new-chart/upgrade.py
# - SCRIPT_NAME, HELM_REPO_NAME, HELM_REPO_URL, HELM_CHART, CHANGELOG_URL
# - CUSTOM_TEMPLATES, CUSTOM_POD_PATCH (as needed)

# 3. Verify drift
./scripts/upgrade-sync/sync.py --check
# All N managed file(s) are in sync.   ← N goes up by one

# 4. Confirm it disappeared from unmanaged
./scripts/upgrade-sync/sync.py --status | grep new-chart
# (none)

# 5. Dry-run
cd observability/logging/new-chart && ./upgrade.py --dry-run
```

### Example 3: Debug when drift is detected

**Scenario**: Someone manually edited the body of `cicd/argo-cd/upgrade.py`.

```bash
# 1. Drift detected
./scripts/upgrade-sync/sync.py --check
#   DRIFT [external-standard] cicd/argo-cd/upgrade.py

# 2. See exactly what differs
./scripts/upgrade-sync/sync.py --print-expected cicd/argo-cd/upgrade.py \
  | diff - cicd/argo-cd/upgrade.py

# 3a. If the change was intentional → reflect it in the canonical, commit, and propagate
vim scripts/upgrade-sync/templates/external-standard.py
git commit -am "<message>"
./scripts/upgrade-sync/sync.py --apply

# 3b. If the change was a mistake → revert via sync
#     (an uncommitted drift trips the dirty-tree guard → just git checkout -- <file>)
./scripts/upgrade-sync/sync.py --apply
# This rewrites the single drifting file from the canonical
```

### Example 4: Apply harbor's image tag updater logic to valkey

```bash
# 1. Change valkey's header
vim db-redis/valkey/upgrade.py
# line 2:
#   # upgrade-template: external-standard
# →
#   # upgrade-template: external-with-image-tag

# 2. Drift detected
./scripts/upgrade-sync/sync.py --check
#   DRIFT [external-with-image-tag] db-redis/valkey/upgrade.py

# 3. Propagate — --apply refuses a dirty working tree, so commit the edit first
git commit -am "<message>"
./scripts/upgrade-sync/sync.py --apply
# valkey now includes the image tag auto-update block

# 4. Verify behavior
cd db-redis/valkey && ./upgrade.py --dry-run
```

<br/>

## Troubleshooting

### `sync.py: command not found` or `Permission denied`

```bash
chmod +x scripts/upgrade-sync/sync.py
```

### `ERROR: <file> has no '# upgrade-template:' header on line 2`

The file is missing its line-2 `# upgrade-template: <name>` header. Every consumer already carries the header, so this only fires for newly-added files — fill it in by hand:
```bash
# 1: #!/usr/bin/env python3
# 2: # upgrade-template: <correct-template>
```

If you're unsure which template applies, call `detect_template()` from `scripts/python/upgrade_sync/detect.py` to see the content-based guess.

### `ERROR: working tree is dirty. Commit or stash before --apply.`

The `--apply` safety guard. Two options:

```bash
# Safer: commit the current changes first
git -C kuberntes-infra status
git -C kuberntes-infra add ... && git -C kuberntes-infra commit -m "..."
./scripts/upgrade-sync/sync.py --apply

# Or override (force-apply on dirty working tree)
./scripts/upgrade-sync/sync.py --apply --force
```

### `--check` reports drift on every file

Possible causes:
1. You modified a canonical but haven't run `--apply` yet → `./scripts/upgrade-sync/sync.py --apply`
2. The canonical's marker structure is broken (the `# ===` line count is not 3) → inspect the canonical
3. The line-2 header (`# upgrade-template:`) points at the wrong canonical → check the header

### `--check` reports drift on a single file

Manually edited, or a partial apply:
```bash
# See what differs
./scripts/upgrade-sync/sync.py --print-expected <file> | diff - <file>

# If intentional, edit the canonical and --apply
# If a mistake, --apply restores it from the canonical
```

### A file is managed under the wrong canonical

`--check` / `--apply` pick the canonical from the line-2 header name alone (`detect_template` is not used). Fix the header manually:
```bash
# Edit line 2 directly
vim path/to/chart/upgrade.py
# 1: #!/usr/bin/env python3
# 2: # upgrade-template: <correct-template>
```

### Added a new canonical but `--check` fails with exit 2

Probably the header name does not match the `templates/<name>.py` file name (the name without extension must match exactly). See [Adding a new canonical variant](#adding-a-new-canonical-variant).

<br/>

## Compatibility

- **Python 3.10+**: sync.py / check-versions.py / manage-backups.py / `templates/*.py` / consumer `upgrade.py` all run on the helmfile-tools image's Python 3.12, Homebrew Mac (3.13+), and Linux distro Python 3.10+. No 3.11+ features (no `tomllib`-only paths, no `ExceptionGroup`). ✅
- **stdlib only**: no third-party dependency on this layer (see `docs/python-script-conventions.md` for the formal dep-introduction procedure if it ever changes). ✅
- **Wrapper `*.sh` portability** (`scripts/python/run.sh`, `scripts/setup-tools.sh`): ✅
  - `#!/usr/bin/env bash` shebang selects the first bash in `$PATH` — Homebrew bash 5.x on macOS, `/bin/bash` 5.x on most Linux. Works on bare macOS bash 3.2 too (wrappers avoid bash 4+ features).
  - zsh direct invocation (`zsh ./run.sh ...`): re-exec guard `if [ -n "${ZSH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi` redirects to bash before any shell option is set.
- **External tool invocations** (called via `subprocess` from python): cross-platform discipline (BSD vs GNU) preserved by python-side argument shaping — e.g. write-then-rename for `sed`, basic POSIX `awk` constructs, `find -not -path` form. ✅

<br/>

## Safety guards

### `--apply` git guard
- Aborts if working tree is dirty
- Prevents accidentally overwriting manual edits
- Override: `--force` flag

<br/>

### Header-based dispatch
- The canonical mapping is explicitly declared in the header, so sync cannot apply the wrong canonical by accident

<br/>

### Bytewise verification
- `--check` byte-compares the synthesized expected against the actual file
- A 1-byte difference is reported as drift → catches subtle changes

<br/>

### Header integrity
- Every managed `upgrade.py` must declare a `# upgrade-template: <name>` header on line 2
- Files without the header are silently SKIPped by `--check` (`SKIP  [no-header]`, exit code unaffected) and ignored by `--apply` — they fall out of the drift gate quietly. The **only** place a missing header is a hard error (exit 2) is `--print-expected` (`_resolve_template()` in `scripts/python/upgrade_sync/commands.py`).

<br/>

## FAQ

**Q: Code I added directly to `upgrade.py` was wiped out by the next sync.**

A: That's intentional. The body is canonical-owned, so `sync --apply` overwrites it from the canonical. To add a new feature to the body:
1. Edit the canonical itself and sync (applies to all charts)
2. Or, if you need per-chart behavior, branch via a CONFIG block variable (e.g., check whether `CONFIG["EXTRA_FEATURE_ENABLED"]` is `True`)

<br/>

**Q: How do I add a per-chart placeholder variable to a canonical?**

A:
1. Add a placeholder to the canonical's CONFIG block (e.g., `"EXTRA_DIR": "__EXTRA_DIR__"`)
2. Use it in the body's owner, `scripts/python/upgrade_core/<template>.py` (e.g., `config["EXTRA_DIR"]`)
3. Fill in the real value in each chart's CONFIG block (`"EXTRA_DIR": "custom-data"`)
4. Charts that don't use it can leave it empty or rely on a default

Each chart's CONFIG is user-owned and untouched by sync.

<br/>

**Q: What happens if I change the `upgrade-template:` header to a different canonical?**

A: The next `--apply` replaces the body with the new canonical's body.

Examples:
- `external-standard` → `external-with-image-tag`: adds the image tag auto-update block
- `external-standard` → `local-with-templates`: replaces the entire flow (CONFIG block is incompatible — handle with care)

CONFIG block compatibility must be verified manually. If incompatible, edit the CONFIG too.

<br/>

**Q: Are existing `backup/` directories affected?**

A: No. `find_managed_files` excludes `*/backup/*`. Each chart's `backup/` directory (auto-created during chart upgrades) is unrelated to sync.

<br/>

**Q: How are `_deprecated/` and `_optional/` handled?**

A: Both are excluded from sync drift, all Makefile checks (test/lint/shell-lint), and governance.
- `_deprecated/` (`*/_deprecated/*` exclude): retired components, kept as a historical trail.
- `_optional/` (`*/_optional/*` exclude): inactive optional components. **To activate, move the directory out of `_optional/`** — it then auto-rejoins sync and check scopes. On activation, run `./upgrade.py` directly, or `sync.py --apply` once to align with the canonical templates.

<br/>

**Q: What about non-helm directories like kubespray?**

A: `find_managed_files` only matches `upgrade.py` files, so directories without both `Chart.yaml` and `upgrade.py` are never candidates.

<br/>

**Q: How do I integrate this with CI?**

A: Add `--check` to a CI step. Drift returns non-zero, which naturally fails the build.

```yaml
# .github/workflows/upgrade-script-drift.yml (example)
name: upgrade-sync drift check
on: [pull_request, push]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/upgrade-sync/sync.py --check
```

<br/>

**Q: How do I recover if the sync system itself has a bug and breaks every file?**

A: `git checkout HEAD -- .` restores everything in one shot. Always run sync from a clean working tree (or a dedicated branch). The `--apply` git guard enforces this.

<br/>

## See also

- Main README: [../../README-en.md](../../README.md)
- Canonical sources: [templates/](templates/)
- Sync tool: [sync.py](sync.py)
