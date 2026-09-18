#!/usr/bin/env bash
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE
# enabling shell options. The body uses `echo -e` and sources lib helpers
# — both depend on bash semantics.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail
IFS=$'\n\t'

# Shared lib — repo-root scripts/lib/prompts.sh + ./lib/es-helpers.sh
# Resolve script path portably across bash and zsh (BASH_SOURCE → $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../../scripts/lib/prompts.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/es-helpers.sh"

###################
# Global Variables #
###################

# Elasticsearch connection settings (env-overridable; localhost defaults).
# Default targets localhost:9200 so the script works over a port-forward:
#   kubectl -n logging port-forward svc/elasticsearch-es-http 9200:9200
# es_curl applies `-k`, so the ECK self-signed HTTPS cert is accepted. To hit a
# different endpoint directly, export ELASTIC_HOST (e.g. http://elasticsearch.example.com).
ELASTIC_USER="${ELASTIC_USER:-elastic}"
# Deliberately EMPTY by default — resolved from the target cluster's own secret
# after the kube-context gate runs (see below). It used to default to a hardcoded
# on-prem password, which became actively wrong once --context made these scripts
# usable against the AWS cluster: every request would have shipped the on-prem
# admin credential to prod and left failed-auth entries in that cluster's audit log.
# Reading the secret through kctl keeps the credential and the target in lockstep.
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
ELASTIC_HOST="${ELASTIC_HOST:-https://localhost:9200}"

# Index names to clean (array)
INDEX_NAMES=()

# Default indices to clean if none specified
# Example: DEFAULT_INDICES=("logstash-*" "filebeat-*" "metricbeat-*")
# Leave empty to require explicit index specification
DEFAULT_INDICES=()

# Retention period settings
# Minimum number of days to keep data
MIN_RETENTION_DAYS=7
# Default retention period in days
RETENTION_DAYS=90

# Force merge flag
FORCE_MERGE=false

# Delete index flag
DELETE_INDEX=false

# Check index settings / Change mode flag (active only when each option is set)
CHECK_SETTINGS=false
UPDATE_LIMIT=""

# Dry-run flag — when set, mutating ES calls (PUT settings / DELETE index /
# _delete_by_query / _forcemerge) are printed but not executed; read-only paths
# (--list / --status / --check-settings) run as usual.
DRY_RUN=0

# Date format
TODAY=$(date +%Y.%m.%d)

# Help function
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [INDEX_NAMES...]

Delete old documents from specified Elasticsearch indices based on retention period.

