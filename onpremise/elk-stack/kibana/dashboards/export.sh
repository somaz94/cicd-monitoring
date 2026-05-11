#!/usr/bin/env bash
# Sync live Kibana saved objects back to repo NDJSON (reverse of apply.sh).
# 라이브 Kibana 의 saved objects 를 repo NDJSON 으로 동기화 (apply.sh 의 역방향).
#
# Default: exports every dashboard listed in `manifest.txt` (one "<dashboard-id>  <ndjson-file>"
# per line, comments with #). You can override per-run with --id/--out.
# 기본 동작: manifest.txt 에 등록된 모든 dashboard 를 export (한 줄당
# "<dashboard-id>  <ndjson-file>", `#` 주석 가능). --id/--out 으로 1회용 override.
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

DASHBOARDS_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${MANIFEST:-$DASHBOARDS_DIR/manifest.txt}"
NAMESPACE="${NAMESPACE:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
KIBANA_SVC="${KIBANA_SVC:-kibana-kb-http.${NAMESPACE}.svc}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
KIBANA_SCHEME="${KIBANA_SCHEME:-http}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"
DATA_VIEW_FILE="${DATA_VIEW_FILE:-dev-example-project-game-data-view.ndjson}"
EMIT_DATA_VIEW="${EMIT_DATA_VIEW:-true}"

if [ -t 1 ]; then
  C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_RST="\033[0m"
else
  C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi
log()  { printf "%b\n" "$*"; }
ok()   { log "${C_OK}✓${C_RST} $*"; }
warn() { log "${C_WARN}!${C_RST} $*"; }
err()  { log "${C_ERR}✗${C_RST} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--id UUID --out FILE]... [--no-data-view] [--dry-run]

Exports dashboards (and their references) from the in-cluster Kibana into NDJSON
files. Run after editing dashboards/lenses in the Kibana UI to capture the new
state into the repo.

Options:
  --id UUID --out FILE  Export a specific dashboard ID to FILE (relative to this
                        directory or absolute). May be repeated for multiple
                        dashboards. When given, the manifest is ignored.
  --no-data-view        Skip writing the data-view bootstrap NDJSON (default: write).
  --dry-run             Print what would be exported without writing files.

Manifest format ($MANIFEST):
  # comments allowed
  <dashboard-uuid>  <ndjson-filename>

Env overrides:
  MANIFEST=$MANIFEST
  NAMESPACE=$NAMESPACE
  ES_POD=$ES_POD
  ES_CONTAINER=$ES_CONTAINER
  KIBANA_SVC=$KIBANA_SVC
  KIBANA_PORT=$KIBANA_PORT
  KIBANA_SCHEME=$KIBANA_SCHEME
  ES_SECRET=$ES_SECRET
  ES_USER=$ES_USER
  DATA_VIEW_FILE=$DATA_VIEW_FILE
EOF
}

