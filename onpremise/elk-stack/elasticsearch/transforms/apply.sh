#!/usr/bin/env bash
# Apply (PUT + start) ES Transform jobs from JSON definitions in this directory.
# 이 디렉토리의 JSON 정의를 ES Transform job 으로 PUT + start.
#
# Each "<name>.json" produces a transform with id="<name>". Re-running is safe:
# PUT with `defer_validation=false` will fail when an existing transform is running,
# so the script first stops & deletes (or updates) when --replace is given.
# 각 "<name>.json" 은 id="<name>" 인 transform 으로 등록. 재실행 시:
# --replace 면 기존을 stop+delete 후 재등록, 기본은 존재 시 skip(idempotent).
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
Usage: $(basename "$0") [--file PATH]... [--preview-only] [--replace] [--no-start] [--dry-run]

Registers (PUT) and starts ES Transform jobs from JSON definitions in this directory.
Default: every "<name>.json" → transform id="<name>", PUT (skip if exists) + start.

Options:
  --file PATH         Apply only the given JSON. May be repeated.
  --preview-only      Call _preview only (no PUT, no start). Useful for validation.
  --replace           Stop + delete + re-PUT existing transforms (use after definition changes).
  --no-start          Register only (PUT), do not start.
  --dry-run           Print actions without contacting ES.

Env overrides:
  NAMESPACE=$NAMESPACE  ES_POD=$ES_POD
  ES_SVC=$ES_SVC  ES_PORT=$ES_PORT  ES_SCHEME=$ES_SCHEME
  ES_SECRET=$ES_SECRET  ES_USER=$ES_USER
EOF
}

DRY_RUN=0
PREVIEW_ONLY=0
REPLACE=0
NO_START=0
EXPLICIT_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      shift; [ $# -gt 0 ] || { err "--file requires PATH"; exit 2; }
      EXPLICIT_FILES+=("$1")
      ;;
    --preview-only) PREVIEW_ONLY=1 ;;
    --replace)      REPLACE=1 ;;
    --no-start)     NO_START=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

resolve_files() {
  if [ ${#EXPLICIT_FILES[@]} -gt 0 ]; then
    for f in "${EXPLICIT_FILES[@]}"; do
      if [ -f "$f" ]; then
        printf '%s\n' "$f"
      elif [ -f "$TRANSFORMS_DIR/$f" ]; then
        printf '%s\n' "$TRANSFORMS_DIR/$f"
      else
        err "missing file: $f"; exit 1
      fi
    done
    return
  fi
  shopt -s nullglob
  for f in "$TRANSFORMS_DIR"/*.json; do
    printf '%s\n' "$f"
  done
  shopt -u nullglob
}

mapfile -t FILES < <(resolve_files)
if [ ${#FILES[@]} -eq 0 ]; then
  warn "No transform definitions found in $TRANSFORMS_DIR"; exit 0
fi

if [ "$DRY_RUN" != "1" ]; then
  PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  [ -z "$PASS" ] && { err "Failed to read elastic password"; exit 1; }
fi

ES_URL="${ES_SCHEME}://${ES_SVC}:${ES_PORT}"

es_curl() {
  # $1 method, $2 path, optional stdin body
  local method="$1" path="$2"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) curl $method ${ES_URL}${path}"
    return 0
  fi
  kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" -H 'Content-Type: application/json' \
      -X "$method" "${ES_URL}${path}" "$@"
}

transform_exists() {
  local id="$1"
  if [ "$DRY_RUN" = "1" ]; then return 1; fi
  local code
  code=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" -o /dev/null -w '%{http_code}' \
      "${ES_URL}/_transform/${id}")
  [ "$code" = "200" ]
}

apply_one() {
  local file="$1"
  local id; id="$(basename "${file%.json}")"

  log ""
  log "→ Transform id=$id  file=$(basename "$file")"

  # --preview-only: call _preview and stop
  if [ "$PREVIEW_ONLY" = "1" ]; then
    log "  preview only"
    if [ "$DRY_RUN" = "1" ]; then
      log "    (dry-run) POST ${ES_URL}/_transform/_preview"
      return 0
    fi
    local resp
    resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
      curl -sk -u "${ES_USER}:${PASS}" -H 'Content-Type: application/json' \
        -X POST "${ES_URL}/_transform/_preview" --data-binary @- < "$file")
    echo "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if d.get('error'):
    print('ERROR:', json.dumps(d['error'], indent=2)[:1500]); sys.exit(1)
preview = d.get('preview', [])
print(f'  preview rows: {len(preview)}')
for row in preview[:3]:
    print('   ', json.dumps({k:row[k] for k in row if k != 'documents'}, default=str))
" || return 1
    return 0
  fi

  # If existing transform and --replace, stop & delete first
  if transform_exists "$id"; then
    if [ "$REPLACE" = "1" ]; then
      log "  existing → stop + delete (--replace)"
      kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
        curl -sk -u "${ES_USER}:${PASS}" -X POST "${ES_URL}/_transform/${id}/_stop?wait_for_completion=true&force=true" > /dev/null
      kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
        curl -sk -u "${ES_USER}:${PASS}" -X DELETE "${ES_URL}/_transform/${id}?force=true" > /dev/null
    else
      log "  exists → skip PUT (use --replace to redefine)"
      _start_if_needed "$id"
      return 0
    fi
  fi

  # PUT (register)
  log "  PUT  ${ES_URL}/_transform/${id}"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run)"
  else
    local put_resp
    put_resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
      curl -sk -u "${ES_USER}:${PASS}" -H 'Content-Type: application/json' \
        -X PUT "${ES_URL}/_transform/${id}" --data-binary @- < "$file")
    echo "$put_resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if d.get('error'):
    print('  PUT ERROR:', json.dumps(d['error'], indent=2)[:1500]); sys.exit(1)
print('  PUT ok:', d.get('acknowledged', d))
" || return 1
  fi

  _start_if_needed "$id"
}

_start_if_needed() {
  local id="$1"
  if [ "$NO_START" = "1" ]; then
    log "  --no-start: leaving transform in 'stopped' state"
    return 0
  fi
  log "  START ${ES_URL}/_transform/${id}/_start"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run)"
    return 0
  fi
  local start_resp
  start_resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" -X POST "${ES_URL}/_transform/${id}/_start")
  echo "$start_resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if d.get('error') and 'already started' not in json.dumps(d['error']):
    print('  START ERROR:', json.dumps(d['error'], indent=2)[:1500]); sys.exit(1)
print('  START ok:', d.get('acknowledged', d))
" || return 1
}

log "ES Transforms apply"
log "  namespace=$NAMESPACE  pod=$ES_POD  es=$ES_URL"
log "  preview-only=$PREVIEW_ONLY  replace=$REPLACE  no-start=$NO_START  dry-run=$DRY_RUN"
log "  files (${#FILES[@]}):"
for f in "${FILES[@]}"; do log "    - $(basename "$f")"; done

FAIL=0
for f in "${FILES[@]}"; do
  if ! apply_one "$f"; then
    FAIL=$((FAIL+1))
  fi
done

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."; exit 1
fi
ok "Done."
