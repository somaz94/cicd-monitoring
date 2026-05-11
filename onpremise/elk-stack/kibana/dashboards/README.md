# Kibana Dashboards

Stores **declarative saved objects** (Lens visualizations + Dashboards) of the Kibana running in the `logging` namespace as NDJSON. The apply/export scripts keep Kibana and the repo bidirectionally in sync; multiple dashboards are managed via `manifest.txt`.

<br/>

## Directory layout

```
dashboards/
├── apply.sh                                    # repo NDJSON  → live Kibana (import)
├── export.sh                                   # live Kibana → repo NDJSON (capture edits)
├── manifest.txt                                # Managed dashboards (id + filename)
├── build-dev-example-project-game.py                  # Recreate the dashboard from code (state-driven, idempotent)
├── dev-example-project-game.state.json                # Auto-allocated UUID cache for build script (do not hand-edit)
├── dev-example-project-game-user-metrics.ndjson       # "Dev ExampleProject Game — User Metrics" (5 lenses + 1 dashboard)
├── dev-example-project-game-data-view.ndjson          # Data view bootstrap (usually not imported, 2 data views)
├── README.md
└── README-en.md
```

Three scripts, distinct roles:
- **`apply.sh`** — auto-imports every `*.ndjson` in the directory (excluding the `*-data-view.ndjson` pattern by default).
- **`export.sh`** — exports every dashboard listed in `manifest.txt` in a single run.
- **`build-*.py`** — recreates the dashboard from code without needing NDJSON. UUIDs are auto-allocated and cached in the state file; you never need to know any UUID.

<br/>

## Current dashboard: `Dev ExampleProject Game — User Metrics`

Four user-metric panels backed by the `dev-example-project-game` index (Kibana data view `dev-example-project-game-logs`, ID `b50c59ea-73c1-4feb-8b42-d642248c8647`).

| Panel | Formula | Notes |
|---|---|---|
| **DAU** | `cardinality(data.userId)` × `date_histogram(@timestamp, 1d)` | All traffic |
| **NU**  | `cardinality(data.accountId)` × `date_histogram(@timestamp, 1d)`<br/>filter: `data.requestPath : "/users/create"` | Signups |
| **WAU** | `cardinality(data.userId)` × `date_histogram(@timestamp, 1w)` | ISO weeks |
| **MAU** | `cardinality(data.userId)` × `date_histogram(@timestamp, 1M)` | Calendar months |

Default time range: **last 90 days** (`now-90d/d` → `now`). Adjustable from the dashboard's top-right picker.

Saved object IDs:
- Dashboard: `c92bea18-3810-4082-a2bc-03ae9ff4afc7`
- Lens DAU: `c88bf6ae-a2d3-452b-b072-824c81e65c1a`
- Lens NU:  `b53eb261-c606-41a3-97b1-5cf82ded667e`
- Lens WAU: `a257e5a8-14e8-4c5b-a72f-a438ebe35056`
- Lens MAU: `eb30574c-408d-4687-af70-f8f85a4c65eb`

<br/>

## Time zone

- **Stored**: fluentd normalizes every `@timestamp` to KST (+09:00) ISO8601 → stored internally as UTC epoch in ES.
- **Displayed**: Kibana → Stack Management → Advanced Settings → `dateFormat:tz` (default `Browser`).
- **Bucket boundaries**: The Lens date_histogram follows the display timezone above. Pin `dateFormat:tz` to `Asia/Seoul` if you want KST cohorts regardless of the viewer's browser.

<br/>

## Usage

### 1) Apply dashboards to the cluster (repo → Kibana)

```bash
cd observability/logging/kibana/dashboards
./apply.sh                          # auto-import every *.ndjson except data-view
./apply.sh --file dev-example-project-game-user-metrics.ndjson   # target a specific file
./apply.sh --no-overwrite           # skip if already present
./apply.sh --include-data-view      # also import data-view (fresh Kibana bootstrap)
./apply.sh --dry-run                # print intended calls only
./apply.sh -h                       # full help
```

What it does:
1. Reads the elastic password from `kubectl -n logging get secret elasticsearch-es-elastic-user`.
2. Runs `kubectl exec elasticsearch-es-default-0 -- curl` to hit the Kibana API from inside the cluster (no port-forward).
3. Uploads each NDJSON as `multipart/form-data` to `POST /api/saved_objects/_import?overwrite=true`.

