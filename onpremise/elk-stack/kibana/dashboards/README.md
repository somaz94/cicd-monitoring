# Kibana Dashboards

Stores **declarative saved objects** (Vega visualizations + Lens + Dashboards) of the Kibana running in the `logging` namespace as NDJSON. The apply/export scripts keep Kibana and the repo bidirectionally in sync; multiple dashboards are managed via `manifest.txt`.

<br/>

## Directory layout

```
dashboards/
├── apply.sh                                    # repo NDJSON  → live Kibana (import, multi-Space)
├── export.sh                                   # live Kibana → repo NDJSON (capture edits, per Space)
├── setup-spaces.sh                             # Kibana Space bootstrap (default=KST + cst=CST)
├── make-cst-variant.sh                         # default(KST) → cst/ variant generator (--check detects drift)
├── manifest.txt                                # Managed dashboards (id + filename) — SSOT
├── <env>-pm-retention-dashboard.ndjson         # Per-environment dashboard; manifest.txt is the SSOT for the list
├── example-project-game-data-view.ndjson              # Data view bootstrap (usually not imported) — authoritative for the data views
├── cst/                                        # ── generated. never hand-edit ──
│   ├── example-project-game-data-view-cst.ndjson      #   CST cohort data views (same index, read active_dates_cst)
│   └── <env>-pm-retention-dashboard-cst.ndjson #   Per-environment CST dashboard (cst- prefixed ids), 1:1 with the default original
├── README.md
└── README-en.md
```

The actual dashboard files and environments are not listed here — `manifest.txt` and the directory itself are the SSOT.

`cst/` is a subdirectory **on purpose** — `apply.sh` auto-discovers `*.ndjson` in this directory only (non-recursive), so a cst variant sitting here flat would also be imported into the `default` Space.

Four scripts, distinct roles:
- **`apply.sh`** — auto-imports every `*.ndjson` in the directory (excluding the `*-data-view.ndjson` pattern by default). `--space-id` may be repeated to import into multiple Spaces in one run.
- **`export.sh`** — exports every dashboard listed in `manifest.txt` in a single run. Calls Kibana with `includeReferencesDeep=true` so all referenced visualizations / lenses / data views are captured along with the dashboard. `--space-id` selects the source Space (default `default`).
- **`setup-spaces.sh`** — bootstrap script for the timezone-toggle Kibana Spaces (`default` = KST, `cst` = CST / UTC+8). Run once per cluster (idempotent).
- **`make-cst-variant.sh`** — derives the `cst/` variants from the `default` (KST) originals. A cohort day boundary is baked into the index as a date string and cannot be re-bucketed by a Space's tz, so the cst Space needs its own objects reading the CST side (`active_dates_cst`). **Re-run it whenever `default` changes**, and use `--check` to detect drift (never hand-edit the generated files).

<br/>

## Current dashboards

**`manifest.txt` is the SSOT for the managed dashboard list** — a new environment adds one line there, so it is not enumerated here. The per-environment naming rules:

| Item | Rule |
|---|---|
| Slug (saved-object id) | `<env>-pm-retention-dashboard` |
| Live title | `<ENV> — Game User Matric & Retention` |
| Raw index | `<env>-example-project-game` |
| Cohort index | `<env>-example-project-game-user-cohort` |
| Repo file | `<env>-pm-retention-dashboard.ndjson` |

Every dashboard shares the same structure (12 panels = 9 Vega + 3 Lens). Env-specific differences: index names / saved-object id prefix / data view UUID / KPI card color palette. The procedure for adding a new environment lives in [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md).

<br/>

### Live URLs (dev cluster)

URLs are derived mechanically from the slug, so they are not enumerated per environment — substitute a `<dashboard-id>` from `manifest.txt` into the slug position in the pattern below.

| Space | URL pattern |
|---|---|
| Default (KST view) | `http://kibana.example.com/app/dashboards#/view/<env>-pm-retention-dashboard` |
| CST (UTC+8 view) | `http://kibana.example.com/s/cst/app/dashboards#/view/cst-<env>-pm-retention-dashboard` |

