# shellcheck shell=bash
# =============================================================================
# observability/logging/elasticsearch/scripts/lib/es-helpers.sh — Shared Elasticsearch / Kibana helpers
# =============================================================================
# Helpers consumed by every script under observability/logging/elasticsearch/scripts/.
# - es_curl:                    invoke curl with -s -k -u auto-applied
# - es_pretty_json:             pretty-print JSON via python3
# - es_fetch_password_from_k8s: read a password from a k8s secret via kubectl
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/es-helpers.sh"
#
# Idempotent guard — safe to source multiple times from the same script.
# =============================================================================

[[ -n "${__SCRIPTS_LIB_ES_HELPERS_LOADED:-}" ]] && return 0
__SCRIPTS_LIB_ES_HELPERS_LOADED=1

# es_curl USER PASS <curl_args...>
#   Invoke curl with the standard option set (`-s -k -u USER:PASS`)
#   prepended; remaining args are forwarded to curl verbatim.
#
# Examples:
#   # ES API
#   es_curl "$EU" "$EP" "$ES_HOST/_cat/indices?v"
#   es_curl "$EU" "$EP" -X DELETE "$ES_HOST/$INDEX"
#
#   # Kibana API (the kbn-xsrf header is added by the caller)
#   es_curl "$KU" "$KP" -H 'kbn-xsrf: true' "$KIBANA_HOST/api/saved_objects/_find"
es_curl() {
  local user="$1" pass="$2"
  shift 2
  curl -s -k -u "${user}:${pass}" "$@"
}

# es_pretty_json [json_string]
#   Pretty-print the JSON taken either from $1 or from stdin via
#   `python3 -m json.tool`. Falls back to the raw input when python3
#   is missing or the JSON fails to parse.
es_pretty_json() {
  if (( $# > 0 )); then
    if command -v python3 >/dev/null 2>&1; then
      printf '%s' "$1" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$1"
    else
      printf '%s\n' "$1"
    fi
  else
    if command -v python3 >/dev/null 2>&1; then
      python3 -m json.tool 2>/dev/null || cat
    else
      cat
    fi
  fi
}

# es_fetch_password_from_k8s NAMESPACE SECRET [KEY]
#   Read the k8s secret's <KEY> (default: password), base64-decode, and
#   emit to stdout. Prints an error message to stderr and returns a
#   non-zero exit code on failure.
#
# Example:
#   PASSWORD=$(es_fetch_password_from_k8s monitoring elasticsearch-master-credentials password) \
#     || exit 1
es_fetch_password_from_k8s() {
  local ns="$1" secret="$2" key="${3:-password}"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl is not available; cannot fetch secret" >&2
    return 1
  fi

  local val
  val=$(kubectl -n "${ns}" get secret "${secret}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null)

  if [[ -z "${val}" ]]; then
    echo "ERROR: failed to read key '${key}' from secret ${ns}/${secret}" >&2
    return 1
  fi

  printf '%s' "${val}"
}
