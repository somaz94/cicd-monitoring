# pino-pretty workaround removal guide

The fluent-bit DaemonSet in `values/dev.yaml` carries a temporary 3-filter workaround for parsing [pino-pretty](https://github.com/pinojs/pino-pretty)-formatted application stdout (marked with the `🔥` emoji). When the game team turns pino-pretty off in production stdout and switches to raw NDJSON output, this workaround needs to be removed. This document captures the procedure.

<br/>

## 1. Why the workaround was temporary

When the PoC stdout DaemonSet went in (2026-05-18), application stdout looked like this:

```
[2026-05-18 07:21:29.744 +0000] \x1b[32mINFO\x1b[39m: \x1b[90m{"level":30,"time":...,"data":{"traceId":"..."}}\x1b[39m
```

- The leading `[YYYY-MM-DD hh:mm:ss.SSS +zzzz] LEVEL: ` prefix is pino-pretty's human-friendly transformation
- The `\x1b[...m` sequences are ANSI color escapes (for terminal rendering)
- The trailing `{ ... }` is the actual Pino NDJSON payload

The existing fluentd `<match example-project.**>` pipeline expects raw NDJSON, so at the fluent-bit stage the 3-filter chain *strips everything but the NDJSON* before forwarding to fluentd:

1. `[FILTER] lua strip_ansi` — removes `\x1b[...m` sequences
2. `[FILTER] parser pino_pretty_extract` — drops the `[ts] LEVEL: ` prefix, captures inner JSON under the `log` key
3. `[FILTER] parser example-project_json_extract` — parses the JSON in `log` and promotes its keys to top-level

This is *temporary* because once the application emits raw NDJSON directly, filters 1 and 2 are unnecessary and only filter 3 remains — with `Key_Name` switched from `log` to `message` (the key the cri parser writes the container log line into).

<br/>

## 2. Coordinate with the game team first

Before changing anything, confirm the following with the game team:

| Item | Expected answer |
|---|---|
| Which component(s) switched stdout to raw NDJSON | Some or all of: game / battle / qa game / staging game |
| One-line stdout sample from a switched component (`kubectl logs`) | No `\x1b`, no `[YYYY-MM-DD ...]` prefix, first char is `{` |
| When the switch was deployed | dev.yaml change should land after that timestamp |
| Did all 4 components switch, or only some | If partial, filter Match patterns need to be split per component |

Sample inspection command:

```bash
# Last 1 line of stdout from a game pod (post-cri-prefix body only)
kubectl -n dev-example-project logs $(kubectl -n dev-example-project get pod -l app=example-project-game -o jsonpath='{.items[0].metadata.name}') --tail=1
```

→ If the body begins with `{"level":30,...}` directly, the switch is done. If it begins with `[2026-...`, it is still pino-pretty.

<br/>

## 3. All 4 components switched — `dev.yaml` edits

Remove 4 blocks and change 1 `Key_Name` in `values/dev.yaml`. Every change point is tagged with `🔥` in the file — search for the marker to locate each one.

### 3-1. Remove — `[FILTER] lua strip_ansi`

Inside `config.filters`:

```diff
-    # 🔥 PINO-PRETTY WORKAROUND BEGIN
-    # Strip ANSI CSI color sequences (\x1b[<digits>m) that pino-pretty injects.
-    # Acts on the `message` field — Parser cri stores the container log line
-    # under `message` (not `log`); Lua + parser filters below must align on the
-    # same key.
-    [FILTER]
-        Name lua
-        Match example-project.stdout.*
-        script /fluent-bit/scripts/strip_ansi.lua
-        call strip_ansi
-
```

### 3-2. Remove — `[FILTER] parser pino_pretty_extract`

Inside `config.filters`, right after the lua filter:

```diff
-    # Extract the JSON object portion from "[<ts>] LEVEL: { ... }".
-    # The pino_pretty_extract parser regex binds the inner JSON string to a new
-    # `log` key for the next parser stage.
-    [FILTER]
-        Name parser
-        Match example-project.stdout.*
-        Key_Name message
-        Parser pino_pretty_extract
-        Reserve_Data On
-        Preserve_Key Off
-    # 🔥 PINO-PRETTY WORKAROUND END
-
```

### 3-3. Change — `[FILTER] parser example-project_json_extract` `Key_Name`

Keep this filter. Change `Key_Name` from `log` to `message` (the cri parser stores the container log line under `message`; previously the filter consumed the `log` key produced by pino_pretty_extract, which no longer exists):

```diff
     [FILTER]
         Name parser
         Match example-project.stdout.*
-        Key_Name log
+        Key_Name message
         Parser example-project_json_extract
         Reserve_Data On
         Preserve_Key Off
```

### 3-4. Remove — `[PARSER] pino_pretty_extract`

Inside `config.customParsers`:

```diff
-    # 🔥 PINO-PRETTY WORKAROUND parser — extracts JSON object after
-    # "[YYYY-MM-DD hh:mm:ss.SSS +zzzz] LEVEL: " prefix produced by pino-pretty.
-    # Remove this parser when stdout switches to raw ndjson.
-    [PARSER]
-        Name pino_pretty_extract
-        Format regex
-        Regex ^\[[^\]]+\]\s+\w+:\s+(?<log>\{.*\})\s*$
-
```

Keep `[PARSER] example-project_json_extract` — it parses the raw NDJSON body.

### 3-5. Remove — the entire `luaScripts.strip_ansi.lua` block + side effect

At the bottom of the file, the entire `luaScripts:` dict:

```diff
-# 🔥 PINO-PRETTY WORKAROUND — entire luaScripts block can be removed when
-# game team disables pino-pretty on stdout.
-luaScripts:
-  strip_ansi.lua: |
-    -- Strip ANSI CSI escape sequences used by pino-pretty for color output.
-    -- Pattern: ESC ('\27') '[' <digits/;>* 'm'
-    -- Operates on the `message` field produced by Parser cri (the standard key
-    -- for container log line content; not `log`).
-    function strip_ansi(tag, ts, record)
-        local msg = record["message"]
-        if msg == nil then
-            return 0, ts, record
-        end
-        record["message"] = string.gsub(msg, "\27%[[%d;]*m", "")
-        return 1, ts, record
-    end
-
```

When `luaScripts` becomes empty, the chart template stops rendering the `ConfigMap/fluent-bit-luascripts`, so `helmfile apply` will auto-delete that ConfigMap. The `luascripts` volumeMount in the DaemonSet pod spec disappears at the same time.

### 3-6. (Optional) Tidy the header comment

The `# 🔥 PINO-PRETTY WORKAROUND (TEMPORARY)` block (~20 lines) at the top of the file is no longer meaningful. Remove it, or compress to a single line in a *change log* style noting when the workaround was retired.

<br/>

## 4. Partial switch — only some components on raw NDJSON

If the game team switches only `dev-example-project-game` to raw NDJSON while other components keep emitting pino-pretty:

Split the existing `Match example-project.stdout.*` into per-component patterns.

### 4-1. Split the lua and pino_pretty_extract filter Match patterns

Target only components that have *not* switched:

```diff
     [FILTER]
         Name lua
-        Match example-project.stdout.*
+        Match example-project.stdout.dev.battle.* example-project.stdout.qa.game.* example-project.stdout.stg.game.*
         script /fluent-bit/scripts/strip_ansi.lua
         call strip_ansi

     [FILTER]
         Name parser
-        Match example-project.stdout.*
+        Match example-project.stdout.dev.battle.* example-project.stdout.qa.game.* example-project.stdout.stg.game.*
         Key_Name message
         Parser pino_pretty_extract
         Reserve_Data On
         Preserve_Key Off
```

> fluent-bit's `Match` accepts multiple space-separated patterns. If only dev game switched, list the other 3.

### 4-2. Split example-project_json_extract into *two* filters

Two input shapes now coexist: switched components emit raw NDJSON in `message` (from cri parser), and non-switched components have the `log` key produced by pino_pretty_extract:

```ini
# For raw-NDJSON-switched components — parse directly from message
[FILTER]
    Name parser
    Match example-project.stdout.dev.game.*
    Key_Name message
    Parser example-project_json_extract
    Reserve_Data On
    Preserve_Key Off

# For still-pino-pretty components — parse from the log key produced by pino_pretty_extract
[FILTER]
    Name parser
    Match example-project.stdout.dev.battle.* example-project.stdout.qa.game.* example-project.stdout.stg.game.*
    Key_Name log
    Parser example-project_json_extract
    Reserve_Data On
    Preserve_Key Off
```

Keep `luaScripts` and `[PARSER] pino_pretty_extract` as long as *any* component still emits pino-pretty. Once the final component switches, follow §3's full-removal procedure.

<br/>

## 5. Apply + verify

```bash
cd observability/logging/fluent-bit
helmfile lint
helmfile -l name=fluent-bit diff   # confirm ConfigMap/Lua entries are removed
helmfile -l name=fluent-bit apply  # DaemonSet 3 pods rolling update
```

Post-apply verification:

```bash
# 1) DaemonSet pod health
kubectl -n logging get pods -l app.kubernetes.io/instance=fluent-bit -o wide

# 2) fluentd skip invalid event (must stay at 0)
kubectl -n logging logs fluentd-0 --since=5m | grep -c "skip invalid event"

# 3) Newest ES doc has fields properly promoted (data.traceId, data.requestPath, …)
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASS" -H 'Content-Type: application/json' \
  "https://localhost:9200/dev-example-project-game/_search" -d '{
    "size": 1, "sort": [{"@timestamp":"desc"}],
    "_source": ["@timestamp","level","data.traceId","data.requestPath","message"]
  }' | python3 -m json.tool
# → data.traceId populated, message empty or non-raw → OK
```

Troubleshooting:
- If `message` still contains raw `{...}` text → `example-project_json_extract` filter's `Key_Name` is wrong. Switched components should use `message`, still-pino-pretty components should use `log`
- If ANSI escapes `\x1b[` appear in docs → the strip_ansi lua filter is missing a component that was assumed to be raw NDJSON but is actually still pino-pretty. Reconfirm with the game team

<br/>

## 6. Commit + plan update

```bash
git add observability/logging/fluent-bit/values/dev.yaml
git commit -m "refactor(observability/logging/fluent-bit): drop pino-pretty workaround after game team switched stdout to raw ndjson"
```

Record the workaround removal in `~/.claude/plans/fluent-bit-prod-aws-topology-review.md` and update the "follow-ups" section of [deployment-to-daemonset-en.md](./deployment-to-daemonset-en.md).
