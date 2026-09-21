#!/usr/bin/env bash
# Create (or update) a Kibana / Elasticsearch user mapped to an existing role,
# via the Security API. Idempotent: PUT-based — re-running with the same
# arguments replaces the user definition (incl. password).
#
# Scope split: role creation lives in a sibling script,
#   ./create-elastic-role.sh --context <ctx> --role-name <name> [permission flags]
# Run that first when the role does not yet exist. This script aborts in step 0
# with a clear message when the target role is missing.
#
# What it does:
#   0. Pre-flight  GET /_security/role/<role_name>  (role must exist).
#   1. PUT  /_security/user/<username>  password + roles=[<role_name>] (+
#       optional full_name / email).
#   2. GET  /_security/_authenticate as the new user — sanity check.
#
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE anything
# else. This is NOT cosmetic — `USERNAME` is a zsh special parameter bound to the
# process owner, so under zsh the `USERNAME="$1"` below is silently ignored and
# `-u viewer` would PUT /_security/user/<operator> instead, creating or
# overwriting the wrong account (silently, since --yes hides the plan). The same
# re-exec also avoids zsh's 1-based arrays in the sibling create-elastic-role.sh.
# Matches the guard already used by observability/logging/*/scripts/bootstrap-*.sh.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/es-common.sh
source "${_SCRIPT_DIR}/../lib/es-common.sh"

# --- defaults -----------------------------------------------------------------

USERNAME=""
ROLE_NAME="read_only_role"
FULL_NAME=""
EMAIL=""
PASSWORD=""
PASSWORD_STDIN=0
PASSWORD_ENV=""
CONFIRM_PROMPT=1
# DRY_RUN comes from es-common.sh.

