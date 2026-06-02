# pino-pretty workaround removal record

The fluent-bit DaemonSet in `values/dev.yaml` once carried a 3-filter workaround for parsing [pino-pretty](https://github.com/pinojs/pino-pretty)-formatted application stdout (lua strip_ansi → parser pino_pretty_extract → parser example-project_json_extract via `Key_Name=log`). Once every game-team component switched its stdout to raw NDJSON, the workaround was retired on 2026-05-22 — this doc records the transition trail and the current state.

<br/>

## Transition trail

| When | Change |
|---|---|
| 2026-05-18 | Initial PoC stdout DaemonSet rollout. dev/qa/stg game/battle all emitted pino-pretty → 3-filter chain enabled. |
| 2026-05-19 | dev.game (Pino) + dev.battle (Serilog) switched to raw JSON. Lua / pino_pretty_extract Match patterns narrowed to `qa.game.*`. stg.game INPUT removed entirely (staging-example-project namespace retired). |
| 2026-05-22 | qa.game flipped to raw NDJSON. **Lua filter + pino_pretty_extract filter + custom parser + `luaScripts.strip_ansi.lua` block + the qa.game-only example-project_json_extract branch were all removed.** `[FILTER] parser example-project_json_extract` was consolidated back to a single `Match example-project.stdout.*` + `Key_Name message`. |

<br/>

## Current operating state (2026-05-22 onwards)

- **dev.game / dev.battle / qa.game** all emit raw NDJSON / Serilog JSON to stdout.
- **stg.game** INPUT is currently absent (staging-example-project namespace retired). Re-deploying staging requires re-adding the INPUT + modify filter; it naturally rejoins the Match pattern.
- fluent-bit `values/dev.yaml` filter chain (post-simplification):
  1. `[FILTER] kubernetes` — pod metadata enrichment
  2. `[FILTER] parser example-project_json_extract` — `Match example-project.stdout.*`, `Key_Name message` (parses raw JSON straight from the container log line the cri parser writes)
  3. `[FILTER] modify` — sets per-component `log_source / environment / component`
- Custom parser: only `example-project_json_extract` (json format) remains — `pino_pretty_extract` (regex format) was removed.
- ConfigMap: helm auto-prunes — `fluent-bit-luascripts` ConfigMap + the DaemonSet's `luascripts` volumeMount/volume are all gone.
- Pino vs Serilog schema normalization happens on the fluentd side — Pino (`level` int / `time` int) vs Serilog (`Level` string / `Timestamp` ISO8601 / `MessageTemplate`). See fluentd `02_filters.conf` Step 2/3.

<br/>

## Plain-text line handling (unchanged — FYI)

Bootup plain-text lines (`Application started.`, `Now listening on: http://[::]:8081`, `info: Microsoft.Hosting.Lifetime[0]`) are not JSON, so `example-project_json_extract` fails to parse them. In that case the `message` key produced by the cri parser keeps the raw text and is forwarded as-is to fluentd; fluentd's `02_filters.conf` Step 2 fallback sets `level="info"`, `message=raw text`, `@timestamp=receive time` and indexes them cleanly. `skip invalid event` count stays at 0 — no data loss.

<br/>

## Verification (when something looks off)

```bash
# 1) DaemonSet health
kubectl -n logging get pods -l app.kubernetes.io/instance=fluent-bit -o wide

# 2) fluentd skip invalid event count (stays 0)
kubectl -n logging logs fluentd-0 --since=5m | grep -c "skip invalid event"

# 3) Promotion in the newest ES doc (data.traceId etc.)
ES_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
for IDX in dev-example-project-game dev-example-project-battle qa-example-project-game; do
  echo "=== $IDX ==="
  kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
    curl -sk -u "elastic:$ES_PASS" -H 'Content-Type: application/json' \
    "https://localhost:9200/$IDX/_search" -d '{
      "size":1,"sort":[{"@timestamp":"desc"}],
      "_source":["@timestamp","level","data.traceId","data.requestPath","message"]
    }' | python3 -m json.tool
done
# → data.* fields are promoted (no raw {...} left inside message) and no ANSI escape (\x1b) anywhere
```

Troubleshooting:
- Raw `{...}` text sitting inside `message` → `example-project_json_extract` filter's `Key_Name` is set to something other than `message`.
- ANSI escape `\x1b[` showing up in a doc → either the application reverted to pino-pretty, or a new namespace component shipped without verifying raw NDJSON output.

<br/>

## Related documentation

- [`deployment-to-daemonset-en.md`](./deployment-to-daemonset.md) — 2026-05-19 fluent-bit Deployment → DaemonSet migration guide + follow-up trail.
- [`../values/dev.yaml`](../values/dev.yaml) — current fluent-bit chart values (simplified filter chain).
- [`../../fluentd/values/dev.yaml`](../../fluentd/values/dev.yaml) — Pino/Serilog normalization (`02_filters.conf` Step 2/3).
