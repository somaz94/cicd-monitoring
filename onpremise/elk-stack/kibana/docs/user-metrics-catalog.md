# User metrics catalog — dev-pm-retention-dashboard

Definitions of all 10 panels of the Kibana dashboard `DEV — Game User Matric & Retention` (saved-object slug `dev-pm-retention-dashboard`), in one place. The QA counterpart (`qa-pm-retention-dashboard`) shares the same structure so this single catalog applies to both. For visualization workflow see [dashboards-saved-objects-en.md](dashboards-saved-objects.md); for porting to a new environment (stg / prod) see [pm-retention-dashboard-template-en.md](pm-retention-dashboard-template.md).

<br/>

## Data source summary

| Dataset | ES index | Kibana data view | Ingest path |
|---|---|---|---|
| **Raw game events** | `dev-example-project-game` | `dev-example-project-game-logs` (id `b50c59ea-…0fe`) | fluent-bit → fluentd → ES (real-time) |
| **User cohort** | `dev-example-project-game-user-cohort` | `dev-example-project-game-user-cohort-logs` (id `410571c2-…b8e2`, time field `first_seen`, runtime field `cohort_date`) | ES Transform pivot job (`dev-example-project-game-user-cohort`, continuous mode, frequency 5m) |

Raw-index fields used by the dashboard:

| Field | Type | Notes |
|---|---|---|
| `@timestamp` | date | fluentd normalises to KST (+09:00) before ES |
| `data.userId` | long | User identifier. Unique key for DAU/WAU/MAU; transform group_by |
| `data.accountId` | long | Account identifier. (Not currently used by this dashboard — reserved.) |
| `data.requestPath` | text + `.keyword` | API endpoint. The `.keyword` sub-field is required for both the NU KPI term filter and the transform scripted_metric |
| `data.statusCode` | long | HTTP status. DAU Trend KQL filters `< 4` (successful responses only) |

Cohort-index fields:

| Field | Type | Notes |
|---|---|---|
| `user_id` | long | Result of transform group_by terms |
| `first_seen` / `last_seen` | date | First / last activity timestamp |
| `total_events` | long | Total events per user |
| `active_days_count` | long | Distinct active days in KST |
| `d1_returning` … `d30_returning` | long (0/1) or null | D-1 … D-30 retention flag. 1 if the user had activity on `/users/create` day + N, 0 if not, null when the user never had a signup event |
| `cohort_date` | runtime keyword | Not in index mapping — a Kibana data view runtime field. Emits `first_seen` as a KST date string → row-grouping key for the Daily Cohort Retention table |

<br/>

## Panel catalog

10 panels, all on the same dashboard (`dev-pm-retention-dashboard`). Default time range `now-30d ~ now` (`timeRestore: true`).

| Row | Panel | Kind | Data source |
|---|---|---|---|
| 1 | NU (Today) / NU (Last 7d) / NU (Last 30d) | Vega-Lite KPI ×3 | raw |
| 2 | DAU / WAU / MAU | Vega-Lite KPI ×3 | raw |
| 3 | NU Trend (30d) / DAU Trend | Lens lnsXY ×2 | raw |
| 4 | Average Retention Curve (D+1..D+30) | Vega (full) | cohort |
| 5 | Daily Cohort Retention (table) | Lens lnsDatatable | cohort |

<br/>

### 1) NU (Today)

| Item | Value |
|---|---|
| Definition | Unique new signups in the time window (unique `data.userId` that hit the signup endpoint) |
| Data source | `dev-example-project-game` (raw) |
| Saved-object id | `dev-pm-retention-nu-today`, `dev-pm-retention-nu-7d`, `dev-pm-retention-nu-30d` |
| Chart | Vega-Lite big-number card, background `#16a34a` (green) |
| Query | `term: data.requestPath.keyword = "/users/create"` ∧ `exists: data.userId` ∧ `range: @timestamp >= {now/d, now-7d, now-30d}` |
| Agg | `cardinality(data.userId)` |

Operational meaning: a fast read on daily / weekly / monthly signup velocity. Repeated `/users/create` calls by the same user are de-duped.

<br/>

### 2) DAU

| Item | Value |
|---|---|
| Definition | Unique active users in the time window |
| Data source | `dev-example-project-game` (raw) |
| Saved-object id | `dev-pm-retention-dau-today` (bg `#1ea7fd` blue), `dev-pm-retention-wau-7d` (`#2c8a96` teal), `dev-pm-retention-mau-30d` (`#7c47ab` purple) |
| Chart | Vega-Lite big-number card |
| Query | `exists: data.userId` ∧ `range: @timestamp >= {now/d, now-7d, now-30d}` (no KQL filter) |
| Agg | `cardinality(data.userId)` |

Operational meaning: a fast read on activity volume. **Health-check / 4xx traffic is included**, so absolute numbers may differ slightly from DAU Trend (the noise-cleaned version below).

<br/>

### 3) NU Trend (30d) — new-user time series