- **Default Space** dashboard URLs use the slug IDs as-is.
- **CST Space** dashboard ids carry a `cst-` prefix. Kibana 9.x's single-namespace constraint means the same slug cannot live in two Spaces, so the prefix works around it — the URLs stay stable and can be embedded directly in an external app or iframe.
- Both Spaces' dashboards share the panel layout and differ in display timezone (default = `Asia/Seoul`, cst = `Asia/Shanghai`). **Cohort / retention panels are the exception** — cst uses a derived variant ([`cst/`](cst/)) that reads the CST day boundary, so its data-view reference differs.
- The data views are multi-namespace and shared from default into cst (`namespaces=['cst','default']`) — Kibana resolves the references automatically.

12-panel analyst-grade dashboard. Default time range `now-30d ~ now` (`timeRestore: true`).

- `<env>-example-project-game` (raw) — Kibana data view `<env>-example-project-game-logs`
- `<env>-example-project-game-user-cohort` (ES Transform output) — data view `<env>-example-project-game-user-cohort-logs` (time field `first_seen`, runtime field `cohort_date`)

| Row | Panel | Type | Data source |
|---|---|---|---|
| 1 | NU (Today) / NU (Last 7d) / NU (Last 30d) | Vega-Lite KPI ×3 | raw |
| 2 | DAU / WAU / MAU | Vega-Lite KPI ×3 | raw |
| 3 | NU (Total) / NU Trend (30d) / DAU Trend | KPI ×1 + Lens lnsXY ×2 | raw |
| 4 | Average Retention Curve (D+1..D+30) | Vega (full) | cohort |
| 5 | Daily Cohort Retention (table) | Lens lnsDatatable | cohort |
| 6 | Chapter Distribution (per user latest) | Vega | cohort |

Per-panel definitions in [user-metrics-catalog-en.md](../docs/user-metrics-catalog.md). For prod migration / automation / compatibility checks see [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md).

Saved-object ID pattern (per-env prefix):
- Dashboard: `<env>-pm-retention-dashboard` (slug)
- Visualization (Vega) ×9: `<env>-pm-retention-{nu-today,nu-7d,nu-30d,dau-today,wau-7d,mau-30d,nu-total,curve,chapter-dist}`
- Lens ×3: `<env>-pm-retention-{nu-trend,dau-trend,daily-table}`
- Data views: two per environment — raw (`<env>-example-project-game`) and cohort (`<env>-example-project-game-user-cohort`, time field `first_seen`). **Data views are identified by UUID, not by slug**, so they cannot be derived from a rule — [`example-project-game-data-view.ndjson`](example-project-game-data-view.ndjson) is the SSOT for the actual UUIDs; read it instead of copying them here.

<br/>

## Time zone

- **Stored**: fluentd normalizes every `@timestamp` to KST (+09:00) ISO8601 → stored internally as UTC epoch in ES.
- **Displayed**: driven per-Space by the `dateFormat:tz` Advanced Setting.
- **Bucket boundaries**: The Lens date_histogram / Vega date math follows the display timezone above.
- **Retention day boundary**: cohort-index D-N is independent of the display timezone — it follows the date strings the transform precomputed: `default` reads `active_dates` (`Asia/Seoul`), `cst` reads `active_dates_cst` (`Asia/Shanghai`). A Space's `dateFormat:tz` does not change it ([docs/timezone-toggle-en.md §5](../docs/timezone-toggle.md)).

<br/>

### Per-Space timezone toggle (KST / CST)

We present KST and CST(UTC+8) as two views via a **Kibana Space split**.

| Space | `dateFormat:tz` | Purpose |
|---|---|---|
| `default` | `Asia/Seoul` | Primary KST operations view |
| `cst` | `Asia/Shanghai` | CST (UTC+8) reporting view |

Users toggle via the Kibana Space switcher (top-left) — same NDJSON, different display timezone. Both Spaces share the same ES indices, so there is no data duplication.

**Model — raw panels share the NDJSON, cohort panels use a derived variant**: Kibana 9.x treats dashboard / lens / visualization as single-namespace objects, so the same saved-object id cannot exist in two Spaces — cst-side ids therefore carry a `cst-` prefix. A data view is the one multi-namespace type, so `setup-spaces.sh` shares the default Space's raw data views into cst and lens references resolve automatically.

