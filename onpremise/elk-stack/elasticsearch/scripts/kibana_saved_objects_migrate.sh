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

# SOURCE Kibana (old stack, monitoring ns)
SOURCE_HOST="https://kibana.example.com"
SOURCE_USER="elastic"
# Empty -> auto-fetch from k8s secret monitoring/elasticsearch-master-credentials
SOURCE_PASSWORD=""

# TARGET Kibana (new stack, logging ns, ECK-managed)
TARGET_HOST="https://kibana-eck.example.com"
TARGET_USER="elastic"
TARGET_PASSWORD="exampleAdminPassword"

# Saved object types to migrate (comma-separated)
SAVED_OBJECT_TYPES="dashboard,visualization,search,index-pattern,lens,map,canvas-workpad,tag"

# NDJSON export/import file path
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NDJSON_FILE="/tmp/kibana-saved-objects-${TIMESTAMP}.ndjson"

# Modes (set by CLI)
MODE=""
OVERWRITE=false
LIST_TARGET=false

# Dry-run — when set, the mutating POST /api/saved_objects/_import is printed
# but not executed; export + list paths are read-only and run as usual.
DRY_RUN=0

# Help function
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Description:
  Migrate Saved Objects (dashboards, visualizations, Data Views, Lens,
  saved searches, tags, etc.) between Kibana instances. Log documents
  (data) are NOT migrated — Saved Objects are configuration/metadata
  stored in Kibana's ".kibana_*" system indices.

  Default SOURCE : old Kibana (monitoring ns, ${SOURCE_HOST})
  Default TARGET : new Kibana (logging ns, ${TARGET_HOST})

Modes (pick one):
  -e, --export            Export SOURCE -> NDJSON file
  -I, --import            Import NDJSON file -> TARGET
  -m, --migrate           SOURCE -> NDJSON -> TARGET in one run (recommended)
  -l, --list              Show per-type counts on SOURCE
      --list-target       Show per-type counts on TARGET

Connection options:
      --source URL               SOURCE Kibana host (default: ${SOURCE_HOST})
      --source-user USER         SOURCE user (default: ${SOURCE_USER})
      --source-password PW       SOURCE password
                                 (if empty, auto-fetched from
                                  monitoring/elasticsearch-master-credentials)
      --target URL               TARGET Kibana host (default: ${TARGET_HOST})
      --target-user USER         TARGET user (default: ${TARGET_USER})
      --target-password PW       TARGET password (default: ${TARGET_PASSWORD})

Data options:
  -f, --file PATH         NDJSON file path
                          (default: /tmp/kibana-saved-objects-YYYYMMDD-HHMMSS.ndjson)
  -t, --types LIST        Comma-separated saved-object types
                          (default: ${SAVED_OBJECT_TYPES})
  -o, --overwrite         On import, overwrite conflicting objects (default: skip)
      --dry-run           Print the mutating POST /api/saved_objects/_import
                          call without executing. Export / list paths still
                          run (read-only). The import confirm prompt is
                          auto-skipped.

Misc:
  -h, --help              Show this help

Examples:
  $(basename $0) --list                                           # Preview what SOURCE has
  $(basename $0) --list-target                                    # Verify TARGET state
  $(basename $0) --migrate                                        # End-to-end migrate (recommended)
  $(basename $0) --migrate --overwrite                            # Overwrite conflicts
  $(basename $0) --export -f ./kibana-export.ndjson               # Export to a file only
  $(basename $0) --import -f ./kibana-export.ndjson --overwrite   # Import from a file only
  $(basename $0) --migrate --types "dashboard,lens,tag"           # Migrate a subset

Notes:
- SOURCE with HTTPS + self-signed cert is fine (-k skips verification).
- Import prompts for confirmation before running.
- Recommended flow: --list -> --migrate -> --list-target to verify.
EOF
  exit 0
}

###################
# Helpers #
###################

# Auto-fetch SOURCE password from Kubernetes secret — delegates to lib es_fetch_password_from_k8s
fetch_source_password() {
    if [ -n "$SOURCE_PASSWORD" ]; then
        return 0
    fi
    echo "▸ Fetching SOURCE password (monitoring/elasticsearch-master-credentials)..."
    SOURCE_PASSWORD=$(es_fetch_password_from_k8s monitoring elasticsearch-master-credentials password) || {
        echo "  Pass --source-password explicitly." >&2
        exit 1
    }
    echo "✓ SOURCE password fetched"
    echo ""
}

