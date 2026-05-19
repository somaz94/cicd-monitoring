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

## 1-1. Current state (2026-05-19)

- **dev.game
- **qa.game** — still on pino-pretty. **No fixed date for the raw-NDJSON switch** — when it happens, follow §3 (full removal) to delete the lua/pino_pretty regex/parser and consolidate example-project_json_extract back to a single block (`Match example-project.stdout.*`, `Key_Name message`). A drop-in trigger prompt for the next session lives in §7
- **stg.game** — INPUT + modify filter were removed on 2026-05-19 (staging-example-project namespace retired). Bring the INPUT and modify filter back if staging is redeployed

### Two pino-pretty line shapes on qa.game (regex updated 2026-05-19)

Two shapes have been observed in qa.game stdout:

| Shape | Example | When it appears |
|---|---|---|
| A: msg is a raw JSON object | `[ts] INFO: {"level":30,"time":...,"data":{...}}` | Request-handling (most traffic) |
| B: msg has controller-name + sub-object prefix | `[ts] INFO: CostumesController {/costumes}: {"context":...}` or `[ts] INFO: Mapped {/costumes/purchase, POST} route {"...}` | Pod boot — routing setup (NestJS-style) |

The original regex `^\[[^\]]+\]\s+\w+:\s+(?<log>\{.*\})\s*$` matches only Shape A; on Shape B the greedy `\{.*\}` captures `{/costumes}: {"context":...}`, which is invalid JSON. While a qa.game pod stays running for hours, no fresh routing-setup lines are emitted and the limitation is invisible; the moment a restart happens, Shape B lines flood in and traceId / data.* promotion silently fails for those lines.

The regex was updated on 2026-05-19 to cover both shapes:

```
^\[[^\]]+\]\s+\w+:\s+.*?(?<log>\{"[\w-]+":.*\})\s*$
```

- `.*?` (lazy) absorbs any controller-name / route-description prefix before the JSON
- `\{"[\w-]+":` anchors the capture to a JSON object that *starts* with `{"<key>":`, skipping past unquoted `{sub-object}` placeholders inside the prefix
- Verified against Shape A (backward compat), both Shape B variants, JSON with nested data, and plain-text lines (no JSON → no match → fluentd fallback handles them)

Plain-text lines with no JSON (e.g. `[ts] INFO: Application started.`) fall through unchanged: regex misses → fluent-bit example-project_json_extract is skipped → fluentd's record_transformer Step 2 fallback sets level="info", message=raw text, @timestamp=receive time. fluentd's `skip invalid event` counter stays at 0 (no data loss).

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

## 4. Partial switch — only some components on raw JSON

If the game team switches some components to raw JSON while others keep emitting pino-pretty, split the existing `Match example-project.stdout.*` into per-component patterns.

> **2026-05-19 application record**: dev.game (Pino raw NDJSON) and dev.battle (Serilog raw JSON) switched to raw; qa.game stayed on pino-pretty. The stg.game INPUT was removed the same day (staging-example-project namespace retired). The examples below reflect the current applied state.

### 4-1. Split the lua and pino_pretty_extract filter Match patterns

Target only components that have *not* switched:

```diff
     [FILTER]
         Name lua
-        Match example-project.stdout.*
+        Match example-project.stdout.qa.game.*
         script /fluent-bit/scripts/strip_ansi.lua
         call strip_ansi

     [FILTER]
         Name parser
-        Match example-project.stdout.*
+        Match example-project.stdout.qa.game.*
         Key_Name message
         Parser pino_pretty_extract
         Reserve_Data On
         Preserve_Key Off
```

> fluent-bit's `Match` accepts multiple space-separated patterns. If more than one component is still on pino-pretty, list them all: `Match example-project.stdout.qa.game.* example-project.stdout.dev.battle.*`.

### 4-2. Split example-project_json_extract into *two* filters

Two input shapes now coexist: switched components emit raw JSON in `message` (from the cri parser), and non-switched components have the `log` key produced by pino_pretty_extract:

```ini
# For raw-JSON-switched components — parse directly from message
# dev.game = Pino NDJSON, dev.battle = Serilog (.NET) JSON. Both schemas are
# normalized in fluentd's record_transformer (Pino: level int/time int;
# Serilog: Level string/Timestamp ISO8601/MessageTemplate). See
# fluentd values/dev.yaml 02_filters.conf Step 2/3 for the normalization logic.
#
# Caveat: fluent-bit's [FILTER] Match accepts a *single* wildcard pattern
# (unlike [OUTPUT] routing — space-separated multi-patterns silently match
# nothing here). To cover both dev.game and dev.battle, either use a single
# wildcard like `example-project.stdout.dev.*`, or split the [FILTER] block into two.
# The single-wildcard form is shown below:
[FILTER]
    Name parser
    Match example-project.stdout.dev.*
    Key_Name message
    Parser example-project_json_extract
    Reserve_Data On
    Preserve_Key Off

# For still-pino-pretty components — parse from the log key produced by pino_pretty_extract
[FILTER]
    Name parser
    Match example-project.stdout.qa.game.*
    Key_Name log
    Parser example-project_json_extract
    Reserve_Data On
    Preserve_Key Off
```

