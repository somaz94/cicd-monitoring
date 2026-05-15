#!/usr/bin/env bash
# Reset the ExampleProject raw + cohort indices for the given environment (any
# DNS-label-ish prefix — qa, dev, stg, prd, ...) and let the cohort transform
# repopulate from fresh data only.
#
# Operational intent: keep ONLY logs that arrive strictly after the delete
# moment. Anything fluent-bit had already read before the delete (its tail
# SQLite checkpoint) or fluentd had buffered (its filesystem buffer)
# represents pre-delete data and must NOT bleed back into the new raw index.
#
# This script automates the ES-side reset (transform + indices) and the
# fluent-bit rollout restart. The full "delete-and-only-new-logs" workflow
# also requires wiping fluent-bit tail SQLite + fluentd buffer; see the
# README in this directory for the manual procedure and the rationale.
#
# Steps (numbered in script output):
#   0. Pre-flight                — transform exists, fluentd buffer queue empty
#   1. Stop transform            POST /_transform/<id>/_stop
#   2. Delete cohort dest index  DELETE /<env>-example-project-game-user-cohort
#   3. Delete raw index          DELETE /<env>-example-project-game
#   3a. (opt) Wipe fluentd buffer    scale fluentd 0 → cleanup Job → scale 1
#   3b. (opt) Wipe fluent-bit state  scale fluent-bit 0 → cleanup Job → scale 1
#   4.  (skipped if 3b ran)      kubectl rollout restart deployment/fluent-bit
#   5. Wait for raw index re-creation from new fluent-bit forwards
#   6. Start transform           POST /_transform/<id>/_start
#   7. Verify                    raw docs.count + cohort first_seen sample
#
# Step 0 reads fluentd's `fluentd_output_status_buffer_queue_length` metric and
# aborts if it is non-zero, because retry_forever + flush_at_shutdown=true would
# re-emit those queued chunks into the new raw index. Override the abort with
# --force-with-fluentd-buffer or --reset-fluentd-buffer (which makes the buffer
# check moot, since the buffer is about to be wiped).
#
# Scenario flags (opt-in; default behavior unchanged):
#   --reset-fluent-bit-checkpoint  Run step 3b — wipe the env-specific tail
#                                  SQLite DB *and* the whole storage/ dir
#                                  (storage chunks are shared across env, so
#                                  this also drops dev/stg in-flight data —
#                                  usually a few seconds' worth).
#   --reset-fluentd-buffer         Run step 3a — wipe the fluentd buffer PVC
#                                  (`elasticsearch-buffers/*`), again shared
#                                  across env.
#   --scenario-a                   Macro for the "post-delete only" flow:
#                                  enables --reset-fluent-bit-checkpoint +
#                                  --reset-fluentd-buffer + --skip-fluent-bit-restart
#                                  (the explicit cleanup of step 3b already
#                                  brings the pod back up, so step 4 is moot).
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

# --- defaults -----------------------------------------------------------------

ENV_NAME=""
DRY_RUN=0
SKIP_FB_RESTART=0
WAIT_DATA_SECONDS=120
CONFIRM_PROMPT=1
FORCE_WITH_BUFFER=0
RESET_FB_CHECKPOINT=0
RESET_FD_BUFFER=0

NAMESPACE_ES="${NAMESPACE_ES:-logging}"
NAMESPACE_FB="${NAMESPACE_FB:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
ES_SVC="${ES_SVC:-localhost}"
ES_PORT="${ES_PORT:-9200}"
ES_SCHEME="${ES_SCHEME:-https}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"
FB_DEPLOYMENT="${FB_DEPLOYMENT:-fluent-bit}"
FB_STATE_PVC="${FB_STATE_PVC:-fluent-bit-state-pvc}"
FD_STATEFULSET="${FD_STATEFULSET:-fluentd}"
FD_POD="${FD_POD:-fluentd-0}"
CLEANUP_IMAGE="${CLEANUP_IMAGE:-busybox:1.36}"

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

Resets the ExampleProject raw and cohort indices for the chosen environment (a.k.a.
index prefix), restarts fluent-bit (default), waits for the raw index to be
re-created from new logs, then re-starts the cohort transform.

