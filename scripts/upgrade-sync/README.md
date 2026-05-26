# upgrade-sync

Canonical templates and a sync tool for the per-component `upgrade.{sh,py}` scripts.

Each component directory (`cicd/argo-cd/`, `observability/monitoring/kube-prometheus-stack/`, `observability/monitoring/node-exporter/`, etc.) has an upgrade script for version upgrades. **Mixed mode (Phase 4 / MR-K6+)**: `external-standard` + `ansible-github-release` template consumers (14) ship `upgrade.py`; the other 6 templates still ship `upgrade.py`. Most components are Helm charts, but Ansible-deployed components (e.g. node-exporter) use the same sync system. The script bodies are nearly identical, so they are managed in one place (this directory) and propagated to every component via [sync.py](sync.py).

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
7. [How it works (internals)](#how-it-works-internals)
8. [Adding a new chart](#adding-a-new-chart)
9. [Adding a new canonical variant](#adding-a-new-canonical-variant)
10. [Worked examples](#worked-examples)
11. [Troubleshooting](#troubleshooting)
12. [Compatibility](#compatibility)
13. [Safety guards](#safety-guards)
14. [FAQ](#faq)

<br/>

## Directory layout

```
scripts/upgrade-sync/
├── README.md                          # Korean docs
├── README-en.md                       # this file
├── sync.py                            # sync tool (cross-platform)
├── check-versions.py                  # preflight upgrade scan (read-only)
├── manage-backups.py                  # bulk backup management (list/cleanup/purge)
└── templates/
    ├── external-standard.py           # external chart (helm repo) + default flow (Python; the first .py canonical)
    ├── external-with-image-tag.py     # external + values image tag auto-update
    ├── external-oci.py                # external OCI chart + GitHub Releases tracking
    ├── external-oci-cr-version.py     # external OCI chart consumer (CR wrapper) + values.version tracking
    ├── local-with-templates.py        # local chart (Chart.yaml in repo) + custom templates
    ├── local-cr-version.py            # local chart (CR wrapper) + values.version + Chart.yaml.appVersion
    └── ansible-github-release.py     # Ansible-deployed component + GitHub Releases tracking (Python; flipped in K7)
```

> Phase 4 / MR-K6+K7 migrated `external-standard` + `ansible-github-release` to `.py` (canonicals + 14 consumers). The remaining 6 templates will be flipped over the K8~K13 sequence. The body lives in `scripts/python/upgrade_core/<template>.py`; each canonical is a thin wrapper around the placeholder dict + ancestor walk.

<br/>

## Key concepts

### The problem

Previously, 16 chart directories each carried a near-identical copy of `upgrade.py`. Fixing a single line in `usage()` required 16 separate Edits, and drift between charts accumulated over time.

### The solution

Each chart's `upgrade.py` is split into two regions:

```bash
#!/bin/bash
# upgrade-template: external-standard       <-- header: declares which canonical to follow
set -euo pipefail

# ============================================================
# Configuration (per-chart)
# ============================================================
SCRIPT_NAME="ArgoCD Helm Chart Upgrade Script"  # ┐
HELM_REPO_NAME="argo"                            # │
HELM_REPO_URL="..."                              # │ ★ user-owned (CONFIG block)
HELM_CHART="argo/argo-cd"                        # │   preserved by sync
CHANGELOG_URL="..."                              # │
CHART_TYPE="external"                            # ┘
# ============================================================

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"      # ┐
BACKUP_DIR="$CHART_DIR/backup"                   # │
...                                              # │ ★ canonical-owned
[7-step main flow]                               # │   overwritten by sync --apply
...                                              # │
echo " Upgrade complete!"                        # ┘
```

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
| Common logic change (e.g., usage text) | User edits once + sync propagates | `vim canonical → ./scripts/upgrade-sync/sync.py --apply` |
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
              upgrade    upgrade   .sh       upgrade     upgrade
              .sh        .sh                 .sh         .sh
```

### Per-file sync flow

```
   target file: cicd/argo-cd/upgrade.py
   ┌──────────────────────────────────┐
   │ #!/bin/bash                       │     1. read line 2 → "external-standard"
   │ # upgrade-template: external-     │ ──────────────────────┐
   │   standard                        │                       │
   │ set -euo pipefail                 │                       │
   │                                   │                       │
   │ # ============================    │     2. extract CONFIG │
   │ # Configuration                   │ ───┐  (markers 1~3)   │
   │ # ============================    │    │                  │
   │ SCRIPT_NAME="ArgoCD Helm..."      │    │                  │
   │ HELM_REPO_NAME="argo"             │    │                  │
   │ ...                               │    │                  │
   │ # ============================    │ ───┘                  │
   │                                   │                       │
   │ CHART_DIR=...                     │     3. body (replaced)│
   │ ... (440 lines)                   │                       │
   │ echo "complete!"                  │                       │
   └──────────────────────────────────┘                       │
                                                                ↓
                  ┌─────────────────────────────────────────────┘
                  │
                  ↓
   canonical: scripts/upgrade-sync/templates/external-standard.py
   ┌──────────────────────────────────┐
   │ #!/bin/bash                       │
   │ # CANONICAL TEMPLATE — DO NOT...  │
   │ set -euo pipefail                 │
   │                                   │
   │ # ============================    │
   │ # Configuration (placeholders)    │
   │ # ============================    │
   │ SCRIPT_NAME="__SCRIPT_NAME__"     │     ★ placeholders only, not used
   │ ...                               │
   │ # ============================    │
   │                                   │
   │ CHART_DIR=...                     │     ★ this body is copied to target
   │ ... (440 lines)                   │
   │ echo "complete!"                  │
   └──────────────────────────────────┘

   build_expected(target):
     header  := "#!/bin/bash"
              + "# upgrade-template: external-standard"
              + "set -euo pipefail"
              + ""
     CONFIG  := extract_config_block(target)        # from target
     body    := extract_body(canonical)             # from canonical
     return header + CONFIG + body

   --check  : diff(build_expected(target), target)
   --apply  : write build_expected(target) → target
```

### 3-marker layout

Each `upgrade.py` and canonical uses the same 3-marker structure:

```bash
# ============================================================  ← marker 1: doc opens
# Configuration (per-chart, sync-managed body below)
# ============================================================  ← marker 2: doc closes / vars opens
SCRIPT_NAME=...
HELM_REPO_NAME=...
...
# ============================================================  ← marker 3: vars closes / body starts
CHART_DIR="$(cd ...)"
...
```

- **CONFIG block** = marker 1 ~ marker 3 (all inclusive)
- **body** = everything after marker 3

An awk counter tracks markers to find precise boundaries.

<br/>

## Canonical templates

### Naming convention

```
<chart-type>-<feature>.sh
   │              │
   │              └── standard | with-image-tag | with-templates | (future...)
   └── external (helm repo) | local (Chart.yaml in repo)
```

New variants must follow the same convention (e.g., `external-multi-release.sh`, `local-bare.sh`).

### Current canonicals (7)

#### 1. [external-standard.py](templates/external-standard.py) — external helm repo chart (most common, Python)

- **Use**: Receives a chart from an external helm repo and deploys via helmfile
- **Language**: Python (.sh → .py flip in Phase 4 / MR-K6). Body lives in `scripts/python/upgrade_core/external_standard.py`; the canonical is a thin wrapper.
- **Flow**: 7 steps (current → fetch latest → download → diff Chart → diff values → check breaking → apply + backup)
- **13 charts** (at MR-K6, source: `sync.py --status`):
  - cicd: `argo-cd`, `gitlab-runner`
  - db-redis: `valkey`
  - network: `metallb`, `nginx-gateway-fabric/cr-chart`
  - observability/logging: `eck-operator`, `fluentd`
  - observability/monitoring: `kube-prometheus-stack`, `prometheus-elasticsearch-exporter`, `prometheus-mysql-exporter`
  - security: `vaultwarden`
  - storage: `nfs-subdir-external-provisioner`, `static-file-server`

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
- **1 chart**: `harbor-helm`

#### 3. [local-with-templates.py](templates/local-with-templates.py) — local chart + custom templates

- **Use**: Local charts that keep `Chart.yaml` and `templates/` in the repo. Fetches the upstream chart, preserves custom templates (e.g., `pv.yaml`, `pvc.yaml`), and re-applies a `_pod.tpl` PVC patch
- **Flow**: 8 steps (current → fetch → download upstream → diff Chart → diff values + templates → check pod patch → check breaking → apply + backup + preserve customs + patch _pod.tpl)
- **Extra variables**: `CUSTOM_TEMPLATES`, `CUSTOM_POD_PATCH`, `EXTRA_DIRS`
- **Two upstream source modes** (selected via CONFIG block):
  - **helm repo mode** (default): set `HELM_REPO_NAME`/`HELM_REPO_URL`/`HELM_CHART`, leave `CHART_GIT_REPO` empty
  - **git source mode**: set `CHART_GIT_REPO`/`CHART_GIT_PATH` (for charts not published to any helm repo). Latest version is auto-detected from git tags and the chart is fetched via git clone.
- **2 charts**:
  - `fluent-bit`, `fluent-bit-aws` (helm repo mode)

#### 4. [local-cr-version.py](templates/local-cr-version.py) — local chart (CR wrapper) + version field tracking

- **Use**: Local charts whose `templates/` directory contains Custom Resource (CR) YAML, with the component version stored in a `values/*.yaml` field (e.g. `version`). **No upstream Helm chart exists** (we are the sole owner). Only the value field needs bumping — no chart sync.
- **Flow**: 6 steps (read current version from values → fetch latest from source feed → **verify container image exists** → compatibility reminder → backup → update values + Chart.yaml appVersion)
- **Extra variables**:
  - `COMPONENT_LABEL`: label shown in output (e.g., `elasticsearch`, `kibana`)
  - `VERSION_SOURCE`: version feed type (currently supported: `elastic-artifacts`)
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
  - Adding a new source: extend the `case` block inside `fetch_ga_versions()` in the canonical.
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
- **2 charts**: `observability/logging/elasticsearch` (elasticsearch-eck OCI chart consumer), `observability/logging/kibana` (kibana-eck OCI chart consumer)

#### 6. [external-oci.py](templates/external-oci.py) — external OCI chart + GitHub Releases tracking

- **Use**: OCI-registry-distributed charts where the chart version itself needs tracking. Bumps `helmfile.yaml.version` via GitHub Releases API.
- **Differences vs external-standard**: `helm search repo` is unavailable for OCI → use GitHub Releases instead.
- **Extra variables**: `HELM_CHART` (oci://... URL), `GITHUB_REPO` (owner/repo), `GITHUB_TAG_PREFIX`
- **2 charts**: `network/nginx-gateway-fabric` (NGF OCI chart), `storage/local-path-provisioner` (Rancher upstream OCI chart)

#### 7. [ansible-github-release.py](templates/ansible-github-release.py) — Ansible-deployed (non-Helm) component + GitHub Releases tracking (Python)

- **Language**: Python (Phase 4

- **Use**: Components **deployed via Ansible**, not Helm, where the version lives in a single YAML file (e.g. `group_vars/all.yml`) and the upstream source is a GitHub Releases feed. No `Chart.yaml` / `helmfile.yaml`.
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
- **1 chart**: `observability/monitoring/node-exporter`

<br/>

## sync.py usage

Run `./scripts/upgrade-sync/sync.py --help` for the full inline help.

### `--status` — show current state

```bash
./scripts/upgrade-sync/sync.py --status
```

```
Managed upgrade.{sh,py} files: 25
  ansible-github-release:  1
  external-oci:            4
  external-oci-cr-version: 2
  external-oci-with-mirror: 3
  external-standard:       13
  external-with-image-tag: 1
  local-with-templates:    1

Available canonicals:
  ansible-github-release
  external-oci
  external-oci-cr-version
  external-oci-with-mirror
  external-standard
  external-with-image-tag
  local-cr-version
  local-with-templates

Unmanaged chart directories (have Chart.yaml but no upgrade.{sh,py}):
  - observability/logging/_deprecated/elasticsearch-helm-8.5.1
  - observability/logging/_deprecated/kibana-helm-8.5.1
```

**Unmanaged charts** are directories that have `Chart.yaml` but no `upgrade.{sh,py}`. They can be onboarded with the [Adding a new chart](#adding-a-new-chart) procedure.

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
All 23 managed file(s) are in sync.
```

<br/>

### `--apply` — propagate canonical → 16 files

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

> **Note**: The bash `sync.sh` once shipped a one-shot migration command `--insert-headers` and a verification mode `--check --no-header`. Both were retired in Phase 5 P5-A (resolute-bison) — every one of the 25 consumers now carries the `# upgrade-template:` header, so the commands were dead code. If you need content-based template auto-detection, call `detect_template()` from `scripts/python/upgrade_sync/detect.py` directly.

<br/>

## check-versions.py usage

A read-only preflight tool. Before running the per-chart `upgrade.py` one by one, use this to scan every managed chart and see which ones have an upstream upgrade available. It does not modify any files — it only prints a summary table.

Each template uses the same upstream lookup logic its `upgrade.py` already relies on:

| Template | Current version | Latest version |
|---|---|---|
| `external-standard`
| `local-with-templates` (helm mode) | `Chart.yaml` → `version` | `helm search repo <HELM_CHART>` (top entry) |
| `local-with-templates` (git mode, `CHART_GIT_REPO` set) | `Chart.yaml` → `version` | Highest semver tag from `git ls-remote --tags` |
| `local-cr-version` | `<VALUES_FILE>` → `<VERSION_KEY>` | `VERSION_SOURCE` feed (e.g. elastic-artifacts), respecting `MAJOR_PIN` |
| `external-oci-cr-version` | `<VALUES_FILE>` → `<VERSION_KEY>` (plus `helmfile.yaml.version` chart pin, shown in a separate table) | `VERSION_SOURCE` feed, respecting `MAJOR_PIN` (no Chart.yaml). Chart pin looked up against `CHART_SOURCE_REPO`'s GitHub Releases filtered by `<CHART_NAME>-X.Y.Z` prefix |
| `ansible-github-release` | `<VERSION_FILE>` → `<VERSION_KEY>` | GitHub Releases API (`<GITHUB_REPO>`), respecting `MAJOR_PIN` |

<br/>

### Default run

```bash
./scripts/upgrade-sync/check-versions.py
```

```
Collecting managed upgrade.py configs...
  Managed: 22  Skipped (no header): 0
Registering 13 helm repo(s)...
Running 'helm repo update'...

  STATUS   TEMPLATE                  CURRENT          LATEST           PATH
  -------  ------------------------  ---------------  ---------------  ----
  UPDATE   external-standard         9.4.15           9.5.0            cicd/argo-cd/upgrade.py
  OK       external-standard         0.87.1           0.87.1           cicd/gitlab-runner/upgrade.py
  ...
  UPDATE   external-oci-cr-version   9.0.0            9.4.0            observability/logging/elasticsearch/upgrade.py
  ...

Summary: OK=15  UPDATE=7  ERROR=0  (total=22)
Upgrades are available. Run 'cd <path> && ./upgrade.py --dry-run' in each directory above.

OCI chart pin status (external-oci-cr-version consumers):

  STATUS   CHART                 CURRENT     LATEST      PATH
  -------  --------------------  ----------  ----------  ----
  OK       elasticsearch-eck     0.1.2       0.1.2       observability/logging/elasticsearch/upgrade.py
  OK       kibana-eck            0.1.1       0.1.1       observability/logging/kibana/upgrade.py

Chart summary: OK=2  UPDATE=0  ERROR=0  (total=2)
```

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
| `bash` (>= 3.2 / 4+) **or** `zsh` | every sync/upgrade script (interactive shell either way) | always |
| `helm` | helm-repo lookups, OCI chart pull | `check-versions.py` + every helm-based `upgrade.py` |
| `helmfile` | helmfile sync/diff/apply | component deploys (CI `apply-components.py`, local `helmfile apply`) |
| `kubectl` | cluster apply / context management | invoked by helmfile, CI `helmfile-apply-component.py` |
| `git` | git-tags lookups, automated commit/push | `local-with-templates` (git mode), CI `auto-upgrade.py` |
| `curl` | upstream metadata fetch | `check-versions.py`, every version-source template |
| `python3` | JSON parsing (helm search / GitHub releases / Docker Hub tags responses) | `check-versions.py`, `local-cr-version`, `external-oci-cr-version`, `ansible-github-release`, `external-oci-with-mirror`, ... |
| `jq` | JSON processing | some helm plugins (auto-upgrade's `jq` usage was replaced with python stdlib `json` in MR-K4) |
| `yq` | YAML processing | CI `helmfile-apply-component.py`, `apply-components.py` |
| `crane` | OCI image mirror (upstream → private registry) | `external-oci-with-mirror` template Step 7 mirror stage |
| `tar`, `gzip` | archive handling | `helm pull --untar`, OCI chart downloads |

Same portability as sync.py: works on macOS bash 3.2, Linux bash 4+, and zsh (active `*.sh` files carry the `#!/usr/bin/env bash` shebang plus a zsh re-exec guard).

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

### sync.py's three core functions

#### `extract_config_block(file)` — extract the CONFIG block

```awk
/^# ={10,}$/ {
  c++
  print
  if (c == 3) exit
  next
}
c >= 1 { print }
```

Counts `# ===` markers and prints from marker 1 through marker 3 (inclusive). This is the user-owned region.

#### `extract_body(file)` — extract the body

```awk
/^# ={10,}$/ { c++; next }
c >= 3 { print }
```

Prints everything after the third marker. This is the canonical-owned region.

#### `build_expected(target, template)` — synthesize the expected result

```bash
printf '#!/bin/bash\n'
printf '# upgrade-template: %s\n' "$template"
printf 'set -euo pipefail\n'
printf '\n'
extract_config_block "$target"     # CONFIG from target (user-owned)
extract_body "$canonical"          # body from canonical (canonical-owned)
```

`--check` diffs this output against the target; `--apply` writes it to the target.

### detect_template — auto-detect for headerless files

```bash
detect_template() {
  local f="$1"
  if grep -q '^GITHUB_REPO=' "$f"; then
    echo "ansible-github-release"
  elif grep -q '^VERSION_SOURCE=' "$f"; then
    echo "local-cr-version"
  elif grep -q '^CUSTOM_TEMPLATES=' "$f"; then
    echo "local-with-templates"
  elif grep -q 'Update image tags in values files' "$f"; then
    echo "external-with-image-tag"
  else
    echo "external-standard"
  fi
}
```

Finds deterministic patterns that distinguish the five canonicals. Update this function when adding a new canonical variant.

### Discovering managed files

```bash
find_managed_files() {
  find "$REPO_ROOT" \
    -type f \
    -name 'upgrade.py' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/_optional/*' \
    -not -path '*/scripts/upgrade-sync/*' \
    | sort
}
```

- Excludes `*/backup/*`: per-chart backups are not sync targets
- Excludes `*/_deprecated/*`: deprecated charts are permanently excluded
- Excludes `*/scripts/upgrade-sync/*`: the canonicals themselves are not targets

### Auto-detecting unmanaged charts

```bash
find_unmanaged_charts() {
  find "$REPO_ROOT" -type f -name 'Chart.yaml' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/templates/*' \
    | while read -r chart; do
        local dir; dir=$(dirname "$chart")
        if [ ! -f "$dir/upgrade.py" ]; then
          echo "${dir#$REPO_ROOT/}"
        fi
      done | sort -u
}
```

Finds directories that have `Chart.yaml` but no `upgrade.py`. Shown in `--status` output so it's hard to forget about new charts that need onboarding.

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

What to edit:
```bash
SCRIPT_NAME="New Chart Helm Upgrade Script"
HELM_REPO_NAME="vendor"
HELM_REPO_URL="https://charts.vendor.example/stable"
HELM_CHART="vendor/new-chart"
CHANGELOG_URL="https://github.com/vendor/new-chart/releases"
CHART_TYPE="external"
```

```bash
# 3. Verify drift (the header is already in place from the canonical copy)
./scripts/upgrade-sync/sync.py --check

# 4. Verify dry-run behavior
cd storage/new-chart && ./upgrade.py --dry-run
```

<br/>

### Case 2: local chart + custom templates (e.g., elasticsearch, kibana)

```bash
cp scripts/upgrade-sync/templates/local-with-templates.py \
   observability/logging/elasticsearch/upgrade.py
chmod +x observability/logging/elasticsearch/upgrade.py
vim observability/logging/elasticsearch/upgrade.py
```

What to edit:
```bash
SCRIPT_NAME="Elasticsearch Helm Chart Upgrade Script (Local Chart)"
HELM_REPO_NAME="elastic"
HELM_REPO_URL="https://helm.elastic.co"
HELM_CHART="elastic/elasticsearch"
CHANGELOG_URL="https://github.com/elastic/helm-charts/releases"

# Custom templates to preserve (not in upstream)
CUSTOM_TEMPLATES=("pv.yaml" "pvc.yaml")

# _pod.tpl patch (PVC volume injection — same as fluent-bit, or modify as needed)
CUSTOM_POD_PATCH='...'
```

```bash
./scripts/upgrade-sync/sync.py --check
cd observability/logging/elasticsearch && ./upgrade.py --dry-run
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

What to edit:
```bash
SCRIPT_NAME="My Chart Upgrade Script (git source)"
HELM_REPO_NAME=""              # ★ leave empty
HELM_REPO_URL=""               # ★ leave empty
HELM_CHART=""                  # ★ leave empty
CHANGELOG_URL="https://github.com/owner/repo/releases"

# git source mode (this triggers git clone instead of helm pull)
CHART_GIT_REPO="https://github.com/owner/repo.git"
CHART_GIT_PATH="path/to/chart"  # e.g., "deploy/chart/my-chart"

CUSTOM_TEMPLATES=("custom1.yaml" "custom2.yaml")
CUSTOM_POD_PATCH=''  # empty if not used
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

What to edit:
```bash
SCRIPT_NAME="My OCI Chart Upgrade Script"
HELM_REPO_NAME="vendor"                          # informational only for OCI
HELM_REPO_URL="oci://ghcr.io/vendor/charts"      # informational only for OCI
HELM_CHART="oci://ghcr.io/vendor/charts/my-chart"
GITHUB_REPO="vendor/my-chart"                    # for Releases API (latest tag)
GITHUB_TAG_PREFIX="${GITHUB_TAG_PREFIX:-v}"      # tags: vX.Y.Z -> X.Y.Z
CHANGELOG_URL="https://github.com/vendor/my-chart/releases"
CHART_TYPE="external"                            # set "local" to compare against local Chart.yaml + values.yaml as source of truth
```

```bash
./scripts/upgrade-sync/sync.py --check
cd new-chart && ./upgrade.py --dry-run
```

Behavior:
- Step 2: latest tag is read from `api.github.com/repos/$GITHUB_REPO/releases/latest` and `GITHUB_TAG_PREFIX` is stripped
- Step 3: chart metadata is fetched via `helm show chart/values` + `helm pull --untar`
- Apply: refreshes `Chart.yaml` + `values.yaml` (+ `values.schema.json` if present) from upstream and bumps `helmfile.yaml.version` via sed

<br/>

## Adding a new canonical variant

When the existing 3 canonicals don't cover a new pattern.

### Example scenarios

- **multi-release**: helmfile deploys multiple releases of the same chart in different namespaces and each needs separate version tracking → `external-multi-release.sh`
- **CRD compatibility check**: charts that need CRD compatibility checks before upgrade → `external-with-crd-check.sh`
- **bare local chart**: `local-with-templates` minus the custom template management → `local-bare.sh`

### Procedure

```bash
# 1. Copy the closest existing canonical
cp scripts/upgrade-sync/templates/external-standard.py \
   scripts/upgrade-sync/templates/external-multi-release.sh

# 2. Modify the new canonical's body (keep CONFIG block placeholders)
vim scripts/upgrade-sync/templates/external-multi-release.sh

# 3. Add a detection branch to sync.py's detect_template()
vim scripts/upgrade-sync/sync.py
```

```bash
detect_template() {
  local f="$1"
  if grep -q '^MULTI_RELEASE=' "$f"; then          # ← new variant
    echo "external-multi-release"
  elif grep -q '^VERSION_SOURCE=' "$f"; then
    echo "local-cr-version"
  elif grep -q '^CUSTOM_TEMPLATES=' "$f"; then
    echo "local-with-templates"
  elif grep -q 'Update image tags in values files' "$f"; then
    echo "external-with-image-tag"
  else
    echo "external-standard"
  fi
}
```

```bash
# 4. Update the chart's upgrade.py header to the new variant
vim path/to/chart/upgrade.py
# line 2: # upgrade-template: external-multi-release

# 5. Verify
./scripts/upgrade-sync/sync.py --check
./scripts/upgrade-sync/sync.py --status

# 6. Update the "Canonical templates" table in this README
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
# Should show DRIFT for all 16 files

# 3. Propagate
./scripts/upgrade-sync/sync.py --apply

# 4. Verify
./scripts/upgrade-sync/sync.py --check
# All 23 managed file(s) are in sync.

# 5. Verify behavior in one chart
cd cicd/argo-cd && ./upgrade.py --help
```

### Example 2: Onboard a new chart (elasticsearch)

```bash
# 0. Precondition: elasticsearch should be unmanaged
./scripts/upgrade-sync/sync.py --status | grep elasticsearch
#   - observability/logging/elasticsearch

# 1. Copy the canonical
cp scripts/upgrade-sync/templates/local-with-templates.py \
   observability/logging/elasticsearch/upgrade.py
chmod +x observability/logging/elasticsearch/upgrade.py

# 2. Fill the CONFIG block
vim observability/logging/elasticsearch/upgrade.py
# - SCRIPT_NAME, HELM_REPO_NAME, HELM_REPO_URL, HELM_CHART, CHANGELOG_URL
# - CUSTOM_TEMPLATES, CUSTOM_POD_PATCH (as needed)

# 3. Verify drift
./scripts/upgrade-sync/sync.py --check
# All 17 managed file(s) are in sync.   ← 16 → 17

# 4. Confirm it disappeared from unmanaged
./scripts/upgrade-sync/sync.py --status | grep elasticsearch
# (none)

# 5. Dry-run
cd observability/logging/elasticsearch && ./upgrade.py --dry-run
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

# 3a. If the change was intentional → reflect it in the canonical and propagate
vim scripts/upgrade-sync/templates/external-standard.py
./scripts/upgrade-sync/sync.py --apply

# 3b. If the change was a mistake → revert via sync
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

# 3. Propagate
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

The file is missing its line-2 `# upgrade-template: <name>` header. Every one of the 25 consumers already carries the header, so this only fires for newly-added files — fill it in by hand:
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
3. `detect_template` mis-classified a file → check the explicit header

### `--check` reports drift on a single file

Manually edited, or a partial apply:
```bash
# See what differs
./scripts/upgrade-sync/sync.py --print-expected <file> | diff - <file>

# If intentional, edit the canonical and --apply
# If a mistake, --apply restores it from the canonical
```

### `detect_template` mis-classifies a file

`detect_template`'s content-based heuristic is imprecise for the file. Fix the header manually:
```bash
# Edit line 2 directly
vim path/to/chart/upgrade.py
# 1: #!/usr/bin/env python3
# 2: # upgrade-template: <correct-template>
```

### Added a new canonical but `--check` doesn't recognize it

Probably forgot to add a branch to `detect_template()`. See [Adding a new canonical variant](#adding-a-new-canonical-variant).

<br/>

## Compatibility

- **macOS bash 3.2** (default): no `declare -A` or other bash 4+ features ✅
- **Linux bash 4+**: works ✅
- **zsh** (direct invocation `zsh ./upgrade.py ...`): works ✅. Canonical bodies start with `[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch` to prevent zsh's `no matches found` fatal when the backup glob (`"$BACKUP_DIR"/2*/`) has zero matches.
- **sed**: works on both BSD sed (macOS) and GNU sed (Linux)
  - Canonical bodies use `sed ... > tmp && mv tmp file` instead of `sed -i ''`
- **awk**: uses only basic constructs compatible with both BSD awk (macOS) and gawk (Linux)
  - Counters, pattern matching, `print` — standard POSIX awk
- **find**: `-not -path '...'` works on both BSD and GNU find

<br/>

## Safety guards

### `--apply` git guard
- Aborts if working tree is dirty
- Prevents accidentally overwriting manual edits
- Override: `--force` flag

### Header-based dispatch
- The canonical mapping is explicitly declared in the header, so sync cannot apply the wrong canonical by accident
- Missing header → `--check` errors out explicitly (no silent fallback)

### Bytewise verification
- `--check` byte-compares the synthesized expected against the actual file
- A 1-byte difference is reported as drift → catches subtle changes

### Header integrity
- Every managed `upgrade.py` must declare a `# upgrade-template: <name>` header on line 2
- Files without the header are silently SKIPped by `--check` and ignored by `--apply` (no drift gate)

<br/>

## FAQ

**Q: Code I added directly to `upgrade.py` was wiped out by the next sync.**

A: That's intentional. The body is canonical-owned, so `sync --apply` overwrites it from the canonical. To add a new feature to the body:
1. Edit the canonical itself and sync (applies to all charts)
2. Or, if you need per-chart behavior, branch via a CONFIG block variable (e.g., check `EXTRA_FEATURE_ENABLED=true`)

<br/>

**Q: How do I add a per-chart placeholder variable to a canonical?**

A:
1. Add a placeholder to the canonical's CONFIG block (e.g., `EXTRA_DIR="__EXTRA_DIR__"`)
2. Use it in the canonical's body (e.g., `cp -r "$EXTRA_DIR" ...`)
3. Fill in the real value in each chart's CONFIG block (`EXTRA_DIR="custom-data"`)
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

A: Both are permanently excluded from sync drift, all Makefile checks (test/lint/shell-lint), and governance.
- `_deprecated/` (`*/_deprecated/*` exclude): retired components, kept as a historical trail.
- `_optional/` (`*/_optional/*` exclude): inactive optional components. **To activate, move the directory out of `_optional/`** — it then auto-rejoins sync and check scopes. On activation, run `./upgrade.py` directly, or `sync.py --apply` once to align with the canonical templates.

<br/>

**Q: What about non-helm directories like kubespray?**

A: `find_managed_files` only matches `upgrade.py` files, so directories without both `Chart.yaml` and `upgrade.py` are never candidates. kubespray is Ansible-based and unrelated.

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

- Main README: [../../README.md](../../README.md)
- Canonical sources: [templates/](templates/)
- Sync tool: [sync.py](sync.py)