<br/>

### 2) Capture Kibana UI edits back into the repo (Kibana → repo)

```bash
cd observability/logging/kibana/dashboards
./export.sh                         # export every dashboard listed in manifest.txt
./export.sh --id <uuid> --out file.ndjson   # one-off export (ignores manifest)
./export.sh --no-data-view          # skip bootstrap NDJSON
./export.sh --dry-run               # print intended exports only
git diff -- .                       # review changes
git add -- *.ndjson && git commit
```

> ⚠️ `export.sh` **overwrites** the NDJSON with whatever is live in Kibana right now. Inspect `git diff` first if you have unmerged local NDJSON edits.

<br/>

### 3) Rebuild the dashboard from code (build script)

`build-dev-example-project-game.py` (re)creates every constituent of the current dashboard (cohort data view, 5 Lenses, dashboard) via the Kibana API. **You don't need to know any UUID** — they are auto-allocated on first run and cached in `dev-example-project-game.state.json` so re-running is idempotent.

```bash
./build-dev-example-project-game.py             # build (overwrite=true)
./build-dev-example-project-game.py --dry-run   # print intended calls only
./build-dev-example-project-game.py --no-overwrite  # fail if any object already exists
```

Adding a new metric is one entry in the `METRICS` list of the build script:

```python
METRICS = [
    ...,
    {
        "key": "PU",                              # used as the state-file key
        "title": "PU — dev-example-project-game",
        "description": "Paying users per day",
        "data_view": "raw",                       # 'raw' or 'cohort'
        "kind": "simple",                         # 'simple' or 'retention'
        "source_field": "data.accountId",
        "op": "unique_count",
        "interval": "1d",
        "kql_filter": 'data.requestPath : "/payments/checkout"',
        "y_label": "Paying users (unique data.accountId)",
        "panel_title": "PU — Paying Users",
        "grid": {"x": 0, "y": 48, "w": 48, "h": 15},   # new row
    },
]
```

On the next `./build-dev-example-project-game.py` run, only the new key (`PU`) gets a fresh UUID written to the state file; everything else keeps its existing IDs.

### 4) Adding a new dashboard

Recommended flow — **build in the Kibana UI, then capture with `export.sh`**:

1. Kibana → Dashboards → Create dashboard → add panels → Save (prefer the `Dev *` prefix).
2. Grab the new dashboard ID from the URL or saved-object listing.
3. Append a line to `manifest.txt`:
   ```
   <new-dashboard-uuid>  <new-filename>.ndjson
   ```
4. Run `./export.sh` — the new NDJSON appears, existing dashboards' NDJSON also refresh.
5. `apply.sh` automatically picks up the new file on subsequent runs.

Direct API approach (for scripting):

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Create a Lens
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/saved_objects/lens/<uuid>" \
  --data-binary @lens-payload.json

# Overwrite same ID
... -X POST ".../api/saved_objects/lens/<uuid>?overwrite=true" ...

# Dashboards follow the same pattern (type=dashboard)
```

<br/>

## Manifest format (`manifest.txt`)

Used by `export.sh`. One dashboard per line.

```
# leading- or inline-# comments allowed
<dashboard-uuid>  <ndjson-filename>   # use the inline comment to note the title
```

Example:
```
c92bea18-3810-4082-a2bc-03ae9ff4afc7  dev-example-project-game-user-metrics.ndjson   # Dev ExampleProject Game — User Metrics
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
| `DATA_VIEW_FILE` (export.sh) | `dev-example-project-game-data-view.ndjson` | Bootstrap NDJSON filename |

<br/>

## Data view management policy

`dev-example-project-game-data-view.ndjson` is **bootstrap-only**. The normal `apply.sh` run does not import it.

Reason: runtime fields, scripted fields, and formatters that users add through the Kibana UI would be wiped every time the data view is re-imported with `overwrite=true`. The data view was already imported during the ECK migration (Phase 0), so it rarely needs touching.

Use `./apply.sh --include-data-view` only when intentionally resetting the data view.

<br/>

## Roadmap

- **D-1 / D-7 Retention**: Cohort analysis requires an ES Transform pivot job that materializes `dev-example-project-game-user-cohort`, then a Lens chart on top. Transform definitions will live under `observability/logging/elasticsearch/transforms/` (planned).
