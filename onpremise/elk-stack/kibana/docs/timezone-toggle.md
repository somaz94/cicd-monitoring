# Kibana Dashboards — Timezone Toggle (Space Split)

Operational guide for presenting the same Kibana dashboards in both KST and CST(UTC+8) views, toggled by a single click on the top-left Space switcher. Bootstrap

<br/>

## 1. Data flow (one-liner)

```
fluentd (KST ISO8601)  →  ES (UTC epoch storage)  →  Kibana per-Space view
                                                     ├── default (Asia/Seoul) ─ KST display
                                                     └── cst     (Asia/Shanghai) ─ CST display
```

- **Storage layer**: fluentd normalizes `@timestamp` to KST(+09:00) ISO8601, but ES stores it internally as UTC epoch (standard). The data is not "skewed" toward any zone.
- **Display layer**: driven by Kibana's `dateFormat:tz` Advanced Setting, configurable **per Space**.
- Therefore changing the view alone is enough to toggle KST/CST. No re-aggregation needed.

fluentd normalization detail: [`observability/logging/fluentd/values/dev.yaml`](../../fluentd/values/dev.yaml) lines 256–265.

<br/>

## 2. What the user sees

### Switch flow

```
┌─ Kibana top-left ───────────────────────────────────────────┐
│ [≡]  [🅢 Default]  Dashboards  >  Game Retention            │   ← click the Space icon
└─────────────────────────────────────────────────────────────┘

Dropdown
┌─────────────────────┐
│ ● Default  (KST)    │   ← current
│ ○ CST              │   ← click to view the same dashboards in CST
└─────────────────────┘

URL after the switch
- KST: https://kibana.../app/dashboards#/view/<id>
- CST: https://kibana.../s/cst/app/dashboards#/view/<id>   ← /s/cst prefix
```

### Live URLs (dev cluster, as of 2026-05-14)

| Env | Default Space (KST view) | CST Space (UTC+8 view) |
|---|---|---|
| **DEV** | [/app/dashboards#/view/dev-pm-retention-dashboard](http://kibana.example.com/app/dashboards#/view/dev-pm-retention-dashboard?_g=(filters:!())) | [/s/cst/app/dashboards#/view/678a6e59-…](http://kibana.example.com/s/cst/app/dashboards#/view/678a6e59-8539-4781-8c7e-c2ddb72a1239?_g=(filters:!())) |
| **QA** | [/app/dashboards#/view/qa-pm-retention-dashboard](http://kibana.example.com/app/dashboards#/view/qa-pm-retention-dashboard?_g=(filters:!())) | [/s/cst/app/dashboards#/view/d485f325-…](http://kibana.example.com/s/cst/app/dashboards#/view/d485f325-8222-45f3-b46d-3bef735da280?_g=(filters:!())) |

> The CST dashboard UUIDs change whenever the cluster is rebuilt

<br/>

### Same chart, different display

```
[Default Space — KST]                  [CST Space — UTC+8]
@timestamp axis                        @timestamp axis
─────────────────                      ─────────────────
2026-05-14 00:00 ┤ ▇▇▇                2026-05-13 23:00 ┤ ▇▇▇
2026-05-14 06:00 ┤ ▇▇▇▇▇              2026-05-14 05:00 ┤ ▇▇▇▇▇
2026-05-14 12:00 ┤ ▇▇▇▇▇▇▇▇           2026-05-14 11:00 ┤ ▇▇▇▇▇▇▇▇
2026-05-14 18:00 ┤ ▇▇▇▇               2026-05-14 17:00 ┤ ▇▇▇▇

* Same event buckets shift by 1 hour: KST midnight = CST 23:00 the day before
```

Same ES index, same query, same results. **Only the display zone differs.**

<br/>

## 3. Extensibility — adding more timezones

`setup-spaces.sh --space NAME:TZ` is repeatable. `apply.sh --space-id ID` is repeatable. So adding N zones follows the same pattern.

### Example — add a JST (Japan) view

```bash
cd observability/logging/kibana/dashboards

# 1) Create the JST Space + pin tz (re-running covers existing default/cst too — idempotent)
./setup-spaces.sh \
  --space default:Asia/Seoul \
  --space cst:Asia/Shanghai \
  --space jst:Asia/Tokyo

# 2) Bootstrap dashboards + data views into the JST Space
./apply.sh --space-id jst --include-data-view

# 3) Routine sync going forward (edit in default → redeploy to all three Spaces)
./apply.sh --space-id default --space-id cst --space-id jst
```

### Common IANA timezone identifiers

| Target zone | spec example | IANA id |
|---|---|---|
| Korea KST | `--space kst:Asia/Seoul` | `Asia/Seoul` |
| China CST | `--space cst:Asia/Shanghai` | `Asia/Shanghai` (or `Asia/Taipei`, `Asia/Hong_Kong`) |
| Japan JST | `--space jst:Asia/Tokyo` | `Asia/Tokyo` |
| Vietnam ICT | `--space ict:Asia/Ho_Chi_Minh` | `Asia/Ho_Chi_Minh` |
| US PST | `--space pst:America/Los_Angeles` | `America/Los_Angeles` |
| US EST | `--space est:America/New_York` | `America/New_York` |
| EU CET | `--space cet:Europe/Berlin` | `Europe/Berlin` |
| UTC | `--space utc:UTC` | `UTC` |

> The abbreviation "CST" is ambiguous between China Standard Time (UTC+8) and US Central Standard Time (UTC-6). **Always use IANA identifiers (e.g. `Asia/Shanghai`)** for the timezone value, and reserve short labels like `cst` for the Space name only.

<br/>

## 4. Model — single NDJSON, import into both Spaces

In Kibana 9.x the `dashboard`

So:

```
repo/observability/logging/kibana/dashboards/*.ndjson   (single source of truth)
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
   default Space            cst Space
   slug IDs preserved       auto-assigned UUIDs
   (dev-pm-retention-       (Kibana generates new
    dashboard …)             IDs on first import
                             to avoid cross-Space
                             id collision)
```

- **Edit direction**: always edit in the default Space. Editing in cst diverges the two Spaces and breaks the single-NDJSON invariant.
- **Redeploy**: `./apply.sh --space-id default --space-id cst` imports the same NDJSON into both.
- **Storage cost**: cst objects exist as separate ES documents (multi-namespace not allowed → no sharing). Only the saved-object metadata is duplicated, not the underlying log data.

<br/>

## 5. Limitation — retention day boundary stays KST

ES Transform `params.tz` is fixed at `Asia/Seoul` regardless of Space, so:

- The cst Space's Daily Cohort Retention row labels stay on KST midnight.
- The cst Space's D+N activity-day judgement is also computed in KST.

Only the display time shifts to CST. **To shift the day boundary itself to CST**, the ES Transform `params.tz` (31 spots) and the cohort data view's `cohort_date` runtime field `ZoneId.of(...)` must also change. Full procedure: [pm-retention-dashboard-template-en.md "Timezone change procedure"](pm-retention-dashboard-template.md#timezone-change-procedure) (incurs a 1–5 minute cohort index re-aggregation).

<br/>

## 6. Verifying after rollout

### A) Browser (most direct)

1. Open Kibana → click the Space icon top-left.
2. Toggle `Default` (KST) ↔ `CST` and watch the same dashboards re-render with a different timezone.
3. Time-axis labels should shift by one hour (KST 09:00 = CST 08:00).

### B) CLI — verify the Advanced Setting

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Default Space dateFormat:tz
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'x-elastic-internal-origin: Kibana' \
    "http://kibana-kb-http.logging.svc:5601/internal/kibana/settings" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('settings',{}).get('dateFormat:tz',{}).get('userValue','(unset)'))"
# Expected: Asia/Seoul

# cst Space dateFormat:tz
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'x-elastic-internal-origin: Kibana' \
    "http://kibana-kb-http.logging.svc:5601/s/cst/internal/kibana/settings" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('settings',{}).get('dateFormat:tz',{}).get('userValue','(unset)'))"