Required:
  --env NAME                  Environment / index prefix (e.g. qa, dev, stg, prd).
                              Resolved index / transform names:
                                raw index   = <NAME>-example-project-game
                                cohort idx  = <NAME>-example-project-game-user-cohort
                                transform   = <NAME>-example-project-game-user-cohort
                              The fluent-bit tail SQLite DB for step 3b is
                              <FB_STATE_PVC>/tail-<NAME>-game.db* — make sure
                              that file actually exists if you use
                              --reset-fluent-bit-checkpoint or --scenario-a.

Options:
  --dry-run                     Print the actions without contacting ES or kubectl.
  --skip-fluent-bit-restart     Do not restart fluent-bit (use only when you have
                                already rotated the pod and the tail DB has caught
                                up to the new userId range).
  --wait-data-seconds N         Max seconds to wait for the raw index to come back
                                after the fluent-bit restart. Default: ${WAIT_DATA_SECONDS}.
  --confirm                     Skip the interactive confirmation prompt (CI use).
  --force-with-fluentd-buffer   Proceed even when the fluentd output buffer queue
                                is non-empty. Read the warning in the script
                                header before using this.
  --reset-fluent-bit-checkpoint Wipe the env tail SQLite DB AND the shared
                                storage/ chunk dir on the fluent-bit state PVC.
                                Required for scenario A. Also bypasses step 4.
                                Affects dev/stg in-flight chunks too.
  --reset-fluentd-buffer        Wipe the fluentd elasticsearch-buffers/ dir on
                                the fluentd buffer PVC. Required for scenario A.
                                Affects dev/stg buffered chunks too.
  --scenario-a                  Macro: enable --reset-fluent-bit-checkpoint +
                                --reset-fluentd-buffer + --skip-fluent-bit-restart.
                                Use for the "post-delete only" intent (QA DB reset).
  -h | --help                   Show this help and exit.

Env overrides (rarely needed):
  NAMESPACE_ES=${NAMESPACE_ES}  NAMESPACE_FB=${NAMESPACE_FB}
  ES_POD=${ES_POD}  ES_CONTAINER=${ES_CONTAINER}
  ES_SVC=${ES_SVC}  ES_PORT=${ES_PORT}  ES_SCHEME=${ES_SCHEME}
  ES_SECRET=${ES_SECRET}  ES_USER=${ES_USER}
  FB_DEPLOYMENT=${FB_DEPLOYMENT}  FB_STATE_PVC=${FB_STATE_PVC}
  FD_STATEFULSET=${FD_STATEFULSET}  FD_POD=${FD_POD}
  CLEANUP_IMAGE=${CLEANUP_IMAGE}
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
    --confirm)                     CONFIRM_PROMPT=0 ;;
    --force-with-fluentd-buffer)   FORCE_WITH_BUFFER=1 ;;
    --reset-fluent-bit-checkpoint) RESET_FB_CHECKPOINT=1 ;;
    --reset-fluentd-buffer)        RESET_FD_BUFFER=1 ;;
    --scenario-a)
      RESET_FB_CHECKPOINT=1
      RESET_FD_BUFFER=1
      SKIP_FB_RESTART=1
      ;;
    -h|--help)                     usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# A wiped buffer cannot leak old chunks → the queue-length safety check is moot.
if [ "$RESET_FD_BUFFER" = "1" ]; then
  FORCE_WITH_BUFFER=1
fi

# Wiping fluent-bit state implies "fluent-bit will be re-scheduled by the
# cleanup flow", so the trailing rollout-restart in step 4 is redundant.
if [ "$RESET_FB_CHECKPOINT" = "1" ]; then
  SKIP_FB_RESTART=1
fi

