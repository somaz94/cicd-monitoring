# shellcheck shell=bash
# Shared environment defaults + helper functions for Elasticsearch operations
# scripts under this directory. Source this file from another shell script —
# do not execute it directly.
#
# Usage:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=lib/es-common.sh
#   source "${_SCRIPT_DIR}/lib/es-common.sh"
#
# Conventions:
#   - All defaults use `${VAR:-...}` so the caller can override by simply
#     setting the variable before sourcing this file (or before invoking the
#     script). Once set, helpers below will see the new value.
#   - Helper functions are prefixed `es_` where they hit Elasticsearch, plain
#     names for generic utilities (log/ok/warn/err/step/csv_to_json_array/...).

# Guard against double-sourcing — re-source is harmless because everything is
# parameterised, but the lib stays cheap and skip-able.
[ "${_ES_COMMON_SOURCED:-0}" = "1" ] && return 0
_ES_COMMON_SOURCED=1

# Make sure callers benefit from `setopt nonomatch` in zsh too — prevents the
# glob no-match fatal when the caller has not enabled set -f.
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

# --- environment defaults -----------------------------------------------------

NAMESPACE_ES="${NAMESPACE_ES:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
ES_SVC="${ES_SVC:-localhost}"
ES_PORT="${ES_PORT:-9200}"
ES_SCHEME="${ES_SCHEME:-https}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"

# Derived. Callers usually do not override this directly — they tweak ES_* above.
ES_URL="${ES_URL:-${ES_SCHEME}://${ES_SVC}:${ES_PORT}}"

# Filled in by load_admin_pass(). Callers should not touch this directly.
ADMIN_PASS="${ADMIN_PASS:-}"

# Dry-run flag — when set to 1 by the caller, es_call / es_status print the
# planned curl line to stderr instead of contacting the cluster.
DRY_RUN="${DRY_RUN:-0}"

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

# --- ES helpers ---------------------------------------------------------------

# Read the admin password from the Kubernetes secret and stash it in ADMIN_PASS.
# Idempotent — repeated calls are cheap because ADMIN_PASS is reused.
load_admin_pass() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  [ -n "$ADMIN_PASS" ] && return 0
  ADMIN_PASS=$(kubectl -n "$NAMESPACE_ES" get secret "$ES_SECRET" \
    -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  [ -n "$ADMIN_PASS" ] || { err "failed to read elastic password from secret/$ES_SECRET"; exit 1; }
}

# es_call METHOD PATH [user] [pass]
#   - Sends an HTTP request to Elasticsearch via `kubectl exec ... curl`.
#   - Request body comes from stdin (if any).
#   - Echoes the response body on stdout. On --dry-run, prints the planned curl
#     to stderr and returns success (no cluster contact).
#   - Optional auth user/pass override (defaults: ES_USER / ADMIN_PASS).
es_call() {
  local method="$1" path="$2" auth_user="${3:-$ES_USER}" auth_pass="${4:-$ADMIN_PASS}"
  if [ "$DRY_RUN" = "1" ]; then
    printf "    (dry-run) curl -X %s %s%s (auth=%s)\n" "$method" "$ES_URL" "$path" "$auth_user" >&2
    return 0
  fi
  kubectl -n "$NAMESPACE_ES" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${auth_user}:${auth_pass}" \
      -H 'Content-Type: application/json' \
      -X "$method" "${ES_URL}${path}" --data-binary @-
}

# es_status METHOD PATH — echoes the HTTP status code only (no body).
# Useful for HEAD / GET existence checks. Returns "000" in --dry-run.
es_status() {
  local method="$1" path="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "000"
    return 0
  fi
  kubectl -n "$NAMESPACE_ES" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${ADMIN_PASS}" -o /dev/null -w '%{http_code}' \
      -X "$method" "${ES_URL}${path}"
}

# --- generic utilities --------------------------------------------------------

# csv_to_json_array CSV — turn 'a,b,c' into '["a","b","c"]'. Globbing is
# disabled so a bare '*' does not expand to cwd contents.
csv_to_json_array() {
  local csv="$1"
  local out="["
  local first=1
  local part
  local restore_glob="set +f"
  case "$-" in *f*) restore_glob="set +f; set -f" ;; esac
  set -f
  # Intentional unquoted expansion for word-splitting on IFS=','.
  # shellcheck disable=SC2086
  {
    local IFS=,
    for part in $csv; do
      [ -z "$part" ] && continue
      if [ "$first" = "1" ]; then first=0; else out+=","; fi
      out+="\"${part}\""
    done
  }
  eval "$restore_glob"
  out+="]"
  printf '%s' "$out"
}

# json_escape STR — escape backslash + double-quote for safe inclusion inside
# a JSON string literal.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# mask_payload PAYLOAD — replace the "password": "..." value with "********".
# Used in --dry-run output so the secret is not echoed.
mask_payload() {
  printf '%s\n' "$1" | sed -E 's/("password"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"********"/'
}