DRY_RUN=0
declare -a ARG_IDS=()
declare -a ARG_OUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id)
      shift; [ $# -gt 0 ] || { err "--id requires UUID"; exit 2; }
      ARG_IDS+=("$1")
      ;;
    --out)
      shift; [ $# -gt 0 ] || { err "--out requires FILE"; exit 2; }
      ARG_OUTS+=("$1")
      ;;
    --no-data-view) EMIT_DATA_VIEW=false ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ ${#ARG_IDS[@]} -ne ${#ARG_OUTS[@]} ]; then
  err "each --id needs a matching --out (got ${#ARG_IDS[@]} ids vs ${#ARG_OUTS[@]} outs)"
  exit 2
fi

# Build the (id, file) work list
declare -a IDS=()
declare -a FILES=()
if [ ${#ARG_IDS[@]} -gt 0 ]; then
  for i in "${!ARG_IDS[@]}"; do
    IDS+=("${ARG_IDS[$i]}")
    FILES+=("${ARG_OUTS[$i]}")
  done
else
  if [ ! -f "$MANIFEST" ]; then
    err "manifest not found: $MANIFEST (provide --id/--out or create the manifest)"
    exit 1
  fi
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"          # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [ -z "$line" ] && continue
    id="${line%%[[:space:]]*}"
    file="${line#"$id"}"
    file="${file#"${file%%[![:space:]]*}"}"
    if [ -z "$id" ] || [ -z "$file" ]; then
      warn "manifest skip (malformed line): $raw"
      continue
    fi
    IDS+=("$id")
    FILES+=("$file")
  done < "$MANIFEST"
fi

if [ ${#IDS[@]} -eq 0 ]; then
  warn "Nothing to export (manifest empty and no --id given)"
  exit 0
fi

KIBANA_URL="${KIBANA_SCHEME}://${KIBANA_SVC}:${KIBANA_PORT}"
EXPORT_PATH="/api/saved_objects/_export"

log "Kibana saved objects export"
log "  namespace=$NAMESPACE  pod=$ES_POD  kibana=$KIBANA_URL"
log "  manifest=$MANIFEST  emit-data-view=$EMIT_DATA_VIEW  dry-run=$DRY_RUN"
log "  targets (${#IDS[@]}):"
for i in "${!IDS[@]}"; do
  log "    - ${IDS[$i]} → ${FILES[$i]}"
done

if [ "$DRY_RUN" = "1" ]; then
  warn "(dry-run) no network call, no files written"
  exit 0
fi

PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
if [ -z "$PASS" ]; then
  err "Failed to read password from secret $NAMESPACE/$ES_SECRET key=$ES_USER"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

DATA_VIEW_RAW=""

export_one() {
  local id="$1"
  local out="$2"
  local raw="$WORKDIR/$(basename "$out").raw"

  # Resolve out to absolute path
  case "$out" in
    /*) ;;  # already absolute
    *)  out="$DASHBOARDS_DIR/$out" ;;
  esac

  log ""
  log "→ Exporting dashboard $id"
  log "  out: $out"

  local req
  req=$(printf '{"objects":[{"type":"dashboard","id":"%s"}],"includeReferencesDeep":true,"excludeExportDetails":false}' "$id")

  kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -u "${ES_USER}:${PASS}" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
      -X POST "${KIBANA_URL}${EXPORT_PATH}" -d "$req" \
    > "$raw"

  if [ ! -s "$raw" ]; then
    err "  empty response from Kibana for id=$id"
    return 1
  fi

  # Detect error responses (Kibana returns JSON with statusCode on failure)
  if head -1 "$raw" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('statusCode') else 1)" 2>/dev/null; then
    err "  Kibana error response:"
    cat "$raw"
    return 1
  fi

  # Split NDJSON into main (lens + dashboard) and bootstrap (data view)
  # NDJSON 을 main(lens + dashboard) 과 bootstrap(data view) 으로 분리
  DATA_VIEW_RAW="$raw" python3 - "$raw" "$out" "$WORKDIR" <<'PYEOF'
import json, sys, pathlib, os
raw_path = sys.argv[1]
out_path = pathlib.Path(sys.argv[2])
workdir  = pathlib.Path(sys.argv[3])

objs, summary = [], None
with open(raw_path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        if 'type' not in o:
            summary = o
        else:
            objs.append(o)

lenses     = sorted([o for o in objs if o['type']=='lens'], key=lambda x: x['attributes']['title'])
dashboards = [o for o in objs if o['type']=='dashboard']
idx_pats   = [o for o in objs if o['type']=='index-pattern']

with open(out_path, 'w') as f:
    for o in lenses + dashboards:
        f.write(json.dumps(o, separators=(',',':')) + '\n')
    if summary:
        s = dict(summary)
        s['exportedCount']  = len(lenses) + len(dashboards)
        s['missingRefCount'] = 0
        s['missingReferences'] = []
        f.write(json.dumps(s, separators=(',',':')) + '\n')

# Stash data-view NDJSON in workdir; main script decides whether to write it.
if idx_pats:
    dv_path = workdir / 'data-view-objs.json'
    payload = {'objs': idx_pats, 'summary': summary}
    with open(dv_path, 'w') as f:
        json.dump(payload, f)

print(f"  main: {out_path.name} ({len(lenses)} lens + {len(dashboards)} dashboard)")
for o in lenses + dashboards:
    print(f"    - {o['type']:10s} {o['id']} | {o['attributes']['title']}")
if idx_pats:
    print(f"  (captured {len(idx_pats)} data-view object(s) for bootstrap)")
PYEOF
}

FAIL=0
for i in "${!IDS[@]}"; do
  if ! export_one "${IDS[$i]}" "${FILES[$i]}"; then
    FAIL=$((FAIL+1))
  fi
done

# Emit data view bootstrap once (deduplicated across all exported dashboards)
# 모든 dashboard 의 data view 객체를 합쳐 1회 출력 (중복 제거)
if [ "$EMIT_DATA_VIEW" = "true" ] && [ -f "$WORKDIR/data-view-objs.json" ]; then
  python3 - "$WORKDIR" "$DASHBOARDS_DIR/$DATA_VIEW_FILE" <<'PYEOF'
import json, sys, pathlib, glob
workdir = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])

merged = {}
last_summary = None
for fp in glob.glob(str(workdir / '*.raw')):
    # Re-read raw exports to merge all index-pattern refs.
    with open(fp) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if 'type' not in o:
                last_summary = o
                continue
            if o['type'] == 'index-pattern':
                merged[o['id']] = o

with open(out_path, 'w') as f:
    for o in merged.values():
        f.write(json.dumps(o, separators=(',',':')) + '\n')
    if last_summary and merged:
        s = dict(last_summary)
        s['exportedCount'] = len(merged)
        f.write(json.dumps(s, separators=(',',':')) + '\n')

print(f"  bootstrap: {out_path.name} ({len(merged)} index-pattern object(s))")
PYEOF
fi

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."
  exit 1
fi

repo_root=$(git -C "$DASHBOARDS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DASHBOARDS_DIR/../..")
ok "Done. Review changes with: git -C $repo_root diff -- observability/logging/kibana/dashboards/"