Options:
  --context CTX           REQUIRED. kube-context the port-forward targets. No
                          default and no fallback to the current context — both
                          clusters expose logging/elasticsearch-es-http, so an
                          implicit context would delete indices on the wrong one.
                          Enforced for --dry-run and for -l / -s too. The name is
                          a LOCAL kubeconfig alias with no fixed value — list
                          yours with \`kubectl config get-contexts -o name\`, and
                          confirm the cluster= line printed at startup (that is
                          the stable id, not the alias).
  -h, --help              Show this help message
  -d, --days DAYS         Number of days to retain data (default: ${RETENTION_DAYS}, minimum: ${MIN_RETENTION_DAYS})
  -i, --indices LIST      Comma-separated list of index names to clean
  -l, --list              List all available indices
  -s, --status            Show current status of all indices
  -f, --force-merge       Force merge indices after deletion to optimize disk space
  -c, --check-settings    Check index settings (total_fields.limit, etc.)
  -u, --update-limit NUM  Update total_fields.limit for specified indices
  --delete-index          Delete entire index (WARNING: irreversible!)
  --dry-run               Print mutating ES calls (PUT settings / DELETE index /
                          _delete_by_query / _forcemerge) without executing.
                          Auto-skips the confirm prompt.

Examples (--context is REQUIRED):
  $(basename "$0") --context <ctx> index1 index2              # Clean specified indices (${RETENTION_DAYS} days retention)
  $(basename "$0") --context <ctx> -d 60 index1 index2        # Clean specified indices (60 days retention)
  $(basename "$0") --context <ctx> -i "index1,index2" -d 60   # Clean indices using comma-separated list
  $(basename "$0") --context <ctx> -l                         # List all available indices
  $(basename "$0") --context <ctx> -s                         # Show current status of all indices
  $(basename "$0") --context <ctx> -f index1                  # Clean and force merge index1
  $(basename "$0") --context <ctx> -d 60 -f index1 index2     # Clean with 60 days retention and force merge
  $(basename "$0") --context <ctx> -c index1                  # Check index1 settings
  $(basename "$0") --context <ctx> -c -i "index1,index2"      # Check multiple index settings
  $(basename "$0") --context <ctx> -u 2000 index1             # Update total_fields.limit to 2000
  $(basename "$0") --context <ctx> -u 2000 -i "idx1,idx2"     # Update limit for multiple indices
  $(basename "$0") --context <ctx> --delete-index index1      # Delete entire index1
  $(basename "$0") --context <ctx> --delete-index -i "a,b"    # Delete multiple indices

Notes:
- You must specify at least one index to clean
- Minimum retention period is ${MIN_RETENTION_DAYS} days for safety
- Use -l option to list all available indices first
- --delete-index option completely removes the index and is irreversible!
EOF
  exit 0
}

# The kube-context gate must run BEFORE the argument loop, not inside it: the loop's
# own -l / -s / -c actions hit Elasticsearch as they are parsed, and the port-forward
# below has to be up by then. So pre-scan argv for --context (the loop still accepts
# the flag, which simply assigns the same value again).
#
# Enforced even for --dry-run and for the read-only actions: a wrong-cluster --list
# is harmless in itself, but it is the step an operator reads before choosing which
# index to delete, so it must describe the same cluster the deletion will hit.
#
# The flag WINS over the environment. Written the other way round
# (`${KUBE_CONTEXT:-$(prescan)}`), an exported KUBE_CONTEXT would silently beat an
# explicit `--context` — the banner would name the cluster you asked for while the
# deletion went somewhere else, which is the exact failure this gate exists to stop.
_ctx_arg="$(kube_context_prescan "$@")"
KUBE_CONTEXT="${_ctx_arg:-${KUBE_CONTEXT:-}}"
unset _ctx_arg

# Scan argv element by element rather than matching against " $* ": `$*` joins on
# the first character of IFS (set to newline on line 9), so the pattern is both
# fragile and value-sensitive — `-i "weird -h name"` would look like a help request
# and skip the gate entirely, while `-l -h` only fails to match by accident.
_want_help=0
for _a in "$@"; do
  case "$_a" in -h|--help) _want_help=1 ;; esac
done
if [ "$_want_help" -eq 0 ]; then
  require_kube_context
  # Auto port-forward to the in-cluster ES when ELASTIC_HOST is localhost (default);
  # torn down automatically on exit. Skipped when ELASTIC_HOST points elsewhere or
  # ES_PF=off.
  #
  # Report what actually routes the traffic. When the port-forward is bypassed the
  # kube-context is NOT what the requests follow, so claiming a cluster there would
  # be the same false assurance the stale-tunnel guard in es-helpers.sh removes.
  if [ "${ES_PF:-auto}" = "off" ]; then
    echo "▸ Target: ${ELASTIC_HOST} (ES_PF=off — your own tunnel routes this, NOT --context ${KUBE_CONTEXT})" >&2
  else
    case "${ELASTIC_HOST}" in
      *localhost*|*127.0.0.1*)
        echo "▸ Target: --context ${KUBE_CONTEXT}  cluster=$(kube_context_cluster)" >&2
        ;;
      *)
        echo "▸ Target: ${ELASTIC_HOST} (direct — --context ${KUBE_CONTEXT} is NOT what routes this)" >&2
        ;;
    esac
  fi
  es_ensure_port_forward || exit 1

  # Resolve the admin password from the TARGET cluster's own secret, so the
  # credential always matches whatever --context selected. An explicit
  # ELASTIC_PASSWORD still wins, for endpoints that are not this ECK cluster.
  if [ -z "$ELASTIC_PASSWORD" ]; then
    ELASTIC_PASSWORD=$(es_fetch_password_from_k8s "${ES_PF_NS:-logging}" \
      "${ES_SECRET:-elasticsearch-es-elastic-user}" "${ELASTIC_USER}") || {
      echo "  Pass ELASTIC_PASSWORD explicitly if this endpoint is not the ECK cluster." >&2
      exit 1
    }
  fi
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        --context)
            # Re-assign rather than discard, so the loop agrees with the pre-scan
            # above instead of leaving two sources of truth. The guarded double
            # shift keeps a trailing bare `--context` from aborting under `set -e`.
            shift
            if [[ $# -gt 0 ]]; then KUBE_CONTEXT="$1"; shift; fi
            ;;
        --context=*)
            KUBE_CONTEXT="${1#--context=}"
            shift
            ;;
        -d|--days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -i|--indices)
            IFS=',' read -ra INDEX_NAMES <<< "$2"
            shift 2
            ;;
        -l|--list)
            echo "Available indices:"
            es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices?v" | awk 'NR>1 {print $3}' | sort
            exit 0
            ;;
        -s|--status)
            echo "Current status of all indices:"
            es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices?v"
            exit 0
            ;;
        -f|--force-merge)
            FORCE_MERGE=true
            shift
            ;;
        -c|--check-settings)
            CHECK_SETTINGS=true
            shift
            ;;
        -u|--update-limit)
            UPDATE_LIMIT="$2"
            shift 2
            ;;
        --delete-index)
            DELETE_INDEX=true
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Try '$(basename $0) --help' for more information." >&2
            exit 1
            ;;
        *)
            INDEX_NAMES+=("$1")
            shift
            ;;
    esac
done

# Index settings check mode
if [ "$CHECK_SETTINGS" = true ]; then
    if [ ${#INDEX_NAMES[@]} -eq 0 ] || [ -z "${INDEX_NAMES[0]}" ]; then
        echo "Error: No indices specified for settings check." >&2
        echo "Try '$(basename $0) --help' for more information." >&2
        exit 1
    fi

    echo "=========================================="
    echo "▸ Index Settings Check"
    echo "=========================================="
    for INDEX in "${INDEX_NAMES[@]}"; do
        echo ""
        echo "▶ Index: $INDEX"
        echo "------------------------------------------"

        # Fetch all settings with flat_settings
        SETTINGS=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            "$ELASTIC_HOST/$INDEX/_settings?flat_settings=true&pretty")

        # Check if index exists
        if echo "$SETTINGS" | grep -q '"error"'; then
            echo "✗ Index not found"
            echo "---"
            continue
        fi

        # Extract main settings (flat_settings=true response: { "<index>": { "settings": { ... } } })
        command -v jq >/dev/null 2>&1 || {
            echo "ERROR: --check-settings needs jq, which is not installed." >&2
            exit 1
        }
        TOTAL_FIELDS=$(echo "$SETTINGS" | jq -r '.[].settings."index.mapping.total_fields.limit" // empty')
        SHARDS=$(echo "$SETTINGS" | jq -r '.[].settings."index.number_of_shards" // empty')
        REPLICAS=$(echo "$SETTINGS" | jq -r '.[].settings."index.number_of_replicas" // empty')
        CREATION_DATE=$(echo "$SETTINGS" | jq -r '.[].settings."index.creation_date" // empty')

        echo "  total_fields.limit : ${TOTAL_FIELDS:-1000 (default)}"
        echo "  number_of_shards   : ${SHARDS:-N/A}"
        echo "  number_of_replicas : ${REPLICAS:-N/A}"
        if [ -n "$CREATION_DATE" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                CREATED=$(date -r $((CREATION_DATE / 1000)) '+%Y-%m-%d %H:%M:%S')
            else
                CREATED=$(date -d @$((CREATION_DATE / 1000)) '+%Y-%m-%d %H:%M:%S')
            fi
            echo "  created_at         : $CREATED"
        fi

        # Count mapped fields
        FIELD_COUNT=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            "$ELASTIC_HOST/$INDEX/_mapping?pretty" | grep '"type"' | wc -l | tr -d ' ' || true)
        echo "  mapped fields      : ~${FIELD_COUNT}"
        echo "---"
    done
    echo ""
    echo "=========================================="
    exit 0
fi

# Index settings update mode
if [ -n "$UPDATE_LIMIT" ]; then
    # Validate numeric value
    if ! [[ "$UPDATE_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: total_fields.limit must be a positive integer" >&2
        exit 1
    fi

    if [ ${#INDEX_NAMES[@]} -eq 0 ] || [ -z "${INDEX_NAMES[0]}" ]; then
        echo "Error: No indices specified for settings update." >&2
        echo "Try '$(basename $0) --help' for more information." >&2
        exit 1
    fi

    echo "=========================================="
    echo "▸  Index Settings Update"
    echo "=========================================="
    echo "Target indices:"
    for INDEX in "${INDEX_NAMES[@]}"; do
        echo "  • $INDEX"
    done
    echo ""
    echo "Change: total_fields.limit → $UPDATE_LIMIT"
    echo "=========================================="
    echo ""
    if [[ "$DRY_RUN" != "1" ]] && ! confirm_yes_no "Are you sure you want to update these settings?"; then
        echo "Operation cancelled."
        exit 0
    fi

    echo ""
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    for INDEX in "${INDEX_NAMES[@]}"; do
        echo "Updating settings: $INDEX"

        if [[ "$DRY_RUN" == "1" ]]; then
            echo "    (dry-run) PUT $ELASTIC_HOST/$INDEX/_settings -d '{\"index.mapping.total_fields.limit\": $UPDATE_LIMIT}'"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "---"
            continue
        fi
        RESPONSE=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            -X PUT "$ELASTIC_HOST/$INDEX/_settings" \
            -H "Content-Type: application/json" \
            -d "{\"index.mapping.total_fields.limit\": $UPDATE_LIMIT}")

        if echo "$RESPONSE" | grep -q '"acknowledged":true'; then
            echo "✓ $INDEX: total_fields.limit → $UPDATE_LIMIT updated"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "✗ $INDEX: Failed to update settings"
            echo "  Response: $RESPONSE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
        echo "---"
    done

    echo ""
    echo "=========================================="
    echo "Settings Update Complete"
    echo "=========================================="
    echo "Success: ${SUCCESS_COUNT}"
    echo "Failed: ${FAIL_COUNT}"
    echo "Total: ${#INDEX_NAMES[@]}"
    echo "=========================================="
    exit 0
fi

# Index deletion mode
if [ "$DELETE_INDEX" = true ]; then
    # Check if indices are specified
    if [ ${#INDEX_NAMES[@]} -eq 0 ] || [ -z "${INDEX_NAMES[0]}" ]; then
        echo "Error: No indices specified for deletion." >&2
        echo "Try '$(basename $0) --help' for more information." >&2
        exit 1
    fi

    # Display indices to be deleted
    echo "=========================================="
    echo "▲  INDEX DELETION OPERATION"
    echo "=========================================="
    echo "The following indices will be completely deleted:"
    echo ""
    for INDEX in "${INDEX_NAMES[@]}"; do
        echo "  • $INDEX"
    done
    echo ""
    echo "Total: ${#INDEX_NAMES[@]} index(es) will be deleted."
    echo "=========================================="
    echo ""
    echo "▲  WARNING: This operation is irreversible!"
    if [[ "$DRY_RUN" != "1" ]] && ! confirm_typed_word "Are you sure you want to delete these indices?" "DELETE"; then
        echo "Operation cancelled."
        exit 0
    fi

    echo ""
    echo "Starting index deletion..."
    echo ""

    # Deletion counters
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    # Loop through and delete specified indices
    for INDEX in "${INDEX_NAMES[@]}"; do
        echo "Deleting index: $INDEX"

        if [[ "$DRY_RUN" == "1" ]]; then
            echo "    (dry-run) DELETE $ELASTIC_HOST/$INDEX"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "---"
            continue
        fi
        RESPONSE=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            -X DELETE "$ELASTIC_HOST/$INDEX" \
            -H "Content-Type: application/json")

        # Check if deletion was successful
        if echo "$RESPONSE" | grep -q '"acknowledged":true'; then
            echo "✓ Successfully deleted index: $INDEX"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "✗ Failed to delete index: $INDEX"
            echo "Response: $RESPONSE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
        echo "---"
    done

    echo ""
    echo "=========================================="
    echo "Index Deletion Complete"
    echo "=========================================="
    echo "Success: ${SUCCESS_COUNT}"
    echo "Failed: ${FAIL_COUNT}"
    echo "Total: ${#INDEX_NAMES[@]}"
    echo "=========================================="

    exit 0
fi

# Document deletion mode (original functionality)

# Validate RETENTION_DAYS
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Error: Days must be a positive number" >&2
    echo "Try '$(basename $0) --help' for more information." >&2
    exit 1
fi

if [ "$RETENTION_DAYS" -lt "$MIN_RETENTION_DAYS" ]; then
    echo "Error: Retention period cannot be less than ${MIN_RETENTION_DAYS} days" >&2
    echo "Try '$(basename $0) --help' for more information." >&2
    exit 1
fi

# If no indices specified, use default indices
if [ ${#INDEX_NAMES[@]} -eq 0 ]; then
    INDEX_NAMES=("${DEFAULT_INDICES[@]}")
fi

# Check if indices are actually specified (not empty)
if [ ${#INDEX_NAMES[@]} -eq 0 ] || [ -z "${INDEX_NAMES[0]}" ]; then
    echo "Error: No indices specified for cleanup." >&2
    echo "Please specify indices using one of the following methods:" >&2
    echo "  1. As arguments: $(basename $0) index1 index2" >&2
    echo "  2. Using -i option: $(basename $0) -i \"index1,index2\"" >&2
    echo "  3. Set DEFAULT_INDICES in the script" >&2
    echo "" >&2
    echo "Use '$(basename $0) -l' to list all available indices." >&2
    echo "Use '$(basename $0) --help' for more information." >&2
    exit 1
fi

# Check OS type and use appropriate date command
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    THRESHOLD_DATE=$(date -v-${RETENTION_DAYS}d -u +"%Y-%m-%dT%H:%M:%S.000Z")
else
    # Linux
    THRESHOLD_DATE=$(date -d "-${RETENTION_DAYS} days" -u +"%Y-%m-%dT%H:%M:%S.000Z")
fi

# Loop through specified indices and delete old documents
echo "Indices to clean: ${INDEX_NAMES[*]}"
echo "Retention period: ${RETENTION_DAYS} days"
echo "Will delete documents older than: $THRESHOLD_DATE"
if [[ "$DRY_RUN" != "1" ]] && ! confirm_yes_no "Are you sure you want to delete old documents from these indices?"; then
    echo "Operation cancelled."
    exit 0
fi

for INDEX in "${INDEX_NAMES[@]}"; do
    echo "Processing index: $INDEX"

    # Delete documents older than the threshold date MINUS the cohort anchor.
    #
    # The must_not clause is not optional and must stay in step with the scheduled
    # counterpart in index-retention/manifests/cronjob.yaml. The cohort transform
    # (transforms/dev-example-project-game-user-cohort.json) derives first_seen from a
    # scripted_metric over the /users/create docs in THIS raw index. Age one of
    # those out and the continuous transform re-triggers, recomputes first_seen as
    # null, and silently corrupts a cohort record that cannot be reconstructed.
    # The anchors cost almost nothing to keep — one doc per registration.
    #
    # This guard was missing here while the CronJob had it, so running the manual
    # script "to do the same thing by hand" destroyed anchors the scheduled job
    # deliberately preserves (found 2026-08-10).
    DELETE_QUERY='{
        "query": {
            "bool": {
                "filter": [
                    {
                        "range": {
                            "@timestamp": {
                                "lt": "'$THRESHOLD_DATE'"
                            }
                        }
                    }
                ],
                "must_not": [
                    {
                        "term": {
                            "data.requestPath.keyword": "/users/create"
                        }
                    }
                ]
            }
        }
    }'

    echo "Deleting old documents from $INDEX..."
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    (dry-run) POST $ELASTIC_HOST/$INDEX/_delete_by_query -d '$DELETE_QUERY'"
        RESPONSE='{"deleted":0}'
    else
        RESPONSE=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            -X POST "$ELASTIC_HOST/$INDEX/_delete_by_query" \
            -H "Content-Type: application/json" \
            -d "$DELETE_QUERY")
    fi

    # Check if deletion was successful and extract deleted count
    if echo "$RESPONSE" | grep -q '"deleted"'; then
        DELETED_COUNT=$(echo "$RESPONSE" | grep -o '"deleted":[0-9]*' | cut -d':' -f2)
        echo "✓ Successfully deleted $DELETED_COUNT documents from index: $INDEX"
    else
        echo "✗ Failed to delete documents from index: $INDEX"
        echo "Response: $RESPONSE"
    fi

    # Force merge if requested
    if [ "$FORCE_MERGE" = true ]; then
        echo "Force merging index: $INDEX..."
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "    (dry-run) POST $ELASTIC_HOST/$INDEX/_forcemerge?only_expunge_deletes=true"
            continue
        fi
        MERGE_RESPONSE=$(es_curl "$ELASTIC_USER" "$ELASTIC_PASSWORD" \
            -X POST "$ELASTIC_HOST/$INDEX/_forcemerge?only_expunge_deletes=true" \
            -H "Content-Type: application/json")

        # Check if force merge was successful
        if echo "$MERGE_RESPONSE" | grep -q '"successful"'; then
            echo "✓ Successfully force merged index: $INDEX"
        else
            echo "✗ Failed to force merge index: $INDEX"
            echo "Response: $MERGE_RESPONSE"
        fi
    fi
    echo "---"
done

echo "Document cleanup process completed."