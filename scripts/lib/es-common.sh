# shellcheck shell=bash
# Repo-root shared environment defaults + helper functions for Elasticsearch
# operations. Sourced by elasticsearch-aws/scripts and scripts/elasticsearch.
# Source this file from another shell script — do not execute it directly.
#
# Usage (from a component under observability/logging/<component>/scripts/):
#   #!/usr/bin/env bash
#   set -euo pipefail
#   _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=../../../../scripts/lib/es-common.sh
#   source "${_SCRIPT_DIR}/../../../../scripts/lib/es-common.sh"
#   ...                          # argument loop, incl. a --context CTX flag
#   require_kube_context         # MANDATORY — see the kube-context section below
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

# --- kube-context ---------------------------------------------------------------

# The mandatory --context gate (KUBE_CONTEXT / require_kube_context / kctl /
# kube_context_cluster / kube_context_prescan) lives in a sibling lib so that the
# on-prem scripts under observability/logging/elasticsearch/scripts/ — which use a
# port-forward instead of `kubectl exec` and therefore cannot source this ES lib —
# share ONE definition rather than growing a second copy.
#
# Name the collision that makes the gate necessary, so the failure message is
# concrete rather than abstract.
KUBE_CONTEXT_HINT="${KUBE_CONTEXT_HINT:-${NAMESPACE_ES}/${ES_POD}}"
_ES_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ ! -f "${_ES_COMMON_LIB_DIR}/kube-context.sh" ]; then
  err "es-common.sh: cannot find sibling scripts/lib/kube-context.sh (looked in ${_ES_COMMON_LIB_DIR})"
  exit 2
fi
# shellcheck source=./kube-context.sh
# shellcheck disable=SC1091
source "${_ES_COMMON_LIB_DIR}/kube-context.sh"

# --- ES helpers ---------------------------------------------------------------

# Read the admin password from the Kubernetes secret and stash it in ADMIN_PASS.
# Idempotent — repeated calls are cheap because ADMIN_PASS is reused.
load_admin_pass() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  [ -n "$ADMIN_PASS" ] && return 0
  ADMIN_PASS=$(kctl -n "$NAMESPACE_ES" get secret "$ES_SECRET" \
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
  # `-i` is correct here — curl reads the request body from stdin (--data-binary @-).
  kctl -n "$NAMESPACE_ES" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
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
  # No `-i` — nothing is piped in (curl sends no body and writes to /dev/null).
  # An idle stdin makes kubectl truncate large responses with "connection reset by
  # peer" at a variable offset; only attach stdin when something is actually fed in.
  kctl -n "$NAMESPACE_ES" exec "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -sk -u "${ES_USER}:${ADMIN_PASS}" -o /dev/null -w '%{http_code}' \
      -X "$method" "${ES_URL}${path}"
}

# --- generic utilities --------------------------------------------------------

# csv_to_json_array CSV — turn 'a,b,c' into '["a","b","c"]'.
#
# Split with parameter expansion rather than `IFS=, ; for part in $csv`: zsh does
# NOT word-split unquoted expansions, so the loop form yielded a single element
# ('["a,b,c"]') there. That fails SILENTLY and lands in a live cluster — the value
# feeds index_patterns for the ILM policy, the cohort ILM exemption and the SLM
# index set, so a one-element array is a glob that matches nothing and the policy
# just never applies. Every caller is behind a bash re-exec guard today, but this
# lib advertises zsh support, so the split must not depend on the shell.
#
# No `set -f` dance is needed either: nothing here is ever glob-expanded, so a
# pattern like 'prod-example-app-*' passes through untouched.
csv_to_json_array() {
  local rest="$1"
  local out="["
  local first=1
  local part
  while [ -n "$rest" ]; do
    part="${rest%%,*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    [ -z "$part" ] && continue
    if [ "$first" = "1" ]; then first=0; else out="${out},"; fi
    out="${out}\"${part}\""
  done
  printf '%s]' "$out"
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
