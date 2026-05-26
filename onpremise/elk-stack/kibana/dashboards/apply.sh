#!/usr/bin/env bash
# Apply Kibana Saved Objects (Lens + Dashboard) NDJSON files to the in-cluster Kibana.
#
# Default behaviour: imports every *.ndjson in this directory that is NOT a data-view
# bootstrap file (filename matching *-data-view.ndjson). Use --include-data-view to
# also import data-view bootstrap files, or --file to target a specific NDJSON.
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE
# enabling shell options. The body uses ``mapfile`` (bash 4+ only) and
# ``declare -a SPACE_IDS=()`` so a zsh interpreter would fail.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

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
# Space targets — default to the built-in "default" space when none given.
declare -a SPACE_IDS=()
# Optional ID prefix applied per Space (--id-prefix-for SPACE:PREFIX), used to
# obtain stable slug-style URLs in non-default Spaces despite Kibana 9.x's
# single-namespace restriction (a slug id can only live in one Space).
declare -a ID_PREFIX_SPECS=()

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
Usage: $(basename "$0") [--file PATH]... [--space-id ID]...
                  [--id-prefix-for SPACE:PREFIX]...
                  [--include-data-view] [--no-overwrite] [--dry-run]

Imports NDJSON Saved Objects into the in-cluster Kibana via the ES pod.
By default every *.ndjson in $(basename "$DASHBOARDS_DIR")/ is imported
(excluding files matching the data-view bootstrap pattern $DATA_VIEW_PATTERN).

Options:
  --file PATH           Import only the given NDJSON file. May be repeated.
                        Path may be absolute or relative to this directory.
  --space-id ID         Import into the given Kibana Space (may be repeated to
                        target multiple Spaces in one run). Default: "default".
                        Used for timezone-toggle Spaces such as "cst".
  --id-prefix-for SPACE:PREFIX
                        For the given non-default Space, rewrite every saved
                        object id (and inter-object reference) of types
                        dashboard / lens / visualization / search by prepending
                        PREFIX before import. Lets non-default Spaces have
                        stable slug URLs (e.g. cst-dev-pm-retention-dashboard)
                        despite Kibana 9.x's single-namespace constraint.
                        Data-view ids are NOT prefixed (Kibana auto-remaps).
                        Example: --id-prefix-for cst:cst-
                        May be repeated for multiple Spaces.
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
    --space-id)
      shift
      [ $# -gt 0 ] || { err "--space-id requires ID"; exit 2; }
      SPACE_IDS+=("$1")
      ;;
    --id-prefix-for)
      shift
      [ $# -gt 0 ] || { err "--id-prefix-for requires SPACE:PREFIX"; exit 2; }
      ID_PREFIX_SPECS+=("$1")
      ;;
    --include-data-view) INCLUDE_DATA_VIEW=true ;;
    --no-overwrite)      OVERWRITE=false ;;
    --dry-run)           DRY_RUN=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# Default to the built-in default Space when no --space-id provided.
