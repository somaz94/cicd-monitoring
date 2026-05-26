#!/usr/bin/env bash
# Reset the ExampleProject raw + cohort indices for the given environment (any
# DNS-label-ish prefix — qa, dev, stg, prod, ...) and let the cohort transform
# repopulate from fresh data only.
#
# Operational intent: ES-side reset only — transform stop / cohort+raw DELETE
# / transform start, with a fluent-bit DaemonSet rollout restart so the next
# polled log file starts at EOF after pod rotation.
#
# Out-of-scope: fluent-bit tail SQLite + fluentd buffer wipe (legacy "scenario
# A"). That branch was retired on 2026-05-22 — the cleanup-Job pattern assumed
# a Deployment + RWO PVC layout, which no longer exists after the 2026-05-19
# DaemonSet + hostPath migration. The script now targets a single,
# unambiguous flow. If you really need to drop in-flight fluent-bit /
# fluentd state, follow the manual per-node cleanup section in
# docs/reset-example-project-cohort.md — it is intentionally not automated.
#
# Steps (numbered in script output):
#   0. Pre-flight                — transform exists
#   1. Stop transform            POST /_transform/<id>/_stop
#   2. Delete cohort dest index  DELETE /<env>-example-project-game-user-cohort
#   3. Delete raw index          DELETE /<env>-example-project-game
#   4. fluent-bit rollout restart (DaemonSet)  (skip with --skip-fluent-bit-restart)
#   5. Wait for raw index re-creation from new fluent-bit forwards
#   6. Start transform           POST /_transform/<id>/_start
#   7. Verify                    raw docs.count + cohort first_seen sample
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

# --- defaults -----------------------------------------------------------------

ENV_NAME=""
DRY_RUN=0
SKIP_FB_RESTART=0
WAIT_DATA_SECONDS=10
CONFIRM_PROMPT=1

NAMESPACE_ES="${NAMESPACE_ES:-logging}"
NAMESPACE_FB="${NAMESPACE_FB:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
ES_SVC="${ES_SVC:-localhost}"
ES_PORT="${ES_PORT:-9200}"
ES_SCHEME="${ES_SCHEME:-https}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"
# Single fluent-bit workload — DaemonSet only since the 2026-05-19 migration.
FB_DAEMONSET="${FB_DAEMONSET:-fluent-bit}"

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
Usage: $(basename "$0") --env NAME [options]

Resets the ExampleProject raw + cohort indices for the chosen environment (a.k.a.
index prefix), rolls the fluent-bit DaemonSet, waits for the raw index to
be re-created from new logs, then re-starts the cohort transform.

Required:
  --env NAME                  Environment / index prefix (e.g. qa, dev, stg, prod).
                              Resolved index / transform names:
                                raw index   = <NAME>-example-project-game
                                cohort idx  = <NAME>-example-project-game-user-cohort
                                transform   = <NAME>-example-project-game-user-cohort

Options:
  --dry-run                     Print the actions without contacting ES or kubectl.
  --skip-fluent-bit-restart     Do not roll the fluent-bit DaemonSet (use only
                                when you have just rotated it manually).
  --wait-data-seconds N         Max seconds to wait for the raw index to come back
                                after the fluent-bit restart. Default: ${WAIT_DATA_SECONDS}.
  -y, --yes                     Skip the interactive 'reset <env>' confirmation prompt (CI use).
  -h | --help                   Show this help and exit.

Env overrides (rarely needed):
  NAMESPACE_ES=${NAMESPACE_ES}  NAMESPACE_FB=${NAMESPACE_FB}
  ES_POD=${ES_POD}  ES_CONTAINER=${ES_CONTAINER}
  ES_SVC=${ES_SVC}  ES_PORT=${ES_PORT}  ES_SCHEME=${ES_SCHEME}
  ES_SECRET=${ES_SECRET}  ES_USER=${ES_USER}
  FB_DAEMONSET=${FB_DAEMONSET}

Out of scope:
  fluent-bit tail SQLite + fluentd buffer wipe (legacy "scenario A") was
  removed on 2026-05-22 — the cleanup-Job pattern assumed a Deployment + RWO
  PVC layout. With fluent-bit on a DaemonSet + hostPath /var/lib/fluent-bit
  (per-node state), wipe needs per-node privileged access; that procedure
  is documented as a manual fallback in docs/reset-example-project-cohort.md and
  is intentionally not automated here.
EOF
}