**But cst is NOT content-identical to default.** Panels that read `@timestamp` directly (NU / DAU / WAU / MAU) get their zone purely from the Space's `dateFormat:tz`. **Cohort / retention panels do not**: their day boundary is baked into the index as a date string (`active_dates`), which no tz setting can re-bucket. So the transform precomputes both zones (`active_dates` + `active_dates_cst`) and cst uses a **derived variant** ([`cst/`](cst/)) that reads the CST twin. `default` is the single source of truth; `cst/` is generated by [`make-cst-variant.sh`](make-cst-variant.sh) — **never hand-edit it**.

```bash
# 1) default (Korea / KST) Space — cohort data views + dashboards
./apply.sh --context onprem-dev --include-data-view --space-id default

# 2) Generate the cst variants (re-run whenever default changes — cst/ is generated)
./make-cst-variant.sh

# 3) cst (China / CST) Space — cst/ is complete, so --id-prefix-for is not needed.
#    Import the data view first so the dashboards' references resolve.
./apply.sh --context onprem-dev --file cst/example-project-game-data-view-cst.ndjson --space-id cst
./apply.sh --context onprem-dev --file cst/dev-pm-retention-dashboard-cst.ndjson --space-id cst
./apply.sh --context onprem-dev --file cst/qa-pm-retention-dashboard-cst.ndjson --space-id cst

# (verify) has cst/ drifted from default?
./make-cst-variant.sh --check
```

> ⚠️ Edit flow: always edit dashboards in the default Space → `./export.sh` to capture → re-run `./make-cst-variant.sh` → redeploy with the commands above. Editing directly in the cst Space is overwritten on the next generation.

> ⚠️ **Do not push the default NDJSON into cst with `--id-prefix-for cst:cst-`.** That was the old flow, and it leaves the cst dashboards reading the KST cohort field (`active_dates`) — CST on the clock, **KST on the day boundary**. Background: [docs/timezone-toggle-en.md §5](../docs/timezone-toggle.md).

**Extensibility — adding more zones (JST / PST / UTC, etc.)**: `setup-spaces.sh --space NAME:TZ` and `apply.sh --space-id ID` both accept repeatable arguments, so N additional zones follow the same pattern. Example:

```bash
# Add a JST (Japan) view
./setup-spaces.sh --context onprem-dev \
  --space default:Asia/Seoul \
  --space cst:Asia/Shanghai \
  --space jst:Asia/Tokyo

./apply.sh --context onprem-dev --space-id jst --include-data-view                     # bootstrap the new Space
```

> ⚠️ The above only covers the **raw time-series panels** (NU/DAU/WAU/MAU). Getting the new zone's **cohort / retention** right needs the same two extra steps cst took: ① add an `active_dates_jst` / `active_days_count_jst` agg pair to the transform pivot and recreate it, ② derive a data view + dashboard variant that reads those fields (reuse `make-cst-variant.sh` with the zone / field / prefix swapped). Skip them and the jst Space shows a JST clock on a KST day boundary.

For a fuller list of IANA timezones (Asia/Tokyo / America/Los_Angeles / America/New_York / Europe/Berlin / UTC etc.), operational mechanics, live URLs, and verification steps, see → [docs/timezone-toggle-en.md](../docs/timezone-toggle.md).

<br/>

## Usage

> 🔴 **`--context` is REQUIRED on `apply.sh` / `export.sh` / `setup-spaces.sh` — there is no default and no fallback to the current kube-context.** This directory and its AWS twin [`../../kibana-aws/dashboards/`](../../kibana-aws/dashboards/) drive *different clusters* with *identical resource names*: both expose `logging/elasticsearch-es-default-0` and a Kibana behind `kibana-kb-http`. A bare `kubectl` therefore succeeds against whichever context happens to be current, and because the two clusters **share cohort data-view UUIDs** (`410571c2`, `fb7b645e`, `cacd5df9`), a wrong-context run does not merely add objects — it **overwrites the other cluster's data views**, breaking its dashboards. This happened on 2026-08-03: an AWS-targeted apply landed here and clobbered the dev/qa example-project cohort views. The scripts now refuse to run without `--context`, and print the resolved cluster (not just the context name) in their startup banner — read that line before trusting the run.

<br/>

