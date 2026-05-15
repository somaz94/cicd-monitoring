# Kibana Dashboards NDJSON Workflow

Documents the internal logic and operational procedures for the **declarative Saved Objects** (Lens + Dashboard) managed under `observability/logging/kibana/dashboards/`. For usage itself see [dashboards/README-en.md](../dashboards/README-en.md); this document covers the *internals*.

<br/>

## Why manage as NDJSON

| Aspect | UI-only | NDJSON + repo (current) |
|---|---|---|
| Change tracking | Kibana audit log only (lossy) | git diff is authoritative |
| Reproducibility | Hand-recreate on a new cluster | `apply.sh` once |
| Review | Screenshots | PR diff |
| Rollback | Separate export/import dance | `git revert` + `apply.sh` |

Trade-off: when users edit through the UI, they must remember to run `export.sh` afterwards. Could be automated later with cron / hooks.

<br/>

## Two flavours of `apply.sh` (don't confuse them)

There are two `apply.sh` files in the repo, dealing with completely different resources.

| | [kibana/dashboards/apply.sh](../dashboards/apply.sh) | [elasticsearch/transforms/apply.sh](../../elasticsearch/transforms/apply.sh) |
|---|---|---|
| Target | **Kibana saved objects** (Lens, Dashboard, Data view) | **ES Transform job** (continuous pivot) |
| API | `POST http://kibana-kb-http:5601/api/saved_objects/_import` | `PUT https://elasticsearch:9200/_transform/<id>` + `_start` |
| Storage | Kibana `.kibana_*` system index | ES `_transform` metadata + dest index (e.g. `dev-example-project-game-user-cohort`) |
| Input file | `*.ndjson` (Kibana export format) | `*.json` (ES Transform definition) |
| Responsibility | "How it looks" (visualization) | "How it's pre-shaped" (data shaping) |
| Dependency direction | Visualizes the transform output ← | Independent (cohort index builds even without Kibana) |
| Failure impact | Blank Lens chart | Stale cohort index |

Workflow order: **Transform first (materialize the data) → Saved Object (visualize on top)**. Fresh-environment bootstrap:

```bash
# 1) Data side
cd observability/logging/elasticsearch/transforms && ./apply.sh

# 2) Visualization side
cd ../../kibana/dashboards && ./apply.sh --include-data-view   # first bootstrap only
```

<br/>

## End-to-end flow

```
                ┌─────────────────────────────────────────┐
                │            Kibana (logging ns)          │
                │  - lens
                │  - .kibana_* internal index             │
                └────────┬─────────────────────────▲──────┘
                         │ POST /_export           │ POST /_import
                         ▼                         │
                    export.sh                  apply.sh
                         │                         ▲
                         ▼                         │
                 *.ndjson  ◀── repo (git) ──▶  *.ndjson
                       (kibana/dashboards/)
```

- A person edits a dashboard in the UI → `export.sh` → updated NDJSON in repo → git commit.
- On a different environment (or a fresh Kibana) → git pull → `apply.sh` → identical dashboard recreated.

<br/>

## NDJSON format

Kibana export uses newline-delimited JSON — one object per line. Our `dev-pm-retention-dashboard.ndjson` looks like:

```
{ "type": "visualization", "id": "dev-pm-retention-…", "attributes": {…}, "references": [{…}] }  ← 7 Vega
…
{ "type": "lens",          "id": "dev-pm-retention-…", "attributes": {…}, "references": [{…}] }  ← 3 Lens
…
{ "type": "dashboard",     "id": "dev-pm-retention-dashboard", "attributes": {…}, "references": [{…}] }
{ "excludedObjects": [], "exportedCount": 11, "missingReferences": [], … }    ← summary
```

Key invariants:
- `id` is deterministic (UUID). Same ID PUT/POST is idempotent.
- `references` glue the saved objects and data views together.
- The last line is the export summary (only present when `excludeExportDetails: false`). Harmless for `apply.sh` import.

<br/>

## API endpoints

| Operation | Method + path | Notes |
|---|---|---|
| Create one saved object | `POST /api/saved_objects/<type>/<id>` | Body: `{"attributes": …, "references": […]}` |
| Overwrite one | `POST /api/saved_objects/<type>/<id>?overwrite=true` | Replaces if same id exists |
| Partial update | `PUT /api/saved_objects/<type>/<id>` | Sub-set of `attributes` keys is allowed |
| Bulk export (NDJSON) | `POST /api/saved_objects/_export` | Body: `{"objects":[{"type":"dashboard","id":"…"}],"includeReferencesDeep":true}` |
| Bulk import (NDJSON) | `POST /api/saved_objects/_import?overwrite=true` | `multipart/form-data` `file` field |
| Single fetch | `GET /api/saved_objects/<type>/<id>` | |
| List | `GET /api/saved_objects/_find?type=dashboard` | Paginated |

Every call needs the `kbn-xsrf: true` header. Auth as the `elastic` user (secret `elasticsearch-es-elastic-user`, key `elastic`).

