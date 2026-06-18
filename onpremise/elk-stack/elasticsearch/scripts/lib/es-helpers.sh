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

# es_pf_cleanup
#   Kill the background port-forward started by es_ensure_port_forward (if any).
#   Wired to the EXIT/INT/TERM trap so the tunnel never outlives the script.
__ES_PF_PID=""
es_pf_cleanup() {
  if [[ -n "${__ES_PF_PID}" ]]; then
    kill "${__ES_PF_PID}" 2>/dev/null || true
    echo "▸ Stopped port-forward (pid ${__ES_PF_PID})" >&2
    __ES_PF_PID=""
  fi
}

# es_ensure_port_forward
#   When the ES endpoint is localhost (the default for these scripts), open a
#   background `kubectl port-forward` to the in-cluster ES service and tear it
#   down automatically on script exit. Honors the CURRENT kubectl context — switch
#   context to target a different cluster (on-prem vs AWS). No-op when the target
#   is not localhost, a tunnel is already up, or ES_PF=off.
#
#   Env overrides:
#     ES_PF       auto (default) | off
#     ES_PF_NS    namespace (default: logging)
#     ES_PF_SVC   service   (default: elasticsearch-es-http)
#     ES_PF_PORT  local+remote port (default: 9200)
#   Reads ELASTIC_HOST (or ES_URL) to decide whether the target is localhost.
es_ensure_port_forward() {
  [[ "${ES_PF:-auto}" == "off" ]] && return 0

  local target="${ELASTIC_HOST:-${ES_URL:-}}"
  case "${target}" in
    *localhost*|*127.0.0.1*) ;;
    *) return 0 ;;
  esac

  local ns="${ES_PF_NS:-logging}"
  local svc="${ES_PF_SVC:-elasticsearch-es-http}"
  local port="${ES_PF_PORT:-9200}"

  # Reuse an existing tunnel / already-reachable endpoint (curl returns 0 even on
  # 401, which still proves the connection works).
  if curl -sk -o /dev/null --max-time 2 "https://localhost:${port}" 2>/dev/null; then
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not available; cannot auto port-forward" >&2
    return 1
  fi

  echo "▸ Starting port-forward: $(kubectl config current-context) → svc/${svc}:${port} (ns ${ns})" >&2
  kubectl -n "${ns}" port-forward "svc/${svc}" "${port}:${port}" >/dev/null 2>&1 &
  __ES_PF_PID=$!
  trap es_pf_cleanup EXIT INT TERM

  local i
  for ((i = 0; i < 30; i++)); do
    if curl -sk -o /dev/null --max-time 2 "https://localhost:${port}" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "${__ES_PF_PID}" 2>/dev/null; then
      echo "ERROR: port-forward exited early (check kubectl context / namespace / service)" >&2
      __ES_PF_PID=""
      return 1
    fi
    sleep 0.5
  done
  echo "ERROR: port-forward did not become ready in time" >&2
  return 1
}
