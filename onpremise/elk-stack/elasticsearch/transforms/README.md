# Elasticsearch Transforms

Stores definitions of **continuous pivot transforms** that materialize analytics-friendly indices on top of raw log indices like `dev-example-project-game`. Once registered, ES incrementally updates these indices automatically.

Sister component: [kibana/dashboards/](../../kibana/dashboards/) — visualizes these indices. For the division of responsibilities between the two `apply.sh` scripts see [kibana/docs/dashboards-saved-objects-en.md → "Two flavours of apply.sh"](../../kibana/docs/dashboards-saved-objects-en.md#two-flavours-of-applysh-dont-confuse-them).

<br/>

## Directory layout

```
transforms/
├── apply.sh                                # JSON → ES Transform job (PUT + start)
├── export.sh                               # ES Transform → JSON (reverse of apply)
├── dev-example-project-game-user-cohort.json      # Per-user cohort (first_seen, D-1
├── README.md
└── README-en.md
```

`apply.sh` discovers every `*.json` in the directory → uses the filename (without extension) as the transform id → PUT + start.

<br/>

## Current transform: `dev-example-project-game-user-cohort`

Pivots the `dev-example-project-game` index on `data.userId` and emits the cohort-analytics index `dev-example-project-game-user-cohort`.

| Field | Meaning | Computation |
|---|---|---|
| `user_id` | User identifier | `data.userId` (group_by terms) |
| `first_seen` | First activity time | `min(@timestamp)` |
| `last_seen` | Most recent activity time | `max(@timestamp)` |
| `total_events` | Total event count | `value_count(@timestamp)` |
| `active_days_count` | Distinct active days | `cardinality(toLocalDate(@timestamp))` |
| `d1_returning` | D-1 retention flag (0/1) | scripted_metric: 1 if first_seen day + 1 ∈ active-day set |
| `d7_returning` | D-7 retention flag (0/1) | scripted_metric: 1 if first_seen day + 7 ∈ active-day set |

Runtime configuration:
- `frequency: 1h` — sync check every hour
- `sync.time.field: @timestamp`, `delay: 60s` — 1-minute safety margin against out-of-order docs
- continuous mode — only the touched user rows are updated incrementally when new events arrive

Load: per-user partial updates are very light. ~200 active users × 1 hourly pivot = tens of KB of traffic per hour.

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

```bash
# Stop
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" -X POST \
    "https://localhost:9200/_transform/dev-example-project-game-user-cohort/_stop?wait_for_completion=true"

# Restart
kubectl -n logging exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:$PASS" -X POST \
    "https://localhost:9200/_transform/dev-example-project-game-user-cohort/_start"

# Full delete (the destination index must be DELETE'd separately to disappear)
./apply.sh --replace --no-start    # stop+delete then PUT (no start)
# or manually:
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
- **D-N retention horizons**: stored as `params.offset_days` per scripted_metric. To add D-14 or D-30, copy the `d7_returning` block and change the offset.
- **Source query filter**: only docs with `data.userId` are considered (`source.query.filter.exists`). Prevents transform failures on records that lack the field.
- **Frequency 1h**: balances freshness vs. cluster load. New users become visible in the cohort index within ~1 hour. Tighten (e.g., `5m`) only if you need finer granularity.

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

<br/>

## References

- ES Transform docs: https://www.elastic.co/guide/en/elasticsearch/reference/current/transforms.html
- scripted_metric aggregation: https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-scripted-metric-aggregation.html
- Visualization side of this repo: [dashboards-saved-objects-en.md](../../kibana/docs/dashboards-saved-objects-en.md)
