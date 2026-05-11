# User Metrics Catalog — Dev ExampleProject Game

Full definitions of the metrics collected and visualized in the `Dev ExampleProject Game — User Metrics` dashboard. For methodology around the visualizations themselves see [dashboards-saved-objects-en.md](dashboards-saved-objects-en.md).

<br/>

## Data sources at a glance

| Dataset | ES index | Kibana data view | Ingestion |
|---|---|---|---|
| **Raw game events** | `dev-example-project-game` | `dev-example-project-game-logs` (id `b50c59ea-…0fe`) | fluent-bit → fluentd → ES (real time) |
| **User cohort** | `dev-example-project-game-user-cohort` | `dev-example-project-game-user-cohort-logs` (id `410571c2-…b8e2`) | ES Transform pivot (`dev-example-project-game-user-cohort`, continuous, 1h sync) |

Fields of the raw index relevant to the dashboard:

| Field | Type | Notes |
|---|---|---|
| `@timestamp` | date | Normalized to KST (+09:00) by fluentd before ingest |
| `data.userId` | long | User identifier. Unique key for DAU/WAU/MAU |
| `data.accountId` | long | Account identifier. Unique key for NU |
| `data.requestPath` | text + `.keyword` | API endpoint (e.g. `/users/create`, `/login`). keyword usable in term filters |
| `data.kind` | text + `.keyword` | Event category |
| `data.statusCode` | long | HTTP status code |
| `log_source`, `environment`, `app`, `component` | text + `.keyword` | Metadata applied by fluent-bit (`dev-example-project-game`, `dev`, `example-project`, `game`) |

<br/>

## Metric catalog

The dashboard (`c92bea18-…afc7`) hosts seven panels in three rows. Default time range `now-90d/d ~ now`.

| Row | Panel | Data source | Unit |
|---|---|---|---|
| 0 | DAU / NU | raw | unique count |
| 1 | WAU / MAU | raw | unique count |
| 2 | Retention (counts) / Retention Rate (%) | cohort | users / % |

<br/>

### 1) DAU — Daily Active Users

| Field | Value |
|---|---|
| Definition | Unique active users per day |
| Source | `dev-example-project-game` (raw) |
| Lens id | `c88bf6ae-a2d3-452b-b072-824c81e65c1a` (title: `DAU — dev-example-project-game`) |
| Formula | `cardinality(data.userId)` × `date_histogram(@timestamp, 1d)` |
| KQL filter | None (all traffic) |
| Chart | Line, X=day, Y=unique userId count |

Operational meaning: daily active users trend. A `0` day usually indicates data loss or a service outage.

<br/>

### 2) NU — New Users

| Field | Value |
|---|---|
| Definition | Unique account count creating new accounts |
| Source | `dev-example-project-game` (raw) |
| Lens id | `b53eb261-c606-41a3-97b1-5cf82ded667e` (title: `NU — dev-example-project-game`) |
| Formula | `cardinality(data.accountId)` × `date_histogram(@timestamp, 1d)` |
| KQL filter | `data.requestPath : "/users/create"` |
| Chart | Line |

Operational meaning: daily signups, baseline for marketing campaigns and growth analysis.

Justification: `/users/create` was confirmed as the signup endpoint via data exploration (127 unique accountIds across the last 30 days; no other `*create*` paths observed).

<br/>

### 3) WAU — Weekly Active Users

| Field | Value |
|---|---|
| Definition | Unique active users per ISO week |
| Source | `dev-example-project-game` (raw) |
| Lens id | `a257e5a8-14e8-4c5b-a72f-a438ebe35056` (title: `WAU — dev-example-project-game`) |
| Formula | `cardinality(data.userId)` × `date_histogram(@timestamp, 1w)` |
| KQL filter | None |
| Chart | Line |

Operational meaning: weekly active users — smooths out day-of-week noise.

<br/>

### 4) MAU — Monthly Active Users

| Field | Value |
|---|---|
| Definition | Unique active users per calendar month |
| Source | `dev-example-project-game` (raw) |
| Lens id | `eb30574c-408d-4687-af70-f8f85a4c65eb` (title: `MAU — dev-example-project-game`) |
| Formula | `cardinality(data.userId)` × `date_histogram(@timestamp, 1M)` |
| KQL filter | None |
| Chart | Line |

Operational meaning: monthly active users — long-term growth trend.

<br/>

### 5) D-1 Retention — Next-day return

| Field | Value |
|---|---|
| Definition | Number of users per signup cohort who returned the next day |
| Source | `dev-example-project-game-user-cohort` (transform) |
| Lens id | `d258439b-5e25-4e5b-9fe6-450c9a22deb3` (title: `Retention — dev-example-project-game`) |
| Formula | `sum(d1_returning)` × `date_histogram(first_seen, 1d)` |
| KQL filter | None (whole cohort index) |
| Chart | Line (one series of the cohort chart) |

`d1_returning` field definition (transform pivot scripted_metric):

```
init_script:    state.days = new ArrayList()
map_script:     state.days.add( @timestamp / 86400000L )   # epoch day
combine_script: return state.days
reduce_script:  first = min(all_days), set = HashSet(all_days)
                return set.contains(first + 1L) ? 1L : 0L
```

→ Stored as 0 or 1 per user row. Summing within the same cohort_date yields D-1 returning user count.

Operational meaning: next-day return rate of newly-acquired users → an onboarding-quality signal.

<br/>

### 6) D-7 Retention — Week-later return

| Field | Value |
|---|---|
| Definition | Number of users per signup cohort who returned 7 days later |
| Source | `dev-example-project-game-user-cohort` (transform) |
| Lens id | `d258439b-5e25-4e5b-9fe6-450c9a22deb3` (same Lens as D-1, different series) |
| Formula | `sum(d7_returning)` × `date_histogram(first_seen, 1d)` |
| KQL filter | None |
| Chart | Line |