if [ -z "$ENV_NAME" ]; then
  err "--env NAME is required (e.g. qa, dev, stg, prd, ...)"
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
  kubectl -n "$NAMESPACE_ES" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
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
  kubectl -n "$NAMESPACE_ES" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
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
  log "  fluent-bit:           ${NAMESPACE_FB}/deployment/${FB_DEPLOYMENT}  restart=$([ "$SKIP_FB_RESTART" = 1 ] && echo no || echo yes)"
  log "  wait-data:            ${WAIT_DATA_SECONDS}s"
  log "  dry-run:              $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
  log "  force w/fd buffer:    $([ "$FORCE_WITH_BUFFER" = 1 ] && echo yes || echo no)"
  log "  reset fb checkpoint:  $([ "$RESET_FB_CHECKPOINT" = 1 ] && echo "yes (tail-${ENV_NAME}-game.db* + storage/*)" || echo no)"
  log "  reset fd buffer:      $([ "$RESET_FD_BUFFER" = 1 ] && echo "yes (elasticsearch-buffers/*)" || echo no)"
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

preflight_fluentd_buffer() {
  if [ "$RESET_FD_BUFFER" = "1" ]; then
    ok "fluentd buffer queue check skipped (--reset-fluentd-buffer will wipe it)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) skipping fluentd buffer queue inspection"
    return 0
  fi
  local fluentd_pod queue_line queue
  fluentd_pod=$(kubectl -n "$NAMESPACE_FB" get pod \
    -l 'app.kubernetes.io/name=fluentd' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$fluentd_pod" ]; then
    warn "fluentd pod not found via label app.kubernetes.io/name=fluentd — skipping buffer check"
    return 0
  fi
  queue_line=$(kubectl -n "$NAMESPACE_FB" exec "$fluentd_pod" -- \
    sh -c 'curl -sf http://127.0.0.1:24231/metrics 2>/dev/null \
      | grep -E "^fluentd_output_status_buffer_queue_length\{[^}]*type=\"elasticsearch\"" \
      | head -n1' 2>/dev/null || true)
  if [ -z "$queue_line" ]; then
    warn "could not read fluentd_output_status_buffer_queue_length — skipping (metric not exposed?)"
    return 0
  fi
  queue=$(printf '%s\n' "$queue_line" | awk '{print $NF}')
  # Treat any non-zero (incl. floats like "3.0") as "queue has chunks".
  if [ "$queue" = "0" ] || [ "$queue" = "0.0" ]; then
    ok "fluentd buffer queue is empty (queue_length=${queue})"
    return 0
  fi
  warn "fluentd buffer queue is non-empty (queue_length=${queue})"
  warn "  → those queued chunks will be re-flushed into the new raw index right after delete."
  warn "  → drain or inspect the buffer before continuing, or rerun with --force-with-fluentd-buffer."
  if [ "$FORCE_WITH_BUFFER" = "0" ]; then
    err "aborting (use --force-with-fluentd-buffer to override)"
    exit 1
  fi
  warn "  → continuing because --force-with-fluentd-buffer was given"
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
  local idx="$1"
  local code
  code=$(es_status HEAD "/${idx}")
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) DELETE /${idx}"
    return 0
  fi
  case "$code" in
    200)
      es_curl DELETE "/${idx}" >/dev/null || { err "DELETE /${idx} failed"; exit 1; }
      ok "deleted index ${idx}"
      ;;
    404)
      warn "index ${idx} did not exist — nothing to delete"
      ;;
    *)
      err "unexpected HEAD /${idx} → HTTP ${code}"
      exit 1
      ;;
  esac
}

delete_cohort_index() {
  step 2 "Delete cohort destination index '${COHORT_INDEX}'"
  delete_index "$COHORT_INDEX"
}

delete_raw_index() {
  step 3 "Delete raw index '${RAW_INDEX}'"
  delete_index "$RAW_INDEX"
}

# --- step 3a / 3b: cleanup Job helpers ---------------------------------------

# Lookup the PVC name backing fluentd's buffer volume. Tries the live pod first,
# then falls back to the StatefulSet volumeClaimTemplate convention.
discover_fluentd_buffer_pvc() {
  local pvc=""
  pvc=$(kubectl -n "$NAMESPACE_FB" get pod "$FD_POD" \
    -o jsonpath='{range .spec.volumes[?(@.persistentVolumeClaim)]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
    2>/dev/null | head -n1 || true)
  if [ -z "$pvc" ]; then
    local vct
    vct=$(kubectl -n "$NAMESPACE_FB" get statefulset "$FD_STATEFULSET" \
      -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)
    [ -n "$vct" ] && pvc="${vct}-${FD_POD}"
  fi
  printf '%s\n' "$pvc"
}

# Apply a single-shot cleanup Job that mounts a PVC and runs a shell command,
# waits for completion, prints its logs, then deletes the Job. Exits non-zero
# on failure.
run_cleanup_job() {
  local job_name="$1" pvc="$2" mount_path="$3" cmd="$4"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) apply Job '${job_name}' (pvc=${pvc}, mount=${mount_path})"
    log "    (dry-run) cmd: ${cmd}"
    log "    (dry-run) wait Job '${job_name}' --for=condition=complete --timeout=120s"
    log "    (dry-run) delete Job '${job_name}'"
    return 0
  fi
  kubectl -n "$NAMESPACE_FB" delete "job/${job_name}" --ignore-not-found=true \
    --wait=true --timeout=60s >/dev/null 2>&1 || true
  cat <<EOF | kubectl -n "$NAMESPACE_FB" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: cleanup
          image: ${CLEANUP_IMAGE}
          command: ["sh", "-c", "${cmd}"]
          volumeMounts:
            - name: target
              mountPath: ${mount_path}
      volumes:
        - name: target
          persistentVolumeClaim:
            claimName: ${pvc}
EOF
  if ! kubectl -n "$NAMESPACE_FB" wait "job/${job_name}" \
       --for=condition=complete --timeout=120s >/dev/null 2>&1; then
    err "cleanup Job '${job_name}' did not complete within 120s"
    kubectl -n "$NAMESPACE_FB" logs "job/${job_name}" --tail=50 || true
    exit 1
  fi
  kubectl -n "$NAMESPACE_FB" logs "job/${job_name}" --tail=50 \
    | sed 's/^/    /' || true
  kubectl -n "$NAMESPACE_FB" delete "job/${job_name}" --wait=false >/dev/null 2>&1 || true
}

# Wait for every pod matched by a label selector to leave (PVC unmount).
# Idempotent when zero pods match.
wait_pods_deleted() {
  local selector="$1" timeout="${2:-90s}"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) wait pods -l ${selector} --for=delete --timeout=${timeout}"
    return 0
  fi
  local pods
  pods=$(kubectl -n "$NAMESPACE_FB" get pod -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  [ -z "$pods" ] && return 0
  # `kubectl wait --for=delete` requires individual resource names.
  echo "$pods" | xargs -I{} kubectl -n "$NAMESPACE_FB" wait "pod/{}" \
    --for=delete --timeout="$timeout" >/dev/null 2>&1 || true
}

# --- step 3a: wipe fluentd buffer --------------------------------------------

reset_fluentd_buffer() {
  [ "$RESET_FD_BUFFER" = "1" ] || return 0
  step "3a" "Wipe fluentd buffer (StatefulSet '${FD_STATEFULSET}', dir 'elasticsearch-buffers/*')"
  warn "  this wipes ALL env buffer chunks (dev/qa/stg) — chunks for other env are dropped too."
  local pvc=""
  if [ "$DRY_RUN" = "1" ]; then
    pvc="<lookup-deferred>"
    log "    (dry-run) discover fluentd buffer PVC via pod '${FD_POD}' or StatefulSet vct"
  else
    pvc=$(discover_fluentd_buffer_pvc)
    [ -n "$pvc" ] || { err "could not resolve fluentd buffer PVC (pod=${FD_POD}, sts=${FD_STATEFULSET})"; exit 1; }
    log "    fluentd buffer PVC: ${pvc}"
  fi

  log "  scaling fluentd to 0 to release the PVC lock"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} scale statefulset/${FD_STATEFULSET} --replicas=0"
  else
    kubectl -n "$NAMESPACE_FB" scale "statefulset/${FD_STATEFULSET}" --replicas=0 >/dev/null
    wait_pods_deleted "statefulset.kubernetes.io/pod-name=${FD_POD}" 120s
  fi

  run_cleanup_job "fluentd-buffer-cleanup-${ENV_NAME}" "$pvc" "/buffers" \
    "rm -rfv /buffers/elasticsearch-buffers/* 2>/dev/null; rm -rfv /buffers/elasticsearch-buffers/.??* 2>/dev/null; ls -la /buffers/elasticsearch-buffers/ 2>/dev/null || true"

  log "  scaling fluentd back to 1"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} scale statefulset/${FD_STATEFULSET} --replicas=1"
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout status statefulset/${FD_STATEFULSET} --timeout=120s"
  else
    kubectl -n "$NAMESPACE_FB" scale "statefulset/${FD_STATEFULSET}" --replicas=1 >/dev/null
    kubectl -n "$NAMESPACE_FB" rollout status "statefulset/${FD_STATEFULSET}" --timeout=120s
  fi
  ok "fluentd buffer wiped"
}

# --- step 3b: wipe fluent-bit state ------------------------------------------

reset_fluent_bit_state() {
  [ "$RESET_FB_CHECKPOINT" = "1" ] || return 0
  step "3b" "Wipe fluent-bit state (PVC '${FB_STATE_PVC}', files 'tail-${ENV_NAME}-game.db*' + 'storage/*')"
  warn "  storage/ wipe drops the input chunks of all env (typically a few seconds' worth of in-flight data)."

  log "  scaling fluent-bit to 0 to release the PVC lock"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} scale deployment/${FB_DEPLOYMENT} --replicas=0"
  else
    kubectl -n "$NAMESPACE_FB" scale "deployment/${FB_DEPLOYMENT}" --replicas=0 >/dev/null
    wait_pods_deleted "app.kubernetes.io/name=fluent-bit" 120s
  fi

  run_cleanup_job "fluent-bit-state-cleanup-${ENV_NAME}" "$FB_STATE_PVC" "/state" \
    "rm -fv /state/tail-${ENV_NAME}-game.db* 2>/dev/null; rm -rfv /state/storage/* 2>/dev/null; ls -la /state 2>/dev/null || true"

  log "  scaling fluent-bit back to 1"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} scale deployment/${FB_DEPLOYMENT} --replicas=1"
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout status deployment/${FB_DEPLOYMENT} --timeout=120s"
  else
    kubectl -n "$NAMESPACE_FB" scale "deployment/${FB_DEPLOYMENT}" --replicas=1 >/dev/null
    kubectl -n "$NAMESPACE_FB" rollout status "deployment/${FB_DEPLOYMENT}" --timeout=120s
  fi
  ok "fluent-bit state wiped"
}

# --- step 4: restart fluent-bit ----------------------------------------------

restart_fluent_bit() {
  step 4 "Restart fluent-bit deployment '${FB_DEPLOYMENT}' (-n ${NAMESPACE_FB})"
  if [ "$SKIP_FB_RESTART" = "1" ]; then
    warn "  --skip-fluent-bit-restart was set, leaving fluent-bit untouched"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout restart deployment/${FB_DEPLOYMENT}"
    log "    (dry-run) kubectl -n ${NAMESPACE_FB} rollout status deployment/${FB_DEPLOYMENT} --timeout=120s"
    return 0
  fi
  kubectl -n "$NAMESPACE_FB" rollout restart "deployment/${FB_DEPLOYMENT}"
  kubectl -n "$NAMESPACE_FB" rollout status "deployment/${FB_DEPLOYMENT}" --timeout=120s
  ok "fluent-bit restarted"
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
      err "raw index '${RAW_INDEX}' did not receive any document within ${WAIT_DATA_SECONDS}s"
      err "  → check fluent-bit pod logs and the source NFS path"
      exit 1
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
    log "    (dry-run) GET /${RAW_INDEX}/_count"
    log "    (dry-run) GET /${COHORT_INDEX}/_search?size=3"
    return 0
  fi
  # Give the transform a moment to write its first checkpoint.
  sleep 15
  local raw_count_resp cohort_search_resp
  raw_count_resp=$(es_curl GET "/${RAW_INDEX}/_count" || true)
  cohort_search_resp=$(es_curl GET "/${COHORT_INDEX}/_search?size=3" || true)
  log ""
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
  preflight_fluentd_buffer

  stop_transform
  delete_cohort_index
  delete_raw_index
  reset_fluentd_buffer
  reset_fluent_bit_state
  restart_fluent_bit
  wait_for_raw_index
  start_transform
  verify

  log ""
  ok "Done. Cohort transform is repopulating from fresh data only."
}

main "$@"
