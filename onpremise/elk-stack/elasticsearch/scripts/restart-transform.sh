#!/usr/bin/env bash
# Restart (stop + _reset + start) an Elasticsearch transform by id.
#
# Operational intent: typical use is "I just replaced the dest index mapping
# and want the transform to reprocess every source doc from scratch". A bare
# transform_start does NOT do this — the in-memory checkpoint survives the
# dest-index DELETE, so ES keeps incrementing from the previous time_upper_bound
# instead of backfilling. _reset clears the checkpoint + stats so the next
# start replays the full source.
#
# Steps (numbered in script output):
#   0. Pre-flight                 — transform exists
#   1. Stop transform             POST /_transform/<id>/_stop  (force=true)
#   2. Reset transform            POST /_transform/<id>/_reset  (skipped with --stop-only)
#   3. Start transform            POST /_transform/<id>/_start  (skipped with --stop-only)
#   4. Verify                     GET  /_transform/<id>/_stats   — print state + checkpoint
#
# This script does NOT touch indices or saved objects. To recreate the dest
# index with a new mapping, follow the canonical workflow:
#   1) restart-transform.sh <id> --stop-only
#   2) kubectl ... curl -X DELETE  /<dest-index>
#   3) cd ../transforms && ./apply.sh --file <id>.json --replace
#      (apply.sh will PUT the sibling <id>.mapping.json before the transform)
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

# --- defaults -----------------------------------------------------------------

TRANSFORM_ID=""
DRY_RUN=0
STOP_ONLY=0
CONFIRM_PROMPT=1

NAMESPACE_ES="${NAMESPACE_ES:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
ES_SVC="${ES_SVC:-localhost}"
ES_PORT="${ES_PORT:-9200}"
ES_SCHEME="${ES_SCHEME:-https}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"

# --- pretty print -------------------------------------------------------------

if [ -t 1 ]; then
  C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_DIM="\033[2m"; C_RST="\033[0m"
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
log()  { printf "%b\n" "$*"; }
ok()   { log "${C_OK}✓${C_RST} $*"; }
warn() { log "${C_WARN}!${C_RST} $*"; }
err()  { log "${C_ERR}✗${C_RST} $*" >&2; }
step() { log ""; log "${C_DIM}[step $1]${C_RST} $2"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") TRANSFORM_ID [options]

Stop, _reset, and start an Elasticsearch transform. _reset clears the
in-memory checkpoint + stats so the next start replays the full source
index — the typical post-mapping-change workflow.

Required:
  TRANSFORM_ID                  Transform id (e.g. qa-example-project-game-user-cohort).

Options:
  --stop-only                   Stop the transform but do NOT _reset or _start.
                                Useful before manually re-creating the dest index.
  --dry-run                     Print the actions without contacting ES.
  -y, --yes                     Skip the interactive 'restart <id>' confirmation prompt (CI use).
  -h, --help                    Show this help and exit.

Env overrides (rarely needed):
  NAMESPACE_ES=${NAMESPACE_ES}
  ES_POD=${ES_POD}  ES_CONTAINER=${ES_CONTAINER}
  ES_SVC=${ES_SVC}  ES_PORT=${ES_PORT}  ES_SCHEME=${ES_SCHEME}
  ES_SECRET=${ES_SECRET}  ES_USER=${ES_USER}

Examples:
  # Full restart with explicit confirmation:
  $(basename "$0") qa-example-project-game-user-cohort

  # Stop only — pair with DELETE /dest + apply.sh --replace when changing mapping:
  $(basename "$0") qa-example-project-game-user-cohort --stop-only -y

  # Dry-run to inspect the planned curl commands:
  $(basename "$0") qa-example-project-game-user-cohort --dry-run -y
EOF
}

# --- arg parse ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --stop-only)  STOP_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -y|--yes)     CONFIRM_PROMPT=0 ;;
    -h|--help)    usage; exit 0 ;;
    --*)
      err "unknown option: $1"; usage; exit 2 ;;
    *)
      if [ -n "$TRANSFORM_ID" ]; then
        err "unexpected positional argument: $1 (TRANSFORM_ID already set to '$TRANSFORM_ID')"
        exit 2
      fi
      TRANSFORM_ID="$1"
      ;;
  esac
  shift
done

if [ -z "$TRANSFORM_ID" ]; then
  err "TRANSFORM_ID is required"
  usage
  exit 2
