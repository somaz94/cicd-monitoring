#!/usr/bin/env bash
# Verify the `example` realm matches the Phase 3 expected shape — read-only.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]

Read-only verification of the Keycloak \`example\` realm Phase 3 configuration.
Logs into master realm via kubectl exec + kcadm.sh, then asserts:
  - master-realm admin user (REAL_ADMIN_USERNAME) + Secret keycloak-master-admin
  - realm 'example' (enabled, sslRequired=external)
  - groups: GITLAB_MAPPED_GROUPS + MANUAL_GROUPS (+ warns when global-admin is empty)
  - clients: VERIFY_CLIENTS (default: argocd harbor vaultwarden example-hub grafana)
    + redirect URIs + groups protocol-mapper
    + 6-field mapper config + 'groups' in default-client-scopes
  - realm-level 'groups' client-scope (with oidc-group-membership-mapper)
  - GitLab Identity Provider (when EXPECT_GITLAB_IDP=1, the default) — providerId=oidc + issuer URL
  - one IdP mapper per GITLAB_MAPPED_GROUPS entry ('<group>-group-map') — must be
    oidc-advanced-group-idp-mapper with claims groups_direct=<group>, group=/<group>,
    syncMode=FORCE (a hardcoded mapper would grant the group to EVERY brokered account)
  - external HTTPS reachability (auth.example.com OIDC discovery → 200)

Env overrides:
  NAMESPACE              keycloak namespace                     (default: keycloak)
  POD                    Keycloak StatefulSet pod name          (default: keycloak-0)
  REALM                  application realm name                 (default: example)
  KEYCLOAK_ADMIN         master-realm admin used to log in       (default: \$REAL_ADMIN_USERNAME)
  KEYCLOAK_ADMIN_PASSWORD password for KEYCLOAK_ADMIN            (default: Secret matching the account —
                         \$REAL_ADMIN_SECRET for the permanent admin, keycloak-initial-admin for temp-admin)
  REAL_ADMIN_USERNAME    permanent master admin username         (default: admin)
  REAL_ADMIN_SECRET      Secret holding admin credentials        (default: keycloak-master-admin)
  EXPECT_GITLAB_IDP      0 to skip GitLab IdP assertions         (default: 1)
  EXPECT_GLOBAL_ADMIN_MEMBERS  1 to FAIL on an empty global-admin group (default: 0 → warn only)
  EXPECT_GITLAB_BASE_URL expected IdP issuer URL                  (default: http://gitlab.example.com)
  VERIFY_CLIENTS         clients to assert; keep in step with CANONICAL_CLIENTS
                         (default: argocd harbor vaultwarden example-hub grafana)
  NGF_IP                 IP for --resolve auth.example.com:443:   (default: 192.0.2.55)
  GITLAB_MAPPED_GROUPS   claim-driven groups (default: server client gamedesign)
  MANUAL_GROUPS          hand-managed groups (default: global-admin)

Exit code: 0 when all checks pass, 1 on any failure, 2 on setup error.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
#
# Read-only; exits non-zero on any failure (CI / pre-cutover gate). Checks are listed in usage().
#
# The same assertions are also available without cluster access at
# hub.example.com/apps/keycloak-ops/ (the realm-check tab, GET /api/realm/check) — use that
# for a quick look; use this script when you need an exit code.
set -uo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"
REALM="${REALM:-example}"
# Login account. Defaults to the PERMANENT master admin (REAL_ADMIN_USERNAME /
# REAL_ADMIN_SECRET below), not the bootstrap `temp-admin`.
#
# 🔴 The default used to be temp-admin, which made the documented invocation
# (`kcadm-verify.sh` with no env) fail at login with exit 2 on any cluster past
# bootstrap — temp-admin is deleted once the permanent admin exists. A verifier
# whose default invocation cannot log in is worse than no verifier: it reports a
# setup error that reads like a cluster problem, and the realm goes unchecked.
#
# temp-admin remains reachable during bootstrap via KEYCLOAK_ADMIN=temp-admin.
ADMIN_USER="${KEYCLOAK_ADMIN:-${REAL_ADMIN_USERNAME:-admin}}"
EXPECT_GITLAB_IDP="${EXPECT_GITLAB_IDP:-1}"   # 0 to skip GitLab IdP assertions
EXPECT_GLOBAL_ADMIN_MEMBERS="${EXPECT_GLOBAL_ADMIN_MEMBERS:-0}"   # 1 to FAIL (not warn) on an empty global-admin group — use for post-bootstrap runs
EXPECT_GITLAB_BASE_URL="${EXPECT_GITLAB_BASE_URL:-http://gitlab.example.com}"   # expected IdP issuer URL — must match GITLAB_BASE_URL used in bootstrap.
REAL_ADMIN_USERNAME="${REAL_ADMIN_USERNAME:-admin}"
REAL_ADMIN_SECRET="${REAL_ADMIN_SECRET:-keycloak-master-admin}"

# Password Secret follows the account: the permanent admin reads REAL_ADMIN_SECRET,
# the bootstrap temp-admin reads keycloak-initial-admin. Picking the Secret by the
# account (rather than always reading the bootstrap one) is what makes the default
# invocation work both during bootstrap and afterwards.
if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  if [[ "$ADMIN_USER" == "$REAL_ADMIN_USERNAME" ]]; then
    PW_SECRET="$REAL_ADMIN_SECRET"
  else
    PW_SECRET="keycloak-initial-admin"
  fi
  KEYCLOAK_ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret "$PW_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]] && { echo "ERROR: cannot read Secret $PW_SECRET (for user $ADMIN_USER). Set KEYCLOAK_ADMIN_PASSWORD manually."; exit 2; }
fi

KCADM="kubectl -n $NAMESPACE exec -i $POD -- /opt/keycloak/bin/kcadm.sh"

PASS=0
FAIL=0
# WARN is reported in the summary but never affects the exit code — conditions that are legitimate
# on a fresh realm yet worth surfacing (e.g. an empty global-admin before anyone's first login).
WARN=0
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
# Must mirror kcadm-bootstrap.sh. Kept as env-overridable variables with the same names so a
# realm configured with a different set can be verified without editing this script.
GITLAB_MAPPED_GROUPS="${GITLAB_MAPPED_GROUPS:-server client gamedesign}"
MANUAL_GROUPS="${MANUAL_GROUPS:-global-admin}"
GROUPS_JSON=$($KCADM get "groups?briefRepresentation=true" -r "$REALM" 2>/dev/null || echo "[]")
for g in $GITLAB_MAPPED_GROUPS $MANUAL_GROUPS; do
  if grep -q "\"name\" : \"$g\"" <<< "$GROUPS_JSON"; then
    printf "  \033[32m✓\033[0m group '$g' exists\n"; PASS=$((PASS+1))
  else
    printf "  \033[31m✗\033[0m group '$g' missing\n"; FAIL=$((FAIL+1))
  fi
done
# global-admin must be NON-EMPTY. An empty group is silently load-bearing: consumers that want an
# admin-only gate cannot use it and fall back to the much broader /server (example-hub gates
# keycloak-ops that way) or to a hardcoded email. Both consumers moved to the group on 2026-07-30,
# so an empty group now locks admins out of ArgoCD AND keycloak-ops rather than just degrading. Warn, do not
# fail, on a fresh realm — brokered users only exist after their first login.
# `search=` is a substring match and can wrap a matching subgroup in its parent, so resolve the id
# by exact name rather than taking the first "id" in the blob.
GLOBAL_ADMIN_GID=$(printf '%s' "$($KCADM get groups -r "$REALM" -q search=global-admin --fields id,name 2>/dev/null || echo '[]')" \
  | python3 -c 'import json,sys
try:
    groups = json.load(sys.stdin)
except Exception:
    groups = []
print(next((g["id"] for g in groups if g.get("name") == "global-admin"), ""))' 2>/dev/null || echo "")
if [[ -z "$GLOBAL_ADMIN_GID" ]]; then
  printf "  \033[31m✗\033[0m group 'global-admin' id not resolvable — cannot check membership\n"; FAIL=$((FAIL+1))
else
  GA_MEMBERS=$($KCADM get "groups/$GLOBAL_ADMIN_GID/members" -r "$REALM" --fields username 2>/dev/null || echo "[]")
  if grep -q '"username"' <<< "$GA_MEMBERS"; then
    printf "  \033[32m✓\033[0m group 'global-admin' has members\n"; PASS=$((PASS+1))
  elif [[ "$EXPECT_GLOBAL_ADMIN_MEMBERS" == "1" ]]; then
    printf "  \033[31m✗\033[0m group 'global-admin' is EMPTY — admin-only gates cannot use it (set GLOBAL_ADMIN_MEMBERS and re-run kcadm-bootstrap.sh after the user's first login)\n"; FAIL=$((FAIL+1))
  else
    printf "  \033[33m!\033[0m group 'global-admin' is EMPTY — admin-only gates cannot use it, so consumers fall back to the much broader /server or to a hardcoded email (set EXPECT_GLOBAL_ADMIN_MEMBERS=1 to make this a failure)\n"; WARN=$((WARN+1))
  fi
fi

echo
echo "Clients:"
# Bash 3.2 (macOS default) lacks associative arrays — using a case fn for the redirect-URI fixture.
expected_redirect() {
  case "$1" in
    argocd)       echo "argocd.example.com/api/dex/callback" ;;
    harbor)       echo "harbor.example.com/c/oidc/callback" ;;
    vaultwarden)  echo "vault.example.com/identity/connect/oidc-signin" ;;
    example-hub)  echo "hub.example.com/oidc/callback" ;;
    grafana)      echo "grafana.example.com/login/generic_oauth" ;;
  esac
}

# Must stay in step with CANONICAL_CLIENTS in kcadm-bootstrap.sh (and with the KNOWN_CLIENTS default
# in the keycloak-ops repo, whose realm check asserts the same set). Overridable so a realm with a
# different client set can be verified without editing this script.
# example-hub and grafana were missing here until 2026-07-30 — the loop silently verified only four
# of the six clients, which is exactly the drift the single-list refactor set out to remove.
# oauth2-proxy intentionally absent (see kcadm-bootstrap.sh NOTE).
VERIFY_CLIENTS="${VERIFY_CLIENTS:-argocd harbor vaultwarden example-hub grafana}"
# shellcheck disable=SC2046  # word splitting is the intent; $(...) splits identically in bash and zsh
for cid in $(printf '%s' "$VERIFY_CLIENTS"); do
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
    # Assert each mapper's TYPE and CLAIM, not just its presence. `oidc-hardcoded-group-idp-mapper`
    # can carry the same name but ignores claims entirely, granting the group to EVERY brokered
    # GitLab user — an over-grant, since /server gates ArgoCD role:server-admin, Harbor login, and
    # the example-hub privileged-tool proxies. A name-only check cannot tell the two apart.
    # Checks EVERY same-named mapper, not just the first: with two mappers sharing the name, array
    # order is unspecified, so a first-match check could report the advanced one while a hardcoded
    # one is still attached and still granting.
    #
    # The rogue scan runs ONCE over all mappers (not per group): a hardcoded mapper aimed at any
    # privilege group is a finding regardless of which group loop is running, and reporting it once
    # keeps the output readable.
    ROGUE=$(printf '%s' "$IDP_MAPPERS" | python3 -c '
import json, sys
BAD_TYPE = "oidc-hardcoded-group-idp-mapper"
# NOTE: no apostrophes in this block - it lives inside python3 -c :single-quoted:, and one would
# close the quote and spill the rest into bash.
mappers = json.load(sys.stdin)
priv = set("/" + g for g in sys.argv[1:])
rogue = [m.get("name") for m in mappers
         if m.get("identityProviderMapper") == BAD_TYPE
         and (m.get("config") or {}).get("group") in priv]
print(",".join(str(n) for n in rogue))
' $GITLAB_MAPPED_GROUPS $MANUAL_GROUPS || echo "parse-error")
    if [[ -n "$ROGUE" ]]; then
      printf "  \033[31m✗\033[0m hardcoded group mapper(s) attached: %s — these grant their group to EVERY brokered GitLab account\n" "$ROGUE"; FAIL=$((FAIL+1))
    fi

    for g in $GITLAB_MAPPED_GROUPS; do
      IDP_MAPPER_STATE=$(printf '%s' "$IDP_MAPPERS" | python3 -c '
import json, sys
WANT_TYPE = "oidc-advanced-group-idp-mapper"
GROUP = sys.argv[1]
NAME = GROUP + "-group-map"

def problem(m):
    if m.get("identityProviderMapper") != WANT_TYPE:
        return "wrong-type:" + str(m.get("identityProviderMapper"))
    cfg = m.get("config") or {}
    try:
        claims = json.loads(cfg.get("claims") or "[]")
    except Exception:
        return "unparsable-claims:" + str(cfg.get("claims"))
    if not any(c.get("key") == "groups_direct" and c.get("value") == GROUP for c in claims):
        return "wrong-claim:" + str(cfg.get("claims"))
    if str(cfg.get("are.claim.values.regex")).lower() == "true":
        return "regex-enabled"
    if cfg.get("group") != "/" + GROUP:
        return "wrong-group:" + str(cfg.get("group"))
    if cfg.get("syncMode") != "FORCE":
        return "wrong-syncmode:" + str(cfg.get("syncMode"))
    return None

mappers = json.load(sys.stdin)          # a parse error must propagate -> "parse-error" verdict
hits = [m for m in mappers if m.get("name") == NAME]
if not hits:
    print("missing")
elif len(hits) > 1:
    print("duplicate:%d" % len(hits))
else:
    print(problem(hits[0]) or "ok")
' "$g" || echo "parse-error")
      if [[ "$IDP_MAPPER_STATE" == "ok" ]]; then
        printf "  \033[32m✓\033[0m IdP mapper '$g-group-map' is advanced claim→group (groups_direct=$g → /$g, FORCE)\n"; PASS=$((PASS+1))
      else
        printf "  \033[31m✗\033[0m IdP mapper '$g-group-map': %s (expected exactly one advanced claim→group mapper)\n" "$IDP_MAPPER_STATE"; FAIL=$((FAIL+1))
      fi
    done
    # The group claim now decides who gets /server, so its delivery preconditions are load-bearing.
    # userInfoUrl matters because GitLab returns group claims from userinfo rather than the ID token
    # (the same reason ArgoCD's dex connector needs getUserInfo: true).
    if grep -q '"userInfoUrl"' <<< "$IDP"; then
      printf "  \033[32m✓\033[0m IdP 'gitlab' userInfoUrl set (group claim arrives via userinfo)\n"; PASS=$((PASS+1))
    else
      printf "  \033[31m✗\033[0m IdP 'gitlab' userInfoUrl missing — the groups_direct claim may never reach the mapper\n"; FAIL=$((FAIL+1))
    fi
    if grep -q '"disableUserInfo" : "true"' <<< "$IDP"; then
      printf "  \033[31m✗\033[0m IdP 'gitlab' disableUserInfo=true — userinfo is not fetched, so the groups_direct claim is lost\n"; FAIL=$((FAIL+1))
    else
      printf "  \033[32m✓\033[0m IdP 'gitlab' userinfo fetch enabled\n"; PASS=$((PASS+1))
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
NGF_IP="${NGF_IP:-192.0.2.55}"
DISC_HTTP=$(curl -sk --resolve "auth.example.com:443:$NGF_IP" -o /dev/null -w '%{http_code}' --max-time 10 \
  https://auth.example.com/realms/$REALM/.well-known/openid-configuration 2>/dev/null || echo "000")
if [[ "$DISC_HTTP" == "200" ]]; then
  printf "  \033[32m✓\033[0m OIDC discovery endpoint returns 200\n"; PASS=$((PASS+1))
else
  printf "  \033[31m✗\033[0m OIDC discovery endpoint returned $DISC_HTTP (expected 200)\n"; FAIL=$((FAIL+1))
fi

echo
echo "Result: $PASS passed, $FAIL failed, $WARN warnings."
[[ "$FAIL" -eq 0 ]] || exit 1