# --- arg parse ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --env)
      shift; [ $# -gt 0 ] || { err "--env requires NAME"; exit 2; }
      ENV_NAME="$1"
      ;;
    --dry-run)                     DRY_RUN=1 ;;
    --skip-fluent-bit-restart)     SKIP_FB_RESTART=1 ;;
    --wait-data-seconds)
      shift; [ $# -gt 0 ] || { err "--wait-data-seconds requires N"; exit 2; }
      WAIT_DATA_SECONDS="$1"
      ;;
    -y|--yes)                      CONFIRM_PROMPT=0 ;;
    -h|--help)                     usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ -z "$ENV_NAME" ]; then
  err "--env NAME is required (e.g. qa, dev, stg, prod, ...)"
  usage
  exit 2
fi
# Accept any DNS-label-ish prefix that produces a valid ES index name (DNS label
# form: lowercase alphanumerics + '-' — matches ES index naming rules).
if ! [[ "$ENV_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  err "invalid --env '$ENV_NAME' — must match ^[a-z][a-z0-9-]*\$"
  exit 2
fi

if ! [[ "$WAIT_DATA_SECONDS" =~ ^[0-9]+$ ]] || [ "$WAIT_DATA_SECONDS" -lt 1 ]; then
  err "--wait-data-seconds must be a positive integer (got: $WAIT_DATA_SECONDS)"
  exit 2
fi

RAW_INDEX="${ENV_NAME}-example-project-game"
COHORT_INDEX="${ENV_NAME}-example-project-game-user-cohort"
TRANSFORM_ID="${ENV_NAME}-example-project-game-user-cohort"

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
  # Usage: es_curl METHOD PATH [extra curl args...]
  # Prints the raw response body to stdout. Returns curl's exit code.
  # On --dry-run, prints the planned curl to stderr so it is still visible when
  # callers capture stdout into a variable.
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
  # Usage: es_status METHOD PATH -> echoes http_code only
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
  log "ExampleProject cohort reset plan"
  log "  env:                  ${ENV_NAME}"
  log "  raw index:            ${RAW_INDEX}"
  log "  cohort index:         ${COHORT_INDEX}"
  log "  transform:            ${TRANSFORM_ID}"
  log "  ES pod:               ${NAMESPACE_ES}/${ES_POD} (container=${ES_CONTAINER})"
  log "  fluent-bit:           ${NAMESPACE_FB}/daemonset/${FB_DAEMONSET}  restart=$([ "$SKIP_FB_RESTART" = 1 ] && echo no || echo yes)"
  log "  wait-data:            ${WAIT_DATA_SECONDS}s"
  log "  dry-run:              $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
}

confirm_or_exit() {
  [ "$CONFIRM_PROMPT" = "0" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  log ""
  warn "This will DELETE the raw + cohort indices for env=${ENV_NAME}. This is destructive."
  printf "Type 'reset %s' to continue: " "$ENV_NAME"
  local answer=""
  IFS= read -r answer || true
  if [ "$answer" != "reset ${ENV_NAME}" ]; then
    err "aborted (expected 'reset ${ENV_NAME}', got: '$answer')"
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
    err "transform '${TRANSFORM_ID}' not found (HTTP ${code}). Apply transforms/${TRANSFORM_ID}.json first."
    exit 1
  fi
  ok "transform exists"
}

# --- step 1: stop transform ---------------------------------------------------

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

# --- step 2 + 3: delete indices ----------------------------------------------

delete_index() {
  # DELETE is idempotent at the ES API level — issue it directly and read the
  # response. Avoids a HEAD pre-check (curl -X HEAD hangs waiting for a body
  # that the server never sends).
  local idx="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) DELETE /${idx}"
    return 0
  fi
  local resp
  resp=$(es_curl DELETE "/${idx}" || true)
  if printf '%s' "$resp" | grep -q '"acknowledged":true'; then
    ok "deleted index ${idx}"
  elif printf '%s' "$resp" | grep -qE '"type":"index_not_found_exception"'; then
    warn "index ${idx} did not exist — nothing to delete"
  else
    err "DELETE /${idx} failed: $resp"
    exit 1
  fi
}

delete_cohort_index() {
  step 2 "Delete cohort destination index '${COHORT_INDEX}'"
  delete_index "$COHORT_INDEX"
}

delete_raw_index() {
  step 3 "Delete raw index '${RAW_INDEX}'"
  delete_index "$RAW_INDEX"
}

# --- step 4: restart fluent-bit DaemonSet ------------------------------------

restart_fluent_bit() {
  step 4 "Restart fluent-bit DaemonSet 'daemonset/${FB_DAEMONSET}' (-n ${NAMESPACE_FB})"
  if [ "$SKIP_FB_RESTART" = "1" ]; then
    warn "  --skip-fluent-bit-restart was set, leaving fluent-bit untouched"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout restart daemonset/${FB_DAEMONSET}"
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout status daemonset/${FB_DAEMONSET} --timeout=180s"
    return 0
  fi
  kubectl -n "$NAMESPACE_FB" rollout restart "daemonset/${FB_DAEMONSET}"
  kubectl -n "$NAMESPACE_FB" rollout status "daemonset/${FB_DAEMONSET}" --timeout=180s
  ok "fluent-bit DaemonSet rolled"
}

# --- step 5: wait for raw index to come back --------------------------------

wait_for_raw_index() {
  step 5 "Wait up to ${WAIT_DATA_SECONDS}s for new raw index '${RAW_INDEX}' to receive docs"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) poll GET /${RAW_INDEX}/_count every 5s"
    return 0
  fi
  local deadline now count_resp count
  deadline=$(( $(date +%s) + WAIT_DATA_SECONDS ))
  while :; do
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      # Idle environments (no traffic yet) are legitimate. ES rejects
      # _transform/_start with `validation_exception: no such index` when the
      # source is missing, so create an empty placeholder index — fluent-bit
      # will populate it later via dynamic mapping when the first doc arrives.
      warn "raw index '${RAW_INDEX}' has no docs yet after ${WAIT_DATA_SECONDS}s — creating empty placeholder so the transform can start"
      local put_resp
      put_resp=$(es_curl PUT "/${RAW_INDEX}" || true)
      if printf '%s' "$put_resp" | grep -qE '"acknowledged":true|"resource_already_exists_exception"'; then
        ok "empty raw index '${RAW_INDEX}' ready — fluent-bit will populate it as traffic arrives"
      else
        err "failed to PUT empty index ${RAW_INDEX}: $put_resp"
        exit 1
      fi
      return 0
    fi
    count_resp=$(es_curl GET "/${RAW_INDEX}/_count" 2>/dev/null || true)
    count=$(printf '%s' "$count_resp" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('count', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ] 2>/dev/null; then
      ok "raw index has ${count} docs"
      return 0
    fi
    sleep 5
  done
}

# --- step 6: start transform --------------------------------------------------

start_transform() {
  step 6 "Start transform '${TRANSFORM_ID}'"
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

# --- step 7: verify -----------------------------------------------------------

verify() {
  step 7 "Verify cohort first_seen / raw count"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) GET /_cat/indices/${ENV_NAME}-example-project-game*?v"
    log "    (dry-run) GET /${RAW_INDEX}/_count"
    log "    (dry-run) GET /${COHORT_INDEX}/_search?size=3"
    return 0
  fi
  # Give the transform a moment to write its first checkpoint.
  sleep 15
  local indices_resp raw_count_resp cohort_search_resp
  indices_resp=$(es_curl GET "/_cat/indices/${ENV_NAME}-example-project-game*?v" || true)
  raw_count_resp=$(es_curl GET "/${RAW_INDEX}/_count" || true)
  cohort_search_resp=$(es_curl GET "/${COHORT_INDEX}/_search?size=3" || true)
  log ""
  log "  indices (${ENV_NAME}-example-project-game*):"
  printf '%s\n' "$indices_resp" | sed 's/^/    /' || true
  log "  raw index _count:"
  printf '%s\n' "$raw_count_resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('    docs.count =', d.get('count', '?'))
" || true
  log "  cohort _search top 3 (user_id, first_seen):"
  printf '%s\n' "$cohort_search_resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
hits = d.get('hits', {}).get('hits', [])
if not hits:
    print('    (no cohort rows yet — transform may need another checkpoint cycle)')
else:
    for h in hits:
        src = h.get('_source', {})
        print('    user_id={} first_seen={}'.format(src.get('user_id'), src.get('first_seen')))
" || true
  log ""
  warn "Manual check: open Kibana dashboard ${ENV_NAME}-pm-retention-dashboard and confirm DAU/NU/cohort render only post-reset data."
}

# --- main ---------------------------------------------------------------------

main() {
  print_plan
  confirm_or_exit
  load_es_pass

  step 0 "Pre-flight checks"
  preflight_transform_exists

  stop_transform
  delete_cohort_index
  delete_raw_index
  restart_fluent_bit
  wait_for_raw_index
  start_transform
  verify

  log ""
  ok "Done. Cohort transform is repopulating from fresh data only."
}

main "$@"
