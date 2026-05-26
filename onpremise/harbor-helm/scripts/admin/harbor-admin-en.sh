#!/usr/bin/env bash
# =============================================================================
# Harbor Admin Helper
# =============================================================================
# Manages Harbor users, projects, members, and OIDC group mappings via the
# Harbor v2.0 REST API. Designed for the example.com self-signed HTTPS setup.
#
# Dependencies: curl, python3 (stdlib only)
#
# Environment overrides:
#   HARBOR_URL              default: https://harbor.example.com
#   HARBOR_IP               default: 192.168.1.55   (for --resolve bypass)
#   HARBOR_ADMIN            default: admin
#   HARBOR_ADMIN_PASSWORD   default: read from ../../values/dev.yaml (harbor-helm chart)
#   HARBOR_NO_RESOLVE=1     skip --resolve (use OS DNS)
# =============================================================================
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE
# enabling shell options. `declare -A` (associative arrays) requires bash 4+
# — assert below so a macOS default bash 3.2 fails fast with a clear message.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash 4+ required (current ${BASH_VERSION:-unknown}). On macOS, install Homebrew bash and ensure it is first on PATH." >&2
  exit 1
fi

# Resolve script path portably across bash and zsh (BASH_SOURCE → $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH
VALUES_FILE="$SCRIPT_DIR/../../values/dev.yaml"

HARBOR_URL="${HARBOR_URL:-https://harbor.example.com}"
HARBOR_IP="${HARBOR_IP:-192.168.1.55}"
HARBOR_ADMIN="${HARBOR_ADMIN:-admin}"
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  if [ -f "$VALUES_FILE" ]; then
    HARBOR_ADMIN_PASSWORD=$(grep '^harborAdminPassword:' "$VALUES_FILE" | awk -F'"' '{print $2}' || true)
  fi
fi
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: HARBOR_ADMIN_PASSWORD not set and could not be read from $VALUES_FILE" >&2
  exit 1
fi

# Role name → numeric id
declare -A ROLES=(
  [project-admin]=1
  [project_admin]=1
  [developer]=2
  [guest]=3
  [master]=4
  [maintainer]=4
  [limited-guest]=5
  [limited_guest]=5
)

# Color output — scripts/lib/colors.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../../scripts/lib/colors.sh"

# -----------------------------------------------
# HTTP helpers
# -----------------------------------------------

_curl_opts() {
  local opts=(-sk -u "$HARBOR_ADMIN:$HARBOR_ADMIN_PASSWORD")
  if [ -z "${HARBOR_NO_RESOLVE:-}" ]; then
    opts+=(--resolve "${HARBOR_URL#https://}:443:${HARBOR_IP}")
  fi
  printf '%s\n' "${opts[@]}"
}

api() {
  # Usage: api <METHOD> <PATH> [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  # Portable read into array — avoids bash-only `mapfile`, works in zsh too.
  local -a opts=()
  local _l
  while IFS= read -r _l; do opts+=("$_l"); done < <(_curl_opts)
  unset _l
  local url="${HARBOR_URL}${path}"
  if [ -n "$body" ]; then
    curl "${opts[@]}" -H "Content-Type: application/json" \
      -X "$method" --data "$body" "$url"
  else
    curl "${opts[@]}" -X "$method" "$url"
  fi
}

api_status() {
  # Like api() but returns "<http_code>\n<body>". Useful for non-2xx checks.
  local method=$1 path=$2 body=${3:-}
  # Portable read into array — avoids bash-only `mapfile`, works in zsh too.
  local -a opts=()
  local _l
  while IFS= read -r _l; do opts+=("$_l"); done < <(_curl_opts)
  unset _l
  local url="${HARBOR_URL}${path}"
  local resp
  if [ -n "$body" ]; then
    resp=$(curl "${opts[@]}" -H "Content-Type: application/json" \
      -X "$method" --data "$body" -w "\n__HTTP_STATUS__%{http_code}" "$url")
  else
    resp=$(curl "${opts[@]}" -X "$method" -w "\n__HTTP_STATUS__%{http_code}" "$url")
  fi
  local code="${resp##*__HTTP_STATUS__}"
  local body_out="${resp%__HTTP_STATUS__*}"
  printf '%s\n%s' "$code" "$body_out"
}

# -----------------------------------------------
# Output helpers
# -----------------------------------------------

_die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }
_info() { echo "${BLUE}→${NC} $*" >&2; }
_ok()   { echo "${GREEN}✓${NC} $*" >&2; }
_warn() { echo "${YELLOW}!${NC} $*" >&2; }

# -----------------------------------------------
# Lookups
# -----------------------------------------------

