# ZLogger Log Normalization Guide

Work log and operations guide for compensating the JSON schema difference introduced when the dev battle server (`dev-example-project-battle` pod) migrated from **SeriLog → ZLogger** on 2026-05-22, applied in `02_filters.conf` of fluentd.

Scope: `dev-example-project-battle` index only. `dev-example-project-game` (Pino) and `qa-example-project-game` (pino-pretty) are unaffected.

<br/>

## Background

The ELK pipeline (fluent-bit → fluentd → Elasticsearch) was originally built around two log schemas.

| Component | Logging lib | level key | message key | timestamp key |
|---|---|---|---|---|
| dev/qa-example-project-game | Pino (Node.js) | `level` (Integer 10/20/.../60) | `msg` | `time` (Unix ms Integer) |
| dev-example-project-battle (old) | Serilog (.NET) | `Level` (String "Information"/...) | `MessageTemplate` | `Timestamp` (ISO8601 + offset) |

ZLogger is a Microsoft.Extensions.Logging-based logger, so it uses PascalCase similar to Serilog but with different key names.

| Component | Logging lib | level key | message key | timestamp key |
|---|---|---|---|---|
| dev-example-project-battle (new) | **ZLogger** (.NET) | **`LogLevel`** (String "Information"/"Critical"/...) | **`Message`** (already rendered string) | `Timestamp` (ISO8601 + offset, same) |

Only `Timestamp` matches Serilog; `LogLevel` / `Message` are new key names that the existing fluentd normalization regex did not cover.

<br/>

## Problems found (before fix)

Inspection of actual ES `dev-example-project-battle` documents after the ZLogger migration:

| # | Symptom | Cause |
|---|---|---|
| 1 | All documents had `level` pinned to `info` (even Warning/Critical) | fluentd Step 2 only had a `record["Level"]` branch. ZLogger emits `LogLevel`, so flow fell to the else fallback `"info"` |
| 2 | `message` field was empty string | fluentd Step 2 only checked `msg \|\| message \|\| MessageTemplate`. ZLogger emits the rendered text under the `Message` key |
| 3 | Original `LogLevel`, `Message` keys remained after normalization | Step 3 `remove_keys` did not include the ZLogger keys |
| 4 | **Expression-as-key** like `JsonSerializer.Serialize(requestBody)`, `requestPath ?? string.Empty` ended up as ES field names | ZLogger adopts the caller-argument-expression of message-template placeholders as the property key. If the app side does not assign the expression to a named variable first, this is what gets emitted |
| 5 | `_ignored: [Message.keyword, JsonSerializer.Serialize(requestBody).keyword, JsonSerializer.Serialize(responseBody).keyword]` | ES dynamic mapping hit the default keyword `ignore_above: 256` byte limit. Text search still works, but aggregation/sort/term queries do not |
| 6 | `_doc_id` dedup broken (documents indexed with random `_id`) | ZLogger payload has no `data.traceId`. Step 6's `record["data"]["traceId"]` evaluates to nil → ES output falls back to random `_id`. Risks duplicate ingestion on fluent-bit/fluentd restart |

<br/>

## Fix applied (2026-05-22, fluentd side only)

No application code change. Only `values/dev.yaml` was updated under `fileConfigs.02_filters.conf`.

### Step 2 — extend level / message normalization

Add a `LogLevel` (ZLogger) branch + add `Message` to the message extraction fallback chain.

```ruby
level ${if record["level"].is_a?(Integer); {...Pino...}
       elsif record["Level"].is_a?(String); {...Serilog...}
       elsif record["LogLevel"].is_a?(String);
         {"Trace"=>"trace","Debug"=>"debug","Information"=>"info","Warning"=>"warn",
          "Error"=>"error","Critical"=>"fatal","None"=>"info"}[record["LogLevel"]]
         || record["LogLevel"].downcase
       else; record["level"] || "info"; end}

message ${m = record["msg"] || record["message"] || record["MessageTemplate"] || record["Message"] || ""; ...}
```

- Both Serilog `Fatal` and ZLogger `Critical` map to fluentd `fatal`.
- `None` (Microsoft.Extensions.Logging.LogLevel enum value 6) is not actually emitted, but mapped to `info` defensively.

### Step 3 — extend remove_keys

```ruby
remove_keys time,msg,filepath,req,log,Timestamp,Level,MessageTemplate,LogLevel,Message
```

- Newly added: `LogLevel`, `Message`
- `Category` (ZLogger class name) and `Properties` (Serilog free-form payload) are **preserved** — useful for class-based filtering in Kibana.
- `Timestamp` has the same capital-T shape in both ZLogger and Serilog, so the existing branch handles it (no change needed).

### Step 5.5 — ZLogger placeholder-key normalization (NEW, battle only)

Scoped to `example-project.stdout.dev.battle.**` — rename known expression keys to canonical names and remove the originals.