### 0) First-time only — bootstrap the Spaces (KST + CST view)

Run once if you want the timezone toggle. Also re-pins the `default` Space's KST setting (idempotent — safe to re-run).

```bash
cd observability/logging/kibana/dashboards
./setup-spaces.sh --context onprem-dev                                       # default=Asia/Seoul, cst=Asia/Shanghai
./setup-spaces.sh --context onprem-dev --dry-run                             # preview the intended calls
./setup-spaces.sh --context onprem-dev --space default:UTC --space jst:Asia/Tokyo   # custom mapping
```

What it does:
1. Checks whether the `cst` Space exists; creates it via `POST /api/spaces/space` if missing.
2. Pins `dateFormat:tz` in each Space via `POST /api/kibana/settings`.
3. Saved objects (dashboards / data views) are imported separately in step 1) below.

<br/>

### 1) Apply dashboards to the cluster (repo → Kibana)

```bash
cd observability/logging/kibana/dashboards
./apply.sh --context onprem-dev                                                       # default Space only (legacy behaviour)
./apply.sh --context onprem-dev --include-data-view --space-id default                # bootstrap default (data views included)
./apply.sh --context onprem-dev --file cst/dev-pm-retention-dashboard-cst.ndjson --space-id cst  # cst takes generated files only
./apply.sh --context onprem-dev --file dev-pm-retention-dashboard.ndjson              # target a specific file
./apply.sh --context onprem-dev --no-overwrite                                        # skip if already present
./apply.sh --context onprem-dev --dry-run                                             # print intended calls only
./apply.sh -h                                                    # full help
```

What it does:
1. Reads the elastic password from `kubectl --context onprem-dev -n logging get secret elasticsearch-es-elastic-user`.
2. Runs `kubectl exec elasticsearch-es-default-0 -- curl` to hit the Kibana API from inside the cluster (no port-forward).
3. Uploads each NDJSON as `multipart/form-data` to `POST {SPACE_PREFIX}/api/saved_objects/_import?overwrite=true` — looped over every `--space-id`.

<br/>

### 2) Capture Kibana UI edits back into the repo (Kibana → repo)

```bash
cd observability/logging/kibana/dashboards
./export.sh --context onprem-dev                                       # export every dashboard from the default Space
./export.sh --context onprem-dev --space-id cst                        # capture edits made in the cst Space instead
./export.sh --context onprem-dev --id <uuid-or-slug> --out file.ndjson   # one-off export (ignores manifest)
./export.sh --context onprem-dev --no-data-view                        # skip bootstrap NDJSON
./export.sh --context onprem-dev --dry-run                             # print intended exports only
git diff -- .                                     # review changes
git add -- *.ndjson && git commit
```

`export.sh` calls Kibana with `includeReferencesDeep=true`, so every visualization / lens / data view referenced by the dashboard is captured. The NDJSON output is sorted `visualization → lens → dashboard` for stable diffs.

> ⚠️ `export.sh` **overwrites** the NDJSON with whatever is live in Kibana right now. Inspect `git diff` first if you have unmerged local NDJSON edits.
>
> ⚠️ Saved objects are Space-scoped. **Edit in `default` only** → `./export.sh` → re-run `./make-cst-variant.sh` → redeploy both. `cst` is generated, so anything edited there disappears on the next generation.

<br/>

### 3) Adding a new dashboard

Recommended flow — **build in the Kibana UI, then capture with `export.sh`**:

1. Kibana → Dashboards → Create dashboard → add panels → Save (prefer a slug id, e.g. `<env>-pm-retention-dashboard`).
2. Grab the new dashboard ID from the URL or saved-object listing.
3. Append a line to `manifest.txt`:
   ```
   <new-dashboard-id>  <new-filename>.ndjson
   ```
4. Run `./export.sh` — the new NDJSON appears, existing dashboards' NDJSON also refresh.
5. `apply.sh` automatically picks up the new file on subsequent runs.

Direct API approach (for scripting):

```bash
# Look up password
PASS=$(kubectl --context onprem-dev -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Create a Visualization (Vega)
kubectl --context onprem-dev -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/saved_objects/visualization/<id>" \
  --data-binary @viz-payload.json

# Create a Lens
kubectl --context onprem-dev -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/saved_objects/lens/<id>" \
  --data-binary @lens-payload.json

# Overwrite same ID
... -X POST ".../api/saved_objects/lens/<id>?overwrite=true" ...

# Dashboards follow the same pattern (type=dashboard)
```

