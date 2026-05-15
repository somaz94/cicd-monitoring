#!/usr/bin/env bash
# Create (or update) an Elasticsearch role via the Security API. Designed as a
# building block for Kibana user accounts (see create-kibana-readonly-user.sh)
# but reusable for any role flavor — read-only, read-write, custom — through the
# permission flags below.
#
# Defaults compose a safe read-only role:
#   cluster=[monitor]
#   indices.names=[*]   privileges=[read, view_index_metadata]
#   applications=[ kibana-.kibana priv=[read] resources=[*] ]
# Override any of these via the flags below.
#
# Examples:
#   # default — read_only_role over all indices
#   ./create-elastic-role.sh --confirm
#
#   # restrict to a specific index family
#   ./create-elastic-role.sh --role-name pm_viewer \
#     --indices 'example-project-*,dev-example-project-game*' --confirm
#
#   # writer role for dev pipelines
#   ./create-elastic-role.sh --role-name dev_writer \
#     --indices 'dev-*' \
#     --index-privileges 'read,write,create,create_index,view_index_metadata' \
#     --kibana-privileges all --confirm
#
#   # Kibana-only role (no ES indices privileges)
#   ./create-elastic-role.sh --role-name kibana_only \
#     --indices '' --kibana-privileges read --confirm
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/es-common.sh
source "${_SCRIPT_DIR}/lib/es-common.sh"

# --- defaults -----------------------------------------------------------------

ROLE_NAME="read_only_role"
INDICES="*"
INDEX_PRIVS="read,view_index_metadata"
CLUSTER_PRIVS="monitor"
KIBANA_APPLICATION="kibana-.kibana"
KIBANA_PRIVS="read"
KIBANA_RESOURCES="*"
CONFIRM_PROMPT=1
# DRY_RUN comes from es-common.sh (default 0).

usage() {
  cat <<EOF
Usage: $(basename "$0") [--role-name NAME] [permission flags] [--dry-run] [--confirm]

Creates (or updates) an Elasticsearch role via the Security API. All defaults
compose a safe read-only role — override individual flags to build different
role flavors (read-write, custom, Kibana-only, etc).

Options:
  --role-name NAME                Role name to PUT. Default: ${ROLE_NAME}.

  --cluster PRIV[,PRIV...]        Cluster privileges. Default: ${CLUSTER_PRIVS}.
                                  Set to '' (empty) to omit the cluster block.
                                  Example: 'monitor,manage_index_templates'.

  --indices PAT[,PAT2...]         Index name patterns this role applies to.
                                  Default: ${INDICES}. Set to '' (empty) to
                                  produce a role with no indices section
                                  (e.g. Kibana-only roles).

  --index-privileges PRIV[,PRIV]  Index privileges. Default: ${INDEX_PRIVS}.
                                  Example: 'read,write,create,view_index_metadata'.

  --kibana-application NAME       Kibana application name. Default: ${KIBANA_APPLICATION}.
                                  Set to '' (empty) to omit the applications block
                                  entirely (Elasticsearch-only role).

  --kibana-privileges PRIV[,PRIV] Kibana application privileges. Default: ${KIBANA_PRIVS}.
                                  Common values: 'read' (Discover/Dashboard/etc Read),
                                  'all' (full Kibana incl. Dev Tools + Management).

  --kibana-resources RES[,RES...] Kibana resources. Default: ${KIBANA_RESOURCES}.
                                  '*' = all spaces. Use 'space:<id>' for a specific space.

  --dry-run                       Print the curl payload without contacting ES.
  --confirm                       Skip the interactive confirmation prompt (CI use).
  -h | --help                     Show this help and exit.

Env overrides (rarely needed):
  NAMESPACE_ES=${NAMESPACE_ES}
  ES_POD=${ES_POD}  ES_CONTAINER=${ES_CONTAINER}
  ES_SVC=${ES_SVC}  ES_PORT=${ES_PORT}  ES_SCHEME=${ES_SCHEME}
  ES_SECRET=${ES_SECRET}  ES_USER=${ES_USER}
EOF
}

# --- arg parse ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --role-name)
      shift; [ $# -gt 0 ] || { err "--role-name requires NAME"; exit 2; }
      ROLE_NAME="$1"
      ;;
    --cluster)
      shift; [ $# -gt 0 ] || { err "--cluster requires PRIV[,PRIV...]"; exit 2; }
      CLUSTER_PRIVS="$1"
      ;;
    --indices)
      shift; [ $# -gt 0 ] || { err "--indices requires PAT[,PAT2...] (or '')"; exit 2; }
      INDICES="$1"
      ;;
    --index-privileges)
      shift; [ $# -gt 0 ] || { err "--index-privileges requires PRIV[,PRIV...]"; exit 2; }
      INDEX_PRIVS="$1"
      ;;
    --kibana-application)
      shift; [ $# -gt 0 ] || { err "--kibana-application requires NAME (or '')"; exit 2; }
      KIBANA_APPLICATION="$1"
      ;;
    --kibana-privileges)
      shift; [ $# -gt 0 ] || { err "--kibana-privileges requires PRIV[,PRIV...]"; exit 2; }
      KIBANA_PRIVS="$1"
      ;;
    --kibana-resources)
      shift; [ $# -gt 0 ] || { err "--kibana-resources requires RES[,RES...]"; exit 2; }
      KIBANA_RESOURCES="$1"
      ;;
    --dry-run) DRY_RUN=1 ;;
    --confirm) CONFIRM_PROMPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