Keep `luaScripts` and `[PARSER] pino_pretty_extract` as long as *any* component still emits pino-pretty. Once the final component switches, follow §3's full-removal procedure.

### 4-3. Serilog schema handling (.NET applications)

A .NET application such as `dev-example-project-battle` emits JSON via Serilog instead of Pino, so the key names differ and fluentd needs a normalization mapping:

| Serilog key | Value shape | Normalized to |
|---|---|---|
| `Level` (capital L) | string (`"Verbose"`/`"Debug"`/`"Information"`/`"Warning"`/`"Error"`/`"Fatal"`) | `level` (`trace`/`debug`/`info`/`warn`/`error`/`fatal`) |
| `Timestamp` | ISO8601 string with offset (e.g. `"2026-05-19T04:04:16.18+00:00"`) | `@timestamp` (Asia/Seoul ISO8601) |
| `MessageTemplate` | string with `{Placeholder}` tokens | `message` (template body verbatim) |
| `Properties` | free-form object | preserved (ES dynamic mapping) |

Additionally, the .NET application's *bootup plain-text lines* (e.g. `Now listening on: http://[::]:8081`, `info: Microsoft.Hosting.Lifetime[0]`) are not JSON, so fluent-bit's `example-project_json_extract` parser fails on them. In that case the `message` key produced by the cri parser keeps the raw text and is forwarded as-is to fluentd, where Step 2's fallback assigns `level="info"` and `message=raw text` — these lines still index cleanly.

The fluentd-side normalization mapping lives in one place — `observability/logging/fluentd/values/dev.yaml`, `02_filters.conf` Step 2 (level + message) and Step 3 (`@timestamp` + `remove_keys`). The full-removal procedure in §3 of this guide does not affect Serilog handling (the fluentd-side change is self-contained).

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

After removal, update the "follow-ups" section of [deployment-to-daemonset-en.md](./deployment-to-daemonset-en.md) to leave a trail.

<br/>

## 7. Trigger prompt for when qa.game switches off pino-pretty

When the game team finally turns off pino-pretty on qa.game stdout, drop the following prompt into Claude in the next session to start the §3 full-removal procedure automatically:

```
In ~/gitlab-project/kuberntes-infra/, qa.game stdout has switched to raw NDJSON. Please:

1. Apply the §3 full-removal procedure from observability/logging/fluent-bit/docs/pino-pretty-removal-en.md:
   - Remove the luaScripts.strip_ansi.lua block from values/dev.yaml
   - Remove [FILTER] lua strip_ansi (Match example-project.stdout.qa.game.*)
   - Remove [FILTER] parser pino_pretty_extract (Match example-project.stdout.qa.game.*)
   - Remove [PARSER] pino_pretty_extract inside config.customParsers
   - Widen the raw-branch example-project_json_extract Match from example-project.stdout.dev.*
     to example-project.stdout.*, and delete the pino-pretty branch
     (Match qa.game.*, Key_Name log)
   - Remove the 🔥 PINO-PRETTY block at the top of the file, or compress it
     to a one-line "switch completed" trail
2. Update 4 docs:
   - docs/pino-pretty-removal.md / -en.md: drop the qa.game line from §1-1
     "current state", mark §4 partial-switch section as historical, and
     remove §7 (this prompt) since it is no longer needed
   - docs/deployment-to-daemonset.md / -en.md: add a "qa.game raw switch
     completed (date)" trail to §8 follow-ups
3. helmfile lint + diff + apply (require explicit user approval first)
4. ES verification:
   - Latest doc in dev-example-project-game / dev-example-project-battle / qa-example-project-game
   - All three should have data.traceId / data.requestPath promoted (qa.game
     now flows through the single raw-branch example-project_json_extract)
   - fluentd skip invalid event count stays at 0
5. Commit (single-line EN, Conventional Commits) + update plan (add a final
   lessons-learned entry)

This task corresponds to "후속 plan 후보 #1" in
~/.claude/plans/gitlab-project-kuberntes-infra-fluent-bit-pino-pretty-partial-removal-crimson-egret.md.
Once done, drop that candidate from the plan and delete §7 from these docs.
```

The prompt assumes the switch has been confirmed by:

```bash
# Confirm qa.game stdout actually switched to raw NDJSON
kubectl -n qa-example-project logs $(kubectl -n qa-example-project get pod -l app.kubernetes.io/instance=qa-example-project-game -o jsonpath='{.items[0].metadata.name}') --tail=5
# → If the body begins with {"level":30,...} (no \x1b, no [2026-... prefix), the switch is done.
```