```ruby
<filter example-project.stdout.dev.battle.**>
  @type record_transformer
  enable_ruby true
  <record>
    requestPath ${record["requestPath ?? string.Empty"] || record["requestPath"]}
    requestBody ${record["JsonSerializer.Serialize(requestBody)"] || record["requestBody"]}
    responseBody ${record["JsonSerializer.Serialize(responseBody)"] || record["responseBody"]}
  </record>
  remove_keys $['requestPath ?? string.Empty'],$['JsonSerializer.Serialize(requestBody)'],$['JsonSerializer.Serialize(responseBody)']
</filter>
```

- `$['...']` syntax in `remove_keys` is the JSONPath form fluentd's record_transformer uses to address keys that contain dots/spaces/parentheses.
- The Match is scoped to `example-project.stdout.dev.battle.**` because dev.game / qa.game (both Pino) do not have this issue and unnecessary record_transformer invocations are avoided.

### Step 6 — dedup key (unchanged)

ZLogger payload has no `data.traceId`, so `_doc_id` is nil and ES output falls back to random `_id`. This cannot be solved at the infra layer alone — the app side needs to emit a traceId again. Current impact: duplicate ingestion on fluent-bit/fluentd restart. Not critical in dev, tracked as follow-up.

<br/>

## Apply procedure

```bash
cd observability/logging/fluentd

# Review the diff
helmfile diff

# Apply (ConfigMap update + fluentd-0 rolling restart)
helmfile apply

# Verify
kubectl get pods -n logging -l app.kubernetes.io/name=fluentd
kubectl logs -n logging fluentd-0 --tail=50 | grep "adding filter"
# Expected: one extra line with the example-project.stdout.dev.battle.** match
```

During the brief fluentd-0 restart, fluent-bit forward is blocked, but fluent-bit's storage buffer (2GB cap) absorbs the gap — no log loss.

<br/>

## Verification (post-apply documents)

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath='{.data.elastic}' | base64 -d)
ES_POD=$(kubectl get pods -n logging -l common.k8s.elastic.co/type=elasticsearch -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n logging "$ES_POD" -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASS" -H 'Content-Type: application/json' \
  "https://localhost:9200/dev-example-project-battle/_search?pretty" \
  -d '{"size":1,"sort":[{"@timestamp":"desc"}]}'
```

Expected:
- `level` is normalized to `info` / `warn` / `error` etc. (mapped from the LogLevel branch)
- `message` is not empty — filled with the ZLogger `Message` value
- Original `LogLevel`, `Message` keys are gone
- `requestBody`, `responseBody`, `requestPath` appear as clean keys; `_ignored` is empty or reduced
- `Category` is still present

<br/>

## Adding a new placeholder key — runbook

When ZLogger code introduces a new expression placeholder, ES dynamic mapping risks growing unbounded again. Follow this procedure.

### 1) Detect new expression keys

After apply, leave it for ~1 day to 1 week, then inspect the index mapping:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath='{.data.elastic}' | base64 -d)
ES_POD=$(kubectl get pods -n logging -l common.k8s.elastic.co/type=elasticsearch -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n logging "$ES_POD" -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/dev-example-project-battle/_mapping?pretty" \
  | grep -E '"[^"]*[ ().?]+[^"]*" : \{' | sort -u
```

Identification criteria: keys with spaces, parentheses, `?`, `??`, or expression fragments like `JsonSerializer.`, `request.`, `?? string.Empty`.

### 2) Register in Step 5.5

Add one line each to the Step 5.5 `<filter example-project.stdout.dev.battle.**>` block in `values/dev.yaml`:

```ruby
<record>
  ...
  newCanonicalName ${record["<expression-as-key>"] || record["newCanonicalName"]}
</record>
remove_keys $['<expression-as-key>'],...,$['<expression-as-key>']
```

### 3) Apply + re-verify

`helmfile diff` → `helmfile apply` → re-run step 1). If no new expression keys appear in the mapping, you're done.

### 4) (Optional) Clean up stale mappings

The existing `dev-example-project-battle` index already carries the bad dynamic mapping. To clean it up, DELETE the index and let it auto-recreate, following the same pattern as [`reset-example-project-cohort.sh`](../../elasticsearch/scripts/reset-example-project-cohort.sh). dev impact is low, but requires explicit user approval.

<br/>

## Open items / follow-ups

| Item | Status | Notes |
|---|---|---|
| `data.traceId` absence breaks dedup | Open | Resolves automatically once ZLogger side re-introduces a traceId enricher. Cannot be worked around at the infra layer |
| Stale bad dynamic mappings on existing docs | Open | Cleaned by an index reset. Pending user decision |
| Placeholder expression growth monitoring | Operational | Absorbed by the "Adding a new placeholder key" runbook above |
| Stale comment in fluent-bit `values/dev.yaml` lines 33-35 ("Serilog schema") | Follow-up | Will be cleaned up in the next fluent-bit edit cycle |

<br/>

## Related files

- [`values/dev.yaml`](../values/dev.yaml) — fluentd normalization filters (Step 2 / Step 3 / Step 5.5)
- [fluent-bit `values/dev.yaml`](../../fluent-bit/values/dev.yaml) — Tag routing + JSON parsing (matches the `example-project.stdout.dev.battle.**` scope used by Step 5.5)
- [`reset-example-project-cohort` ops guide](../../elasticsearch/docs/reset-example-project-cohort-en.md) — reference pattern for index reset