# Build a JSON array literal from a comma-separated type list
build_types_json() {
    echo "$1" | awk -F',' '{
        for (i=1; i<=NF; i++) printf "\"%s\"%s", $i, (i==NF ? "" : ",")
    }'
}

# Pretty-print JSON — delegates to lib es_pretty_json
pretty_json() {
    es_pretty_json "$1"
}

###################
# Mode: List #
###################

do_list() {
    local host="" user="" pw="" label=""
    if [ "$LIST_TARGET" = true ]; then
        host="$TARGET_HOST"; user="$TARGET_USER"; pw="$TARGET_PASSWORD"
        label="TARGET ($TARGET_HOST)"
    else
        fetch_source_password
        host="$SOURCE_HOST"; user="$SOURCE_USER"; pw="$SOURCE_PASSWORD"
        label="SOURCE ($SOURCE_HOST)"
    fi

    echo "=========================================="
    echo "▸ Saved Objects inventory: $label"
    echo "=========================================="

    IFS=',' read -ra TYPES <<< "$SAVED_OBJECT_TYPES"
    local total=0
    local fail=0
    for t in "${TYPES[@]}"; do
        local resp="" count=""
        resp=$(es_curl "$user" "$pw" \
            -H 'kbn-xsrf: true' \
            "$host/api/saved_objects/_find?type=${t}&per_page=1&fields=id")
        count=$(echo "$resp" | grep -o '"total":[0-9]*' | head -1 | cut -d: -f2)
        if [ -z "$count" ]; then
            printf "  %-18s : (query failed)\n" "$t"
            fail=$((fail + 1))
            continue
        fi
        printf "  %-18s : %d\n" "$t" "$count"
        total=$((total + count))
    done
    echo "------------------------------------------"
    printf "  %-18s : %d\n" "TOTAL" "$total"
    echo "=========================================="
    if [ "$fail" -gt 0 ]; then
        echo "▲ ${fail} type(s) failed to query — check auth/host" >&2
        exit 1
    fi
}

###################
# Mode: Export #
###################

do_export() {
    fetch_source_password

    echo "=========================================="
    echo "▸ Saved Objects Export"
    echo "=========================================="
    echo "SOURCE : $SOURCE_HOST"
    echo "Types  : $SAVED_OBJECT_TYPES"
    echo "File   : $NDJSON_FILE"
    echo "=========================================="

    local types_json="" http_code=""
    types_json=$(build_types_json "$SAVED_OBJECT_TYPES")

    http_code=$(es_curl "$SOURCE_USER" "$SOURCE_PASSWORD" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
        -X POST "$SOURCE_HOST/api/saved_objects/_export" \
        -d "{\"type\":[${types_json}],\"includeReferencesDeep\":true}" \
        -o "$NDJSON_FILE" -w "%{http_code}")

    if [ "$http_code" != "200" ]; then
        echo "✗ Export failed (HTTP $http_code)" >&2
        if [ -s "$NDJSON_FILE" ]; then
            echo "Response body (first 500B):" >&2
            head -c 500 "$NDJSON_FILE" >&2; echo >&2
        fi
        rm -f "$NDJSON_FILE"
        exit 1
    fi

    local lines
    lines=$(wc -l < "$NDJSON_FILE" | tr -d ' ')
    echo "✓ Export complete: $NDJSON_FILE (${lines} lines)"
    # Last NDJSON line is the summary: {"exportedCount":N,"missingRefCount":M,...}
    local summary
    summary=$(tail -1 "$NDJSON_FILE" 2>/dev/null | grep -o '"exportedCount":[0-9]*,"missingRefCount":[0-9]*' || true)
    if [ -n "$summary" ]; then
        echo "  Summary: $summary"
    fi
}

###################
# Mode: Import #
###################

