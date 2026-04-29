#!/usr/bin/env bash
# Verify the `example` realm matches the Phase 3 expected shape — read-only.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]

Read-only verification of the Keycloak \`example\` realm Phase 3 configuration.
Logs into master realm via kubectl exec + kcadm.sh, then asserts:
  - master-realm admin user (REAL_ADMIN_USERNAME) + Secret keycloak-master-admin
  - realm 'example' (enabled, sslRequired=external)
  - groups: server, global-admin
  - clients: argocd, harbor, oauth2-proxy, vaultwarden + redirect URIs + groups protocol-mapper
    + 6-field mapper config + 'groups' in default-client-scopes
  - realm-level 'groups' client-scope (with oidc-group-membership-mapper)
  - GitLab Identity Provider (when EXPECT_GITLAB_IDP=1, the default) — providerId=oidc + issuer URL
  - external HTTPS reachability (auth.example.com OIDC discovery → 200)

Env overrides:
  NAMESPACE              keycloak namespace                     (default: keycloak)
  POD                    Keycloak StatefulSet pod name          (default: keycloak-0)
  REALM                  application realm name                 (default: example)
  KEYCLOAK_ADMIN         master-realm admin used to log in       (default: temp-admin)
  KEYCLOAK_ADMIN_PASSWORD password for KEYCLOAK_ADMIN            (default: keycloak-initial-admin Secret)
  REAL_ADMIN_USERNAME    permanent master admin username         (default: admin)
  REAL_ADMIN_SECRET      Secret holding admin credentials        (default: keycloak-master-admin)
  EXPECT_GITLAB_IDP      0 to skip GitLab IdP assertions         (default: 1)
  EXPECT_GITLAB_BASE_URL expected IdP issuer URL                  (default: http://gitlab.example.com)
  NGF_IP                 IP for --resolve auth.example.com:443:   (default: 192.168.1.55)

Exit code: 0 when all checks pass, 1 on any failure, 2 on setup error.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
#
# Checks: realm exists
# Exits non-zero on any failure so it can be wired into CI
set -uo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"
REALM="${REALM:-example}"
ADMIN_USER="${KEYCLOAK_ADMIN:-temp-admin}"
EXPECT_GITLAB_IDP="${EXPECT_GITLAB_IDP:-1}"   # 0 to skip GitLab IdP assertions
EXPECT_GITLAB_BASE_URL="${EXPECT_GITLAB_BASE_URL:-http://gitlab.example.com}"   # expected IdP issuer URL — must match GITLAB_BASE_URL used in bootstrap.
REAL_ADMIN_USERNAME="${REAL_ADMIN_USERNAME:-admin}"
REAL_ADMIN_SECRET="${REAL_ADMIN_SECRET:-keycloak-master-admin}"

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  KEYCLOAK_ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret keycloak-initial-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]] && { echo "ERROR: cannot read keycloak-initial-admin Secret. Set KEYCLOAK_ADMIN_PASSWORD manually."; exit 2; }
fi

KCADM="kubectl -n $NAMESPACE exec -i $POD -- /opt/keycloak/bin/kcadm.sh"

PASS=0
FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  \033[32m✓\033[0m %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$label"
    FAIL=$((FAIL + 1))
  fi
}
check_grep() {
  local label="$1" pattern="$2"; shift 2
  if "$@" 2>/dev/null | grep -qE "$pattern"; then
    printf "  \033[32m✓\033[0m %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$label"
    FAIL=$((FAIL + 1))
  fi
}

echo "[$(date '+%H:%M:%S')] Logging in as $ADMIN_USER..."
$KCADM config credentials --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "ERROR: kcadm login failed."; exit 2; }

echo
echo "Master-realm admin:"
ADMIN_USER_JSON=$($KCADM get users -r master -q "username=$REAL_ADMIN_USERNAME" 2>/dev/null || echo "[]")
if grep -q "\"username\" : \"$REAL_ADMIN_USERNAME\"" <<< "$ADMIN_USER_JSON"; then
  printf "  \033[32m✓\033[0m master user '$REAL_ADMIN_USERNAME' exists\n"; PASS=$((PASS+1))
  ADMIN_ROLES=$($KCADM get-roles -r master --uusername "$REAL_ADMIN_USERNAME" --rolename admin 2>/dev/null || true)
  if grep -q '"name" : "admin"' <<< "$ADMIN_ROLES"; then
    printf "  \033[32m✓\033[0m master user '$REAL_ADMIN_USERNAME' has 'admin' realm role\n"; PASS=$((PASS+1))
  else
    printf "  \033[31m✗\033[0m master user '$REAL_ADMIN_USERNAME' missing 'admin' realm role\n"; FAIL=$((FAIL+1))
  fi
else
  printf "  \033[31m✗\033[0m master user '$REAL_ADMIN_USERNAME' missing\n"; FAIL=$((FAIL+1))
fi
if kubectl -n "$NAMESPACE" get secret "$REAL_ADMIN_SECRET" >/dev/null 2>&1; then
  printf "  \033[32m✓\033[0m Secret %s/%s exists\n" "$NAMESPACE" "$REAL_ADMIN_SECRET"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m Secret %s/%s missing\n" "$NAMESPACE" "$REAL_ADMIN_SECRET"; FAIL=$((FAIL+1))
fi

echo
echo "Realm:"
REALM_JSON=$($KCADM get "realms/$REALM" 2>/dev/null || true)
if grep -q "\"realm\" : \"$REALM\"" <<< "$REALM_JSON"; then
  printf "  \033[32m✓\033[0m realm '$REALM' exists\n"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m realm '$REALM' missing\n"; FAIL=$((FAIL+1))
fi
if grep -q '"enabled" : true' <<< "$REALM_JSON"; then
  printf "  \033[32m✓\033[0m realm '$REALM' enabled=true\n"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m realm '$REALM' not enabled\n"; FAIL=$((FAIL+1))
fi
if grep -q '"sslRequired" : "external"' <<< "$REALM_JSON"; then
  printf "  \033[32m✓\033[0m realm '$REALM' sslRequired=external\n"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m realm '$REALM' sslRequired != external\n"; FAIL=$((FAIL+1))
fi

echo
echo "Groups:"
GROUPS_JSON=$($KCADM get "groups?briefRepresentation=true" -r "$REALM" 2>/dev/null || echo "[]")
for g in server global-admin; do
  if grep -q "\"name\" : \"$g\"" <<< "$GROUPS_JSON"; then
    printf "  \033[32m✓\033[0m group '$g' exists\n"; PASS=$((PASS+1))
  else
    printf "  \033[31m✗\033[0m group '$g' missing\n"; FAIL=$((FAIL+1))
  fi
done

echo
echo "Clients:"
# Bash 3.2 (macOS default) lacks associative arrays — using a case fn for the redirect-URI fixture.
expected_redirect() {
  case "$1" in
    argocd)       echo "argocd.example.com/api/dex/callback" ;;
    harbor)       echo "harbor.example.com/c/oidc/callback" ;;
    oauth2-proxy) echo "example.com/oauth2/callback" ;;
    vaultwarden)  echo "vault.example.com/identity/connect/oidc-signin" ;;
  esac
}

for cid in argocd harbor oauth2-proxy vaultwarden; do
  CL=$($KCADM get clients -r "$REALM" -q clientId="$cid" 2>/dev/null || echo "[]")
  if grep -q "\"clientId\" : \"$cid\"" <<< "$CL"; then
    printf "  \033[32m✓\033[0m client '$cid' exists\n"; PASS=$((PASS+1))
    expected=$(expected_redirect "$cid")
    if grep -qF "$expected" <<< "$CL"; then
      printf "  \033[32m✓\033[0m client '$cid' redirect URI contains '%s'\n" "$expected"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m client '$cid' redirect URI missing '%s'\n" "$expected"; FAIL=$((FAIL+1))
    fi
    cl_id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<< "$CL" | head -1)
    MAPPERS=$($KCADM get "clients/$cl_id/protocol-mappers/models" -r "$REALM" 2>/dev/null || echo "[]")
    if grep -q '"protocolMapper" : "oidc-group-membership-mapper"' <<< "$MAPPERS" \
       && grep -q '"name" : "groups"' <<< "$MAPPERS"; then
      printf "  \033[32m✓\033[0m client '$cid' groups protocol-mapper present\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m client '$cid' groups protocol-mapper missing\n"; FAIL=$((FAIL+1))
    fi
    # Mapper config must have all 6 fields. Keycloak 26.x interprets an empty config `{}` as all-false →
    # the mapper silently drops the claim from every token. Catch this regression.
    mapper_id=$(echo "$MAPPERS" | python3 -c 'import sys,json; m=json.loads(sys.stdin.read()); print(next((x["id"] for x in m if x.get("name")=="groups"),""))' 2>/dev/null || true)
    if [[ -n "$mapper_id" ]]; then
      MAPPER_RAW=$($KCADM get "clients/$cl_id/protocol-mappers/models/$mapper_id" -r "$REALM" 2>/dev/null || echo "{}")
      missing=""
      for k in '"claim.name" : "groups"' '"full.path" : "false"' '"id.token.claim" : "true"' '"access.token.claim" : "true"' '"userinfo.token.claim" : "true"' '"introspection.token.claim" : "true"'; do
        grep -qF "$k" <<< "$MAPPER_RAW" || missing="$missing ${k%% *}"
      done
      if [[ -z "$missing" ]]; then
        printf "  \033[32m✓\033[0m client '$cid' groups mapper config has all 6 fields (claim.name, full.path, *.token.claim×4)\n"; PASS=$((PASS+1))
      else
        printf "  \033[31m✗\033[0m client '$cid' groups mapper config missing fields:%s\n" "$missing"; FAIL=$((FAIL+1))
      fi
    fi
    # default-client-scopes must include 'groups'. Without it dex-style consumers requesting `groups` scope are rejected by Keycloak.
    DEFAULT_SCOPES=$($KCADM get "clients/$cl_id/default-client-scopes" -r "$REALM" --fields name 2>/dev/null || echo "[]")
    if grep -q '"name" : "groups"' <<< "$DEFAULT_SCOPES"; then
      printf "  \033[32m✓\033[0m client '$cid' default-client-scopes includes 'groups'\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m client '$cid' default-client-scopes missing 'groups'\n"; FAIL=$((FAIL+1))
    fi
  else
    printf "  \033[31m✗\033[0m client '$cid' missing\n"; FAIL=$((FAIL+1))
  fi
done

echo
echo "Realm-level 'groups' client-scope:"
SCOPES_LIST=$($KCADM get client-scopes -r "$REALM" --fields id,name 2>/dev/null || echo "[]")
if grep -q '"name" : "groups"' <<< "$SCOPES_LIST"; then
  printf "  \033[32m✓\033[0m client-scope 'groups' exists\n"; PASS=$((PASS+1))
  GROUPS_SCOPE_ID=$(echo "$SCOPES_LIST" | python3 -c 'import sys,json; m=json.loads(sys.stdin.read()); print(next((x["id"] for x in m if x.get("name")=="groups"),""))' 2>/dev/null || true)
  if [[ -n "$GROUPS_SCOPE_ID" ]]; then
    SCOPE_MAPPERS=$($KCADM get "client-scopes/$GROUPS_SCOPE_ID/protocol-mappers/models" -r "$REALM" 2>/dev/null || echo "[]")
    if grep -q '"protocolMapper" : "oidc-group-membership-mapper"' <<< "$SCOPE_MAPPERS"; then
      printf "  \033[32m✓\033[0m client-scope 'groups' has oidc-group-membership-mapper\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m client-scope 'groups' missing oidc-group-membership-mapper\n"; FAIL=$((FAIL+1))
    fi
  fi
else
  printf "  \033[31m✗\033[0m client-scope 'groups' missing (Keycloak does not auto-create it; required for dex-style consumers)\n"; FAIL=$((FAIL+1))
fi

if [[ "$EXPECT_GITLAB_IDP" == "1" ]]; then
  echo
  echo "GitLab Identity Provider:"
  IDP=$($KCADM get "identity-provider/instances/gitlab" -r "$REALM" 2>/dev/null || echo "")
  if [[ -n "$IDP" ]]; then
    printf "  \033[32m✓\033[0m IdP 'gitlab' exists\n"; PASS=$((PASS+1))
    if grep -q '"enabled" : true' <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' enabled=true\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' not enabled\n"; FAIL=$((FAIL+1))
    fi
    # providerId must be 'oidc' — built-in 'gitlab' provider hardcodes endpoints to gitlab.com and breaks self-hosted GitLab brokering.
    if grep -q '"providerId" : "oidc"' <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' providerId=oidc\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' providerId != oidc (expected oidc; built-in 'gitlab' points at gitlab.com)\n"; FAIL=$((FAIL+1))
    fi
    # Issuer URL must match the self-hosted GitLab base URL (no trailing slash).
    if grep -q "\"issuer\" : \"$EXPECT_GITLAB_BASE_URL\"" <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' issuer=%s\n" "$EXPECT_GITLAB_BASE_URL"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' issuer != %s (override via EXPECT_GITLAB_BASE_URL)\n" "$EXPECT_GITLAB_BASE_URL"; FAIL=$((FAIL+1))
    fi
    # trustEmail=true accepts GitLab's email_verified claim — without it, brokered users show as "Not verified" in the Admin UI even though GitLab already verified the email at signup.
    if grep -q '"trustEmail" : true' <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' trustEmail=true\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' trustEmail != true (brokered users will appear as 'Not verified')\n"; FAIL=$((FAIL+1))
    fi
    if grep -q '"syncMode" : "IMPORT"' <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' syncMode=IMPORT\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' syncMode != IMPORT\n"; FAIL=$((FAIL+1))
    fi
    IDP_MAPPERS=$($KCADM get "identity-provider/instances/gitlab/mappers" -r "$REALM" 2>/dev/null || echo "[]")
    if grep -q '"name" : "server-group-map"' <<< "$IDP_MAPPERS"; then
      printf "  \033[32m✓\033[0m IdP mapper 'server-group-map' present\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP mapper 'server-group-map' missing\n"; FAIL=$((FAIL+1))
    fi
  else
    printf "  \033[31m✗\033[0m IdP 'gitlab' missing\n"; FAIL=$((FAIL+1))
  fi
else
  echo
  echo "GitLab Identity Provider: skipped (EXPECT_GITLAB_IDP=0)"
fi

echo
echo "External reachability:"
# Hostname header forced via --resolve to bypass macOS DNS cache flakiness during tests.
NGF_IP="${NGF_IP:-192.168.1.55}"
DISC_HTTP=$(curl -sk --resolve "auth.example.com:443:$NGF_IP" -o /dev/null -w '%{http_code}' --max-time 10 \
  https://auth.example.com/realms/$REALM/.well-known/openid-configuration 2>/dev/null || echo "000")
if [[ "$DISC_HTTP" == "200" ]]; then
  printf "  \033[32m✓\033[0m OIDC discovery endpoint returns 200\n"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m OIDC discovery endpoint returned $DISC_HTTP (expected 200)\n"; FAIL=$((FAIL+1))
fi

echo
echo "Result: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] || exit 1