Where the call runs: `kubectl exec elasticsearch-es-default-0 -- curl ...` — from inside the ES pod to Kibana's ClusterIP DNS. No port-forward needed.

<br/>

## Core Saved Object schema

### Lens (`type: "lens"`)

```jsonc
{
  "type": "lens",
  "id": "<uuid>",
  "attributes": {
    "title": "DAU — dev-example-project-game",
    "visualizationType": "lnsXY",        // chart type: lnsXY, lnsMetric, lnsPie, lnsDatatable, …
    "state": {
      "datasourceStates": {
        "formBased": {
          "layers": {
            "layer1": {                  // arbitrary layerId
              "columnOrder": ["col_x","col_y"],
              "columns": {
                "col_x": {
                  "operationType": "date_histogram",
                  "sourceField": "@timestamp",
                  "params": {"interval": "1d"},
                  "isBucketed": true
                },
                "col_y": {
                  "operationType": "unique_count",
                  "sourceField": "data.userId",
                  "isBucketed": false
                }
              }
            }
          }
        }
      },
      "visualization": { … },             // chart layout info
      "query": {"query":"", "language":"kuery"},
      "filters": []
    }
  },
  "references": [
    {
      "id": "<data-view-uuid>",
      "name": "indexpattern-datasource-layer-layer1",   // ⚠ fixed format
      "type": "index-pattern"
    }
  ]
}
```

Key points:
- The `formBased.layers.<layerId>` key must exactly match `references[].name`'s `indexpattern-datasource-layer-<layerId>` suffix.
- The data view is glued in via `references` only — no index name appears in the chart proper, so changing data view IDs only touches `references`.

### Dashboard (`type: "dashboard"`)

```jsonc
{
  "type": "dashboard",
  "id": "<dash-uuid>",
  "attributes": {
    "title": "Game User Matric & Retention",
    "panelsJSON": "[…]",                  // string-escaped JSON (that's how Kibana stores it)
    "timeRestore": true,
    "timeFrom": "now-30d",
    "timeTo":   "now",
    "kibanaSavedObjectMeta": {
      "searchSourceJSON": "{\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
    }
  },
  "references": [
    {
      "id": "<lens-uuid>",
      "name": "<panelIndex>:panel_<panelIndex>",   // ⚠ fixed format
      "type": "lens"
    }
  ]
}
```

After parsing `panelsJSON`, each panel:

```jsonc
{
  "version": "9.3.3",
  "type": "lens",
  "gridData": {"x":0,"y":0,"w":24,"h":15,"i":"<panelIndex>"},
  "panelIndex": "<panelIndex>",
  "embeddableConfig": {"enhancements": {}},
  "panelRefName": "panel_<panelIndex>",   // ⚠ matches the tail of references[].name
  "title": "DAU — Daily Active Users"
}
```

Key points:
- `panelIndex` is an arbitrary identifier (UUID recommended).
- `panelRefName` follows `panel_<panelIndex>`.
- If the same lens is referenced twice in the same dashboard, you need two distinct panelIndex values and two reference entries.

### Index pattern / Data view (`type: "index-pattern"`)

```jsonc
{
  "type": "index-pattern",
  "id": "<data-view-uuid>",
  "attributes": {
    "title": "dev-example-project-game",            // ⚠ actual ES index pattern (wildcards allowed)
    "name":  "dev-example-project-game-logs",       // ⚠ label shown in the Kibana UI
    "timeFieldName": "@timestamp",
    "typeMeta": {}
  }
}
```

Here `title ≠ name` is possible — `title` is the actual index, `name` is the UI label. The Phase 0 migration resolved this mismatch.

<br/>

## How this repo wires it up

### `apply.sh`

```
1) kubectl get secret elasticsearch-es-elastic-user → elastic password
2) Glob *.ndjson in the directory (excluding *-data-view.ndjson, opt-in)
3) For each file → kubectl exec elasticsearch-es-default-0 -- curl
              -X POST  http://kibana-kb-http.logging.svc:5601/api/saved_objects/_import?overwrite=true
              -F file=@-;filename=…;type=application/ndjson
              < <ndjson>
4) Validate response { "success": true, "successCount": N }
```

### `export.sh`

```
1) Resolve password
2) Read manifest.txt (one dashboard per line)  OR  --id/--out flags
3) For each dashboard id → POST /api/saved_objects/_export (includeReferencesDeep:true)
   Response: NDJSON (data-view + lens objects + dashboard + summary)
4) Split response into two:
   - lens + dashboard → designated *.ndjson
   - index-pattern (data view) → example-project-game-data-view.ndjson (merged + dedup across all dashboards)
5) Recompute summary's exportedCount and append
```

### `manifest.txt`

```
# comments allowed
<dashboard-uuid>  <ndjson-filename>   # use inline comment for the title
```

Adding more dashboards = add more lines; `export.sh` exports them all in one shot.

<br/>

## Adding a new visualization or dashboard

### Path A — build in the UI, then capture (recommended)

1. Kibana → Dashboards → Create dashboard → add Lens → Save.
   - Use the `Dev *` prefix in the title.