if [ ${#SPACE_IDS[@]} -eq 0 ]; then
  SPACE_IDS=("default")
fi

# Resolve target file list.
# Data-view bootstrap NDJSONs are emitted FIRST so dashboards on a fresh Space
# can resolve their data-view references on the very first import.
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
  # Auto-discover *.ndjson in this directory.
  shopt -s nullglob
  # Pass 1: data-view bootstrap files (only when --include-data-view).
  if [ "$INCLUDE_DATA_VIEW" = "true" ]; then
    for f in "$DASHBOARDS_DIR"/*.ndjson; do
      base=$(basename "$f")
      # shellcheck disable=SC2053
      if [[ "$base" == $DATA_VIEW_PATTERN ]]; then
        printf '%s\n' "$f"
      fi
    done
  fi
  # Pass 2: dashboards / lenses / vega (everything except data-view bootstrap).
  for f in "$DASHBOARDS_DIR"/*.ndjson; do
    base=$(basename "$f")
    # shellcheck disable=SC2053
    if [[ "$base" == $DATA_VIEW_PATTERN ]]; then
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

# Look up elastic password from the ECK-managed secret.
if [ "$DRY_RUN" != "1" ]; then
  PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  if [ -z "$PASS" ]; then
    err "Failed to read password from secret $NAMESPACE/$ES_SECRET key=$ES_USER"
    exit 1
  fi
fi

KIBANA_URL="${KIBANA_SCHEME}://${KIBANA_SVC}:${KIBANA_PORT}"
IMPORT_PATH="/api/saved_objects/_import?overwrite=${OVERWRITE}"

# Build the Space URL prefix. Default Space has no prefix; named Spaces use "/s/<id>".
space_prefix() {
  local id="$1"
  if [ "$id" = "default" ]; then
    printf ''
  else
    printf '/s/%s' "$id"
  fi
}

# Look up the configured id-prefix for the given Space (empty when unset).
id_prefix_for() {
  local target="$1"
  for spec in "${ID_PREFIX_SPECS[@]+"${ID_PREFIX_SPECS[@]}"}"; do
    local k="${spec%%:*}"
    local v="${spec#*:}"
    if [ "$k" = "$target" ] && [ "$k" != "$spec" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
}

# Rewrite NDJSON on stdin → stdout, prepending PREFIX (arg 1) to the `id` of
# every dashboard / lens / visualization / search saved object AND to every
# matching entry in each object's `references[]`. Data-view ids are left as-is
# (Kibana keeps them resolvable via multi-namespace share). Lines that fail to
# parse as JSON (e.g. the trailing excludeExportDetails summary) pass through.
#
# Note: implemented with `python3 -c "..."` (NOT a heredoc) so that the
# function's stdin remains available for `sys.stdin.read()`. A heredoc would
# steal the script's stdin and the transform would receive an empty NDJSON.
transform_ndjson() {
  python3 -c '
import json, sys
prefix = sys.argv[1]
SLUG_TYPES = {"dashboard", "lens", "visualization", "search"}
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line.strip():
        sys.stdout.write(raw)
        continue
    try:
        o = json.loads(line)
    except json.JSONDecodeError:
        sys.stdout.write(raw)
        continue
    if isinstance(o, dict):
        if o.get("type") in SLUG_TYPES and isinstance(o.get("id"), str):
            o["id"] = prefix + o["id"]
        refs = o.get("references")
        if isinstance(refs, list):
            for r in refs:
                if isinstance(r, dict) and r.get("type") in SLUG_TYPES and isinstance(r.get("id"), str):
                    r["id"] = prefix + r["id"]
    sys.stdout.write(json.dumps(o, separators=(",", ":")) + "\n")
' "$1"
}

import_one() {
  local file="$1"
  local space_id="$2"
  local prefix
  prefix=$(space_prefix "$space_id")
  local id_prefix
  id_prefix=$(id_prefix_for "$space_id")
  log ""
  log "→ Importing $(basename "$file") [space=${space_id}${id_prefix:+, id-prefix=${id_prefix}}]"
  log "  file:     $file"
  log "  endpoint: ${KIBANA_URL}${prefix}${IMPORT_PATH}"
  log "  pod:      ${NAMESPACE}/${ES_POD}"

  if [ "$DRY_RUN" = "1" ]; then
    warn "  (dry-run) skipped"
    return 0
  fi

  # When --id-prefix-for matches this Space, transform NDJSON before upload.
  # Otherwise upload the file as-is (pre-existing fast path).
  local resp
  if [ -n "$id_prefix" ]; then
    resp=$(transform_ndjson "$id_prefix" < "$file" | \
      kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
        curl -s -u "${ES_USER}:${PASS}" -H 'kbn-xsrf: true' \
          -X POST "${KIBANA_URL}${prefix}${IMPORT_PATH}" \
          -F "file=@-;filename=$(basename "$file");type=application/ndjson")
  else
    resp=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
      curl -s -u "${ES_USER}:${PASS}" -H 'kbn-xsrf: true' \
        -X POST "${KIBANA_URL}${prefix}${IMPORT_PATH}" \
        -F "file=@-;filename=$(basename "$file");type=application/ndjson" \
        < "$file")
  fi

  echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"

  # Trust the API's own `success` boolean. Earlier the `2>/dev/null` swallowed
  # python's exit=1 path on some platforms and mis-reported success — keep the
  # exit code visible and gate ok/err on it explicitly.
  local ok_flag=0
  if printf '%s' "$resp" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('success') else 1)"; then
    ok_flag=1
  fi
  if [ "$ok_flag" = "1" ]; then
    ok "  imported"
  else
    err "  import reported failures (see response above)"
    return 1
  fi
}

log "Kibana saved objects apply"
log "  namespace=$NAMESPACE  pod=$ES_POD  kibana=$KIBANA_URL"
log "  overwrite=$OVERWRITE  include-data-view=$INCLUDE_DATA_VIEW  dry-run=$DRY_RUN"
log "  spaces (${#SPACE_IDS[@]}): ${SPACE_IDS[*]}"
if [ ${#ID_PREFIX_SPECS[@]} -gt 0 ]; then
  log "  id-prefix specs: ${ID_PREFIX_SPECS[*]}"
fi
log "  targets (${#FILES[@]}):"
for f in "${FILES[@]}"; do
  log "    - $(basename "$f")"
done

FAIL=0
for s in "${SPACE_IDS[@]}"; do
  for f in "${FILES[@]}"; do
    # Skip data-view bootstrap NDJSON for non-default Spaces — data views are
    # shared from default via setup-spaces.sh (multi-namespace index-pattern).
    # Importing them per-Space would create duplicate UUIDs that lens
    # references in dashboards cannot resolve.
    base=$(basename "$f")
    # shellcheck disable=SC2053
    if [ "$s" != "default" ] && [[ "$base" == $DATA_VIEW_PATTERN ]]; then
      log ""
      log "→ Skipping $base [space=$s] — data view is shared from default Space"
      continue
    fi
    if ! import_one "$f" "$s"; then
      FAIL=$((FAIL+1))
    fi
  done
done

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."
  exit 1
fi
ok "Done."
