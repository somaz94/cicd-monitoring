# Kibana Dashboards

Stores **declarative saved objects** (Vega visualizations + Lens + Dashboards) of the Kibana running in the `logging` namespace as NDJSON. The apply/export scripts keep Kibana and the repo bidirectionally in sync; multiple dashboards are managed via `manifest.txt`.

<br/>

## Directory layout

```
dashboards/
├── apply.sh                                    # repo NDJSON  → live Kibana (import, multi-Space)
├── export.sh                                   # live Kibana → repo NDJSON (capture edits, per Space)
├── setup-spaces.sh                             # Kibana Space bootstrap (default=KST + cst=CST)
├── manifest.txt                                # Managed dashboards (id + filename)
├── dev-pm-retention-dashboard.ndjson           # "DEV — Game User Matric & Retention" (7 Vega + 3 Lens + 1 Dashboard)
├── qa-pm-retention-dashboard.ndjson            # "QA — Game User Matric & Retention" (same structure, qa-example-project-game indices)
├── example-project-game-data-view.ndjson          # Data view bootstrap (usually not imported, holds 4 data views — dev raw / dev cohort / qa raw / qa cohort)
├── README.md
└── README-en.md
```

Three scripts, distinct roles:
- **`apply.sh`** — auto-imports every `*.ndjson` in the directory (excluding the `*-data-view.ndjson` pattern by default). `--space-id` may be repeated to import into multiple Spaces in one run.
- **`export.sh`** — exports every dashboard listed in `manifest.txt` in a single run. Calls Kibana with `includeReferencesDeep=true` so all referenced visualizations / lenses / data views are captured along with the dashboard. `--space-id` selects the source Space (default `default`).
- **`setup-spaces.sh`** — bootstrap script for the timezone-toggle Kibana Spaces (`default` = KST, `cst` = CST / UTC+8). Run once per cluster (idempotent).

<br/>

## Current dashboards (2 environments)

| Env | Slug | Live title | Raw index | Cohort index | Repo file |
|---|---|---|---|---|---|
| **DEV** | `dev-pm-retention-dashboard` | DEV — Game User Matric & Retention | `dev-example-project-game` | `dev-example-project-game-user-cohort` | `dev-pm-retention-dashboard.ndjson` |
| **QA** | `qa-pm-retention-dashboard` | QA — Game User Matric & Retention | `qa-example-project-game` | `qa-example-project-game-user-cohort` | `qa-pm-retention-dashboard.ndjson` |

Both dashboards share the same structure (10 panels = 7 Vega + 3 Lens). Env-specific differences: index names / saved-object id prefix / data view UUID / KPI card color palette. The procedure for adding a new environment lives in [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md).

<br/>

### Live URLs (dev cluster)