`d7_returning` mirrors D-1 with `first + 7L`.

Operational meaning: week-later return rate — core user stickiness.

<br/>

### 7) Retention Rate — D-1 / D-7 (%)

| Field | Value |
|---|---|
| Definition | Per-cohort D-1 / D-7 retention **rates** (%) |
| Source | `dev-example-project-game-user-cohort` (transform) |
| Lens id | `853e0e95-b891-4164-b4dc-d340e867e788` (title: `Retention Rate — dev-example-project-game`) |
| Formula (Lens) | D-1%: `sum(d1_returning) / count() * 100`<br/>D-7%: `sum(d7_returning) / count() * 100` |
| X axis | `date_histogram(first_seen, 1d)` |
| Y axis unit | Percent (1 decimal, `%` suffix) |
| Chart | Line (2 series) |

Operational meaning: **separates absolute volume from retention quality** that the count chart (5, 6) conflates.

Example — signups doubled and D-1 returning also doubled:
- The **Retention chart** (id `d258439b…`) shows both lines climbing → "absolute numbers grew" only
- The **Retention Rate chart** stays flat → "the rate is unchanged; onboarding quality didn't move"

Reverse — signups flat but D-1 dropped:
- Retention chart: only the D-1 line goes down — change visible
- Retention Rate chart: D-1% drops cleanly — quantifies the drop

> **Why pair the two retention charts**: looking at the numerator (returning count) alone mixes cohort-size changes with retention-quality changes. With raw count + rate side-by-side, the two effects are cleanly separated. Both panels live in the dashboard's Retention row.

#### Small-sample caveat (observed)

In the dev dataset, three cohort days hit D-1 = 100% (2026-04-19, 04-25, 04-26). All three had a **cohort size of 1** — a single new user who returned the next day → 100% retention. Statistically meaningless.

→ When interpreting Retention Rate spikes, always check the **denominator** (new users in cohort) in the adjacent Retention (counts) chart. Retention rate becomes operationally meaningful only once cohort size ≥ 10 or so.

<br/>

## Cohort index schema (`dev-example-project-game-user-cohort`)

Transform output index. One row = one user.

| Field | Type | Meaning |
|---|---|---|
| `user_id` | long | `data.userId` (pivot group_by) |
| `first_seen` | date | First activity `@timestamp` (= signup or first log) |
| `last_seen` | date | Most recent activity `@timestamp` |
| `total_events` | long | Cumulative event count |
| `active_days_count` | long | Distinct active days (`toLocalDate` in KST) |
| `d1_returning` | long | 0 or 1 — first_seen day + 1 ∈ active days |
| `d7_returning` | long | 0 or 1 — first_seen day + 7 ∈ active days |

To add metrics, extend `dev-example-project-game-user-cohort.json` `pivot.aggregations` → `./apply.sh --replace`. Examples:

- **D-30 returning** — scripted_metric, `first + 30L`
- **lifetime_events_p50** — `percentiles { field: total_events, percents: [50] }` (transforms can't compute this directly; needs a separate search aggregation)
- **last_active_age_days** — runtime field: `now - last_seen`

<br/>

## Time-accuracy notes

- **Cohort reference day**: KST date of `first_seen`. Since fluentd normalizes `@timestamp` to +09:00, users at the very edge of midnight may fall into one cohort or its neighbor (~minute scale). Lens date_histogram timezone follows Kibana `dateFormat:tz` — pin it to `Asia/Seoul` for consistency.
- **Backfill**: when the transform is first applied it sweeps the entire raw index once. Our cluster: 142k docs processed in < 1 min, 202 user rows produced.
- **D-1 / D-7 semantics**: "did the user act on first_seen day + 1 / + 7?" (calendar-day, not rolling-24h). If first_seen is 2026-04-23 23:50 KST, D-1 is anything during 2026-04-24. Some midnight effect, but acceptable for operational metrics.
- **Continuous sync lag**: 1h frequency + `delay: 60s` — a new user becomes visible in the cohort index within ~1 hour. Tighten `frequency` (e.g. `5m`) for finer freshness at the cost of more cluster work.

<br/>

## `first_seen` accuracy and `Ignore_Older 7d`

The fluent-bit input option `Ignore_Older 7d` ([fluent-bit/values/dev.yaml:88-91](../../fluent-bit/values/dev.yaml#L88)) applies **only at file discovery time** — when fluent-bit first encounters a file, anything with mtime older than 7 days is ignored. Once a file is being tailed it stays tailed regardless.

| Scenario | `first_seen` accuracy |
|---|---|
| User joined **after** fluent-bit went live | ✅ Accurate (real first activity time) |
| User joined **before** fluent-bit went live (in ES before ingestion started) | ⚠️ first_seen snaps to the ingestion start (actual signup is earlier) |
| fluent-bit pod restart + new file appears that's untouched for 7+ days | ⚠️ That file's logs are skipped — rare edge case |

This cluster is dev and fluent-bit has been running for weeks → **almost every user's `first_seen` is close to actual signup**. Newly joining users are always ingested in real time → accurate.

The tiny gap between NU (`/users/create` callers) and Retention's cohort size is exactly: **users predating fluent-bit's deployment**, and **users that appeared in ES without ever hitting `/users/create`**.

<br/>

## Roadmap

| Metric | Status | Notes |
|---|---|---|
| DAU
| D-1
| Retention Rate (%) | ✅ Done | Lens formula on cohort |
| D-30 Retention | ⏳ Candidate | Extend transform aggregation |
| Per-user LTV
| Activity by day-of-week
| Cohort funnel (signup → first payment) | ⏳ Candidate | Extend scripted_metric or a separate transform |