find_user_id() {
  # Resolve username OR email to numeric user_id. Echoes id or empty.
  local needle=$1
  api GET "/api/v2.0/users?page_size=100" | python3 -c "
import json, sys
needle = sys.argv[1].lower()
data = json.load(sys.stdin)
for u in data:
    if u.get('username','').lower() == needle or u.get('email','').lower() == needle:
        print(u['user_id']); break
" "$needle"
}

find_group_id() {
  # Resolve OIDC group name → numeric user_group_id. Echoes id or empty.
  local needle=$1
  api GET "/api/v2.0/usergroups?page_size=100" | python3 -c "
import json, sys
needle = sys.argv[1]
data = json.load(sys.stdin)
for g in data:
    if g.get('group_name') == needle:
        print(g['id']); break
" "$needle"
}

role_id() {
  local name=$1
  local id="${ROLES[${name,,}]:-}"
  [ -n "$id" ] || _die "unknown role '$name'. valid: ${!ROLES[*]}"
  echo "$id"
}

# -----------------------------------------------
# Commands
# -----------------------------------------------

cmd_whoami() {
  api GET "/api/v2.0/users/current" | python3 -c "
import json, sys
u = json.load(sys.stdin)
print(f\"id        {u['user_id']}\")
print(f\"username  {u['username']}\")
print(f\"email     {u.get('email','')}\")
print(f\"sysadmin  {u['sysadmin_flag']}\")
print(f\"realname  {u.get('realname','')}\")"
}

cmd_users() {
  api GET "/api/v2.0/users?page_size=100" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"{'ID':>4}  {'USERNAME':20s}  {'EMAIL':30s}  {'SYSADMIN':8s}  CREATED\")
print('-'*90)
for u in sorted(data, key=lambda x: x['user_id']):
    created = (u.get('creation_time','') or '')[:10]
    print(f\"{u['user_id']:>4}  {u.get('username','')[:20]:20s}  {(u.get('email') or '')[:30]:30s}  {str(u.get('sysadmin_flag')):8s}  {created}\")"
}

cmd_user_info() {
  local who=$1
  local id
  id=$(find_user_id "$who") || true
  [ -n "$id" ] || _die "user not found: $who"
  api GET "/api/v2.0/users/$id" | python3 -m json.tool
}

cmd_promote() {
  local who=$1
  local id
  id=$(find_user_id "$who") || true
  [ -n "$id" ] || _die "user not found: $who (must have logged in via OIDC at least once)"
  _info "promoting user_id=$id ($who) → sysadmin"
  local resp="" code=""
  resp=$(api_status PUT "/api/v2.0/users/$id/sysadmin" '{"sysadmin_flag":true}')
  code=$(echo "$resp" | head -1)
  [ "$code" = "200" ] || _die "promote failed (HTTP $code): $(echo "$resp" | tail -n +2)"
  _ok "promoted: $who is now sysadmin"
}

cmd_demote() {
  local who=$1
  local id
  id=$(find_user_id "$who") || true
  [ -n "$id" ] || _die "user not found: $who"
  _info "demoting user_id=$id ($who) ← sysadmin"
  local resp="" code=""
  resp=$(api_status PUT "/api/v2.0/users/$id/sysadmin" '{"sysadmin_flag":false}')
  code=$(echo "$resp" | head -1)
  [ "$code" = "200" ] || _die "demote failed (HTTP $code): $(echo "$resp" | tail -n +2)"
  _ok "demoted: $who is no longer sysadmin"
}

cmd_projects() {
  api GET "/api/v2.0/projects?page_size=100" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"{'ID':>4}  {'NAME':25s}  {'PUBLIC':6s}  {'REPOS':>5}  OWNER\")
print('-'*70)
for p in sorted(data, key=lambda x: x['project_id']):
    meta = p.get('metadata') or {}
    public = meta.get('public','false')
    repos = p.get('repo_count', 0)
    owner = p.get('owner_name','')
    print(f\"{p['project_id']:>4}  {p['name'][:25]:25s}  {str(public)[:6]:6s}  {repos:>5}  {owner}\")"
}

cmd_project_members() {
  local project=$1
  api GET "/api/v2.0/projects/$project/members?page_size=100" | python3 -c "
import json, sys
data = json.load(sys.stdin)
role_name = {1:'project-admin',2:'developer',3:'guest',4:'maintainer',5:'limited-guest'}
etype = {'u':'user','g':'group'}
print(f\"{'MID':>4}  {'TYPE':5s}  {'NAME':25s}  {'ROLE':14s}  ENTITY_ID\")
print('-'*70)
for m in data:
    t = etype.get(m.get('entity_type'), '?')
    rid = m.get('role_id')
    rn = role_name.get(rid, f'unknown({rid})')
    name = m.get('entity_name','')
    eid = m.get('entity_id','')
    print(f\"{m['id']:>4}  {t:5s}  {name[:25]:25s}  {rn:14s}  {eid}\")"
}

cmd_add_member() {
  # add-member <project> <user|group:name> <role>
  local project=$1 target=$2 role=$3
  local rid
  rid=$(role_id "$role")

  local kind="" name=""
  if [[ "$target" == group:* ]]; then
    kind=group; name="${target#group:}"
  else
    kind=user; name="$target"
  fi

  local body
  if [ "$kind" = user ]; then
    local uid
    uid=$(find_user_id "$name") || true
    [ -n "$uid" ] || _die "user not found: $name"
    body=$(printf '{"role_id":%d,"member_user":{"user_id":%d}}' "$rid" "$uid")
  else
    local gid
    gid=$(find_group_id "$name") || true
    if [ -z "$gid" ]; then
      # Register OIDC group if missing (group_type=3 = OIDC)
      _info "OIDC group '$name' not registered yet — creating"
      local grp_body
      grp_body=$(printf '{"group_name":"%s","group_type":3,"ldap_group_dn":"%s"}' "$name" "$name")
      local resp="" code=""
      resp=$(api_status POST "/api/v2.0/usergroups" "$grp_body")
      code=$(echo "$resp" | head -1)
      [[ "$code" =~ ^(200|201)$ ]] || _die "failed to create group (HTTP $code)"
      gid=$(find_group_id "$name")
      [ -n "$gid" ] || _die "group creation reported success but id not found"
      _ok "created OIDC group: $name (id=$gid)"
    fi
    body=$(printf '{"role_id":%d,"member_group":{"id":%d}}' "$rid" "$gid")
  fi

  local resp="" code=""
  resp=$(api_status POST "/api/v2.0/projects/$project/members" "$body")
  code=$(echo "$resp" | head -1)
  [[ "$code" =~ ^(201)$ ]] || _die "add-member failed (HTTP $code): $(echo "$resp" | tail -n +2)"
  _ok "added $kind '$name' to project '$project' as $role"
}

cmd_remove_member() {
  # remove-member <project> <user|mid>
  local project=$1 target=$2
  local mid
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    mid="$target"
  else
    # find by name
    mid=$(api GET "/api/v2.0/projects/$project/members?page_size=100" | python3 -c "
import json, sys
needle = sys.argv[1].lower()
for m in json.load(sys.stdin):
    if (m.get('entity_name') or '').lower() == needle:
        print(m['id']); break
" "$target")
  fi
  [ -n "$mid" ] || _die "member not found in project '$project': $target"
  local resp="" code=""
  resp=$(api_status DELETE "/api/v2.0/projects/$project/members/$mid")
  code=$(echo "$resp" | head -1)
  [ "$code" = "200" ] || _die "remove-member failed (HTTP $code)"
  _ok "removed member mid=$mid from project '$project'"
}

cmd_groups() {
  api GET "/api/v2.0/usergroups?page_size=100" | python3 -c "
import json, sys
gt = {1:'LDAP',2:'HTTP',3:'OIDC'}
data = json.load(sys.stdin)
print(f\"{'ID':>4}  {'TYPE':5s}  {'NAME':25s}  LDAP_DN / OIDC_GROUP\")
print('-'*70)
for g in sorted(data, key=lambda x: x['id']):
    t = gt.get(g.get('group_type'), '?')
    print(f\"{g['id']:>4}  {t:5s}  {g.get('group_name','')[:25]:25s}  {g.get('ldap_group_dn','')}\")"
}

cmd_add_group() {
  # add-group <oidc-group-name>
  local name=$1
  local existing
  existing=$(find_group_id "$name") || true
  [ -z "$existing" ] || _die "group already exists: $name (id=$existing)"
  local body
  body=$(printf '{"group_name":"%s","group_type":3,"ldap_group_dn":"%s"}' "$name" "$name")
  local resp="" code=""
  resp=$(api_status POST "/api/v2.0/usergroups" "$body")
  code=$(echo "$resp" | head -1)
  [[ "$code" =~ ^(200|201)$ ]] || _die "add-group failed (HTTP $code)"
  local gid=""; gid=$(find_group_id "$name")
  _ok "registered OIDC group '$name' (id=$gid)"
}

cmd_config() {
  api GET "/api/v2.0/configurations" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = ['auth_mode','oidc_name','oidc_endpoint','oidc_client_id',
        'oidc_groups_claim','oidc_admin_group','oidc_group_filter',
        'oidc_scope','oidc_user_claim','oidc_verify_cert','oidc_auto_onboard']
for k in keys:
    v = d.get(k,{}).get('value')
    if k == 'oidc_client_id' and v:
        v = v[:12] + '...'
    print(f'{k:22s} = {v}')
print(f'{\"oidc_client_secret\":22s} = *** (write-only)')"
}

cmd_set_oidc() {
  # set-oidc --name X --endpoint Y --client-id Z --client-secret W [...]
  local name="" endpoint="" client_id="" client_secret=""
  local verify_cert=""
  local groups_claim="groups"
  local group_filter="server"
  local user_claim="preferred_username"
  local admin_group=""
  local scope="openid,profile,email"
  local auto_onboard="true"
  local dry_run=0 no_confirm=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)            name="$2"; shift 2 ;;
      --endpoint)        endpoint="$2"; shift 2 ;;
      --client-id)       client_id="$2"; shift 2 ;;
      --client-secret)   client_secret="$2"; shift 2 ;;
      --verify-cert)     verify_cert="$2"; shift 2 ;;
      --groups-claim)    groups_claim="$2"; shift 2 ;;
      --group-filter)    group_filter="$2"; shift 2 ;;
      --user-claim)      user_claim="$2"; shift 2 ;;
      --admin-group)     admin_group="$2"; shift 2 ;;
      --scope)           scope="$2"; shift 2 ;;
      --auto-onboard)    auto_onboard="$2"; shift 2 ;;
      --dry-run)         dry_run=1; shift ;;
      -y|--no-confirm)   no_confirm=1; shift ;;
      *)                 _die "unknown option: $1" ;;
    esac
  done

  [ -n "$client_secret" ] || client_secret="${HARBOR_OIDC_CLIENT_SECRET:-}"

  [ -n "$name" ]          || _die "--name required"
  [ -n "$endpoint" ]      || _die "--endpoint required"
  [ -n "$client_id" ]     || _die "--client-id required"
  [ -n "$client_secret" ] || _die "--client-secret required (or set HARBOR_OIDC_CLIENT_SECRET)"

  if [ -z "$verify_cert" ]; then
    case "$endpoint" in
      https://*) verify_cert="true" ;;
      *)         verify_cert="false" ;;
    esac
  fi
  case "$verify_cert" in true|false) ;; *) _die "--verify-cert must be true|false";; esac
  case "$auto_onboard" in true|false) ;; *) _die "--auto-onboard must be true|false";; esac

  local body
  body=$(NAME="$name" ENDPOINT="$endpoint" CID="$client_id" CSEC="$client_secret" \
         GCLAIM="$groups_claim" AGRP="$admin_group" GFILT="$group_filter" \
         SCOPE="$scope" UCLAIM="$user_claim" VCERT="$verify_cert" AUTO="$auto_onboard" \
         python3 -c '
import json, os
v = lambda s: True if s == "true" else False
print(json.dumps({
  "oidc_name": os.environ["NAME"],
  "oidc_endpoint": os.environ["ENDPOINT"],
  "oidc_client_id": os.environ["CID"],
  "oidc_client_secret": os.environ["CSEC"],
  "oidc_groups_claim": os.environ["GCLAIM"],
  "oidc_admin_group": os.environ["AGRP"],
  "oidc_group_filter": os.environ["GFILT"],
  "oidc_scope": os.environ["SCOPE"],
  "oidc_user_claim": os.environ["UCLAIM"],
  "oidc_verify_cert": v(os.environ["VCERT"]),
  "oidc_auto_onboard": v(os.environ["AUTO"]),
}))')

  _info "target: ${HARBOR_URL}/api/v2.0/configurations"
  echo "$body" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
d['oidc_client_secret'] = '***' if d.get('oidc_client_secret') else ''
print(json.dumps(d, indent=2))" >&2

  if [ "$dry_run" -eq 1 ]; then
    _ok "DRY RUN — skipping PUT"
    return 0
  fi

  if [ "$no_confirm" -eq 0 ]; then
    printf '%s' "${YELLOW}Continue? [y/N]: ${NC}" >&2
    local reply
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) _info "cancelled"; exit 0 ;;
    esac
  fi

  local resp="" code=""
  resp=$(api_status PUT "/api/v2.0/configurations" "$body")
  code=$(echo "$resp" | head -1)
  [ "$code" = "200" ] || _die "OIDC update failed (HTTP $code): $(echo "$resp" | tail -n +2)"
  _ok "OIDC config updated. Run 'config' to verify"
}