if ! [[ "$ROLE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  err "invalid role name '$ROLE_NAME' — must match ^[A-Za-z_][A-Za-z0-9_.-]*\$"
  exit 2
fi

# --- payload ------------------------------------------------------------------

build_role_payload() {
  local sections=()

  if [ -n "$CLUSTER_PRIVS" ]; then
    sections+=("\"cluster\": $(csv_to_json_array "$CLUSTER_PRIVS")")
  fi

  if [ -n "$INDICES" ]; then
    local indices_json index_privs_json
    indices_json=$(csv_to_json_array "$INDICES")
    index_privs_json=$(csv_to_json_array "$INDEX_PRIVS")
    sections+=("\"indices\": [
    {
      \"names\": ${indices_json},
      \"privileges\": ${index_privs_json}
    }
  ]")
  fi

  if [ -n "$KIBANA_APPLICATION" ]; then
    local kb_privs_json kb_resources_json
    kb_privs_json=$(csv_to_json_array "$KIBANA_PRIVS")
    kb_resources_json=$(csv_to_json_array "$KIBANA_RESOURCES")
    sections+=("\"applications\": [
    {
      \"application\": \"${KIBANA_APPLICATION}\",
      \"privileges\": ${kb_privs_json},
      \"resources\": ${kb_resources_json}
    }
  ]")
  fi

  if [ ${#sections[@]} -eq 0 ]; then
    err "empty role payload — at least one of --cluster / --indices / --kibana-application is required"
    exit 2
  fi

  # Join sections with ',\n  '
  local body="{
  "
  local i
  for ((i=0; i<${#sections[@]}; i++)); do
    body+="${sections[i]}"
    if [ "$i" -lt $((${#sections[@]} - 1)) ]; then
      body+=",
  "
    fi
  done
  body+="
}"
  printf '%s' "$body"
}

# --- plan / confirm -----------------------------------------------------------

print_plan() {
  log ""
  log "Elasticsearch role plan"
  log "  ES pod:              ${NAMESPACE_ES}/${ES_POD} (container=${ES_CONTAINER})"
  log "  role:                ${ROLE_NAME}"
  log "  cluster:             ${CLUSTER_PRIVS:-(omitted)}"
  log "  indices:             ${INDICES:-(omitted)}"
  log "  index privileges:    ${INDEX_PRIVS:-(omitted)}"
  log "  kibana application:  ${KIBANA_APPLICATION:-(omitted)}"
  log "  kibana privileges:   ${KIBANA_PRIVS:-(omitted)}"
  log "  kibana resources:    ${KIBANA_RESOURCES:-(omitted)}"
  log "  dry-run:             $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
}

confirm_or_exit() {
  [ "$CONFIRM_PROMPT" = "0" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  log ""
  printf "Create / update role '%s'? Type 'yes' to continue: " "$ROLE_NAME"
  local answer=""
  IFS= read -r answer || true
  if [ "$answer" != "yes" ]; then
    err "aborted (expected 'yes', got: '$answer')"
    exit 1
  fi
}

# --- step ---------------------------------------------------------------------

put_role() {
  step 1 "PUT /_security/role/${ROLE_NAME}"
  local payload resp
  payload=$(build_role_payload)
  if [ "$DRY_RUN" = "1" ]; then
    log "    body:"
    printf '%s\n' "$payload" | sed 's/^/      /'
    es_call PUT "/_security/role/${ROLE_NAME}" >/dev/null || true
    return 0
  fi
  resp=$(printf '%s' "$payload" | es_call PUT "/_security/role/${ROLE_NAME}")
  if printf '%s' "$resp" | grep -q '"created":\|"role":'; then
    ok "role '${ROLE_NAME}' applied"
    log "    response: ${resp}"
  else
    err "unexpected role response: $resp"
    exit 1
  fi
}

# --- main ---------------------------------------------------------------------

main() {
  print_plan
  confirm_or_exit
  load_admin_pass
  put_role
  log ""
  log "Next: attach this role to a user (existing or new):"
  log "  ./create-kibana-readonly-user.sh -u <username> --role-name '${ROLE_NAME}'"
  log ""
  ok "Done."
}

main "$@"
