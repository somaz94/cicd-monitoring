# Elasticsearch Transforms

Stores definitions of **continuous pivot transforms** that materialize analytics-friendly indices on top of raw log indices like `dev-example-project-game`. Once registered, ES incrementally updates these indices automatically.

Sister component: [kibana/dashboards/](../../kibana/dashboards/) — visualizes these indices (`dev-pm-retention-dashboard`

<br/>

## Directory layout

```
transforms/
├── apply.sh                                       # JSON → ES Transform job (PUT + start)
├── export.sh                                      # ES Transform → JSON (reverse of apply)
├── dev-example-project-game-user-cohort.json             # Per-user atomic-facts pivot
├── dev-example-project-game-user-cohort.mapping.json     # Explicit mapping for the dest index
├── qa-example-project-game-user-cohort.json
├── qa-example-project-game-user-cohort.mapping.json
├── README.md
└── README-en.md
```

`apply.sh` discovers every `*.json` in the directory (excluding `*.mapping.json`) → uses the filename (without extension) as the transform id → if a sibling `*.mapping.json` exists and the dest index is absent, PUT the mapping first → then PUT the transform + start.

<br/>

## Current transform: `dev-example-project-game-user-cohort`

Pivots the `dev-example-project-game` index on `data.userId` and emits the cohort-analytics index `dev-example-project-game-user-cohort`. The destination index is queried directly by the Retention Curve / Daily Cohort Retention panels of [dev-pm-retention-dashboard](../../kibana/dashboards/dev-pm-retention-dashboard.ndjson). QA follows the same pattern: `qa-example-project-game-user-cohort.json` + [qa-pm-retention-dashboard](../../kibana/dashboards/qa-pm-retention-dashboard.ndjson).

| Field | Meaning | Computation |
|---|---|---|
| `user_id` | User identifier | `data.userId` (group_by terms) — dest mapping pins as `keyword` |
| `first_seen` | First signup time | scripted_metric — earliest `@timestamp` of a `/users/create` event for the user. `null` if the user never signed up |
| `last_seen` | Most recent activity time | `max(@timestamp)` |
| `total_events` | Total event count | `value_count(@timestamp)` |
| `active_days_count` | Distinct active days | `cardinality(toLocalDate(@timestamp))` |
| `active_dates` | List of active dates (`YYYY-MM-DD` strings) | scripted_metric — distinct set of `toLocalDate(@timestamp)`. **Dest mapping MUST pin as `keyword`** (if inferred as date the dashboard's retention runtime fields fall back to `String == ZonedDateTime` and emit 0 for every horizon) |
| `max_cleared_chapter` | Highest chapter cleared | `max(lastClearedChapter)` — runtime field that parses `lastClearedChapter` integer from the `/adventures/clear` responseBody |

> Retention itself (D-1 … D-30 returning flags) is **NOT computed by the transform**. The transform only freezes the two atomic facts above (`active_dates` + `first_seen`); the **Kibana data view runtime fields `d1_live..d30_live`** compute retention at visualization time by checking whether `first_seen + N day` appears in `active_dates`. See [kibana/docs/pm-retention-dashboard-template-en.md](../../kibana/docs/pm-retention-dashboard-template-en.md) for the full split.

Runtime configuration:
- `frequency: 5m` — sync check every 5 minutes
- `sync.time.field: @timestamp`, `delay: 60s` — 1-minute safety margin against out-of-order docs
- continuous mode — only the touched user rows are updated incrementally when new events arrive

Key rules of the signup anchor:
- **Anchor**: `first_seen` is not `min(@timestamp)` but the **first occurrence per user of `params.path` (`/users/create`)**.
- **Null handling**: a user with no signup event ever yields `first_seen = null` → the data view runtime fields `d{N}_live` early-return → ES `avg()` automatically skips them → Retention Curve / Daily Table divisor naturally reduces to "signed-up users only".
- **Timezone**: `params.tz = "Asia/Seoul"` sets the day-boundary. To change, update the transform's `active_dates.scripted_metric.params.tz` together with every `d{N}_live` runtime field's `ZoneId.of(...)` on the cohort data view. Full procedure in [kibana/docs/timezone-toggle-en.md](../../kibana/docs/timezone-toggle-en.md).
- **Adding a horizon** (e.g. D-60): add a single `d60_live` runtime field on the cohort data view (the transform stays untouched). Also extend the Retention Curve Vega's N range to match.

Load: per-user partial updates are very light. ~200 active users × 1 pivot every 5 minutes = tens of KB of traffic per hour.

<br/>

## Dest-index mapping — `<id>.mapping.json`

Place a sibling **`<id>.mapping.json`** next to each transform definition (`<id>.json`); `apply.sh` and `scripts/reset-example-project-cohort.sh` will PUT it before the dest index is created.

**Why it is required**: if the transform alone is PUT and the dest index is left to ES dynamic mapping, `active_dates` (ISO-date strings) gets auto-inferred as `date`. The cohort data view runtime fields `d1_live..d30_live` then compare `String == ZonedDateTime`, always emit 0, and **every retention metric silently flat-lines at 0**. The dashboard renders normally but every curve sits on the X axis — this took 5 days to notice in the 2026-05-22 QA cohort incident.

**apply.sh behaviour**:
- Dest index **absent** → PUT mapping → PUT transform + start.
- Dest index **present** → skip mapping PUT (ES does not allow live property-type changes). To actually replace the mapping use the workflow: `scripts/restart-transform.sh <id> --stop-only` → `DELETE /<dest-index>` → `apply.sh --file <id>.json --replace`.

**File shape** (identical across dev

```json
{
  "settings": { "number_of_shards": 1, "number_of_replicas": 1 },
  "mappings": {
    "_meta": { "managed_by": "...", "purpose": "..." },
    "properties": {
      "user_id":             { "type": "keyword" },
      "first_seen":          { "type": "date" },
      "last_seen":           { "type": "date" },
      "active_dates":        { "type": "keyword" },
      "active_days_count":   { "type": "long" },
      "total_events":        { "type": "long" },
      "max_cleared_chapter": { "type": "float" }
    }
  }
}
```

<br/>

## Usage

### 1) Apply / start

```bash
cd observability/logging/elasticsearch/transforms
./apply.sh                          # PUT + start every *.json (skip if already present)
./apply.sh --file dev-example-project-game-user-cohort.json   # target a specific definition
./apply.sh --preview-only           # just call _preview (no PUT, validation only)
./apply.sh --replace                # stop + delete + re-PUT (use after definition changes)
./apply.sh --no-start               # register only, do not start
./apply.sh --dry-run                # print intended calls only
./apply.sh -h                       # full help
```

### 2) Status check

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Transform metadata + state
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" "https://localhost:9200/_transform/dev-example-project-game-user-cohort"

# Runtime stats (docs_processed / indexed / failures)
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" "https://localhost:9200/_transform/dev-example-project-game-user-cohort/_stats"

# Destination index
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" "https://localhost:9200/_cat/indices/dev-example-project-game-user-cohort?v"
```

### 3) Stop / restart / delete

`scripts/restart-transform.sh` wraps stop + `_reset` + start in a single call. `_reset` clears the in-memory checkpoint and stats so the next start replays the full source index — the canonical workflow after a dest-index mapping swap or a transform definition change.

```bash
cd observability/logging/elasticsearch/scripts

# Stop + _reset + start (interactive prompt — type 'restart <id>')
./restart-transform.sh dev-example-project-game-user-cohort

# Stop only (first step of the DELETE dest + apply.sh --replace workflow)
./restart-transform.sh dev-example-project-game-user-cohort --stop-only -y

# Dry-run to inspect the planned calls
./restart-transform.sh dev-example-project-game-user-cohort --dry-run -y
```

Low-level curl pattern (legacy, pre-script):

```bash
# Full delete (the destination index must be DELETE'd separately to disappear)
./apply.sh --replace --no-start    # stop+delete then PUT (no start)
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" -X DELETE \
    "https://localhost:9200/_transform/dev-example-project-game-user-cohort?force=true"
```

### 4) Re-applying after a definition edit

Transform definitions are immutable once registered — to edit, follow this flow:

```bash
# 1) Edit the JSON
vi dev-example-project-game-user-cohort.json

# 2) Validate via preview
./apply.sh --preview-only

# 3) Re-register with --replace (stop + delete + PUT + start)
./apply.sh --replace
```

`--replace` discards the existing transform's checkpoint. Data already in the destination index (`dev-example-project-game-user-cohort`) stays in place; the transform re-traverses source from the start and overwrites.

### 4a) Changing the dest-index mapping

ES does not allow live property-type changes, so to swap the mapping the dest index has to be emptied:

```bash
cd observability/logging/elasticsearch/scripts

# 1) Stop the transform only (start happens later)
./restart-transform.sh dev-example-project-game-user-cohort --stop-only

# 2) DELETE the dest index — no data loss (the transform rebuilds it from the source index)
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" -X DELETE \
    "https://localhost:9200/dev-example-project-game-user-cohort"

# 3) (Optional) edit transforms/dev-example-project-game-user-cohort.mapping.json

# 4) apply.sh PUTs the mapping first, then re-PUTs the transform + starts it
cd ../transforms
./apply.sh --file dev-example-project-game-user-cohort.json --replace
```

### 5) Pull cluster state back to repo (reverse sync)

```bash
./export.sh                         # re-pull every *.json present here
./export.sh --id dev-example-project-game-user-cohort   # specific id
./export.sh --dry-run               # print only
```

The exporter strips runtime metadata (create_time, version, etc.) and keeps only user-supplied fields.

<br/>

## Adding a new transform

1. Create a new `<name>.json` (the file basename becomes the id).
2. `./apply.sh --preview-only --file <name>.json` to validate the output.
3. `./apply.sh --file <name>.json` to register.
4. On the Kibana side, create a data view for the destination index (UI or API), then add a Lens under [dashboards/](../../kibana/dashboards/).

> Creating the Kibana data view is out of scope for this directory. Make the new destination index's data view via the Kibana UI or API, then capture it as NDJSON with `dashboards/export.sh --include-data-view`.

<br/>

## Environment variables

| Var | Default | Description |
|---|---|---|
| `NAMESPACE` | `logging` | |
| `ES_POD` | `elasticsearch-es-default-0` | Pod used to run curl |
| `ES_CONTAINER` | `elasticsearch` | |
| `ES_SVC` | `localhost` | Reached from inside the ES pod, so localhost is the default |
| `ES_PORT` | `9200` | |
| `ES_SCHEME` | `https` | ECK self-signed cert — curl uses `-k` |
| `ES_SECRET` | `elasticsearch-es-elastic-user` | ECK-managed secret |
| `ES_USER` | `elastic` | |

<br/>

## Design choices

- **`params.tz` indirection**: every day-boundary calculation uses `scripted_metric`
- **D-N retention horizons**: stored as `params.offset_days` per scripted_metric. The current definition covers D-1 … D-30. To add D-60 / D-90, copy any `dN_returning` block and change `offset_days`.
- **Signup-anchored cohort**: D-N counts only users with a `/users/create` event (anchored via `params.path`). Users without a signup event return `null`, so ES `avg()` excludes them automatically.
- **Source query filter**: only docs with `data.userId` are considered (`source.query.filter.exists`). Prevents transform failures on records that lack the field.
- **Frequency 5m**: matches the live cluster (was `1h` historically). Tighten further only when finer granularity is needed; widen if cluster load becomes an issue.

<br/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `script_exception` from `_preview` | Painless syntax error in scripted_metric. Check that `reduce_script` handles the `states` (list of combine outputs) properly. |
| state `failed` | Check `_stats` for `node`
| Dest index stays empty | Either `sync.time.field` (`@timestamp`) is missing/typed differently in source, or `delay` is too long for anything to be visible yet. |
| Edited the JSON but no effect | Transforms are immutable — use `./apply.sh --replace`. |
| Backfill is slow | Increase `settings.max_page_search_size` (default 500). Watch cluster load. |
| Fewer rows than expected | `source.query` filter is too strict. Verify via `--preview-only` and relax the query. |
| `null_pointer_exception` in reduce_script | `combine_script` returned an empty list and `reduce_script` doesn't handle it. Add `if (states.isEmpty()) return 0L;`. |
| **Retention metrics all render as 0** (flat Curve, all-zero Daily Table) | `active_dates` in the dest mapping was inferred as `date`. Check: `GET /<env>-example-project-game-user-cohort/_mapping` → `active_dates.type == "date"` is the hit. Fix: `restart-transform.sh <id> --stop-only` → `DELETE /<dest-index>` → `apply.sh --file <id>.json --replace` (the sibling `.mapping.json` is PUT automatically). |
| Bare `_start` does nothing after I deleted the dest index | The transform's in-memory checkpoint is still alive, so it tries to resume from the old `time_upper_bound`. Use `restart-transform.sh <id>` (= stop + `_reset` + start) so the next start replays the full source. |

<br/>

## References

- ES Transform docs: https://www.elastic.co/guide/en/elasticsearch/reference/current/transforms.html
- scripted_metric aggregation: https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-scripted-metric-aggregation.html
- Visualization side of this repo: [dashboards-saved-objects-en.md](../../kibana/docs/dashboards-saved-objects-en.md)