2. Grab `<uuid>` from `…/app/dashboards#/view/<uuid>`.
3. Append a line to `dashboards/manifest.txt`: `<uuid>  <filename>.ndjson  # title`.
4. `./export.sh` → NDJSON appears.
5. `git add -- *.ndjson manifest.txt && git commit`.
6. Apply elsewhere via `git pull && ./apply.sh`.

### Path B — write via API (scriptable)

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
LENS_ID=$(uuidgen | tr 'A-Z' 'a-z')
DASH_ID=$(uuidgen | tr 'A-Z' 'a-z')

# Author the Lens payload (see schema above)
cat > /tmp/lens.json <<EOF
{ "attributes": { "title": "…", "visualizationType": "lnsXY", "state": {…} },
  "references": [{ "id": "<data-view-uuid>", "name": "indexpattern-datasource-layer-layer1", "type": "index-pattern" }] }
EOF

# PUT (= create with explicit id)
kubectl -n logging exec -i elasticsearch-es-default-0 -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/saved_objects/lens/${LENS_ID}" \
  --data-binary @/tmp/lens.json

# Dashboard follows the same pattern (type=dashboard, panelsJSON references the lens)
…

# Finally update manifest.txt and run export.sh to sync NDJSON.
```

> Never hand-author NDJSON. Always source it from a live Kibana via `export.sh`.

<br/>

## Data view NDJSON automation

> "Is the data view NDJSON also automated?" — **Yes, already.**

Core mechanism: `export.sh`'s `includeReferencesDeep: true` flag walks dashboard references depth-first → lens → data view, then splits the result and writes to `example-project-game-data-view.ndjson`.

```
Kibana dashboard
   └─ references: lens IDs
        └─ Lens
             └─ references: data view ID  ← auto-captured here
```

When multiple dashboards reference multiple data views, `export.sh` merges all the raw exports and dedupes → single NDJSON file holds them all (currently 2: `dev-example-project-game`, `dev-example-project-game-user-cohort`).

### Automating "first creation"

`export.sh` captures *existing* data views. Creating a new one for the first time still uses one of:

| Method | Command | Notes |
|---|---|---|
| **UI** | Stack Management → Data Views → Create | Most intuitive, one-off |
| **Direct API** | `POST /api/data_views/data_view` (example below) | Scriptable |
| **Hand-author NDJSON** | Not recommended | Schema-error prone |

API example (the exact flow used to create the cohort data view):

```bash
DV_ID=$(uuidgen | tr 'A-Z' 'a-z')
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

cat > /tmp/dv.json <<EOF
{
  "data_view": {
    "id": "$DV_ID",
    "title": "dev-example-project-game-user-cohort",
    "name":  "dev-example-project-game-user-cohort-logs",
    "timeFieldName": "first_seen"
  },
  "override": false
}
EOF

kubectl -n logging exec -i elasticsearch-es-default-0 -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X POST "http://kibana-kb-http.logging.svc:5601/api/data_views/data_view" \
  --data-binary @/tmp/dv.json
```

After that, add a Lens referencing the new data view in your dashboard and run `export.sh` — the data view will be captured automatically.

### Applying (recreate elsewhere)

```bash
cd observability/logging/kibana/dashboards
./apply.sh --include-data-view     # import data view + lens + dashboard
```

The `*-data-view.ndjson` pattern is excluded from the default `apply.sh` run (opt-in). Reasoning is in [dashboards/README-en.md → Data view management policy](../dashboards/README-en.md#data-view-management-policy).

<br/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `apply.sh` → `"missingReferences"` | A referenced data view is absent from Kibana. Use `./apply.sh --include-data-view` to import it alongside, or create it in the UI first. |
| `apply.sh` → `"version conflict"` | Object with same ID exists. With `overwrite=true` (default) it shouldn't. If you used `--no-overwrite` it's expected. |
| Lens shows "No data" | Either the references' data view ID disagrees with Kibana's, or the ES index is empty. Use raw `_search` to inspect. |
| Lens X axis is empty | `formBased.layers.<layerId>.columnOrder` and the visualization layer's `xAccessor` point at different column ids. |
| Dashboard doesn't render panel | `panelsJSON.panelRefName` and `references[].name` are out of sync. Verify `panel_<panelIndex>` and `<panelIndex>:panel_<panelIndex>`. |
| 405 / 406 on Kibana call | Missing `kbn-xsrf: true` header. |
| TLS handshake error (`exit 35`) | You called `https://` but Kibana serves plain HTTP — use `http://kibana-kb-http.logging.svc:5601`. |

<br/>

## References

- Kibana 9.x Saved Objects API: https://www.elastic.co/docs/api/doc/kibana/group/endpoint-saved-objects
- Lens state schema is poorly documented officially — in practice, the safest workflow is to build in the UI and capture via `export.sh`.
- For data views over `transform` output indices (e.g. `dev-example-project-game-user-cohort`), a separate data view must be created. `dashboards/example-project-game-data-view.ndjson` here is bootstrap-only.
