#!/usr/bin/env bash
# Bootstrap Kibana Spaces for timezone toggle (KST / CST).
#
# Per Space spec the script:
#   1) creates the Space if missing (idempotent)
#   2) pins `dateFormat:tz` Advanced Setting (Space-scoped)
#
# Dashboard/lens/visualization/data view objects are NOT cross-Space-shared by
# this script. Kibana 9.x treats those types as single-namespace, so the same
# saved-object id literally cannot live in two Spaces. Instead, `apply.sh`
# imports identical NDJSON into each Space — same titles/panels/indices, but
# the cst Space's objects receive auto-generated UUIDs. The NDJSON files in
# this directory remain the single source of truth.
#
# Default mapping:
#   default → Asia/Seoul   (KST,  built-in space)
#   cst     → Asia/Shanghai (CST/UTC+8, created if absent)
#
# Re-running is safe — every API call (Space create, Settings POST) is idempotent.
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

NAMESPACE="${NAMESPACE:-logging}"
ES_POD="${ES_POD:-elasticsearch-es-default-0}"
ES_CONTAINER="${ES_CONTAINER:-elasticsearch}"
KIBANA_SVC="${KIBANA_SVC:-kibana-kb-http.${NAMESPACE}.svc}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
KIBANA_SCHEME="${KIBANA_SCHEME:-http}"
ES_SECRET="${ES_SECRET:-elasticsearch-es-elastic-user}"
ES_USER="${ES_USER:-elastic}"

# Default Space specs: "<id>:<IANA_zone>".
declare -a SPECS=(
  "default:Asia/Seoul"
  "cst:Asia/Shanghai"
)

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
Usage: $(basename "$0") [--space NAME:TZ]... [--dry-run]

Creates Kibana Spaces (if missing) and pins each Space's dateFormat:tz
Advanced Setting. Safe to re-run.

Default specs:
  default:Asia/Seoul    (KST)
  cst:Asia/Shanghai     (CST / UTC+8)

Options:
  --space NAME:TZ   Override the default spec list. May be repeated.
                    When provided at least once, the defaults are dropped.
                    Examples:
                      --space default:Asia/Seoul --space cst:Asia/Shanghai
                      --space default:UTC --space jst:Asia/Tokyo
  --dry-run         Print actions without contacting Kibana.

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
declare -a USER_SPECS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --space)
      shift; [ $# -gt 0 ] || { err "--space requires NAME:TZ"; exit 2; }
      USER_SPECS+=("$1")
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ ${#USER_SPECS[@]} -gt 0 ]; then
  SPECS=("${USER_SPECS[@]}")
fi

KIBANA_URL="${KIBANA_SCHEME}://${KIBANA_SVC}:${KIBANA_PORT}"

# Look up elastic password
if [ "$DRY_RUN" != "1" ]; then
  PASS=$(kubectl -n "$NAMESPACE" get secret "$ES_SECRET" -o jsonpath="{.data.${ES_USER}}" | base64 -d)
  if [ -z "$PASS" ]; then
    err "Failed to read password from secret $NAMESPACE/$ES_SECRET key=$ES_USER"
    exit 1
  fi
fi

# Build the Space URL prefix. Default Space has no prefix; named Spaces use "/s/<id>".
space_prefix() {
  local id="$1"
  if [ "$id" = "default" ]; then
    printf ''
  else
    printf '/s/%s' "$id"
  fi
}

# Common headers for Kibana API calls. The `/internal/...` endpoints
# (used for Advanced Settings on Kibana 8+) require the internal-origin header.
KBN_HEADERS=(
  -H 'kbn-xsrf: true'
  -H 'x-elastic-internal-origin: Kibana'
  -H 'Content-Type: application/json'
)

# Ensure a Space exists. The built-in "default" Space cannot be created via API
# (it always exists), so we just no-op for it.
ensure_space() {
  local name="$1"
  if [ "$name" = "default" ]; then
    ok "  space '$name' is the built-in default (no create needed)"
    return 0
  fi

  local code
  code=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -o /dev/null -w '%{http_code}' \
      -u "${ES_USER}:${PASS}" "${KBN_HEADERS[@]}" \
      "${KIBANA_URL}/api/spaces/space/${name}")

  if [ "$code" = "200" ]; then
    ok "  space '$name' already exists"
    return 0
  fi

  # Build a friendly display name (uppercase the id) without using bash-only
  # `${var^^}` (which zsh -n rejects).
  local display
  display=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')

  local payload
  payload=$(printf '{"id":"%s","name":"%s","description":"Timezone view mirror — same dashboards as Default Space, different dateFormat:tz","disabledFeatures":[]}' "$name" "$display")

  # Note: trailing slash + non-2xx must propagate even though caller uses `if !`,
  # which suppresses set -e inside the function. Capture status explicitly.
  local status
  status=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -o /dev/null -w '%{http_code}' \
      -u "${ES_USER}:${PASS}" "${KBN_HEADERS[@]}" \
      -X POST "${KIBANA_URL}/api/spaces/space" -d "$payload")
  case "$status" in
    2??) ok "  created space '$name' (display: $display)" ;;
    *)   err "  create failed for space '$name' (HTTP $status)"; return 1 ;;
  esac
}

