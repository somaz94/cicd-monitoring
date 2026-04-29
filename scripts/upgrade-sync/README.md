# upgrade-sync

Canonical templates and a sync tool for the per-component `upgrade.sh` scripts.

Each component directory (`cicd/argo-cd/`, `observability/monitoring/kube-prometheus-stack/`, `observability/monitoring/node-exporter/`, etc.) has an `upgrade.sh` for version upgrades. Most components are Helm charts, but Ansible-deployed components (e.g. node-exporter) use the same sync system. The script bodies are nearly identical, so they are managed in one place (this directory) and propagated to every component via [sync.sh](sync.sh).

To survey which charts have an upstream upgrade available before touching any `upgrade.sh`, use [check-versions.sh](check-versions.sh) (read-only).

To inspect or bulk-clean the `backup/` directories across every chart at once, use [manage-backups.sh](manage-backups.sh).

<br/>

## Table of contents

1. [Directory layout](#directory-layout)
2. [Key concepts](#key-concepts)
3. [Architecture](#architecture)
4. [Canonical templates](#canonical-templates)
5. [sync.sh usage](#syncsh-usage)
6. [check-versions.sh usage](#check-versionssh-usage)
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
├── sync.sh                            # sync tool (cross-platform)
├── check-versions.sh                  # preflight upgrade scan (read-only)
├── manage-backups.sh                  # bulk backup management (list/cleanup/purge)
└── templates/
    ├── external-standard.sh           # external chart (helm repo) + default flow
    ├── external-with-image-tag.sh     # external + values image tag auto-update
    ├── external-oci.sh                # external OCI chart + GitHub Releases tracking
    ├── external-oci-cr-version.sh     # external OCI chart consumer (CR wrapper) + values.version tracking
    ├── local-with-templates.sh        # local chart (Chart.yaml in repo) + custom templates
    ├── local-cr-version.sh            # local chart (CR wrapper) + values.version + Chart.yaml.appVersion
    └── ansible-github-release.sh     # Ansible-deployed component + GitHub Releases tracking
```

<br/>

## Key concepts

### The problem

Previously, 16 chart directories each carried a near-identical copy of `upgrade.sh`. Fixing a single line in `usage()` required 16 separate Edits, and drift between charts accumulated over time.

### The solution

Each chart's `upgrade.sh` is split into two regions:

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

`sync.sh --apply` keeps each file's CONFIG block intact and replaces only the body with the canonical's body.

### Impact

| Aspect | Before | After |
|---|---|---|
| Edit one line in `usage()` | 16 Edits | 1 Edit + `sync.sh --apply` |
| Detect drift between charts | Manual grep | `sync.sh --check` (CI-friendly) |
| Add a new chart | Copy nearest file → risk of editing body | Copy canonical → edit only CONFIG |
| Canonical divergence | Implicit, hard to track | Header makes it explicit |

### Responsibility split (who edits what)

| Action | Who | Where |
|---|---|---|
| Add a new chart | User | Copy canonical → **fill in the CONFIG block variables only** |
| Chart version upgrade | `upgrade.sh` automatically | Run `./upgrade.sh` or `./upgrade.sh --version X.Y.Z` |
| Common logic change (e.g., usage text) | User edits once + sync propagates | `vim canonical → ./scripts/upgrade-sync/sync.sh --apply` |
| Add a per-chart placeholder | User edits both canonical and each chart's CONFIG | Add placeholder to canonical + real value to each chart |
| Edit body directly | ❌ Don't | Will be overwritten by next sync (see [FAQ](#faq)) |

**Key rule**: CONFIG block (markers 1~3) = user-owned, body (after marker 3) = canonical-owned. sync.sh never touches CONFIG.

<br/>

## Architecture

### Overall structure

```
                ┌─────────────────────────────────────────────┐
                │  scripts/upgrade-sync/templates/            │
                │  ┌────────────────────────────────────────┐ │
                │  │ external-standard.sh         (CANONICAL)│ │
                │  │ external-with-image-tag.sh   (CANONICAL)│ │
                │  │ local-with-templates.sh      (CANONICAL)│ │
                │  └────────────────────────────────────────┘ │
                └─────────────────┬───────────────────────────┘
                                  │
                                  │  sync.sh --apply
                                  │  (copy body, preserve CONFIG)
                                  │
        ┌─────────┬──────────┬────┴───┬──────────┬──────────┐
        ↓         ↓          ↓        ↓          ↓          ↓
   argo-cd/   gitlab-    harbor-   valkey/   fluent-     kube-prom-
   upgrade.sh runner/    helm/     upgrade   bit/        stack/
              upgrade    upgrade   .sh       upgrade     upgrade
              .sh        .sh                 .sh         .sh
```

### Per-file sync flow

```
   target file: cicd/argo-cd/upgrade.sh
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
   canonical: scripts/upgrade-sync/templates/external-standard.sh
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

Each `upgrade.sh` and canonical uses the same 3-marker structure:

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

#### 1. [external-standard.sh](templates/external-standard.sh) — external helm repo chart (most common)

- **Use**: Receives a chart from an external helm repo and deploys via helmfile
- **Flow**: 7 steps (current → fetch latest → download → diff Chart → diff values → check breaking → apply + backup)
- **16 charts**:
  - cicd: `argo-cd`, `gitlab-runner`
  - db-redis: `valkey`
  - network: `metallb`, `ingress-nginx`
  - observability/logging: `eck-operator`, `fluentd`
  - observability/monitoring: `kube-prometheus-stack`, `prometheus-mysql-exporter`, `prometheus-redis-exporter`, `prometheus-elasticsearch-exporter`, `prometheus-postgres-exporter`, `thanos`
  - security: `vaultwarden`
  - storage: `nfs-subdir-external-provisioner`, `static-file-server`

#### 2. [external-with-image-tag.sh](templates/external-with-image-tag.sh) — external + image tag auto-update

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

#### 3. [local-with-templates.sh](templates/local-with-templates.sh) — local chart + custom templates

- **Use**: Local charts that keep `Chart.yaml` and `templates/` in the repo. Fetches the upstream chart, preserves custom templates (e.g., `pv.yaml`, `pvc.yaml`), and re-applies a `_pod.tpl` PVC patch
- **Flow**: 8 steps (current → fetch → download upstream → diff Chart → diff values + templates → check pod patch → check breaking → apply + backup + preserve customs + patch _pod.tpl)
- **Extra variables**: `CUSTOM_TEMPLATES`, `CUSTOM_POD_PATCH`, `EXTRA_DIRS`
- **Two upstream source modes** (selected via CONFIG block):
  - **helm repo mode** (default): set `HELM_REPO_NAME`/`HELM_REPO_URL`/`HELM_CHART`, leave `CHART_GIT_REPO` empty
  - **git source mode**: set `CHART_GIT_REPO`/`CHART_GIT_PATH` (for charts not published to any helm repo). Latest version is auto-detected from git tags and the chart is fetched via git clone.
- **2 charts**:
  - `fluent-bit`, `fluent-bit-aws` (helm repo mode)

#### 4. [local-cr-version.sh](templates/local-cr-version.sh) — local chart (CR wrapper) + version field tracking

- **Use**: Local charts whose `templates/` directory contains Custom Resource (CR) YAML, with the component version stored in a `values/*.yaml` field (e.g. `version`). **No upstream Helm chart exists** (we are the sole owner). Only the value field needs bumping — no chart sync.
- **Flow**: 6 steps (read current version from values → fetch latest from source feed → **verify container image exists** → compatibility reminder → backup → update values + Chart.yaml appVersion)
- **Extra variables**:
  - `COMPONENT_LABEL`: label shown in output (e.g., `elasticsearch`, `kibana`)
  - `VERSION_SOURCE`: version feed type (currently supported: `elastic-artifacts`)
  - `VALUES_FILE`: path to the values file holding the version (e.g., `values/mgmt.yaml`)
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

#### 5. [external-oci-cr-version.sh](templates/external-oci-cr-version.sh) — external OCI chart consumer (CR wrapper) + version field tracking

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

#### 6. [external-oci.sh](templates/external-oci.sh) — external OCI chart + GitHub Releases tracking

- **Use**: OCI-registry-distributed charts where the chart version itself needs tracking. Bumps `helmfile.yaml.version` via GitHub Releases API.
- **Differences vs external-standard**: `helm search repo` is unavailable for OCI → use GitHub Releases instead.
- **Extra variables**: `HELM_CHART` (oci://... URL), `GITHUB_REPO` (owner/repo), `GITHUB_TAG_PREFIX`
- **2 charts**: `network/nginx-gateway-fabric` (NGF OCI chart), `storage/local-path-provisioner` (Rancher upstream OCI chart)

#### 7. [ansible-github-release.sh](templates/ansible-github-release.sh) — Ansible-deployed (non-Helm) component + GitHub Releases tracking

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

## sync.sh usage

Run `./scripts/upgrade-sync/sync.sh --help` for the full inline help.

### `--status` — show current state

```bash
./scripts/upgrade-sync/sync.sh --status
```

```
Managed upgrade.sh files: 22
  external-standard:       16
  external-with-image-tag: 1
  local-with-templates:    3
  local-cr-version:        2

Available canonicals:
  external-standard
  external-with-image-tag
  local-with-templates
  local-cr-version

Unmanaged chart directories (have Chart.yaml but no upgrade.sh):
  - observability/logging/_deprecated/elasticsearch-helm-8.5.1
  - observability/logging/_deprecated/kibana-helm-8.5.1
```

**Unmanaged charts** are directories that have `Chart.yaml` but no `upgrade.sh`. They can be onboarded with the [Adding a new chart](#adding-a-new-chart) procedure.

<br/>

### `--check` — drift verification (CI-friendly)

```bash
./scripts/upgrade-sync/sync.sh --check
```

Verifies that every file matches its canonical bytewise. Exits non-zero on drift. Recommended in CI / pre-commit hooks.

```
  OK    [external-standard] cicd/argo-cd/upgrade.sh
  OK    [external-standard] cicd/gitlab-runner/upgrade.sh
  OK    [external-with-image-tag] cicd/harbor-helm/upgrade.sh
  ...
All 23 managed file(s) are in sync.
```

<br/>

### `--apply` — propagate canonical → 16 files

```bash
# Working tree must be clean (safety guard)
./scripts/upgrade-sync/sync.sh --apply

# Force-apply even when working tree is dirty
./scripts/upgrade-sync/sync.sh --apply --force
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
./scripts/upgrade-sync/sync.sh --print-expected cicd/argo-cd/upgrade.sh

# Compare against the current file
./scripts/upgrade-sync/sync.sh --print-expected cicd/argo-cd/upgrade.sh | diff - cicd/argo-cd/upgrade.sh
```

Useful for debugging when a single file shows drift.

<br/>

### `--insert-headers` — one-shot migration

```bash
./scripts/upgrade-sync/sync.sh --insert-headers
```

Inserts a `# upgrade-template: <name>` header on line 2 of every file that doesn't have one yet. The template type is auto-detected from file content:
- File contains `CUSTOM_TEMPLATES=` variable → `local-with-templates`
- File contains `Update image tags in values files` comment → `external-with-image-tag`
- Otherwise → `external-standard`

Idempotent — files that already have a header are skipped. Run once when first introducing the upgrade-sync infrastructure.

<br/>

### `--no-header` — Phase 1 verification mode

```bash
./scripts/upgrade-sync/sync.sh --check --no-header
```

For verifying that the canonical extraction logic is correct *before* `--insert-headers` runs. Auto-detects template type. No longer needed once headers are in place.

<br/>

## check-versions.sh usage

A read-only preflight tool. Before running the per-chart `upgrade.sh` one by one, use this to scan every managed chart and see which ones have an upstream upgrade available. It does not modify any files — it only prints a summary table.

Each template uses the same upstream lookup logic its `upgrade.sh` already relies on:

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
./scripts/upgrade-sync/check-versions.sh
```

```
Collecting managed upgrade.sh configs...
  Managed: 22  Skipped (no header): 0
Registering 13 helm repo(s)...
Running 'helm repo update'...

  STATUS   TEMPLATE                  CURRENT          LATEST           PATH
  -------  ------------------------  ---------------  ---------------  ----
  UPDATE   external-standard         9.4.15           9.5.0            cicd/argo-cd/upgrade.sh
  OK       external-standard         0.87.1           0.87.1           cicd/gitlab-runner/upgrade.sh
  ...
  UPDATE   external-oci-cr-version   9.0.0            9.4.0            observability/logging/elasticsearch/upgrade.sh
  ...

Summary: OK=15  UPDATE=7  ERROR=0  (total=22)
Upgrades are available. Run 'cd <path> && ./upgrade.sh --dry-run' in each directory above.

OCI chart pin status (external-oci-cr-version consumers):

  STATUS   CHART                 CURRENT     LATEST      PATH
  -------  --------------------  ----------  ----------  ----
  OK       elasticsearch-eck     0.1.2       0.1.2       observability/logging/elasticsearch/upgrade.sh
  OK       kibana-eck            0.1.1       0.1.1       observability/logging/kibana/upgrade.sh

Chart summary: OK=2  UPDATE=0  ERROR=0  (total=2)
```

STATUS column (main table = Stack/component version):
- `OK`: current version matches the upstream latest
- `UPDATE`: a higher upstream version exists → `cd` into the chart dir and run `./upgrade.sh --dry-run`
- `NO_IMG`: upstream feed lists a new version but the container image has not been published yet (common for Elastic etc.)
- `ERROR`: upstream lookup failed, CONFIG missing, current version could not be read, etc. (reason printed on the next line as `-> ...`)

**OCI chart pin table** (secondary table, shown at the bottom): only rows using the `external-oci-cr-version` template with `CHART_SOURCE_*` CONFIG set appear here. This reports drift on `helmfile.yaml.version` (chart pin) independently of the Stack/component version. When `UPDATE` is shown, run `./upgrade.sh --check-chart` and `--upgrade-chart --dry-run` in the listed directory before applying.

<br/>

### Options

```bash
# Only print rows that have an upgrade or an error
./scripts/upgrade-sync/check-versions.sh --updates-only

# Restrict by path substring (repeatable, OR-matched)
./scripts/upgrade-sync/check-versions.sh --only observability/monitoring
./scripts/upgrade-sync/check-versions.sh --only argo-cd --only valkey

# Skip `helm repo update` (faster if you just updated)
./scripts/upgrade-sync/check-versions.sh --no-update

# Combine
./scripts/upgrade-sync/check-versions.sh --updates-only --only observability
```

<br/>

### Exit codes

- `0`: all lookups succeeded, regardless of whether any UPDATE was found.
- `1`: one or more rows ended up as ERROR (network issue, `helm` missing, CONFIG missing, etc). Treat as a CI failure if desired.

<br/>

### Prerequisites

- `helm` (for helm-repo lookups)
- `git` (for git-tags lookups, used by `local-with-templates` in git mode)
- `curl`, `python3` (for version-source lookups — used by `local-cr-version`, `external-oci-cr-version`, `ansible-github-release`)

Same portability as sync.sh: works on macOS bash 3.2 and Linux bash 4+.

<br/>

### Recommended workflow

```bash
# 1. Survey upstream versions across every managed chart
./scripts/upgrade-sync/check-versions.sh --updates-only

# 2. For each chart with an upgrade, inspect the detailed diff
cd observability/monitoring/kube-prometheus-stack
./upgrade.sh --dry-run

# 3. Apply when satisfied
./upgrade.sh

# 4. Roll out via helmfile
helmfile diff
helmfile apply
```

<br/>

## manage-backups.sh usage

Each chart's `upgrade.sh` copies current files to `<chart>/backup/<TIMESTAMP>/` on every run. These accumulate over time — `manage-backups.sh` provides cross-chart visibility and bulk cleanup.

<br/>

### Governance rules

| Topic | Rule |
|---|---|
| **Naming** | `backup/` (no leading underscore). Distinct from `_optional/` and `_deprecated/` — those are git-tracked meta dirs, this is a transient artifact with no gitignore |
| **Location** | Always a child of the chart dir — `<chart>/backup/<TIMESTAMP>/` |
| **Creator** | `upgrade.sh` (canonical template) only. No manual backups — use `~/tmp/` etc. outside the repo for ad-hoc snapshots |
| **Git tracking** | Untracked by default (not in `.gitignore`). Users may selectively `git add` a specific backup as a preserved rollback point |
| **Retention** | `KEEP_BACKUPS` policy (default 5). Auto-pruned via `auto_prune_backups` on every successful `upgrade.sh` run |
| **Override** | Tune per-run via env: `KEEP_BACKUPS=1 ./upgrade.sh` |
| **Bulk ops** | `scripts/upgrade-sync/manage-backups.sh` — `--list` / `--cleanup` / `--total-size` / `--purge` |
| **Sync exclusion** | `sync.sh`, `check-versions.sh`, `manage-backups.sh`, and `cicd-sync/*` all skip `backup/` — backups never sync to other repos |

<br/>

### Backup retention policy

- **Default**: keep the latest 5 per chart (`KEEP_BACKUPS=5`)
- **Auto-cleanup**: after a successful `upgrade.sh` run, `auto_prune_backups` silently trims anything beyond the retention limit
- **Override**: set via env on invocation — `KEEP_BACKUPS=1 ./upgrade.sh` keeps only the newest one

<br/>

### `--list` — summary of all backups

```bash
./scripts/upgrade-sync/manage-backups.sh --list
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
./scripts/upgrade-sync/manage-backups.sh --cleanup

# Everything stable: keep just the latest one
./scripts/upgrade-sync/manage-backups.sh --cleanup --keep 1

# Keep 3
./scripts/upgrade-sync/manage-backups.sh --cleanup --keep 3
```

<br/>

### `--total-size` — disk usage

```bash
./scripts/upgrade-sync/manage-backups.sh --total-size
# Total: 23 backup(s) in 14 chart(s), 1.7M
```

Suitable for CI / cron monitoring.

<br/>

### `--purge` — delete everything (destructive)

```bash
./scripts/upgrade-sync/manage-backups.sh --purge
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
./scripts/upgrade-sync/manage-backups.sh --list        # see current state
./upgrade.sh                                            # upgrade (auto-prunes at end)

# Periodic housekeeping (e.g. weekly)
./scripts/upgrade-sync/manage-backups.sh --cleanup     # keep=5 bulk prune

# Stable state — aggressive cleanup
./scripts/upgrade-sync/manage-backups.sh --cleanup --keep 1
```

<br/>

## How it works (internals)

### sync.sh's three core functions

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
    -name 'upgrade.sh' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
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
        if [ ! -f "$dir/upgrade.sh" ]; then
          echo "${dir#$REPO_ROOT/}"
        fi
      done | sort -u
}
```

Finds directories that have `Chart.yaml` but no `upgrade.sh`. Shown in `--status` output so it's hard to forget about new charts that need onboarding.

<br/>

## Adding a new chart

### Case 1: external helm repo chart (most common)

Candidates: `storage/nfs-subdir-external-provisioner`, `storage/static-file-server`

```bash
# 1. Copy the canonical to the new chart directory
cp scripts/upgrade-sync/templates/external-standard.sh storage/new-chart/upgrade.sh
chmod +x storage/new-chart/upgrade.sh

# 2. Fill in the CONFIG block placeholders with real values
vim storage/new-chart/upgrade.sh
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
./scripts/upgrade-sync/sync.sh --check

# 4. Verify dry-run behavior
cd storage/new-chart && ./upgrade.sh --dry-run
```

<br/>

### Case 2: local chart + custom templates (e.g., elasticsearch, kibana)

```bash
cp scripts/upgrade-sync/templates/local-with-templates.sh \
   observability/logging/elasticsearch/upgrade.sh
chmod +x observability/logging/elasticsearch/upgrade.sh
vim observability/logging/elasticsearch/upgrade.sh
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
./scripts/upgrade-sync/sync.sh --check
cd observability/logging/elasticsearch && ./upgrade.sh --dry-run
```

<br/>

### Case 3: external chart + image tag auto-update

```bash
cp scripts/upgrade-sync/templates/external-with-image-tag.sh new-chart/upgrade.sh
# Assumes values/*.yaml uses `tag: vX.Y.Z` pattern
./scripts/upgrade-sync/sync.sh --check
```

Precondition: `values/*.yaml` image tags must follow the `tag: v2.14.3` form. Other formats (SHA, quoted, etc.) won't match.

<br/>

### Case 4: local chart with no helm repo (git source mode)

For charts that are not published to any helm repo and only available in a git repository. Use the `local-with-templates` canonical's git source mode.

```bash
cp scripts/upgrade-sync/templates/local-with-templates.sh new-chart/upgrade.sh
chmod +x new-chart/upgrade.sh
vim new-chart/upgrade.sh
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
./scripts/upgrade-sync/sync.sh --check
cd new-chart && ./upgrade.sh --dry-run
```

Behavior:
- Step 2: latest semver tag is auto-detected via `git ls-remote --tags`
- Step 3: `git clone --depth 1 --branch v<VERSION>` (`v` prefix tried first, then plain version)
- Step 5+: same templates/values diff + breaking-change check + custom preservation as helm repo mode

<br/>

### Case 5: external OCI chart (`oci://...`)

Candidates: `network/nginx-gateway-fabric`, `storage/local-path-provisioner` (already adopted). Used to consume charts published to an OCI registry where `helm search repo` is unavailable; the GitHub Releases API supplies the latest tag instead.

```bash
cp scripts/upgrade-sync/templates/external-oci.sh new-chart/upgrade.sh
chmod +x new-chart/upgrade.sh
vim new-chart/upgrade.sh
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
./scripts/upgrade-sync/sync.sh --check
cd new-chart && ./upgrade.sh --dry-run
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
cp scripts/upgrade-sync/templates/external-standard.sh \
   scripts/upgrade-sync/templates/external-multi-release.sh

# 2. Modify the new canonical's body (keep CONFIG block placeholders)
vim scripts/upgrade-sync/templates/external-multi-release.sh

# 3. Add a detection branch to sync.sh's detect_template()
vim scripts/upgrade-sync/sync.sh
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
# 4. Update the chart's upgrade.sh header to the new variant
vim path/to/chart/upgrade.sh
# line 2: # upgrade-template: external-multi-release

# 5. Verify
./scripts/upgrade-sync/sync.sh --check
./scripts/upgrade-sync/sync.sh --status

# 6. Update the "Canonical templates" table in this README
vim scripts/upgrade-sync/README-en.md
```

<br/>

## Worked examples

### Example 1: Update one line in usage() across all charts

**Scenario**: Make the `--exclude` option description clearer.

```bash
# 1. Edit canonicals
vim scripts/upgrade-sync/templates/external-standard.sh
# (modify the --exclude description in usage())

vim scripts/upgrade-sync/templates/external-with-image-tag.sh
# (modify the same section)

vim scripts/upgrade-sync/templates/local-with-templates.sh
# (modify the same section)

# 2. Preview impact
./scripts/upgrade-sync/sync.sh --check
# Should show DRIFT for all 16 files

# 3. Propagate
./scripts/upgrade-sync/sync.sh --apply

# 4. Verify
./scripts/upgrade-sync/sync.sh --check
# All 23 managed file(s) are in sync.

# 5. Verify behavior in one chart
cd cicd/argo-cd && ./upgrade.sh --help
```

### Example 2: Onboard a new chart (elasticsearch)

```bash
# 0. Precondition: elasticsearch should be unmanaged
./scripts/upgrade-sync/sync.sh --status | grep elasticsearch
#   - observability/logging/elasticsearch

# 1. Copy the canonical
cp scripts/upgrade-sync/templates/local-with-templates.sh \
   observability/logging/elasticsearch/upgrade.sh
chmod +x observability/logging/elasticsearch/upgrade.sh

# 2. Fill the CONFIG block
vim observability/logging/elasticsearch/upgrade.sh
# - SCRIPT_NAME, HELM_REPO_NAME, HELM_REPO_URL, HELM_CHART, CHANGELOG_URL
# - CUSTOM_TEMPLATES, CUSTOM_POD_PATCH (as needed)

# 3. Verify drift
./scripts/upgrade-sync/sync.sh --check
# All 17 managed file(s) are in sync.   ← 16 → 17

# 4. Confirm it disappeared from unmanaged
./scripts/upgrade-sync/sync.sh --status | grep elasticsearch
# (none)

# 5. Dry-run
cd observability/logging/elasticsearch && ./upgrade.sh --dry-run
```

### Example 3: Debug when drift is detected

**Scenario**: Someone manually edited the body of `cicd/argo-cd/upgrade.sh`.

```bash
# 1. Drift detected
./scripts/upgrade-sync/sync.sh --check
#   DRIFT [external-standard] cicd/argo-cd/upgrade.sh

# 2. See exactly what differs
./scripts/upgrade-sync/sync.sh --print-expected cicd/argo-cd/upgrade.sh \
  | diff - cicd/argo-cd/upgrade.sh

# 3a. If the change was intentional → reflect it in the canonical and propagate
vim scripts/upgrade-sync/templates/external-standard.sh
./scripts/upgrade-sync/sync.sh --apply

# 3b. If the change was a mistake → revert via sync
./scripts/upgrade-sync/sync.sh --apply
# This rewrites the single drifting file from the canonical
```

### Example 4: Apply harbor's image tag updater logic to valkey

```bash
# 1. Change valkey's header
vim db-redis/valkey/upgrade.sh
# line 2:
#   # upgrade-template: external-standard
# →
#   # upgrade-template: external-with-image-tag

# 2. Drift detected
./scripts/upgrade-sync/sync.sh --check
#   DRIFT [external-with-image-tag] db-redis/valkey/upgrade.sh

# 3. Propagate
./scripts/upgrade-sync/sync.sh --apply
# valkey now includes the image tag auto-update block

# 4. Verify behavior
cd db-redis/valkey && ./upgrade.sh --dry-run
```

<br/>

## Troubleshooting

### `sync.sh: command not found` or `Permission denied`

```bash
chmod +x scripts/upgrade-sync/sync.sh
```

### `ERROR: <file> has no '# upgrade-template:' header on line 2`

The file is missing its header. Run the one-shot migration:
```bash
./scripts/upgrade-sync/sync.sh --insert-headers
```

### `ERROR: working tree is dirty. Commit or stash before --apply.`

The `--apply` safety guard. Two options:

```bash
# Safer: commit the current changes first
git -C kuberntes-infra status
git -C kuberntes-infra add ... && git -C kuberntes-infra commit -m "..."
./scripts/upgrade-sync/sync.sh --apply

# Or override (force-apply on dirty working tree)
./scripts/upgrade-sync/sync.sh --apply --force
```

### `--check` reports drift on every file

Possible causes:
1. You modified a canonical but haven't run `--apply` yet → `./scripts/upgrade-sync/sync.sh --apply`
2. The canonical's marker structure is broken (the `# ===` line count is not 3) → inspect the canonical
3. `detect_template` mis-classified a file → check the explicit header

### `--check` reports drift on a single file

Manually edited, or a partial apply:
```bash
# See what differs
./scripts/upgrade-sync/sync.sh --print-expected <file> | diff - <file>

# If intentional, edit the canonical and --apply
# If a mistake, --apply restores it from the canonical
```

### `--insert-headers` mis-classifies a file

`detect_template`'s pattern is imprecise. Fix the header manually:
```bash
# Edit line 2 directly
vim path/to/chart/upgrade.sh
# 1: #!/bin/bash
# 2: # upgrade-template: <correct-template>
# 3: set -euo pipefail
```

### Added a new canonical but `--check` doesn't recognize it

Probably forgot to add a branch to `detect_template()`. See [Adding a new canonical variant](#adding-a-new-canonical-variant).

<br/>

## Compatibility

- **macOS bash 3.2** (default): no `declare -A` or other bash 4+ features ✅
- **Linux bash 4+**: works ✅
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

### Phase 1 gate (during migration)
- `--check --no-header` verifies the canonical extraction logic is correct
- Must pass before proceeding

<br/>

## FAQ

**Q: Code I added directly to `upgrade.sh` was wiped out by the next sync.**

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

A:
- `_deprecated/` is permanently excluded (`*/_deprecated/*` exclude)
- `_optional/` is treated as an active directory and included in sync (e.g., `_optional/fluent-bit-aws`, `_optional/thanos`)

<br/>

**Q: What about non-helm directories like kubespray?**

A: `find_managed_files` only matches `upgrade.sh` files, so directories without both `Chart.yaml` and `upgrade.sh` are never candidates. kubespray is Ansible-based and unrelated.

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
      - run: ./scripts/upgrade-sync/sync.sh --check
```

<br/>

**Q: How do I recover if the sync system itself has a bug and breaks every file?**

A: `git checkout HEAD -- .` restores everything in one shot. Always run sync from a clean working tree (or a dedicated branch). The `--apply` git guard enforces this.

<br/>

## See also

- Main README: [../../README.md](../../README.md)
- Canonical sources: [templates/](templates/)
- Sync tool: [sync.sh](sync.sh)