do_import() {
    if [ ! -f "$NDJSON_FILE" ]; then
        echo "✗ File not found: $NDJSON_FILE" >&2
        exit 1
    fi
    local lines
    lines=$(wc -l < "$NDJSON_FILE" | tr -d ' ')
    if [ "$lines" -eq 0 ]; then
        echo "✗ File is empty: $NDJSON_FILE" >&2
        exit 1
    fi

    echo "=========================================="
    echo "▸ Saved Objects Import"
    echo "=========================================="
    echo "TARGET    : $TARGET_HOST"
    echo "File      : $NDJSON_FILE (${lines} lines)"
    if [ "$OVERWRITE" = true ]; then
        echo "Conflict  : overwrite (replace existing objects)"
    else
        echo "Conflict  : skip (default — keep existing objects)"
    fi
    echo "=========================================="
    echo ""
    if [[ "$DRY_RUN" != "1" ]] && ! confirm_yes_no "Proceed with import?"; then
        echo "Operation cancelled."
        exit 0
    fi
    echo ""

    local url_params=""
    [ "$OVERWRITE" = true ] && url_params="?overwrite=true"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    (dry-run) POST $TARGET_HOST/api/saved_objects/_import${url_params} --form file=@$NDJSON_FILE"
        echo "✓ (dry-run) Import plan printed — no changes made."
        return 0
    fi

    local resp
    resp=$(es_curl "$TARGET_USER" "$TARGET_PASSWORD" \
        -H 'kbn-xsrf: true' \
        -X POST "$TARGET_HOST/api/saved_objects/_import${url_params}" \
        --form file=@"$NDJSON_FILE")

    echo "Response:"
    pretty_json "$resp"
    echo ""

    local success="" success_count="" error_count=""
    success=$(echo "$resp" | grep -o '"success":[a-z]*' | head -1 | cut -d: -f2)
    success_count=$(echo "$resp" | grep -o '"successCount":[0-9]*' | head -1 | cut -d: -f2)
    error_count=$(echo "$resp" | grep -o '"errors":\[' | wc -l | tr -d ' ')

    if [ "$success" = "true" ]; then
        echo "✓ Import complete (successCount=${success_count:-?})"
    else
        echo "✗ Import produced errors — inspect errors[] in the response above" >&2
        echo "  (for conflicts on existing objects, retry with --overwrite)" >&2
        exit 1
    fi
}

###################
# Mode: Migrate #
###################

do_migrate() {
    echo "=========================================="
    echo "▸ Saved Objects migrate (SOURCE → TARGET)"
    echo "=========================================="
    echo "SOURCE : $SOURCE_HOST"
    echo "TARGET : $TARGET_HOST"
    echo "Types  : $SAVED_OBJECT_TYPES"
    echo "File   : $NDJSON_FILE"
    echo "=========================================="
    echo ""

    do_export
    echo ""
    do_import
    echo ""
    echo "=========================================="
    echo "▸ Migration done — verify TARGET with:"
    echo "    $(basename $0) --list-target"
    echo "=========================================="
}

###################
# Arg parser #
###################

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -e|--export)
            MODE="export"; shift
            ;;
        -I|--import)
            MODE="import"; shift
            ;;
        -m|--migrate)
            MODE="migrate"; shift
            ;;
        -l|--list)
            MODE="list"; shift
            ;;
        --list-target)
            MODE="list"; LIST_TARGET=true; shift
            ;;
        --source)
            SOURCE_HOST="$2"; shift 2
            ;;
        --source-user)
            SOURCE_USER="$2"; shift 2
            ;;
        --source-password)
            SOURCE_PASSWORD="$2"; shift 2
            ;;
        --target)
            TARGET_HOST="$2"; shift 2
            ;;
        --target-user)
            TARGET_USER="$2"; shift 2
            ;;
        --target-password)
            TARGET_PASSWORD="$2"; shift 2
            ;;
        -f|--file)
            NDJSON_FILE="$2"; shift 2
            ;;
        -t|--types)
            SAVED_OBJECT_TYPES="$2"; shift 2
            ;;
        -o|--overwrite)
            OVERWRITE=true; shift
            ;;
        --dry-run)
            DRY_RUN=1; shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "See '$(basename $0) --help' for usage." >&2
            exit 1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

###################
# Dispatch #
###################

if [ -z "$MODE" ]; then
    echo "Error: mode is required." >&2
    echo "       one of --export / --import / --migrate / --list / --list-target" >&2
    echo "See '$(basename $0) --help' for usage." >&2
    exit 1
fi

case "$MODE" in
    export)  do_export ;;
    import)  do_import ;;
    migrate) do_migrate ;;
    list)    do_list ;;
esac