usage() {
  cat <<EOF
Usage: $(basename "$0") --context CTX -u NAME
                        [-p STR | --password-stdin | --password-env VAR] [options]

Creates (or updates) a Kibana / Elasticsearch user mapped to an existing role.
The role itself must already exist — create it first with create-elastic-role.sh
(or any equivalent PUT to /_security/role/<name>).

Required:
  --context CTX               kube-context to run every kubectl call against.
                              No default and no fallback to the current context —
                              the on-prem and AWS clusters have identically named
                              logging pods, so an implicit context silently targets
                              the wrong one and would create this user in the wrong
                              cluster. The name is a LOCAL kubeconfig alias with
                              no fixed value — list yours with
                              \`kubectl config get-contexts -o name\`, and confirm
                              the cluster= line in the printed plan (that is the
                              stable id, not the alias).
  -u, --username NAME         Elasticsearch / Kibana username to create.

Password (exactly one expected; prompt is used if none given):
  --password-stdin            Read the password from stdin (cat secret | script ... --password-stdin).
  --password-env VAR          Read the password from environment variable VAR.
  -p, --password STR          Pass the password directly (visible in ps/history — discouraged).

Options:
  --role-name NAME            Existing role to attach to the user. Default: ${ROLE_NAME}.
                              The script aborts in step 0 if this role does not exist.
  --full-name NAME            Optional 'full_name' field for the user record.
  --email EMAIL               Optional 'email' field for the user record.
  --dry-run                   Print the curl payloads (password masked) without contacting ES.
  -y, --yes                   Skip the interactive 'create user' confirmation prompt.
  -h | --help                 Show this help and exit.

Env overrides (rarely needed):
  KUBE_CONTEXT=${KUBE_CONTEXT}
  NAMESPACE_ES=${NAMESPACE_ES}
  ES_POD=${ES_POD}  ES_CONTAINER=${ES_CONTAINER}
  ES_SVC=${ES_SVC}  ES_PORT=${ES_PORT}  ES_SCHEME=${ES_SCHEME}
  ES_SECRET=${ES_SECRET}  ES_USER=${ES_USER}

Examples:
  # interactive prompt (recommended)
  $(basename "$0") --context <ctx> -u viewer

  # from stdin (CI / wrapping)
  echo "\$NEW_PASSWORD" | $(basename "$0") --context <ctx> -u viewer --password-stdin --yes

  # attach to a different role created by create-elastic-role.sh
  $(basename "$0") --context <ctx> -u pm-viewer --role-name pm_viewer
EOF
}

# --- arg parse ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --context)
      shift; [ $# -gt 0 ] || { err "--context requires CTX"; exit 2; }
      KUBE_CONTEXT="$1"
      ;;
    -u|--username)
      shift; [ $# -gt 0 ] || { err "--username requires NAME"; exit 2; }
      USERNAME="$1"
      ;;
    -p|--password)
      shift; [ $# -gt 0 ] || { err "--password requires STR"; exit 2; }
      PASSWORD="$1"
      ;;
    --password-stdin) PASSWORD_STDIN=1 ;;
    --password-env)
      shift; [ $# -gt 0 ] || { err "--password-env requires VAR"; exit 2; }
      PASSWORD_ENV="$1"
      ;;
    --role-name)
      shift; [ $# -gt 0 ] || { err "--role-name requires NAME"; exit 2; }
      ROLE_NAME="$1"
      ;;
    --full-name)
      shift; [ $# -gt 0 ] || { err "--full-name requires NAME"; exit 2; }
      FULL_NAME="$1"
      ;;
    --email)
      shift; [ $# -gt 0 ] || { err "--email requires EMAIL"; exit 2; }
      EMAIL="$1"
      ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) CONFIRM_PROMPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# Hard-fail unless a real kube-context was named — enforced for --dry-run too.
require_kube_context

if [ -z "$USERNAME" ]; then
  err "-u / --username is required"
  usage
  exit 2
fi
if ! [[ "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  err "invalid username '$USERNAME' — must match ^[A-Za-z_][A-Za-z0-9_.-]*\$"
  exit 2
fi

# --- password resolution ------------------------------------------------------

resolve_password() {
  local sources=0
  [ -n "$PASSWORD" ] && sources=$((sources + 1))
  [ "$PASSWORD_STDIN" = "1" ] && sources=$((sources + 1))
  [ -n "$PASSWORD_ENV" ] && sources=$((sources + 1))
  if [ "$sources" -gt 1 ]; then
    err "pick only one of --password / --password-stdin / --password-env"
    exit 2
  fi

  if [ "$PASSWORD_STDIN" = "1" ]; then
    IFS= read -r PASSWORD || true
  elif [ -n "$PASSWORD_ENV" ]; then
    PASSWORD="${!PASSWORD_ENV-}"
    [ -n "$PASSWORD" ] || { err "env var '${PASSWORD_ENV}' is empty / unset"; exit 2; }
  elif [ -z "$PASSWORD" ]; then
    # Interactive prompt — disable echo.
    printf "Password for new user '%s': " "$USERNAME" >&2
    IFS= read -r -s PASSWORD || true
    printf "\nConfirm password: " >&2
    local pw2=""
    IFS= read -r -s pw2 || true
    printf "\n" >&2
    if [ "$PASSWORD" != "$pw2" ]; then
      err "passwords do not match"
      exit 1
    fi
  fi

  if [ -z "$PASSWORD" ]; then
    err "empty password"
    exit 1
  fi
  if [ "${#PASSWORD}" -lt 8 ]; then
    err "password must be at least 8 characters (got ${#PASSWORD})"
    exit 1
  fi
  if [ "${#PASSWORD}" -lt 12 ]; then
    warn "password is shorter than 12 characters — consider a longer one"
  fi
}
resolve_password

# --- payload ------------------------------------------------------------------

build_user_payload() {
  local pw_escaped extras=""
  pw_escaped=$(json_escape "$PASSWORD")
  if [ -n "$FULL_NAME" ]; then
    extras+=$',\n  "full_name": "'"$(json_escape "$FULL_NAME")"'"'
  fi
  if [ -n "$EMAIL" ]; then
    extras+=$',\n  "email": "'"$(json_escape "$EMAIL")"'"'
  fi
  cat <<EOF
{
  "password": "${pw_escaped}",
  "roles": ["${ROLE_NAME}"]${extras}
}
EOF
}

# --- plan / confirm -----------------------------------------------------------

print_plan() {
  log ""
  log "Kibana / Elasticsearch user plan"
  # Print the resolved cluster, not just the context name — a context can be renamed
  # or repointed, so the cluster is what actually identifies the target. This line is
  # the operator's last chance to catch a wrong-cluster run.
  log "  kube context:  ${KUBE_CONTEXT}  (cluster=$(kube_context_cluster))"
  log "  ES pod:        ${NAMESPACE_ES}/${ES_POD} (container=${ES_CONTAINER})"
  log "  role:          ${ROLE_NAME}   (must already exist — created by create-elastic-role.sh)"
  log "  username:      ${USERNAME}"
  [ -n "$FULL_NAME" ] && log "  full_name:     ${FULL_NAME}"
  [ -n "$EMAIL" ]     && log "  email:         ${EMAIL}"
  log "  password:      ********  (length=${#PASSWORD})"
  log "  dry-run:       $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
}

confirm_or_exit() {
  [ "$CONFIRM_PROMPT" = "0" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  log ""
  printf "Create user '%s' with role '%s'? Type 'yes' to continue: " "$USERNAME" "$ROLE_NAME"
  local answer=""
  IFS= read -r answer || true
  if [ "$answer" != "yes" ]; then
    err "aborted (expected 'yes', got: '$answer')"
    exit 1
  fi
}

# --- steps --------------------------------------------------------------------

preflight_role_exists() {
  step 0 "Pre-flight — role '${ROLE_NAME}' must exist"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) assume role exists"
    return 0
  fi
  local code
  code=$(es_status GET "/_security/role/${ROLE_NAME}")
  case "$code" in
    200)
      ok "role '${ROLE_NAME}' exists"
      ;;
    404)
      err "role '${ROLE_NAME}' not found — create it first:"
      err "    ./create-elastic-role.sh --context '${KUBE_CONTEXT}' --role-name '${ROLE_NAME}' [permission flags] --yes"
      exit 1
      ;;
    *)
      err "unexpected HTTP ${code} from GET /_security/role/${ROLE_NAME}"
      exit 1
      ;;
  esac
}

put_user() {
  step 1 "PUT /_security/user/${USERNAME}"
  local payload resp
  payload=$(build_user_payload)
  if [ "$DRY_RUN" = "1" ]; then
    log "    body (password masked):"
    mask_payload "$payload" | sed 's/^/      /'
    es_call PUT "/_security/user/${USERNAME}" >/dev/null || true
    return 0
  fi
  resp=$(printf '%s' "$payload" | es_call PUT "/_security/user/${USERNAME}")
  if printf '%s' "$resp" | grep -q '"created":\|"user":'; then
    ok "user '${USERNAME}' applied"
  else
    err "unexpected user response: $resp"
    exit 1
  fi
}

verify_auth() {
  step 2 "Authenticate as '${USERNAME}'"
  if [ "$DRY_RUN" = "1" ]; then
    log "    (dry-run) GET /_security/_authenticate (auth=${USERNAME})"
    return 0
  fi
  local resp who roles_field
  resp=$(printf '' | es_call GET "/_security/_authenticate" "$USERNAME" "$PASSWORD")
  who=$(printf '%s' "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d.get('username', ''))
" 2>/dev/null || echo "")
  roles_field=$(printf '%s' "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(','.join(d.get('roles', [])))
" 2>/dev/null || echo "")
  if [ "$who" = "$USERNAME" ]; then
    ok "authenticated as '${who}' with roles=[${roles_field}]"
  else
    err "authentication failed — response: $resp"
    exit 1
  fi
}

print_next_steps() {
  log ""
  log "Next steps:"
  log "  • Log into Kibana with username='${USERNAME}' and verify access:"
  log "      - Discover / Dashboard / Visualize: visible (read-only role)"
  log "      - Dev Tools / Stack Management: NOT visible (intentional)"
  log "  • Rotate the password periodically:"
  log "      ./$(basename "$0") --context '${KUBE_CONTEXT}' -u '${USERNAME}' --password-stdin"
  log "  • Disable the account when no longer needed:"
  log "      kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE_ES} exec ${ES_POD} -c ${ES_CONTAINER} -- \\"
  log "        curl -sk -u ${ES_USER}:\$ADMIN_PASS -X PUT '${ES_URL}/_security/user/${USERNAME}/_disable'"
}

# --- main ---------------------------------------------------------------------

main() {
  print_plan
  confirm_or_exit
  load_admin_pass
  preflight_role_exists
  put_user
  verify_auth
  print_next_steps
  log ""
  ok "Done."
}

main "$@"
