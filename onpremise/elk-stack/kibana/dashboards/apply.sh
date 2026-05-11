#!/usr/bin/env bash
# Apply Kibana Saved Objects (Lens + Dashboard) NDJSON files to the in-cluster Kibana.
# in-cluster Kibana 에 Saved Objects (Lens + Dashboard) NDJSON 파일을 import.
#
# Default behaviour: imports every *.ndjson in this directory that is NOT a data-view
# bootstrap file (filename matching *-data-view.ndjson). Use --include-data-view to
# also import data-view bootstrap files, or --file to target a specific NDJSON.
# 기본 동작: 이 디렉토리 안의 모든 *.ndjson 중 data-view bootstrap (`*-data-view.ndjson`)
# 패턴을 제외하고 import. data view 까지 import 하려면 --include-data-view,
# 특정 파일만 다루려면 --file 사용.
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

DASHBOARDS_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
KIBANA_SVC="${KIBANA_SVC:-kibana-kb-http.${NAMESPACE}.svc}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
KIBANA_SCHEME="${KIBANA_SCHEME:-http}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"
OVERWRITE="${OVERWRITE:-true}"
INCLUDE_DATA_VIEW="${INCLUDE_DATA_VIEW:-false}"
DATA_VIEW_PATTERN="*-data-view.ndjson"

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
Usage: $(basename "$0") [--file PATH]... [--include-data-view] [--no-overwrite] [--dry-run]

Imports NDJSON Saved Objects into the in-cluster Kibana via the ES pod.
By default every *.ndjson in $(basename "$DASHBOARDS_DIR")/ is imported
(excluding files matching the data-view bootstrap pattern $DATA_VIEW_PATTERN).

Options:
  --file PATH           Import only the given NDJSON file. May be repeated.
                        Path may be absolute or relative to this directory.
  --include-data-view   Also import files matching $DATA_VIEW_PATTERN
                        (skipped by default to avoid overwriting user-managed
                         data view fields like runtime fields).
  --no-overwrite        Set overwrite=false on import (default: overwrite=true).
  --dry-run             Print actions without contacting Kibana.

Env overrides:
  NAMESPACE=$NAMESPACE
  ES_POD=$ES_POD
  ES_CONTAINER=$ES_CONTAINER
  KIBANA_SVC=$KIBANA_SVC
  KIBANA_PORT=$KIBANA_PORT
  KIBANA_SCHEME=$KIBANA_SCHEME
  ES_SECRET=$ES_SECRET
  ES_USER=$ES_USER
EOF
}

DRY_RUN=0
EXPLICIT_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      shift
      [ $# -gt 0 ] || { err "--file requires PATH"; exit 2; }
      EXPLICIT_FILES+=("$1")
      ;;
    --include-data-view) INCLUDE_DATA_VIEW=true ;;
    --no-overwrite)      OVERWRITE=false ;;
    --dry-run)           DRY_RUN=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# Resolve target file list
resolve_files() {
  if [ ${#EXPLICIT_FILES[@]} -gt 0 ]; then
    for f in "${EXPLICIT_FILES[@]}"; do
      if [ -f "$f" ]; then
        printf '%s\n' "$f"
      elif [ -f "$DASHBOARDS_DIR/$f" ]; then
        printf '%s\n' "$DASHBOARDS_DIR/$f"
      else
        err "missing file: $f"
        exit 1
      fi
    done
    return
  fi
  # Auto-discover *.ndjson in this directory
  shopt -s nullglob
  for f in "$DASHBOARDS_DIR"/*.ndjson; do
    base=$(basename "$f")
    # shellcheck disable=SC2053
    if [[ "$base" == $DATA_VIEW_PATTERN ]] && [ "$INCLUDE_DATA_VIEW" != "true" ]; then
      continue
    fi
    printf '%s\n' "$f"
  done
  shopt -u nullglob
}

mapfile -t FILES < <(resolve_files)

if [ ${#FILES[@]} -eq 0 ]; then
  warn "No NDJSON files to import (directory: $DASHBOARDS_DIR)"
  exit 0
fi

# Look up elastic password from the ECK-managed secret
if [ "$DRY_RUN" != "1" ]; then
  PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  if [ -z "$PASS" ]; then
    err "Failed to read password from secret $NAMESPACE/$ES_SECRET key=$ES_USER"
    exit 1
  fi
fi

KIBANA_URL="${KIBANA_SCHEME}://${KIBANA_SVC}:${KIBANA_PORT}"
IMPORT_PATH="/api/saved_objects/_import?overwrite=${OVERWRITE}"

import_one() {
  local file="$1"
  log ""
  log "→ Importing $(basename "$file")"
  log "  file:     $file"
  log "  endpoint: ${KIBANA_URL}${IMPORT_PATH}"
  log "  pod:      ${NAMESPACE}/${ES_POD}"

  if [ "$DRY_RUN" = "1" ]; then
    warn "  (dry-run) skipped"
    return 0
  fi

  local resp
  resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -u "${ES_USER}:${PASS}" -H 'kbn-xsrf: true' \
      -X POST "${KIBANA_URL}${IMPORT_PATH}" \
      -F "file=@-;filename=$(basename "$file");type=application/ndjson" \
      < "$file")

  echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"

  if echo "$resp" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('success') else 1)" 2>/dev/null; then
    ok "  imported"
  else
    err "  import reported failures (see response above)"
    return 1
  fi
}

log "Kibana saved objects apply"
log "  namespace=$NAMESPACE  pod=$ES_POD  kibana=$KIBANA_URL"
log "  overwrite=$OVERWRITE  include-data-view=$INCLUDE_DATA_VIEW  dry-run=$DRY_RUN"
log "  targets (${#FILES[@]}):"
for f in "${FILES[@]}"; do
  log "    - $(basename "$f")"
done

FAIL=0
for f in "${FILES[@]}"; do
  if ! import_one "$f"; then
    FAIL=$((FAIL+1))
  fi
done

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."
  exit 1
fi
ok "Done."