| Item | Value |
|---|---|
| Definition | Daily new users over a 30-day trend |
| Data source | `dev-example-project-game` (raw) |
| Saved-object id | `dev-pm-retention-nu-trend` |
| Chart | Lens lnsXY (line) |
| X | `date_histogram(@timestamp, 1d)` |
| Y | `unique_count(data.userId)` label `New users` |
| KQL filter | none (relies on the dashboard `now-30d ~ now` time range) |

Operational meaning: a per-day breakdown of NU. Note: the Lens has no `/users/create` filter, so what it actually shows is **unique daily users** within the dashboard window. To make it strictly "new signups", add `data.requestPath : /users/create` as a KQL filter.

<br/>

### 4) DAU Trend — daily active users (noise-cleaned)

| Item | Value |
|---|---|
| Definition | Daily unique active users, excluding health-check / stats / 4xx responses |
| Data source | `dev-example-project-game` (raw) |
| Saved-object id | `dev-pm-retention-dau-trend` |
| Chart | Lens lnsXY (line) |
| X | `date_histogram(@timestamp, 1d)` |
| Y | `unique_count(data.userId)` label `DAU` |
| KQL filter | `data.userId : * and not data.requestPath : "/api/health" and not data.requestPath : "/api/stats" and data.statusCode < 4` |

Operational meaning: the noise-cleaned version of the DAU KPI. Any gap between DAU KPI and DAU Trend signals how much health-check traffic exists.

<br/>

### 5) Average Retention Curve (D+1..D+30) — full Vega

| Item | Value |
|---|---|
| Definition | Average D+1..D+30 retention rate across all cohorts in the time range |
| Data source | `dev-example-project-game-user-cohort` (cohort) |
| Saved-object id | `dev-pm-retention-curve` |
| Chart | Vega (vega/v5) — area + line + symbol + `.1%` labels above each point |
| Time filter | `%timefield% = first_seen`, `%context% = true` (dashboard time range applied) |
| Query | 30 × `avg(dN_returning)` for N=1..30 |
| Y axis | 0 ~ 1 (`.0%` format) |

Operational meaning: the average retention curve 1..30 days after signup. `null` values (users that never signed up) are automatically excluded → the denominator naturally reduces to "signed-up users only". The `defined: rate != null` guard hides points where data is missing, so early-prod thin data doesn't render misleading 0% spikes.

<br/>

### 6) Daily Cohort Retention (table) — per-cohort retention table

| Item | Value |
|---|---|
| Definition | Per-signup-day NU + D+1..D+30 retention rate table |
| Data source | `dev-example-project-game-user-cohort` (cohort) |
| Saved-object id | `dev-pm-retention-daily-table` |
| Chart | Lens `lnsDatatable` |
| Row group | `terms(cohort_date)` (runtime keyword field, max 100 rows) — "Date" |
| Col 1 | `count(___records___)` — "NU" (number of signups in that cohort) |
| Cols 2 ~ 31 | `average(d1_returning)` … `average(d30_returning)` labels `D+1` … `D+30` |
| Time filter | dashboard `now-30d ~ now`, by `first_seen` |

Operational meaning: the raw decomposition behind the Retention Curve. Surfaces which cohort day has an anomalous retention pattern at a row-by-row level. Cohorts with very small NU (e.g. NU=1) render D+N as exactly 0% or 100%, so apply a **small-sample caveat** — trust rows only when cohort NU ≥ 10.

<br/>

## Operational caveats

- **Data-sparsity signal**: cohorts with NU between 1 and 5 show retention as 0% or 100% — do not generalize.
- **`cohort_date` runtime-field dependency**: the row-group key for Daily Cohort Retention. Re-importing the data view wipes runtime fields — see [dashboards/README-en.md "Data view management policy"](../dashboards/README.md#data-view-management-policy).
- **DAU vs DAU Trend mismatch**: caused by the KQL filter. If health-check traffic frequency varies over time, the ratio between the two will drift.
- **Timezone**: Curve / Table cohort-day boundaries follow `params.tz = Asia/Seoul` (in the transform). Independent of viewer browser timezone.
- **`/users/create` as anchor**: for other services

<br/>

## Change-impact quick map

| Change | Affected files |
|---|---|
| Retention horizon extension (e.g. D-60) | `elasticsearch/transforms/dev-example-project-game-user-cohort.json` (add `dN_returning`), `dev-pm-retention-curve` Vega `aggs` + `points` N-range, `dev-pm-retention-daily-table` Lens columns |
| Signup endpoint change | NU KPI ×3 `term` filter, transform `params.path` (every `dN_returning`), README / catalog text |
| New panel (e.g. PU, ARPU) | `dev-pm-retention-dashboard.ndjson` lens/visualization + dashboard refs/grid, this catalog table |
| Timezone change | every `params.tz` in the transform, cohort data view's `cohort_date` runtime field script |

This table is the quick index for dashboard maintenance. The full NDJSON / JSON workflow lives in [dashboards/README-en.md](../dashboards/README.md) + [transforms/README-en.md](../../elasticsearch/transforms/README.md).
