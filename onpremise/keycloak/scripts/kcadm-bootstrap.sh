#!/usr/bin/env bash
# Bootstrap the `example` realm via kcadm.sh — run AFTER `helmfile apply` once Keycloak Pod is Ready.
#
# Idempotent end-to-end: master-realm permanent admin (+ Secret), realm, groups, clients (with secrets), groups protocol-mapper, GitLab Identity Provider.
# Re-running is safe — every "create" path checks for existence first and falls through to "already exists — skip" instead of failing.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]

Bootstrap the Keycloak \`example\` realm end-to-end. Logs into master realm via
kubectl exec + kcadm.sh as the operator-managed bootstrap admin (\`temp-admin\`),
then reconciles every Phase 3 object (idempotent).

Env overrides (with defaults):
  NAMESPACE                       keycloak namespace            (default: keycloak)
  POD                             Keycloak pod name             (default: keycloak-0)
  REALM                           target realm                  (default: example)
  KEYCLOAK_ADMIN                  bootstrap admin username      (default: temp-admin)
  KEYCLOAK_ADMIN_PASSWORD         bootstrap admin password      (default: keycloak-initial-admin Secret)
  REAL_ADMIN_USERNAME             permanent master admin name   (default: admin)
  REAL_ADMIN_PASSWORD             permanent master admin pass   (default: exampleAdminPassword)
  REAL_ADMIN_SECRET               Secret to store creds in      (default: keycloak-master-admin)
  ARGOCD_REDIRECTS                argocd client redirectUris    (default: argocd.example.com callbacks)
  HARBOR_REDIRECTS                harbor client redirectUris    (default: harbor.example.com callback)
  OAUTH2_PROXY_REDIRECTS          oauth2-proxy redirectUris     (default: *.example.com/oauth2/callback)
  VAULTWARDEN_REDIRECTS           vaultwarden redirectUris      (default: vault.example.com/identity/connect/oidc-signin)
  GITLAB_BROKERING_CLIENT_ID      GitLab Application ID         (unset → IdP step skipped)
  GITLAB_BROKERING_CLIENT_SECRET  GitLab Application Secret     (unset → IdP step skipped)
  GITLAB_BASE_URL                 GitLab self-hosted base URL    (default: http://gitlab.example.com)

Exit code: 0 on success. Re-run after a partial failure is safe.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"
REALM="${REALM:-example}"
ADMIN_USER="${KEYCLOAK_ADMIN:-temp-admin}"

# Per-client redirect URIs. Override via env to retarget for a different cluster (qa/prod).
ARGOCD_REDIRECTS="${ARGOCD_REDIRECTS:-https://argocd.example.com/auth/callback,https://argocd.example.com/api/dex/callback}"
HARBOR_REDIRECTS="${HARBOR_REDIRECTS:-https://harbor.example.com/c/oidc/callback}"
OAUTH2_PROXY_REDIRECTS="${OAUTH2_PROXY_REDIRECTS:-https://*.example.com/oauth2/callback}"
VAULTWARDEN_REDIRECTS="${VAULTWARDEN_REDIRECTS:-https://vault.example.com/identity/connect/oidc-signin}"

# Permanent master-realm admin (replaces the operator's bootstrap `temp-admin`). Stored in Secret $REAL_ADMIN_SECRET so re-runs are idempotent and other tooling (Phase 4-5 migrations) can read it.
# Override REAL_ADMIN_PASSWORD via env for prod/qa where a stronger value is required.
REAL_ADMIN_USERNAME="${REAL_ADMIN_USERNAME:-admin}"
REAL_ADMIN_PASSWORD="${REAL_ADMIN_PASSWORD:-exampleAdminPassword}"
REAL_ADMIN_SECRET="${REAL_ADMIN_SECRET:-keycloak-master-admin}"

# When set, the GitLab IdP step is reconciled. Use the credentials of the GitLab Application created for "Keycloak Brokering (example)" — see docs/gitlab-brokering.md.
GITLAB_BROKERING_CLIENT_ID="${GITLAB_BROKERING_CLIENT_ID:-}"
GITLAB_BROKERING_CLIENT_SECRET="${GITLAB_BROKERING_CLIENT_SECRET:-}"
# Self-hosted GitLab base URL — issuer/authorization/token/userinfo/jwks URLs derive from this. Override for qa/prod or http→https.
GITLAB_BASE_URL="${GITLAB_BASE_URL:-http://gitlab.example.com}"

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  KEYCLOAK_ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret keycloak-initial-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]] && { echo "ERROR: cannot read keycloak-initial-admin Secret. Set KEYCLOAK_ADMIN_PASSWORD manually."; exit 1; }
fi

KCADM="kubectl -n $NAMESPACE exec -i $POD -- /opt/keycloak/bin/kcadm.sh"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Extract a single JSON field from kcadm output without jq (kcadm prints pretty JSON).
json_field() { sed -n "s/.*\"$2\" *: *\"\\([^\"]*\\)\".*/\\1/p" <<< "$1" | head -1; }

log "Logging in as $ADMIN_USER (master)..."
$KCADM config credentials --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# 0. Master-realm permanent admin. Idempotent — checks user existence + sync Secret.
# kcadm `get users -q username=...` is a partial match (so `admin` matches `temp-admin` too) — `exact=true` enforces full match.
log "Reconciling master-realm admin user '$REAL_ADMIN_USERNAME'..."
EXISTING_ADMIN=$($KCADM get users -r master -q "username=$REAL_ADMIN_USERNAME" -q "exact=true" --fields id,username 2>/dev/null || true)
ADMIN_USER_ID=""
if grep -q "\"username\" : \"$REAL_ADMIN_USERNAME\"" <<< "$EXISTING_ADMIN"; then
  ADMIN_USER_ID=$(json_field "$EXISTING_ADMIN" id)
fi
if [[ -z "$ADMIN_USER_ID" ]]; then
  log "  Creating user '$REAL_ADMIN_USERNAME'..."
  $KCADM create users -r master \
    -s username="$REAL_ADMIN_USERNAME" \
    -s enabled=true \
    -s "credentials=[{\"type\":\"password\",\"value\":\"$REAL_ADMIN_PASSWORD\",\"temporary\":false}]" >/dev/null
  $KCADM add-roles --uusername "$REAL_ADMIN_USERNAME" --rolename admin -r master >/dev/null
else
  log "  User '$REAL_ADMIN_USERNAME' exists — ensuring 'admin' realm role + password is in sync."
  $KCADM add-roles --uusername "$REAL_ADMIN_USERNAME" --rolename admin -r master >/dev/null 2>&1 || true
  $KCADM set-password -r master --username "$REAL_ADMIN_USERNAME" --new-password "$REAL_ADMIN_PASSWORD" >/dev/null
fi

# Reflect credentials into a Cluster Secret so other Phase 4-5 tooling (kubectl + kcadm) can read it without re-running this script.
if kubectl -n "$NAMESPACE" get secret "$REAL_ADMIN_SECRET" >/dev/null 2>&1; then
  log "  Secret $NAMESPACE/$REAL_ADMIN_SECRET exists — patching."
  kubectl -n "$NAMESPACE" create secret generic "$REAL_ADMIN_SECRET" \
    --from-literal=username="$REAL_ADMIN_USERNAME" \
    --from-literal=password="$REAL_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  log "  Creating Secret $NAMESPACE/$REAL_ADMIN_SECRET."
  kubectl -n "$NAMESPACE" create secret generic "$REAL_ADMIN_SECRET" \
    --from-literal=username="$REAL_ADMIN_USERNAME" \
    --from-literal=password="$REAL_ADMIN_PASSWORD" >/dev/null
fi

# 1. Realm. / 1. Realm.
if ! $KCADM get "realms/$REALM" >/dev/null 2>&1; then
  log "Creating realm $REALM..."
  $KCADM create realms -s realm="$REALM" -s enabled=true -s sslRequired=external
else
  log "Realm $REALM exists — skip."
fi

# 2. Groups.
EXISTING_GROUPS=$($KCADM get "groups?briefRepresentation=true" -r "$REALM" 2>/dev/null || echo "[]")
for group in server global-admin; do
  if ! grep -q "\"name\" : \"$group\"" <<< "$EXISTING_GROUPS"; then
    log "Creating group $group..."
    $KCADM create groups -r "$REALM" -s name="$group" >/dev/null
  else
    log "Group $group exists — skip."
  fi
done

# 3. Clients (idempotent — keep existing). Returns each client's secret on stdout when applicable.
# args: clientId redirectUris (comma-separated) extraAttrsJson(optional).
upsert_client() {
  local cid="$1"
  local redirects_csv="$2"
  local extra_attrs_json="${3:-}"
  # Build JSON array from csv list.
  local redirects_json
  redirects_json=$(awk -v s="$redirects_csv" 'BEGIN{n=split(s,a,","); printf "[";for(i=1;i<=n;i++){printf "%s\"%s\"", (i>1?",":""), a[i]} printf "]"}')

  local existing
  existing=$($KCADM get clients -r "$REALM" -q clientId="$cid" --fields id 2>/dev/null || true)
  local id
  id=$(json_field "$existing" id)
  if [[ -z "$id" ]]; then
    log "Creating client $cid..."
    local args=(
      create clients -r "$REALM"
      -s clientId="$cid"
      -s enabled=true
      -s protocol=openid-connect
      -s publicClient=false
      -s standardFlowEnabled=true
      -s directAccessGrantsEnabled=false
      -s "redirectUris=$redirects_json"
      -s 'webOrigins=["+"]'
    )
    [[ -n "$extra_attrs_json" ]] && args+=(-s "attributes=$extra_attrs_json")
    $KCADM "${args[@]}" >/dev/null
    existing=$($KCADM get clients -r "$REALM" -q clientId="$cid" --fields id 2>/dev/null)
    id=$(json_field "$existing" id)
  else
    log "Client $cid exists — skip create."
  fi

  # Secret retrieval (always — useful for re-printing on re-run).
  local secret_json
  secret_json=$($KCADM get "clients/$id/client-secret" -r "$REALM" 2>/dev/null || true)
  local secret
  secret=$(json_field "$secret_json" value)
  echo "  $cid: clientId=$cid id=$id secret=$secret"
}

log "Reconciling clients..."
upsert_client argocd "$ARGOCD_REDIRECTS"
upsert_client harbor "$HARBOR_REDIRECTS"
upsert_client oauth2-proxy "$OAUTH2_PROXY_REDIRECTS" '{"pkce.code.challenge.method":"S256"}'
upsert_client vaultwarden "$VAULTWARDEN_REDIRECTS" '{"pkce.code.challenge.method":"S256"}'

# 4. Groups protocol-mapper — defense in depth: client-direct mapper (always applied) + 'groups' client-scope (kicks in
# whenever the client requests `groups` scope). Without the client-scope a dex-style consumer that requests
# `groups` scope is rejected with `Invalid scopes: ... groups` because Keycloak does not auto-create a
# 'groups' client-scope.
#
# Mapper config: 6 fields. With Keycloak 26.x, an empty config `{}` is interpreted as all-false →
# the mapper silently drops the claim from every token type. Always write all 6 explicitly.
# Use a JSON file (`-f`) instead of repeated `-s 'config."dotted.key"=value'` because the latter
# silently drops nested config in some environments — observed during the Phase 6 cutover.
GROUPS_MAPPER_JSON='{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "consentRequired": false,
  "config": {
    "claim.name": "groups",
    "full.path": "false",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "introspection.token.claim": "true"
  }
}'

# 4a. Per-client direct mapper.
log "Reconciling groups protocol-mappers (client-direct)..."
for cid in argocd harbor oauth2-proxy vaultwarden; do
  client_id=$(json_field "$($KCADM get clients -r "$REALM" -q clientId="$cid" --fields id 2>/dev/null)" id)
  existing_mappers=$($KCADM get "clients/$client_id/protocol-mappers/models" -r "$REALM" 2>/dev/null || echo "[]")
  if grep -q "\"name\" : \"groups\"" <<< "$existing_mappers"; then
    log "  $cid: groups mapper exists — skip."
  else
    log "  $cid: adding groups mapper..."
    kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -c "cat > /tmp/groups-mapper-$cid.json" <<< "$GROUPS_MAPPER_JSON"
    $KCADM create "clients/$client_id/protocol-mappers/models" -r "$REALM" -f "/tmp/groups-mapper-$cid.json" >/dev/null
  fi
done

# 4b. 'groups' client-scope (realm-level).
log "Reconciling 'groups' client-scope at realm level..."
EXISTING_SCOPES=$($KCADM get client-scopes -r "$REALM" --fields id,name 2>/dev/null || echo "[]")
GROUPS_SCOPE_ID=""
if grep -q "\"name\" : \"groups\"" <<< "$EXISTING_SCOPES"; then
  GROUPS_SCOPE_ID=$(echo "$EXISTING_SCOPES" | python3 -c 'import sys,json; m=json.loads(sys.stdin.read()); print(next((x["id"] for x in m if x["name"]=="groups"),""))' 2>/dev/null || true)
  log "  client-scope groups exists (id=$GROUPS_SCOPE_ID) — skip create."
else
  log "  Creating client-scope groups..."
  GROUPS_SCOPE_JSON='{
  "name": "groups",
  "description": "Add user group memberships as a `groups` claim",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "true"
  }
}'
  kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -c 'cat > /tmp/groups-scope.json' <<< "$GROUPS_SCOPE_JSON"
  $KCADM create client-scopes -r "$REALM" -f /tmp/groups-scope.json >/dev/null
  GROUPS_SCOPE_ID=$(json_field "$($KCADM get client-scopes -r "$REALM" --fields id,name 2>/dev/null | python3 -c 'import sys,json; m=json.loads(sys.stdin.read()); print(next((json.dumps(x) for x in m if x["name"]=="groups"),"{}"))' 2>/dev/null)" id)
fi

# Mapper inside the client-scope (same 6-field config as the client-direct mapper).
existing_scope_mappers=$($KCADM get "client-scopes/$GROUPS_SCOPE_ID/protocol-mappers/models" -r "$REALM" 2>/dev/null || echo "[]")
if grep -q "\"name\" : \"groups\"" <<< "$existing_scope_mappers"; then
  log "  client-scope groups mapper exists — skip."
else
  log "  Adding mapper to client-scope groups..."
  kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -c 'cat > /tmp/groups-scope-mapper.json' <<< "$GROUPS_MAPPER_JSON"
  $KCADM create "client-scopes/$GROUPS_SCOPE_ID/protocol-mappers/models" -r "$REALM" -f /tmp/groups-scope-mapper.json >/dev/null
fi

# 4c. Attach 'groups' to every client's default-client-scopes. Idempotent — Keycloak ignores duplicate adds.
log "Attaching 'groups' client-scope to each client's default scopes..."
for cid in argocd harbor oauth2-proxy vaultwarden; do
  client_id=$(json_field "$($KCADM get clients -r "$REALM" -q clientId="$cid" --fields id 2>/dev/null)" id)
  $KCADM update "clients/$client_id/default-client-scopes/$GROUPS_SCOPE_ID" -r "$REALM" >/dev/null 2>&1 || true
  log "  $cid: groups scope attached."
done

# 5. GitLab Identity Provider — only when credentials supplied.
# Uses providerId=oidc (NOT built-in providerId=gitlab) because the built-in provider hardcodes endpoints to gitlab.com and cannot point at a self-hosted GitLab.
if [[ -n "$GITLAB_BROKERING_CLIENT_ID" && -n "$GITLAB_BROKERING_CLIENT_SECRET" ]]; then
  log "Reconciling GitLab IdP (providerId=oidc, base=$GITLAB_BASE_URL)..."
  EXISTING_IDP=$($KCADM get "identity-provider/instances/gitlab" -r "$REALM" 2>/dev/null || echo "")
  EXISTING_PROVIDER_ID=""
  if [[ -n "$EXISTING_IDP" ]]; then
    EXISTING_PROVIDER_ID=$(json_field "$EXISTING_IDP" providerId)
  fi
  # Wrong providerId (e.g. built-in 'gitlab' from a previous bootstrap) cannot be patched — must drop and recreate. Mappers under it are deleted as a side effect; reconciled below.
  if [[ -n "$EXISTING_IDP" && "$EXISTING_PROVIDER_ID" != "oidc" ]]; then
    log "  IdP gitlab has providerId=$EXISTING_PROVIDER_ID (must be oidc) — deleting for recreate."
    $KCADM delete "identity-provider/instances/gitlab" -r "$REALM" >/dev/null
    EXISTING_IDP=""
  fi
  # trustEmail=true accepts GitLab's email_verified claim verbatim — appropriate for a federation where GitLab is the upstream source-of-truth and has already verified the email at signup. Without this, Keycloak imports users with emailVerified=false and the Admin UI displays them as "Not verified" even though they've already proven email ownership upstream.
  if [[ -n "$EXISTING_IDP" ]]; then
    log "  IdP gitlab exists (providerId=oidc) — updating clientId/clientSecret/endpoints..."
    $KCADM update "identity-provider/instances/gitlab" -r "$REALM" \
      -s enabled=true \
      -s trustEmail=true \
      -s "config.clientId=$GITLAB_BROKERING_CLIENT_ID" \
      -s "config.clientSecret=$GITLAB_BROKERING_CLIENT_SECRET" \
      -s "config.issuer=$GITLAB_BASE_URL" \
      -s "config.authorizationUrl=$GITLAB_BASE_URL/oauth/authorize" \
      -s "config.tokenUrl=$GITLAB_BASE_URL/oauth/token" \
      -s "config.userInfoUrl=$GITLAB_BASE_URL/oauth/userinfo" \
      -s "config.jwksUrl=$GITLAB_BASE_URL/oauth/discovery/keys" \
      -s 'config.clientAuthMethod=client_secret_post' \
      -s 'config.validateSignature=true' \
      -s 'config.useJwksUrl=true' \
      -s 'config.syncMode=IMPORT' \
      -s 'config.defaultScope=openid email profile' >/dev/null
  else
    log "  Creating IdP gitlab (providerId=oidc)..."
    $KCADM create identity-provider/instances -r "$REALM" \
      -s alias=gitlab \
      -s providerId=oidc \
      -s enabled=true \
      -s displayName=GitLab \
      -s trustEmail=true \
      -s "config.clientId=$GITLAB_BROKERING_CLIENT_ID" \
      -s "config.clientSecret=$GITLAB_BROKERING_CLIENT_SECRET" \
      -s "config.issuer=$GITLAB_BASE_URL" \
      -s "config.authorizationUrl=$GITLAB_BASE_URL/oauth/authorize" \
      -s "config.tokenUrl=$GITLAB_BASE_URL/oauth/token" \
      -s "config.userInfoUrl=$GITLAB_BASE_URL/oauth/userinfo" \
      -s "config.jwksUrl=$GITLAB_BASE_URL/oauth/discovery/keys" \
      -s 'config.clientAuthMethod=client_secret_post' \
      -s 'config.validateSignature=true' \
      -s 'config.useJwksUrl=true' \
      -s 'config.syncMode=IMPORT' \
      -s 'config.defaultScope=openid email profile' >/dev/null
  fi

  # IdP-level mapper: hardcode every brokered GitLab user into the `server` group so existing ArgoCD `g, server, role:server-admin` keeps working.
  existing_idp_mappers=$($KCADM get "identity-provider/instances/gitlab/mappers" -r "$REALM" 2>/dev/null || echo "[]")
  if grep -q "\"name\" : \"server-group-map\"" <<< "$existing_idp_mappers"; then
    log "  IdP mapper server-group-map exists — skip."
  else
    log "  Adding IdP mapper server-group-map (hardcoded → /server)..."
    $KCADM create "identity-provider/instances/gitlab/mappers" -r "$REALM" \
      -s name=server-group-map \
      -s identityProviderAlias=gitlab \
      -s identityProviderMapper=oidc-hardcoded-group-idp-mapper \
      -s 'config.syncMode=FORCE' \
      -s 'config.group=/server' >/dev/null
  fi
else
  log "GitLab IdP step skipped (set GITLAB_BROKERING_CLIENT_ID / _SECRET to enable)."
fi

log "Bootstrap complete. Run scripts/kcadm-verify.sh for an end-to-end check."