<br/>

## Manifest format (`manifest.txt`)

Used by `export.sh`. One dashboard per line.

```
# leading- or inline-# comments allowed
<dashboard-id>  <ndjson-filename>   # use the inline comment to note the title
```

Example (read `manifest.txt` for the real lines — one per environment):
```
<dashboard-id>  <ndjson-filename>   # <ENV> — Game User Matric & Retention
```

<br/>

## Environment variables (apply.sh / export.sh)

| Var | Default | Description |
|---|---|---|
| `NAMESPACE` | `logging` | ES/Kibana namespace |
| `ES_POD` | `elasticsearch-es-default-0` | Pod used to run curl (any pod reaching Kibana works) |
| `ES_CONTAINER` | `elasticsearch` | Container name in that pod |
| `KIBANA_SVC` | `kibana-kb-http.logging.svc` | Kibana ClusterIP DNS |
| `KIBANA_PORT` | `5601` | |
| `KIBANA_SCHEME` | `http` | Dev runs plain HTTP — `http.tls.selfSignedCertificate.disabled: true` |
| `ES_SECRET` | `elasticsearch-es-elastic-user` | ECK-managed elastic-user secret |
| `ES_USER` | `elastic` | Username (also secret key) |
| `MANIFEST` (export.sh) | `./manifest.txt` | Managed dashboards file |
| `DATA_VIEW_FILE` (export.sh) | `example-project-game-data-view.ndjson` | Bootstrap NDJSON filename |
| `SPACE_ID` (export.sh) | `default` | Source Space for export (`/s/<id>` prefix when not `default`) |

<br/>

## Data view management policy

`example-project-game-data-view.ndjson` is **bootstrap-only**. The normal `apply.sh` run does not import it.

Reason: runtime fields (e.g. `cohort_date`), scripted fields, and formatters that users add through the Kibana UI would be wiped every time the data view is re-imported with `overwrite=true`. The data views were already imported during the ECK migration (Phase 0), so they rarely need touching.

Use `./apply.sh --include-data-view` only when intentionally resetting the data views.

<br/>

## Porting to other environments (new env)

To carry the dashboard over to a new environment (e.g. stg / prod):

1. **Pre-check** — confirm the raw index has the same schema (`data.userId`, `data.requestPath` + `.keyword`, `data.statusCode`). The full compatibility checklist lives in [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md#compatibility-checklist).
2. **Apply the transform** — clone `elasticsearch/transforms/dev-example-project-game-user-cohort.json` with the env prefix and run `apply.sh --file`. (QA already done — see `qa-example-project-game-user-cohort.json`.)
3. **Create the data views** — bootstrap raw + cohort data views via the Kibana API (the cohort view must include the `cohort_date` runtime field).
4. **Substitute + apply the NDJSON** — search-and-replace the index names / saved-object ids / data view UUIDs in `dev-pm-retention-dashboard.ndjson` to the new env prefix, then run `apply.sh --file`. The QA case (already validated) lives in `qa-pm-retention-dashboard.ndjson`.

The end-to-end guide (with the qa-example-project-game validated procedure) lives in [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md).

<br/>

## Roadmap

- **Retention horizons extension**: D-1 through D-30 are computed by the cohort data view's runtime fields `d1_live..d30_live` (the transform only stores the `active_dates` atomic fact). For D-60 / D-90, add one `dN_live` runtime field on the cohort data view (the transform stays untouched), then extend the Curve Vega N range.
- **User LTV / billing metrics**: once payment events are standardized in the raw index, add mappings + a separate cohort or Lens.
- **State-driven build script**: today, new-environment rollout is NDJSON substitution. The [build-pm-retention.py](../docs/pm-retention-dashboard-template.md#automation-strategy) pattern documented in the template guide codifies it.

Full panel definitions in [user-metrics-catalog-en.md](../docs/user-metrics-catalog.md); workflow details in [dashboards-saved-objects-en.md](../docs/dashboards-saved-objects.md).