# Pin dateFormat:tz in the given Space via the (internal) Settings API.
# Kibana 8+ moved this from /api/kibana/settings to /internal/kibana/settings.
set_timezone() {
  local space="$1"
  local tz="$2"
  local prefix
  prefix=$(space_prefix "$space")

  local payload
  payload=$(printf '{"changes":{"dateFormat:tz":"%s"}}' "$tz")

  local status
  status=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -o /dev/null -w '%{http_code}' \
      -u "${ES_USER}:${PASS}" "${KBN_HEADERS[@]}" \
      -X POST "${KIBANA_URL}${prefix}/internal/kibana/settings" -d "$payload")
  case "$status" in
    2??) ok "  set dateFormat:tz=$tz in space '$space'" ;;
    *)   err "  set failed for space '$space' (HTTP $status)"; return 1 ;;
  esac
}

# Share every index-pattern (data view) in the default Space into the given
# target Space. index-pattern is one of the few multi-namespace Kibana types,
# so a single object can live in multiple Spaces — which means lens references
# to a data view UUID resolve in every Space the data view has been shared to.
share_data_views_to() {
  local target="$1"
  if [ "$target" = "default" ]; then
    return 0  # default is the share source
  fi

  # Find every index-pattern in the default Space.
  local list_json
  list_json=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -u "${ES_USER}:${PASS}" "${KBN_HEADERS[@]}" \
      "${KIBANA_URL}/api/saved_objects/_find?type=index-pattern&per_page=100&fields=title")

  # Build the objects array from the find result.
  local objs
  objs=$(printf '%s' "$list_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
out = [{'type': o['type'], 'id': o['id']} for o in d.get('saved_objects', [])]
print(json.dumps(out))
")
  if [ "$objs" = "[]" ]; then
    warn "  no index-patterns to share from default → '$target'"
    return 0
  fi

  local payload
  payload=$(printf '{"objects":%s,"spacesToAdd":["%s"],"spacesToRemove":[]}' "$objs" "$target")

  local body status
  body=$(kubectl -n "$NAMESPACE" exec -i "$ES_POD" -c "$ES_CONTAINER" -- \
    curl -s -w '\n__HTTP__%{http_code}' \
      -u "${ES_USER}:${PASS}" "${KBN_HEADERS[@]}" \
      -X POST "${KIBANA_URL}/api/spaces/_update_objects_spaces" -d "$payload")
  status="${body##*__HTTP__}"
  body="${body%$'\n__HTTP__'*}"

  case "$status" in
    2??)
      local nshared nfail
      nshared=$(printf '%s' "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
objs = d.get('objects', [])
ok = sum(1 for o in objs if not o.get('error'))
print(ok)
")
      nfail=$(printf '%s' "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('?'); sys.exit()
objs = d.get('objects', [])
bad = sum(1 for o in objs if o.get('error'))
print(bad)
")
      if [ "$nfail" = "0" ]; then
        ok "  shared $nshared data view(s) from 'default' → '$target'"
        return 0
      fi
      err "  data view share reported $nfail error(s) for '$target':"
      printf '%s\n' "$body" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$body"
      return 1
      ;;
    *)
      err "  data view share failed for '$target' (HTTP $status):"
      printf '%s\n' "$body" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$body"
      return 1
      ;;
  esac
}

log "Kibana Space bootstrap"
log "  namespace=$NAMESPACE  pod=$ES_POD  kibana=$KIBANA_URL"
log "  dry-run=$DRY_RUN"
log "  specs (${#SPECS[@]}):"
for spec in "${SPECS[@]}"; do
  log "    - $spec"
done

FAIL=0
for spec in "${SPECS[@]}"; do
  name="${spec%%:*}"
  tz="${spec#*:}"
  if [ -z "$name" ] || [ -z "$tz" ] || [ "$name" = "$spec" ]; then
    err "malformed spec (expected NAME:TZ): $spec"
    FAIL=$((FAIL+1))
    continue
  fi

  log ""
  log "→ Space '$name' (tz=$tz)"
  if [ "$DRY_RUN" = "1" ]; then
    warn "  (dry-run) would ensure space + set dateFormat:tz"
    continue
  fi

  if ! ensure_space "$name"; then
    FAIL=$((FAIL+1))
    continue
  fi
  if ! set_timezone "$name" "$tz"; then
    FAIL=$((FAIL+1))
    continue
  fi
  if ! share_data_views_to "$name"; then
    FAIL=$((FAIL+1))
  fi
done

log ""
if [ "$FAIL" -gt 0 ]; then
  err "Done with $FAIL failure(s)."
  exit 1
fi
ok "Done."