fi
# DNS-label-ish id check — matches the ES transform id naming rules in practice.
if ! [[ "$TRANSFORM_ID" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  err "invalid TRANSFORM_ID '$TRANSFORM_ID' — must match ^[a-z0-9][a-z0-9._-]*\$"
  exit 2
fi

ES_URL="${ES_SCHEME}://${ES_SVC}:${ES_PORT}"
PASS=""

# --- ES helpers ---------------------------------------------------------------

load_es_pass() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  PASS=$(kubectl -n "$NAMESPACE_ES" get secret "$ES_SECRET" \
    -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  [ -n "$PASS" ] || { err "failed to read elastic password from secret/$ES_SECRET"; exit 1; }
}

es_curl() {
  local method="$1" path="$2"
  shift 2
  if [ "$DRY_RUN" = "1" ]; then
    printf "    (dry-run) curl -X %s %s%s\n" "$method" "$ES_URL" "$path" >&2
    return 0
  fi
  kubectl -n "$NAMESPACE_ES" exec "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" \
      -H 'Content-Type: application/json' \
      -X "$method" "${ES_URL}${path}" "$@"
}

es_status() {
  local method="$1" path="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "000"
    return 0
  fi
  kubectl -n "$NAMESPACE_ES" exec "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${PASS}" -o /dev/null -w '%{http_code}' \
      -X "$method" "${ES_URL}${path}"
}

# --- confirmation -------------------------------------------------------------

print_plan() {
  log ""
  log "Transform restart plan"
  log "  transform id:         ${TRANSFORM_ID}"
  log "  mode:                 $([ "$STOP_ONLY" = 1 ] && echo 'stop only (no _reset, no _start)' || echo 'stop + _reset + _start')"
  log "  ES pod:               ${NAMESPACE_ES}/${ES_POD} (container=${ES_CONTAINER})"
  log "  dry-run:              $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
}

confirm_or_exit() {
  [ "$CONFIRM_PROMPT" = "0" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  log ""
  if [ "$STOP_ONLY" = "1" ]; then
    warn "This will STOP the transform '${TRANSFORM_ID}'."
  else
    warn "This will STOP + _RESET + START the transform '${TRANSFORM_ID}'."
    warn "  _reset clears checkpoint + stats — the next start replays the full source index."
  fi
  printf "Type 'restart %s' to continue: " "$TRANSFORM_ID"
  local answer=""
  IFS= read -r answer || true
  if [ "$answer" != "restart ${TRANSFORM_ID}" ]; then
    err "aborted (expected 'restart ${TRANSFORM_ID}', got: '$answer')"
    exit 1
  fi
}

# --- step 0: pre-flight -------------------------------------------------------

preflight_transform_exists() {
  local code
  code=$(es_status GET "/_transform/${TRANSFORM_ID}")
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) assume transform exists"
    return 0
  fi
  if [ "$code" != "200" ]; then
    err "transform '${TRANSFORM_ID}' not found (HTTP ${code})."
    exit 1
  fi
  ok "transform exists"
}

# --- step 1: stop -------------------------------------------------------------

stop_transform() {
  step 1 "Stop transform '${TRANSFORM_ID}'"
  local resp
  resp=$(es_curl POST "/_transform/${TRANSFORM_ID}/_stop?wait_for_completion=true&force=true" || true)
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  if printf '%s' "$resp" | grep -q '"acknowledged":true'; then
    ok "transform stopped"
  else
    err "unexpected stop response: $resp"
    exit 1
  fi
}

# --- step 2: _reset -----------------------------------------------------------

reset_transform() {
  step 2 "Reset transform stats + checkpoint"
  local resp
  resp=$(es_curl POST "/_transform/${TRANSFORM_ID}/_reset" || true)
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  if printf '%s' "$resp" | grep -q '"acknowledged":true'; then
    ok "transform reset (next start will replay the full source)"
  else
    err "unexpected reset response: $resp"
    exit 1
  fi
}

# --- step 3: start ------------------------------------------------------------

start_transform() {
  step 3 "Start transform '${TRANSFORM_ID}'"
  local resp
  resp=$(es_curl POST "/_transform/${TRANSFORM_ID}/_start" || true)
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  if printf '%s' "$resp" | grep -q '"acknowledged":true'; then
    ok "transform started"
  else
    err "unexpected start response: $resp"
    exit 1
  fi
}

# --- step 4: verify -----------------------------------------------------------

verify() {
  step 4 "Verify transform state + first checkpoint"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) GET /_transform/${TRANSFORM_ID}/_stats"
    return 0
  fi
  # Give the transform a moment to either move past 'started' or, in stop-only
  # mode, report 'stopped'.
  sleep 5
  local resp
  resp=$(es_curl GET "/_transform/${TRANSFORM_ID}/_stats" || true)
  printf '%s' "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ts = d.get('transforms') or []
if not ts:
    print('    (no transform returned by _stats)')
    sys.exit(0)
t = ts[0]
s = t.get('stats', {})
cp = t.get('checkpointing', {}).get('last', {}).get('checkpoint')
print('    state                  =', t.get('state'))
print('    last checkpoint        =', cp)
print('    pages_processed        =', s.get('pages_processed'))
print('    documents_processed    =', s.get('documents_processed'))
print('    documents_indexed      =', s.get('documents_indexed'))
print('    index_failures         =', s.get('index_failures'))
print('    search_failures        =', s.get('search_failures'))
" || true
}

# --- main ---------------------------------------------------------------------

main() {
  print_plan
  confirm_or_exit
  load_es_pass

  step 0 "Pre-flight checks"
  preflight_transform_exists

  stop_transform
  if [ "$STOP_ONLY" = "1" ]; then
    log ""
    ok "Done (stop-only). Next: DELETE the dest index and run ../transforms/apply.sh --file <id>.json --replace, or _start the transform again with this script (without --stop-only)."
    verify
    return 0
  fi
  reset_transform
  start_transform
  verify

  log ""
  ok "Done. Transform '${TRANSFORM_ID}' is reprocessing the full source — first checkpoint within one frequency cycle."
}

main "$@"
