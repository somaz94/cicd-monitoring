# pm-retention-dashboard — Prod templating guide

Analysis and qa/prod-portable templating of the Kibana dashboard `Game User Matric & Retention` (slug `<env>-pm-retention-dashboard`) that is currently live on the dev cluster. Captures the **data sources

<br/>

## One-line summary

`<env>-pm-retention-dashboard` = (1) six KPI Vega cards + two Trend Lenses on top of the raw `dev-example-project-game` index, (2) a D+1..D+30 Retention Curve (Vega) + a Daily Cohort Retention table (Lens) on top of `dev-example-project-game-user-cohort` (transform output). Default time range: `now-30d ~ now`.

<br/>

## TL;DR — "Do I really just rename the index?"

**Yes — as long as the schema matches, swapping the index name + saved-object id prefix is enough.** Verified end-to-end on the QA environment (`qa-example-project-game`) — full results in [§Validation result](#validation-result--qa-example-project-game-import-completed).

Five substitutions:

| # | Substitution | Example |
|---|---|---|
| 1 | Raw index name | `dev-example-project-game` → `<env>-example-project-game` |
| 2 | Cohort index name + transform id | `dev-example-project-game-user-cohort` → `<env>-example-project-game-user-cohort` |
| 3 | Kibana data view UUID (raw / cohort) | new UUIDs issued on the target cluster |
| 4 | Dashboard
| 5 | (Optional) KPI card 4-color palette | per-env visual cue — dev/qa/prod different palettes recommended |

Things that do **not** need to change (env-invariant):

- Time range (`now-30d ~ now`), `timeRestore`
- Field names: `data.userId` / `data.requestPath` / `data.statusCode`
- `params.tz = "Asia/Seoul"` (matches fluentd KST normalisation)
- `params.path = "/users/create"` (assumes signup endpoint matches across envs)
- Vega / Lens visualization body (axes, marks, columns)

Full compatibility check in [§Compatibility checklist](#compatibility-checklist).

<br/>

## Compatibility checklist

Run through this before applying to a prod (or qa) cluster:

### A. Raw index schema (required)

| Field | Type | Used for | If missing |
|---|---|---|---|
| `@timestamp` | `date` | every KPI / Trend / Transform | nothing works |
| `data.userId` | `long` or `keyword` | KPI cardinality, Trend Lens unique_count, Transform `group_by`, Transform source `exists` | nothing works |
| `data.requestPath` | `text` | NU KPI human readability (optional) | irrelevant if KPI only reads keyword |
| `data.requestPath.keyword` | `keyword` (multi-field) | **Transform scripted_metric** (`doc['data.requestPath.keyword']`), NU KPI `term` filter | **Transform fails to boot** (the most common prod-rollout failure) |
| `data.accountId` | `long` or `keyword` | (not used by this dashboard — reserved for sibling metrics) | no effect |
| `data.statusCode` | `long` | DAU Trend Lens KQL `< 4` | drop that KQL clause if missing |

> **Check command**: `GET /<RAW_INDEX>/_mapping`, confirm all fields exist under `properties.data.properties`, and `requestPath.fields.keyword` sub-field is present.

### B. Ingest assumptions

| Item | Assumption | If different |
|---|---|---|
| timezone normalisation | fluentd writes `@timestamp` normalised to KST(+09:00) before ES | adjust the transform's `params.tz` to the actual data zone (ES converts internally, only the *value* needs to match) |
| signup endpoint | `/users/create` is the new-user event (`data.requestPath` value) | swap the transform's `params.path` and the NU KPI's three `term` filters together |
| health-check endpoint | `/api/health`, `/api/stats` are operational polling | adjust the DAU Trend KQL exclude clause |
| signup-event retention window | the cohort transform needs the signup events to still exist in the raw index at run time to anchor the cohort | if ILM expires signup events first, D-N anchoring breaks — keep `/users/create` retained even when other events expire |

### C. ECK / Kibana versions

| Item | Verified version |
|---|---|
| Elasticsearch | 9.x (ECK operator-managed) |
| Kibana | 9.3.x — uses Vega plugin `%context%` / `%timefield%` |
| ES Transform | continuous mode + scripted_metric (works on 7.x+, 9.x recommended) |

### D. Capacity / ops considerations

- If prod `data.userId` cardinality is much larger than dev/qa, raise transform `max_page_search_size` (currently 500) and expect a longer backfill. Start `frequency` at `1h` and shorten gradually under load-busy environments.

<br/>

## Validation result — `qa-example-project-game` (import completed)

The template was **validated end-to-end on QA — full dashboard imported and verified** (`2026-05-13`):

| Check | Result |
|---|---|
| Index existence + health | `qa-example-project-game` open / yellow, 16,021 docs / 11.5 MB |
| Core field schema | matches dev — `@timestamp:date`, `data.userId:long`, `data.requestPath:text + .keyword` multi-field, `data.statusCode:long` |
| `/users/create` events | 31 hits / 30 unique `data.userId` (signup events present) |
| Transform `qa-example-project-game-user-cohort` | PUT + start succeeded, state=started, checkpoint=1, docs_processed=13,646, docs_indexed=33, failures=0 |
| Cohort index `qa-example-project-game-user-cohort` | 33 rows (= preview's 33), `first_seen`, `total_events`, `d1_returning..d30_returning` populated |
| Avg retention agg (whole cohort) | D+1=16.7%, D+7=13.3%, D+30=0% (cohort has not reached D+30 yet) |
| Cohort data view `qa-example-project-game-user-cohort-logs` | includes `cohort_date` runtime keyword field, time field `first_seen` |
| Dashboard `qa-pm-retention-dashboard` | NDJSON import succeeded (7 viz + 3 lens + 1 dashboard, all references mapped correctly) — title `QA — Game User Matric & Retention` |
| Daily Cohort Retention grouping (uses `cohort_date`) | 10 cohort-day rows produced (e.g. `2026-04-30` NU=12 / D+1=16.7% / D+7=16.7%) |

**Conclusion**: against a target environment with matching schema, the template needs only **index prefix + saved-object id prefix + data view UUID** substitutions to fully work. Prod will work the same way if it uses the same fluentd/fluent-bit pipeline.

Live URL: `http://kibana.example.com/app/dashboards#/view/qa-pm-retention-dashboard`.

> The actual commands used for QA are exactly Steps 1~3 of [§Prod migration recipe](#prod-migration-recipe) (substitute index names

<br/>

## Data flow

```
NFS log files
   │  fluent-bit tail → fluentd normalisation
   ▼
ES index: dev-example-project-game            ◀── raw events
   │
   │ [ES Transform: dev-example-project-game-user-cohort]
   │  continuous, frequency 5m, sync.delay 60s
   ▼
ES index: dev-example-project-game-user-cohort  ◀── 1 row = 1 user
                                            (first_seen, total_events, d1_returning … d30_returning)
                                            anchor = day of first /users/create event
   │
   ▼ Kibana data view (runtime field: cohort_date)
Kibana dashboard: <env>-pm-retention-dashboard
```

<br/>

## Dashboard layout (10 panels, 48-grid)

Coordinates are Kibana grid (48 columns). `y` grows downward.

| Row | y | h | Panel | Kind | (x, w) | saved-object id (per-env prefix) | Data source |
|---|---|---|---|---|---|---|---|
| 1 | 0 | 7 | **NU (Today)** | Vega-Lite | (0,12) | `<env>-pm-retention-nu-today` | raw |
| 1 | 0 | 7 | **NU (Last 7d)** | Vega-Lite | (12,12) | `<env>-pm-retention-nu-7d` | raw |
| 1 | 0 | 7 | **NU (Last 30d)** | Vega-Lite | (24,12) | `<env>-pm-retention-nu-30d` | raw |
| 2 | 7 | 7 | **DAU** | Vega-Lite | (0,12) | `<env>-pm-retention-dau-today` | raw |
| 2 | 7 | 7 | **WAU** | Vega-Lite | (12,12) | `<env>-pm-retention-wau-7d` | raw |
| 2 | 7 | 7 | **MAU** | Vega-Lite | (24,12) | `<env>-pm-retention-mau-30d` | raw |
| 3 | 14 | 11 | **NU Trend (30d)** | Lens (lnsXY) | (0,25) | `<env>-pm-retention-nu-trend` | raw |
| 3 | 14 | 11 | **DAU Trend** | Lens (lnsXY) | (25,23) | `<env>-pm-retention-dau-trend` | raw |
| 4 | 25 | 14 | **Average Retention Curve (D+1..D+30)** | Vega (full) | (0,48) | `<env>-pm-retention-curve` | cohort |
| 5 | 39 | 15 | **Daily Cohort Retention (table)** | Lens (lnsDatatable) | (0,48) | `<env>-pm-retention-daily-table` | cohort |

> Dashboard saved-object id: `<env>-pm-retention-dashboard` (slug)
> Description (verbatim): *"All live — DAU/WAU/MAU/DAU Trend/Stickiness/DAU breakdown query raw events, NU + cohort retention query the dev-example-project-game-user-cohort transform."*

<br/>

## Data sources

### 1) Raw game-event index

| Item | Value |
|---|---|
| ES index | `dev-example-project-game` |
| Kibana data view | `dev-example-project-game-logs` (id `b50c59ea-73c1-4feb-8b42-d642248c8647`) |
| Ingest path | fluent-bit (NFS tail) → fluentd → ES |
| Fields used | `@timestamp` (date, normalised to KST), `data.userId`, `data.accountId`, `data.requestPath` + `.keyword`, `data.statusCode` |

### 2) ES Transform (cohort pivot)

Definition is stored at [`elasticsearch/transforms/dev-example-project-game-user-cohort.json`](../../elasticsearch/transforms/dev-example-project-game-user-cohort.json) — **but the live cluster has drifted past the repo copy** (see *drift* section below).

Live spec (`kubectl ... GET /_transform/dev-example-project-game-user-cohort`):

| Item | Value |
|---|---|
| Source | `dev-example-project-game`, query `exists(data.userId)` |
| Group by | `user_id` (terms on `data.userId`) |
| Aggregations | `first_seen` (min @timestamp), `last_seen` (max), `total_events` (value_count), `active_days_count` (cardinality of KST local-date string), `d1_returning … d30_returning` (30 scripted_metric blocks) |
| Dest | `dev-example-project-game-user-cohort` |
| Frequency | `5m` (live) |
| Sync | `time.field: @timestamp`, `delay: 60s` |
| Settings | `max_page_search_size: 500` |

`dN_returning` scripted_metric shape (same template for every D+N):

```text
params:
  offset_days: N            # 1..30
  tz: Asia/Seoul            # day-boundary timezone
  path: /users/create       # requestPath that anchors the cohort

init_script:   state.create_days = []; state.all_days = []
map_script:    epoch = doc[@timestamp] → KST → toLocalDate().toEpochDay()
               state.all_days.add(epoch)
               if doc[data.requestPath.keyword] == params.path:
                 state.create_days.add(epoch)
combine:       return state
reduce:        firstCreate = min(state.create_days across all states)
               allDays = union(state.all_days across all states)
               if no create event seen for this user: return null
               else return allDays.contains(firstCreate + offset_days) ? 1 : 0
```

Key consequences:
- The **anchor is the first occurrence of `params.path` (`/users/create`)**, not just `min(@timestamp)`.
- Users without any `/users/create` event have D-N as **`null`** → the ES `avg()` operator skips them automatically → the Retention Curve / Table divisor naturally becomes "signed-up users only".
- Timezone is controlled in one place via `params.tz`.

### 3) Cohort Kibana data view (with runtime field)

| Item | Value |
|---|---|
| Title | `dev-example-project-game-user-cohort` |
| Name | `dev-example-project-game-user-cohort-logs` (id `410571c2-5b86-4ba9-a02e-418671d0b8e2`) |
| Time field | `first_seen` |
| Runtime field — `cohort_date` (keyword) | `if (doc['first_seen'].size() > 0) { emit(doc['first_seen'].value.toInstant().atZone(ZoneId.of('Asia/Seoul')).toLocalDate().toString()); }` — powers the keyword grouping of the Daily Cohort Retention table's "Date" column |
| Runtime field — `d1_live`..`d30_live` (long) | Emit `1` if `first_seen + N day` appears in `active_dates`, otherwise `0`. The core check is `String t = (first_seen + N day).toString(); for (def d : doc['active_dates']) if (d == t) emit(1L)`. **The index mapping's `active_dates` MUST be `keyword`** — if inferred as `date`, the `String == ZonedDateTime` comparison is always false and every retention horizon emits 0 (2026-05-22 QA cohort incident). The cohort index's explicit mapping is pinned via `<id>.mapping.json` per [transforms/README-en.md → "Dest-index mapping"](../../elasticsearch/transforms/README.md#dest-index-mapping----idmappingjson). |

Both `cohort_date` and `d{N}_live` are **Kibana data view runtime fields only** — they don't live in the underlying index mapping and are computed per cohort doc at visualization time.

<br/>

## Per-panel definitions

### KPI cards (6 × Vega-Lite, colored backgrounds)

All six follow the same Vega-Lite shape (big number + label, full-bleed colored background). Only the colour and filters differ.

| Panel | Index | KQL/term filter | Time range | Agg | Background |
|---|---|---|---|---|---|
| NU (Today) | `dev-example-project-game` | `requestPath = /users/create` ∧ `exists(data.userId)` | `@timestamp >= now/d` | `cardinality(data.userId)` | `#16a34a` |
| NU (Last 7d) | `dev-example-project-game` | same | `@timestamp >= now-7d` | `cardinality(data.userId)` | `#16a34a` |
| NU (Last 30d) | `dev-example-project-game` | same | `@timestamp >= now-30d` | `cardinality(data.userId)` | `#16a34a` |
| DAU | `dev-example-project-game` | `exists(data.userId)` | `@timestamp >= now/d` | `cardinality(data.userId)` | `#1ea7fd` |
| WAU | `dev-example-project-game` | `exists(data.userId)` | `@timestamp >= now-7d` | `cardinality(data.userId)` | `#2c8a96` |
| MAU | `dev-example-project-game` | `exists(data.userId)` | `@timestamp >= now-30d` | `cardinality(data.userId)` | `#7c47ab` |

KPI Vega-Lite skeleton:

```jsonc
{
  "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
  "width": "container", "height": "container", "padding": 0,
  "background": "<COLOR>",
  "data": {
    "url": {
      "index": "<RAW_INDEX>",
      "body": {
        "size": 0,
        "query": { "bool": { "filter": [ /* <FILTERS> */ ] } },
        "aggs":  { "c": { "cardinality": { "field": "<USER_FIELD>" } } }
      }
    },
    "format": { "property": "aggregations.c" }
  },
  "layer": [
    /* big number + label text marks — see exported NDJSON for details */
  ]
}
```

<br/>

### Trend lenses (2 × line)

#### NU Trend (30d) — `<env>-pm-retention-nu-trend`

| Item | Value |
|---|---|
| Chart | Lens lnsXY (line) |
| Data view | `dev-example-project-game-logs` (raw) |
| X | `date_histogram(@timestamp, 1d)` |
| Y | `unique_count(data.userId)` label "New users" |
| KQL filter | none (dashboard-level `now-30d` `timeRestore` handles the window) |

#### DAU Trend — `<env>-pm-retention-dau-trend`

| Item | Value |
|---|---|
| Chart | Lens lnsXY (line) |
| Data view | `dev-example-project-game-logs` (raw) |
| X | `date_histogram(@timestamp, 1d)` |
| Y | `unique_count(data.userId)` label "DAU" |
| **KQL filter** | `data.userId : * and not data.requestPath : "/api/health" and not data.requestPath : "/api/stats" and data.statusCode < 4` |

> Only the DAU Trend excludes health-check / stats endpoints and 4xx/5xx responses. NU and Retention already self-isolate because they look at the signup endpoint.

<br/>

### Average Retention Curve (full Vega)

| Item | Value |
|---|---|
| Chart | Vega (vega/v5) — area + line + symbol + text label |
| Data view | `dev-example-project-game-user-cohort-logs` (cohort) |
| Time filter | `%timefield% = first_seen`, `%context% = true` (dashboard time range applied) |
| Query | 30 × `avg(dN_returning)` aggregations for N=1..30 |
| Visual | X = D+1..D+30, Y = `[0, 1]` (% scale) |
| Markings | symbol point + `.1%` label above each point (e.g. `12.5%`); area fill `#1ea7fd` at 12% opacity; line stroke `#1ea7fd` 2.5px |
| `defined` guard | when `rate == null` the point/label is suppressed |

Critical `data` block:

```jsonc
{
  "name": "es_agg",
  "url": {
    "%context%": true,
    "%timefield%": "first_seen",
    "index": "<COHORT_INDEX>",
    "body": {
      "size": 0,
      "aggs": {
        "d1":  { "avg": { "field": "d1_returning"  } },
        "d2":  { "avg": { "field": "d2_returning"  } },
        // ... d3 through d30 ...
        "d30": { "avg": { "field": "d30_returning" } }
      }
    }
  },
  "format": { "property": "aggregations" }
}
```

Then a `points` dataset (D+1..D+30) is joined to `es_agg` via a `formula` transform: `data('es_agg')[0]['d' + datum.day].value`. See the exported `<env>-pm-retention-curve` for the full spec.

<br/>

### Daily Cohort Retention (Lens datatable)

| Item | Value |
|---|---|
| Chart | Lens `lnsDatatable` |
| Data view | `dev-example-project-game-user-cohort-logs` (cohort) |
| Row group | `terms(cohort_date)` (runtime field, size 100) — "Date" |
| Col 1 | `count(___records___)` — "NU" (number of signups in that cohort) |
| Cols 2..31 | `average(d1_returning)` … `average(d30_returning)` — labels `D+1` … `D+30` |
| Time filter | dashboard `now-30d ~ now`, by `first_seen` |
| Sorting | none (terms order via the data view) |

One row = one cohort day. Each D+N cell = that cohort's D+N retention rate (0..1, formatted as `%` by Kibana).

<br/>

## Template parameters

Values to substitute for prod:

| Param | dev value | Where it appears | prod example |
|---|---|---|---|
| `<RAW_INDEX>` | `dev-example-project-game` | KPI Vega `data.url.index` ×6, Trend Lens data view title, Transform `source.index` | `prod-example-project-game` |
| `<COHORT_INDEX>` | `dev-example-project-game-user-cohort` | Curve Vega `data.url.index`, Table Lens data view title, Transform `dest.index`, Transform id | `prod-example-project-game-user-cohort` |
| `<RAW_DATA_VIEW_ID>` | `b50c59ea-73c1-4feb-8b42-d642248c8647` | Trend Lens `references[].id` (raw data view) | fresh UUID issued on the prod cluster |
| `<COHORT_DATA_VIEW_ID>` | `410571c2-5b86-4ba9-a02e-418671d0b8e2` | Table Lens `references[].id` | fresh UUID issued on the prod cluster |
| `<USER_FIELD>` | `data.userId` | KPI Vega cardinality, Trend Lens unique_count, Transform `group_by.terms.field`, Transform source `exists` | same (if schema matches) |
| `<SIGNUP_PATH>` | `/users/create` | NU KPI `term` filters, Transform `params.path` | same or game-specific endpoint |
| `<HEALTH_EXCLUDES>` | `/api/health`, `/api/stats`, `statusCode >= 4` | DAU Trend Lens KQL | adjust to your operational endpoints |
| `<TIMEZONE>` | `Asia/Seoul` | All Transform `params.tz`, cohort data view `cohort_date` script | `UTC` for global games etc. |
| `<RETENTION_HORIZONS>` | D+1..D+30 (30 values) | Transform `dN_returning` aggs, Curve Vega aggs+points, Table Lens columns | same, or extend to D+1..D+60 |
| `<DEFAULT_TIME_RANGE>` | `now-30d ~ now`, `timeRestore: true` | Dashboard `timeFrom` / `timeTo` | same |
| `<FREQUENCY>` | `5m` | Transform `frequency` | start with `1h` if data volume is high |
| `<DASHBOARD_ID>` | `<env>-pm-retention-dashboard` | dashboard saved-object id | `prod-pm-retention-dashboard` (namespace separation) |
| `<PANEL_ID_PREFIX>` | `pm-retention-` | prefix of the 10 panel saved-object ids | `prod-pm-retention-` |

> The colors (`#16a34a`, `#1ea7fd`, `#2c8a96`, `#7c47ab`) act as intentional prod/dev disambiguation. Pick a different palette for prod so an analyst can never mistake one environment for the other at a glance.

<br/>

## Automation strategy

Instead of hand-editing NDJSON and running apply, build a **state-driven Python builder**. One command idempotently (re)creates the transform + data views (runtime field included) + 10 saved objects + dashboard. The repo does not yet ship such a builder under `dashboards/` (current standard is NDJSON substitution + `apply.sh`); the skeleton below is a blueprint for future implementation.

### Execution model

```
build-pm-retention.py
  │
  ├─ load config         (env or top-of-file constants — RAW_INDEX, SIGNUP_PATH, TIMEZONE, HORIZONS …)
  ├─ load/init state     (pm-retention.state.json — UUID cache, preserved across reruns)
  ├─ ensure transform    (PUT + start; --replace stops+deletes+PUTs when the definition changed)
  ├─ ensure data views   (raw is referenced; cohort is created with the cohort_date runtime field)
  └─ ensure saved objects
       ├─ KPI Vega ×6  (NU today/7d/30d, DAU/WAU/MAU)   ← generated from METRICS_KPI
       ├─ Trend Lens ×2 (NU Trend, DAU Trend)            ← from METRICS_TREND
       ├─ Curve Vega ×1 (D+1..D+N)                       ← HORIZONS expand to aggs + points
       ├─ Table Lens ×1 (Daily Cohort, D+1..D+N)         ← HORIZONS expand to columns
       └─ Dashboard    (panelsJSON
```

### dev / prod switching

A single **env prefix** swap (`dev` / `prod`) updates all index names, dashboard id, and data view names:

```python
ENV        = os.environ.get("ENV", "dev")              # 'dev' or 'prod'
PROJECT    = os.environ.get("PROJECT", "example-project-game")
RAW_INDEX        = f"{ENV}-{PROJECT}"
COHORT_INDEX     = f"{ENV}-{PROJECT}-user-cohort"
DASHBOARD_ID     = f"{ENV}-pm-retention-dashboard"
PANEL_ID_PREFIX  = f"{ENV}-pm-retention-"
SIGNUP_PATH      = os.environ.get("SIGNUP_PATH", "/users/create")
TIMEZONE         = os.environ.get("TIMEZONE", "Asia/Seoul")
HORIZONS         = list(range(1, int(os.environ.get("HORIZONS", "30")) + 1))
FREQUENCY        = os.environ.get("FREQUENCY", "5m")
KPI_COLORS       = {"NU": "#16a34a", "DAU": "#1ea7fd", "WAU": "#2c8a96", "MAU": "#7c47ab"}
```

The state file (`pm-retention.state.json`) auto-allocates UUIDs on first run; later runs reuse them so the script is idempotent under `overwrite=true`.

### Transform builder (HORIZONS loop)

```python
def transform_aggs(horizons: list[int], tz: str, path: str) -> dict:
    aggs = {
        "first_seen":   {"min": {"field": "@timestamp"}},
        "last_seen":    {"max": {"field": "@timestamp"}},
        "total_events": {"value_count": {"field": "@timestamp"}},
        "active_days_count": {
            "cardinality": {
                "script": {
                    "source": "doc['@timestamp'].value.toInstant().atZone(ZoneId.of(params.tz)).toLocalDate().toString()",
                    "params": {"tz": tz},
                }
            }
        },
    }
    map_script = (
        "long epoch = doc['@timestamp'].value.toInstant()"
        ".atZone(ZoneId.of(params.tz)).toLocalDate().toEpochDay();"
        " state.all_days.add(epoch);"
        " if (doc['data.requestPath.keyword'].size() > 0 && doc['data.requestPath.keyword'].value == params.path) {"
        " state.create_days.add(epoch); }"
    )
    reduce_script = (
        "long firstCreate = Long.MAX_VALUE; boolean any = false; HashSet allDays = new HashSet();"
        " for (def s : states) {"
        " for (def d : s.create_days) { long dl = (long)d; if (dl < firstCreate) firstCreate = dl; any = true; }"
        " for (def d : s.all_days) { allDays.add((long)d); } }"
        " if (!any) return null;"
        " return allDays.contains(firstCreate + ((long)params.offset_days)) ? 1L : 0L;"
    )
    for n in horizons:
        aggs[f"d{n}_returning"] = {
            "scripted_metric": {
                "params": {"offset_days": n, "tz": tz, "path": path},
                "init_script":    "state.create_days = new ArrayList(); state.all_days = new ArrayList();",
                "map_script":     map_script,
                "combine_script": "return state;",
                "reduce_script":  reduce_script,
            }
        }
    return aggs
```

### KPI / Trend / Curve / Table builders

```python
METRICS_KPI = [   # 6 KPI Vega cards on RAW_INDEX
    {"key": "nu-today", "title": "NU (Today)",    "color": KPI_COLORS["NU"],  "time": "now/d",   "filters": ["signup_path", "user_exists"]},
    {"key": "nu-7d",    "title": "NU (Last 7d)",  "color": KPI_COLORS["NU"],  "time": "now-7d",  "filters": ["signup_path", "user_exists"]},
    {"key": "nu-30d",   "title": "NU (Last 30d)", "color": KPI_COLORS["NU"],  "time": "now-30d", "filters": ["signup_path", "user_exists"]},
    {"key": "dau-today","title": "DAU",           "color": KPI_COLORS["DAU"], "time": "now/d",   "filters": ["user_exists"]},
    {"key": "wau-7d",   "title": "WAU",           "color": KPI_COLORS["WAU"], "time": "now-7d",  "filters": ["user_exists"]},
    {"key": "mau-30d",  "title": "MAU",           "color": KPI_COLORS["MAU"], "time": "now-30d", "filters": ["user_exists"]},
]

METRICS_TREND = [  # 2 Trend Lenses on RAW_INDEX
    {"key": "nu-trend",  "title": "NU Trend (30d)", "kql": ""},
    {"key": "dau-trend", "title": "DAU Trend",
     "kql": 'data.userId : * and not data.requestPath : "/api/health" and not data.requestPath : "/api/stats" and data.statusCode < 4'},
]
```

Each builder reassembles its part of the exported live spec jinja-style. The trickier bits (Lens `columnOrder`, dashboard `panelRefName` matching) can be lifted verbatim from the live `dev-pm-retention-dashboard.ndjson` (or `qa-pm-retention-dashboard.ndjson`) references — the format is fixed at `<panelIndex>:panel_<panelIndex>`.

### Suggested CLI

```bash
# Recreate dev (idempotent when the state file already exists)
ENV=dev   PROJECT=example-project-game ./build-pm-retention.py

# One-shot apply on prod
ENV=prod  PROJECT=example-project-game KUBECONFIG=$PROD_KUBECONFIG ./build-pm-retention.py

# Diff-only preview
ENV=prod ./build-pm-retention.py --dry-run

# When the transform definition changes (e.g. HORIZONS 30 → 60)
ENV=prod ./build-pm-retention.py --replace-transform
```

The state file is per-environment (`pm-retention.{ENV}.state.json`) so dev and prod UUIDs do not collide.

### Recommended two-stage operating pattern

1. **Develop
2. **Replay on prod** — `ENV=prod ./build-pm-retention.py` once. Humans never click in the prod Kibana UI.

The UI-first stage mirrors the `export.sh` flow from [`dashboards/README.md`](../dashboards/README.md). The builder's job is to freeze the result into code.

> Recommended rollout order: capture the live state via `export.sh` and commit first; then implement the builder incrementally — first cut covers transform + cohort data view + 6 KPI Vega; second cut adds the Trend / Table Lenses and the dashboard.

<br/>

## Prod migration recipe

Assumption: the prod ES cluster already ingests `<RAW_INDEX>` and fluent-bit / fluentd are wired to a prod-specific dataset.

### Step 0 — refresh the repo snapshot (resolve drift)

Bring the repo's transform / dashboard definitions in line with the live state before doing anything else:

```bash
# Live transform definition → repo JSON
cd observability/logging/elasticsearch/transforms
./export.sh --id dev-example-project-game-user-cohort
git diff -- .

# Live dashboard → repo NDJSON
cd ../../kibana/dashboards
# Add a line to manifest.txt:
#   pm-retention-dashboard  pm-retention-dashboard.ndjson  # Game User Matric & Retention
./export.sh --id dev-pm-retention-dashboard --out dev-pm-retention-dashboard.ndjson
git diff -- .
```

Then `git commit`.

### Step 1 — Parameterise for prod

Recommended workflow:

1. Copy `dev-pm-retention-dashboard.ndjson` to `prod-pm-retention-dashboard.ndjson` and substitute (`<RAW_INDEX>`, `<SIGNUP_PATH>`, dashboard
2. Copy `dev-example-project-game-user-cohort.json` to `prod-example-project-game-user-cohort.json` and apply the same substitutions.
3. Pre-create the raw + cohort data views on prod Kibana (UI or via the same `ensure_data_view` logic from the build script), then plug the issued UUIDs back into the NDJSON `references` fields.

### Step 2 — Apply the transform first

```bash
cd observability/logging/elasticsearch/transforms
# Confirm both files are staged in transforms/
ls prod-example-project-game-user-cohort*.json
KUBECONFIG=... NAMESPACE=logging ./apply.sh --file prod-example-project-game-user-cohort.json
```

* `--preview-only` validates first → confirm the atomic facts (`first_seen`, `last_seen`, `active_dates`, `active_days_count`, `total_events`, `max_cleared_chapter`) match expectations before the real apply.
* `apply.sh` auto-detects the sibling `.mapping.json` and PUTs the explicit dest-index mapping first (pinning `active_dates: keyword`) when the dest index is absent. Without this, ES dynamic mapping infers `active_dates` as `date` and dashboard retention silently renders as 0 — see [transforms/README-en.md → "Dest-index mapping"](../../elasticsearch/transforms/README.md#dest-index-mapping----idmappingjson).
* The dashboard only shows meaningful numbers once the backfill completes. Continuous mode keeps the index fresh at `frequency` cadence.

### Step 3 — Apply the dashboard

```bash
cd observability/logging/kibana/dashboards
./apply.sh --file pm-retention-dashboard-prod.ndjson
```

`apply.sh` imports every saved object in the NDJSON (7 visualization + 3 lens + 1 dashboard + 2 data-view) with `overwrite=true`.

### Step 4 — Post-apply verification

| Check | Command / behavior |
|---|---|
| Transform status | `GET /_transform/<COHORT_INDEX>/_stats` → `state: started`, `docs_processed > 0` |
| Cohort sample doc | `GET /<COHORT_INDEX>/_search?size=1` → `first_seen`, `active_dates`, `active_days_count` fields present |
| Cohort index mapping | `GET /<COHORT_INDEX>/_mapping` → `properties.active_dates.type == "keyword"` (if `date`, retention breaks) |
| Dashboard renders | Open the dashboard in Kibana → 6 KPI numbers populated, Curve plots D+1..D+30, Table has cohort-by-cohort rows |
| Runtime field | The cohort data view's `cohort_date` resolves to KST local dates (`Stack Management → Data Views`) |

<br/>

## Timezone change procedure

The cohort D-N boundary and the Daily Cohort Retention row grouping are both timezone-controlled in **two places** — the transform's `params.tz` and the cohort data view's `cohort_date` runtime field `ZoneId`. Patterns:

### Current state (snapshot 2026-05-13)

| Location | DEV | QA | Source of truth |
|---|---|---|---|
| Transform `params.tz` (31 aggs: 30 × `dN_returning` + `active_days_count`) | `Asia/Seoul` | `Asia/Seoul` | live ES + repo `*-example-project-game-user-cohort.json` |
| Cohort data view `cohort_date` runtime field `ZoneId.of('…')` | `Asia/Seoul` | `Asia/Seoul` | live Kibana data view + repo `example-project-game-data-view.ndjson` (the 4-data-view bootstrap NDJSON includes both env cohort data views) |

All four points across both environments unified at KST. The transform's `first_seen` is timezone-independent (effectively `min(@timestamp)`) and not in scope.

<br/>

### Four locations to change

| # | Location | Keyword to replace |
|---|---|---|
| 1 | `observability/logging/elasticsearch/transforms/dev-example-project-game-user-cohort.json` | every `"tz": "Asia/Seoul"` |
| 2 | `observability/logging/elasticsearch/transforms/qa-example-project-game-user-cohort.json` | every `"tz": "Asia/Seoul"` |
| 3 | DEV cohort data view runtime field (live, id `410571c2-5b86-4ba9-a02e-418671d0b8e2`) | `ZoneId.of('Asia/Seoul')` |
| 4 | QA cohort data view runtime field (live, id `fb7b645e-78ff-4da7-b231-ec2c4165cf98`) | `ZoneId.of('Asia/Seoul')` |

After updating the four live points, run `dashboards/export.sh --include-data-view` to refresh the repo bootstrap NDJSON (both cohort data views' runtime fields are captured together).

<br/>

### One-shot state check

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Transform (dev + qa) — every params.tz should be the same value
for tid in dev-example-project-game-user-cohort qa-example-project-game-user-cohort; do
  echo "--- $tid ---"
  kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
    curl -sk -u "elastic:$PASS" "https://localhost:9200/_transform/$tid" \
    | python3 -c "
import json,sys,collections
t=json.load(sys.stdin)['transforms'][0]
tzs=collections.Counter()
for k,v in t['pivot']['aggregations'].items():
    if 'scripted_metric' in v and 'tz' in v['scripted_metric'].get('params',{}):
        tzs[v['scripted_metric']['params']['tz']] += 1
ac=t['pivot']['aggregations'].get('active_days_count',{})
if 'cardinality' in ac and 'script' in ac['cardinality']:
    tzs[ac['cardinality']['script']['params']['tz']] += 1
print('  params.tz counts:', dict(tzs))
"
done

# Cohort data view (dev + qa) — cohort_date runtime field ZoneId
for dvid in 410571c2-5b86-4ba9-a02e-418671d0b8e2 fb7b645e-78ff-4da7-b231-ec2c4165cf98; do
  kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
    curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' "http://kibana-kb-http.logging.svc:5601/api/data_views/data_view/$dvid" \
    | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['data_view']
src=d['runtimeFieldMap']['cohort_date']['script']['source']
m=re.search(r\"ZoneId\.of\('([^']+)'\)\", src)
print(f'  {d[\"title\"]:42s} ZoneId = {m.group(1) if m else \"?\"}')
"
done
```

<br/>

### Scenario A — match the server wall clock (host systemd / OS timezone)

If the server runs in KST (`Asia/Seoul`), the current setup is already correct — no change. If the server runs in a different zone (UTC, …), swap to that zone.

### Scenario B — match a specific country

Replace with the IANA `ZoneId` string of the target zone (`UTC`, `America/Los_Angeles`, `America/New_York`, `Asia/Tokyo`, `Europe/London`, …).

> **Independent of what zone fluentd writes `@timestamp` in**: ES `ZoneId.of(params.tz).toLocalDate()` converts UTC epoch to the target zone internally. You do not need to change fluentd's output zone.

### Two locations to change (must be in lockstep)

**1) Transform definition (`elasticsearch/transforms/dev-example-project-game-user-cohort.json`)**

Inside `pivot.aggregations`:
- `active_days_count.cardinality.script.params.tz`
- `d1_returning.scripted_metric.params.tz` … `d30_returning.scripted_metric.params.tz` (30 entries)

Replace every occurrence with the same value, then:

```bash
cd observability/logging/elasticsearch/transforms
# verify
./apply.sh --preview-only
# stop + delete + re-PUT + start (discards the checkpoint, retains existing cohort docs and re-aggregates over them)
./apply.sh --replace
```

**2) Cohort Kibana data view's `cohort_date` runtime field**

Replace the runtime field script's `ZoneId.of('Asia/Seoul')` with the same target zone. If the data view is not managed by the bootstrap NDJSON (`example-project-game-data-view.ndjson`) and was added via UI, patch via API:

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

NEW_TZ='UTC'
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -X PUT "http://kibana-kb-http.logging.svc:5601/api/data_views/data_view/410571c2-5b86-4ba9-a02e-418671d0b8e2" \
  --data-binary "$(cat <<EOF
{
  "data_view": {
    "runtimeFieldMap": {
      "cohort_date": {
        "type": "keyword",
        "script": {"source": "if (doc['first_seen'].size() > 0) { emit(doc['first_seen'].value.toInstant().atZone(ZoneId.of('${NEW_TZ}')).toLocalDate().toString()); }"}
      }
    }
  }
}
EOF
)"
```

### Impact summary

| Item | Effect |
|---|---|
| D-N boundary (Transform `params.tz`) | Cohort signup-day (first `/users/create`) and D+N activity-day judged at the new zone |
| Daily Cohort Retention row grouping (`cohort_date`) | Row labels emitted as date strings in the same zone |
| KPI
| Retention Curve (Vega) | Curve plots cohort-averaged retention over time. `%timefield%` is `first_seen` (date) so ES is timezone-agnostic at the query level — only the dashboard time range (`now-30d` etc.) is affected |
| Existing cohort index data | `--replace` keeps existing rows in the destination index untouched, but the transform re-traverses source from the start and overwrites every row consistent with the new zone |

### Consistency checklist

After the change, verify both locations carry the same zone:

```bash
# Transform params.tz (all should be the same value)
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$PASS" "https://localhost:9200/_transform/dev-example-project-game-user-cohort" \
  | python3 -c "import json,sys; t=json.load(sys.stdin)['transforms'][0]; tzs=set(); [tzs.add(v['scripted_metric']['params']['tz']) for k,v in t['pivot']['aggregations'].items() if 'scripted_metric' in v]; tzs.add(t['pivot']['aggregations']['active_days_count']['cardinality']['script']['params']['tz']); print('unique tz values:', tzs)"

# Cohort data view runtime field's ZoneId
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'kbn-xsrf: true' "http://kibana-kb-http.logging.svc:5601/api/data_views/data_view/410571c2-5b86-4ba9-a02e-418671d0b8e2" \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data_view']; print('cohort_date script:', d['runtimeFieldMap']['cohort_date']['script']['source'])"
```

If the two zones diverge, cohort day boundaries follow the transform's zone but the Daily Table row labels follow the data view's zone — a subtle inconsistency. Keep them identical.

<br/>

## Known drift (repo vs live, snapshot 2026-05-13)

Differences found while analysing the live cluster. **Do not apply the repo definitions to prod until Step 0 captures the live state.**

| Item | repo (`dev-example-project-game-user-cohort.json`) | live |
|---|---|---|
| Retention horizons | D-1, D-7 (2 values) | D-1 … D-30 (30 values) |
| D-N anchor | `min(@timestamp)` (first activity day) | first `/users/create` day (`params.path`) |
| Users with no signup event | returns 0 or 1 (included in the denominator) | returns `null` (excluded from avg / denominator) |
| `frequency` | `1h` | `5m` |
| Cohort data view `cohort_date` runtime field | not managed in repo (likely absent from `-data-view.ndjson`) | configured in Kibana |
| Dashboard NDJSON | absent | live only (`<env>-pm-retention-dashboard`) |
| `cohort_entries` in cohort mapping | absent | present in live mapping (no current agg writes to it — leftover from a prior iteration; new docs do not populate it) |

> Follow-up: when committing the Step 0 export, code-review the three artifacts (transform JSON / dashboard NDJSON / data view NDJSON) to confirm they accurately mirror the live state. The leftover `cohort_entries` field can be cleaned up by `DELETE /<dest-index>` + `--replace` (optional).

<br/>

## Related docs

- [dashboards/README-en.md](../dashboards/README.md) — apply.sh / export.sh / build script usage
- [docs/dashboards-saved-objects-en.md](dashboards-saved-objects.md) — NDJSON schema, two flavours of apply.sh, data view policy
- [docs/user-metrics-catalog-en.md](user-metrics-catalog.md) — this dashboard's 10-panel catalog (definitions + operational caveats)
- [elasticsearch/transforms/README-en.md](../../elasticsearch/transforms/README.md) — transform management commands
- [docs/example-project-user-metrics-overview.md](../../../../docs/example-project-user-metrics-overview.md) — pipeline-wide entry point (Korean, internal)

<br/>

## External references

- [Kibana Vega plugin — `%context%` / `%timefield%`](https://www.elastic.co/guide/en/kibana/current/vega.html#context-and-time-filters)
- [Elasticsearch scripted_metric](https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-scripted-metric-aggregation.html)
- [Kibana saved-objects export/import API](https://www.elastic.co/docs/api/doc/kibana/group/endpoint-saved-objects)