# Expected: Asia/Shanghai
```

### C) Verify dashboards / data views in the cst Space

```bash
PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -s -u "elastic:$PASS" -H 'x-elastic-internal-origin: Kibana' \
    "http://kibana-kb-http.logging.svc:5601/s/cst/api/saved_objects/_find?type=dashboard" \
  | python3 -m json.tool | grep -E 'title|"id"' | head -10

# Should list 2 dashboards (DEV / QA). IDs are UUIDs (not slugs).
```

<br/>

## 7. Kibana API quick reference (useful in operations)

| Action | Endpoint | Required headers |
|---|---|---|
| Create Space | `POST /api/spaces/space` | `kbn-xsrf: true` |
| Delete Space | `DELETE /api/spaces/space/<id>` | `kbn-xsrf: true` |
| Advanced Settings GET | `GET /internal/kibana/settings` | `x-elastic-internal-origin: Kibana` (required) |
| Advanced Settings POST | `POST /internal/kibana/settings` | `x-elastic-internal-origin: Kibana` + `kbn-xsrf: true` |
| Saved-object import | `POST {SPACE_PREFIX}/api/saved_objects/_import?overwrite=true` | `kbn-xsrf: true` |
| Saved-object find | `GET {SPACE_PREFIX}/api/saved_objects/_find?type=...` | `kbn-xsrf: true` |

- `{SPACE_PREFIX}` is empty for the default Space, `/s/<id>` otherwise.
- In Kibana 8/9 the Advanced Settings endpoint moved from `/api/kibana/settings` to `/internal/kibana/settings` — the old path returns 400. The `x-elastic-internal-origin` header is required for the `/internal/` family.

<br/>

## 8. Future extensions

- **Per-user default Space**: assign a Kibana role with `cst` as the default Space, so specific users/groups land in the CST view on login (they can still toggle to KST via the top-left switcher).
- **Spec-as-code zone roster**: lift `setup-spaces.sh`'s spec list into an external file / ConfigMap to manage zone additions through infra-as-code.
- **Day-boundary parity per zone**: to address the limitation in section 5, run a separate cohort transform per zone (e.g. `<zone>-example-project-game-user-cohort`). This increases cost, so most teams keep a single canonical zone for cohort math.