cmd_systeminfo() {
  # /systeminfo is public (no auth required) — drop basic auth
  local -a opts=(-sk)
  if [ -z "${HARBOR_NO_RESOLVE:-}" ]; then
    opts+=(--resolve "${HARBOR_URL#https://}:443:${HARBOR_IP}")
  fi
  curl "${opts[@]}" "$HARBOR_URL/api/v2.0/systeminfo" | python3 -m json.tool
}

# -----------------------------------------------
# Usage / dispatcher
# -----------------------------------------------

usage() {
  cat <<EOF
${BOLD}Harbor Admin Helper${NC}

  Usage: $(basename "$0") <command> [args...]

${BOLD}User management${NC}
  whoami                          Who am I (admin sanity check)
  users                           List all users
  user-info <user|email>          Show user details
  promote <user|email>            Promote to sysadmin
  demote <user|email>             Demote from sysadmin

${BOLD}Project / membership${NC}
  projects                        List projects
  project-members <project>       List project members
  add-member <project> <target> <role>
                                  target: username | email | group:<oidc-group>
                                  role:   project-admin | maintainer | developer | guest | limited-guest
  remove-member <project> <user|mid>

${BOLD}OIDC groups${NC}
  groups                          List user groups
  add-group <oidc-group-name>     Register an OIDC group (type=3)

${BOLD}OIDC config update${NC}
  set-oidc --name N --endpoint E --client-id ID --client-secret S [opts]
                                  PUT OIDC settings (supports --dry-run / -y).
                                  optional: --verify-cert true|false (auto-true on https),
                                            --groups-claim, --group-filter, --user-claim,
                                            --admin-group, --scope, --auto-onboard true|false.
                                  client-secret may be set via HARBOR_OIDC_CLIENT_SECRET env.

${BOLD}Diagnostics${NC}
  config                          Dump OIDC-related configuration
  systeminfo                      Public systeminfo (auth_mode etc.)

${BOLD}Environment${NC}
  HARBOR_URL                  default ${HARBOR_URL}
  HARBOR_IP                   default ${HARBOR_IP} (used for --resolve)
  HARBOR_ADMIN                default ${HARBOR_ADMIN}
  HARBOR_ADMIN_PASSWORD       default reads from ../../values/dev.yaml (harbor-helm chart)
  HARBOR_OIDC_CLIENT_SECRET   alternative to --client-secret on set-oidc
  HARBOR_NO_RESOLVE=1         use OS DNS instead of --resolve

${BOLD}Examples${NC}
  $(basename "$0") users
  $(basename "$0") promote admin@example.com
  $(basename "$0") add-member library admin@example.com maintainer
  $(basename "$0") add-member example-project group:server developer
  $(basename "$0") add-group server
  # Switch to Keycloak (Phase 4)
  $(basename "$0") set-oidc --name Keycloak \\
    --endpoint https://auth.example.com/realms/example \\
    --client-id harbor --client-secret 'XXXX' --dry-run
  # Rollback to GitLab
  $(basename "$0") set-oidc --name GitLab \\
    --endpoint http://gitlab.example.com \\
    --client-id 'GL_APP_ID' --client-secret 'GL_SECRET' --verify-cert false
EOF
  exit "${1:-0}"
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage 1
  shift || true
  case "$cmd" in
    -h|--help|help)       usage 0 ;;
    whoami)               cmd_whoami ;;
    users)                cmd_users ;;
    user-info)            [ $# -ge 1 ] || _die "user-info <user|email>"; cmd_user_info "$1" ;;
    promote)              [ $# -ge 1 ] || _die "promote <user|email>"; cmd_promote "$1" ;;
    demote)               [ $# -ge 1 ] || _die "demote <user|email>"; cmd_demote "$1" ;;
    projects)             cmd_projects ;;
    project-members)      [ $# -ge 1 ] || _die "project-members <project>"; cmd_project_members "$1" ;;
    add-member)           [ $# -ge 3 ] || _die "add-member <project> <target> <role>"; cmd_add_member "$1" "$2" "$3" ;;
    remove-member)        [ $# -ge 2 ] || _die "remove-member <project> <user|mid>"; cmd_remove_member "$1" "$2" ;;
    groups)               cmd_groups ;;
    add-group)            [ $# -ge 1 ] || _die "add-group <oidc-group-name>"; cmd_add_group "$1" ;;
    config)               cmd_config ;;
    set-oidc)             cmd_set_oidc "$@" ;;
    systeminfo)           cmd_systeminfo ;;
    *)                    echo "unknown command: $cmd" >&2; usage 1 ;;
  esac
}

main "$@"
