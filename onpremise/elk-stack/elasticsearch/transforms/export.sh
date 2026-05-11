#!/usr/bin/env bash
# Pull ES Transform definitions from the cluster back into this directory as JSON.
# 클러스터의 ES Transform 정의를 이 디렉토리의 JSON 으로 동기화 (apply.sh 의 역방향).
#
# Default: export every transform whose id matches a "<id>.json" file already present.
# Use --id <id> to export a specific transform (creates a new <id>.json if missing).
# 기본: 디렉토리에 이미 "<id>.json" 으로 존재하는 transform 들을 export.
# --id <id> 로 특정 transform 만 export 가능 (없는 파일은 신규 생성).
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

TRANSFORMS_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
ES_SVC="${ES_SVC:-localhost}"
ES_PORT="${ES_PORT:-9200}"
ES_SCHEME="${ES_SCHEME:-https}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"

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
Usage: $(basename "$0") [--id ID]... [--dry-run]

Exports ES Transform definitions from the cluster as JSON files in this directory.
By default, every existing "<id>.json" file → re-pulled from ES (and overwritten).

Options:
  --id ID     Export a specific transform id (file created if missing). Repeatable.
  --dry-run   Print actions without contacting ES or writing files.

Env overrides:
  NAMESPACE=$NAMESPACE  ES_POD=$ES_POD
  ES_SVC=$ES_SVC  ES_PORT=$ES_PORT  ES_SCHEME=$ES_SCHEME
  ES_SECRET=$ES_SECRET  ES_USER=$ES_USER
EOF
}

DRY_RUN=0
ARG_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id)
      shift; [ $# -gt 0 ] || { err "--id requires ID"; exit 2; }
      ARG_IDS+=("$1")
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# Resolve target id list
declare -a IDS=()
if [ ${#ARG_IDS[@]} -gt 0 ]; then
  IDS=("${ARG_IDS[@]}")
else
  shopt -s nullglob
  for f in "$TRANSFORMS_DIR"/*.json; do
    IDS+=("$(basename "${f%.json}")")
  done
  shopt -u nullglob
fi

if [ ${#IDS[@]} -eq 0 ]; then
  warn "No transform ids to export (no JSON files yet — provide --id <id>)"
  exit 0
fi

log "ES Transforms export"
log "  namespace=$NAMESPACE  pod=$ES_POD  dry-run=$DRY_RUN"
log "  targets (${#IDS[@]}):"
for id in "${IDS[@]}"; do log "    - $id"; done

if [ "$DRY_RUN" = "1" ]; then
  warn "(dry-run) no network call, no files written"
  exit 0
fi

PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
[ -z "$PASS" ] && { err "Failed to read elastic password"; exit 1; }

ES_URL="${ES_SCHEME}://${ES_SVC}:${ES_PORT}"

FAIL=0
for id in "${IDS[@]}"; do
  log ""
  log "→ GET ${ES_URL}/_transform/${id}"
  resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" "${ES_URL}/_transform/${id}")

  # Detect not-found
  if echo "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if d.get('status') == 404 or 'resource_not_found_exception' in json.dumps(d):
    sys.exit(2)
if not d.get('transforms'):
    sys.exit(3)
" 2>/dev/null; then :; else
    err "  not found or empty: $id"
    FAIL=$((FAIL+1))
    continue
  fi

  # Extract only the user-supplied definition fields (drop create_time, version, etc.)
  # 사용자 정의 필드만 추출 (create_time, version 등 메타데이터 제거)
  out_file="$TRANSFORMS_DIR/${id}.json"
  tmp_in=$(mktemp)
  printf '%s' "$resp" > "$tmp_in"
  python3 - "$tmp_in" "$out_file" <<'PYEOF'
import json, sys
in_path, out_path = sys.argv[1], sys.argv[2]
with open(in_path) as f:
    d = json.load(f)
t = d['transforms'][0]
keep = {}
for k in ('description', 'source', 'pivot', 'latest', 'dest', 'frequency', 'sync', 'retention_policy', 'settings'):
    if k in t:
        keep[k] = t[k]
with open(out_path, 'w') as f:
    json.dump(keep, f, indent=2)
    f.write('\n')
print(f'  wrote: {out_path}')
PYEOF
  rm -f "$tmp_in"
done

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."; exit 1
fi
ok "Done. Review changes with: git -C $(git -C "$TRANSFORMS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$TRANSFORMS_DIR/../..") diff -- observability/logging/elasticsearch/transforms/"