| Env | Default Space (KST view) | CST Space (UTC+8 view) |
|---|---|---|
| **DEV** | [/app/dashboards#/view/dev-pm-retention-dashboard](http://kibana.example.com/app/dashboards#/view/dev-pm-retention-dashboard?_g=(filters:!())) | [/s/cst/app/dashboards#/view/678a6e59-…](http://kibana.example.com/s/cst/app/dashboards#/view/678a6e59-8539-4781-8c7e-c2ddb72a1239?_g=(filters:!())) |
| **QA** | [/app/dashboards#/view/qa-pm-retention-dashboard](http://kibana.example.com/app/dashboards#/view/qa-pm-retention-dashboard?_g=(filters:!())) | [/s/cst/app/dashboards#/view/d485f325-…](http://kibana.example.com/s/cst/app/dashboards#/view/d485f325-8222-45f3-b46d-3bef735da280?_g=(filters:!())) |

- **Default Space** dashboard URLs use the slug IDs (`dev-pm-retention-dashboard` / `qa-pm-retention-dashboard`).
- **CST Space** dashboard URLs use auto-generated UUIDs (Kibana 9.x single-namespace constraint — the same slug ID cannot live in two Spaces). Content is 100% identical to the Default Space; only the display timezone differs (`Asia/Shanghai`).
- Since the UUIDs change if the cluster is rebuilt, prefer guiding users via **top-left Space switcher → CST → Dashboards → "DEV — …"** rather than pinning the UUID URLs in external docs.

10-panel analyst-grade dashboard. Default time range `now-30d ~ now` (`timeRestore: true`).

Per-panel definitions in [user-metrics-catalog-en.md](../docs/user-metrics-catalog.md). For prod migration / automation / compatibility checks see [pm-retention-dashboard-template-en.md](../docs/pm-retention-dashboard-template.md).

Saved-object ID pattern (per-env prefix):
- Dashboard: `<env>-pm-retention-dashboard` (slug)
- Visualization (Vega) ×7: `<env>-pm-retention-{nu-today,nu-7d,nu-30d,dau-today,wau-7d,mau-30d,curve}`
- Lens ×3: `<env>-pm-retention-{nu-trend,dau-trend,daily-table}`
- DEV data view (raw):    `b50c59ea-73c1-4feb-8b42-d642248c8647` — `dev-example-project-game`
- DEV data view (cohort): `410571c2-5b86-4ba9-a02e-418671d0b8e2` — `dev-example-project-game-user-cohort` (time field `first_seen`)
- QA data view (raw):     `78a74d07-ca35-4790-8531-837f4da47bb7` — `qa-example-project-game`
- QA data view (cohort):  `fb7b645e-78ff-4da7-b231-ec2c4165cf98` — `qa-example-project-game-user-cohort` (time field `first_seen`)

<br/>

## Time zone

- **Stored**: fluentd normalizes every `@timestamp` to KST (+09:00) ISO8601 → stored internally as UTC epoch in ES.
- **Displayed**: driven per-Space by the `dateFormat:tz` Advanced Setting.
- **Bucket boundaries**: The Lens date_histogram / Vega date math follows the display timezone above.
- **Retention day boundary**: cohort-index D-N is computed against the ES Transform's `params.tz = "Asia/Seoul"` (independent of the display timezone). To change globally see [pm-retention-dashboard-template-en.md "Timezone change procedure"](../docs/pm-retention-dashboard-template.md#timezone-change-procedure).

<br/>

### Per-Space timezone toggle (KST / CST)

We present KST and CST(UTC+8) as two views via a **Kibana Space split**.

| Space | `dateFormat:tz` | Purpose |
|---|---|---|
| `default` | `Asia/Seoul` | Primary KST operations view |
| `cst` | `Asia/Shanghai` | CST (UTC+8) reporting view |

Users toggle via the Kibana Space switcher (top-left) — same NDJSON, different display timezone. Both Spaces share the same ES indices, so there is no data duplication.

**Model — single NDJSON, import into both**: Kibana 9.x treats dashboard

> ⚠️ Edit flow: always edit dashboards in the default Space → `./export.sh` to capture → `./apply.sh --space-id default --space-id cst` to redeploy to both. Editing directly in the cst Space will diverge the two and should be avoided.

**View limitation — retention day boundary**: ES Transform `params.tz` is `Asia/Seoul` regardless of Space, so even in the cst Space the Daily Cohort Retention row labels are KST midnight boundaries. To shift the day boundary itself to CST, follow the transform `params.tz` + cohort data view ZoneId procedure in [pm-retention-dashboard-template-en.md "Timezone change procedure"](../docs/pm-retention-dashboard-template.md#timezone-change-procedure).

**Extensibility — adding more zones (JST / PST / UTC, etc.)**: `setup-spaces.sh --space NAME:TZ` and `apply.sh --space-id ID` both accept repeatable arguments, so N additional zones follow the same pattern. Example:

```bash
# Add a JST (Japan) view
./setup-spaces.sh \
  --space default:Asia/Seoul \
  --space cst:Asia/Shanghai \
  --space jst:Asia/Tokyo

./apply.sh --space-id jst --include-data-view                     # bootstrap the new Space
./apply.sh --space-id default --space-id cst --space-id jst       # routine sync going forward
```

For a fuller list of IANA timezones (Asia/Tokyo

<br/>

## Usage

### 0) First-time only — bootstrap the Spaces (KST + CST view)

Run once if you want the timezone toggle. Also re-pins the `default` Space's KST setting (idempotent — safe to re-run).

```bash
cd observability/logging/kibana/dashboards
./setup-spaces.sh                                       # default=Asia/Seoul, cst=Asia/Shanghai
./setup-spaces.sh --dry-run                             # preview the intended calls
./setup-spaces.sh --space default:UTC --space jst:Asia/Tokyo   # custom mapping
```

What it does:
1. Checks whether the `cst` Space exists; creates it via `POST /api/spaces/space` if missing.
2. Pins `dateFormat:tz` in each Space via `POST /api/kibana/settings`.
3. Saved objects (dashboards / data views) are imported separately in step 1) below.

<br/>

### 1) Apply dashboards to the cluster (repo → Kibana)

```bash
cd observability/logging/kibana/dashboards
./apply.sh                                                       # default Space only (legacy behaviour)
./apply.sh --space-id default --space-id cst                     # import into both KST + CST Spaces in one run
./apply.sh --space-id default --space-id cst --include-data-view # full bootstrap (data views included) for a fresh cst Space
./apply.sh --file dev-pm-retention-dashboard.ndjson              # target a specific file
./apply.sh --no-overwrite                                        # skip if already present
./apply.sh --dry-run                                             # print intended calls only
./apply.sh -h                                                    # full help
```

What it does:
1. Reads the elastic password from `kubectl -n logging get secret elasticsearch-es-elastic-user`.
2. Runs `kubectl exec elasticsearch-es-default-0 -- curl` to hit the Kibana API from inside the cluster (no port-forward).
3. Uploads each NDJSON as `multipart/form-data` to `POST {SPACE_PREFIX}/api/saved_objects/_import?overwrite=true` — looped over every `--space-id`.

<br/>

### 2) Capture Kibana UI edits back into the repo (Kibana → repo)

```bash

cd observability/logging/kibana/dashboards
./export.sh                                       # export every dashboard from the default Space
./export.sh --space-id cst                        # capture edits made in the cst Space instead
./export.sh --id <uuid-or-slug> --out file.ndjson   # one-off export (ignores manifest)
./export.sh --no-data-view                        # skip bootstrap NDJSON
./export.sh --dry-run                             # print intended exports only
git diff -- .                                     # review changes
git add -- *.ndjson && git commit
```

`export.sh` calls Kibana with `includeReferencesDeep=true`, so every visualization

> ⚠️ `export.sh` **overwrites** the NDJSON with whatever is live in Kibana right now. Inspect `git diff` first if you have unmerged local NDJSON edits.
>
> ⚠️ Saved objects are Space-scoped. To avoid the `cst` Space drifting from `default`, **edit in one Space only** (typically `default`) and redeploy to both with `apply.sh --space-id default --space-id cst`. If you do edit in `cst`, capture it with `./export.sh --space-id cst` and replay into `default` to keep them in sync.

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
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Create a Visualization (Vega)
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/saved_objects/visualization/<id>" \
  --data-binary @viz-payload.json

# Create a Lens
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
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

Example:
```
dev-pm-retention-dashboard  dev-pm-retention-dashboard.ndjson   # DEV — Game User Matric & Retention
qa-pm-retention-dashboard   qa-pm-retention-dashboard.ndjson    # QA — Game User Matric & Retention
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

- **Retention horizons extension**: D-1 through D-30 are currently stored as boolean fields in the cohort index. For D-60
- **User LTV / billing metrics**: once payment events are standardized in the raw index, add mappings + a separate cohort or Lens.
- **State-driven build script**: today, new-environment rollout is NDJSON substitution. The [build-pm-retention.py](../docs/pm-retention-dashboard-template.md#automation-strategy) pattern documented in the template guide codifies it.

Full panel definitions in [user-metrics-catalog-en.md](../docs/user-metrics-catalog.md); workflow details in [dashboards-saved-objects-en.md](../docs/dashboards-saved-objects.md).
