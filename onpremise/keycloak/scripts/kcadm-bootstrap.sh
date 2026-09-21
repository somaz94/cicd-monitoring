#!/usr/bin/env bash
# Bootstrap the `example` realm via kcadm.sh — run AFTER `helmfile apply` once Keycloak Pod is Ready.
#
# Idempotent end-to-end: master-realm permanent admin (+ Secret), realm, groups, clients (with secrets), groups protocol-mapper, GitLab Identity Provider.
# Re-running is safe — every "create" path checks for existence first and falls through to "already exists — skip" instead of failing.
#
# WHEN TO USE THIS vs the keycloak-ops console (hub.example.com/apps/keycloak-ops/):
#   This script  — FIRST bootstrap (realm does not exist yet) and the master-realm admin.
#                  Those two cannot move to the console: keycloak-ops sits behind the
#                  example-hub portal, and that portal is an OIDC client OF THIS REALM, so
#                  without the realm nobody can reach the console at all.
#   The console  — day-2 work on an existing realm: group + IdP-mapper creation, group
#                  membership, client registration, and realm/client-scope/IdP convergence.
#                  It needs no cluster access and no master-admin password.
# Both converge to the same shape, so running either after the other is a no-op.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h] [-c|--client <name>] [-g|--group <name>] [-D|--delete-group <name>]

Bootstrap the Keycloak \`example\` realm end-to-end. Logs into master realm via
kubectl exec + kcadm.sh as the operator-managed bootstrap admin (\`temp-admin\`),
then reconciles every Phase 3 object (idempotent).

Options:
  -c, --client <name>   Minimal mode: upsert only this one client (+ wire its groups
                        claim) and exit, skipping the master-admin / realm / IdP
                        reconcile. Use to register a single new client (e.g. example-hub)
                        without resetting the master admin password. Known clients:
                        argocd harbor vaultwarden example-hub grafana.
                        (Authoritative list: CANONICAL_CLIENTS in this script. Keep the
                        KNOWN_CLIENTS default in the keycloak-ops repo in step with it —
                        its realm check asserts exactly this set.)
  -g, --group <name>    Minimal mode: create only this group (+ its GitLab IdP group mapper) and
                        exit, skipping the master-admin / realm / client reconcile. The name must
                        be in GITLAB_MAPPED_GROUPS, and the gitlab IdP must already exist.
                        The keycloak-ops console does the same thing without cluster access.
  -D, --delete-group <name>
                        Minimal mode: delete this group AND its GitLab IdP group mapper, then exit.
                        Refuses any name still listed in GITLAB_MAPPED_GROUPS or MANUAL_GROUPS —
                        a full run would just recreate it, so the deletion would be a lie. Remove
                        the name from that list first. Refuses a non-empty group unless
                        DELETE_GROUP_CONFIRM=1. keycloak-ops enforces the same two rules via
                        SCRIPT_MANAGED_GROUPS / PROTECTED_GROUPS.

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
  VAULTWARDEN_REDIRECTS           vaultwarden redirectUris      (default: vault.example.com/identity/connect/oidc-signin)
  EXAMPLE_HUB_REDIRECTS           example-hub redirectUris      (default: hub.example.com/oidc/callback)
  EXAMPLE_HUB_POST_LOGOUT         example-hub post-logout URIs  (default: hub.example.com/*)
  GRAFANA_REDIRECTS               grafana client redirectUris   (default: grafana.example.com/login/generic_oauth)
  GLOBAL_ADMIN_MEMBERS            usernames for global-admin group (default: admin)
  GITLAB_MAPPED_GROUPS            groups driven by a GitLab claim, one IdP mapper each
                                  (default: server client gamedesign)
  MANUAL_GROUPS                   groups with no mapper, membership by hand (default: global-admin)
  DELETE_GROUP_CONFIRM            1 to allow --delete-group on a group that still has members
                                  (default: 0 → refuse and list them)
  SHOW_CLIENT_SECRETS             1 to print client secrets in full (default: 0 → masked)
  GITLAB_BROKERING_CLIENT_ID      GitLab Application ID         (unset → IdP step skipped)
  GITLAB_BROKERING_CLIENT_SECRET  GitLab Application Secret     (unset → IdP step skipped)
  GITLAB_BASE_URL                 GitLab self-hosted base URL    (default: http://gitlab.example.com)

Exit code: 0 on success. Re-run after a partial failure is safe.
EOF
}
# ONLY_CLIENT (set via --client) restricts the run to a single client's upsert + groups wiring,
# skipping the master-admin / realm / IdP reconcile. Used to register one new client (e.g. example-hub)
# without re-running the full bootstrap (which resets the master admin password to its default).
ONLY_CLIENT=""
# ONLY_GROUP (set via --group) restricts the run to one group + its IdP mapper. Same reason
# --client exists: a full run also resets the master-admin password and re-upserts every client,
# which is far more blast radius than "add one group".
ONLY_GROUP=""
# DELETE_GROUP (set via --delete-group) removes one group + its mapper. Guarded, see usage.
DELETE_GROUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -c|--client) ONLY_CLIENT="${2:-}"; [[ -z "$ONLY_CLIENT" ]] && { echo "ERROR: --client requires a name" >&2; exit 1; }; shift 2 ;;
    -g|--group)  ONLY_GROUP="${2:-}";  [[ -z "$ONLY_GROUP" ]]  && { echo "ERROR: --group requires a name" >&2; exit 1; }; shift 2 ;;
    -D|--delete-group) DELETE_GROUP="${2:-}"; [[ -z "$DELETE_GROUP" ]] && { echo "ERROR: --delete-group requires a name" >&2; exit 1; }; shift 2 ;;
    *)           echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"
REALM="${REALM:-example}"
ADMIN_USER="${KEYCLOAK_ADMIN:-temp-admin}"

# Per-client redirect URIs. Override via env to retarget for a different cluster (qa/prod).
ARGOCD_REDIRECTS="${ARGOCD_REDIRECTS:-https://argocd.example.com/auth/callback,https://argocd.example.com/api/dex/callback}"
HARBOR_REDIRECTS="${HARBOR_REDIRECTS:-https://harbor.example.com/c/oidc/callback}"
# NOTE: oauth2-proxy has NO OIDC client on purpose.
# It was planned in the Phase 2/3 design docs (2026-04) and its client was bootstrapped, but
# oauth2-proxy itself was never deployed — there is no workload, no chart and no Secret anywhere,
# only commented-out sidecar blocks in kube-prometheus-stack values. The client therefore sat unused
# for a year holding the broadest redirect of the whole realm (https://*.example.com/oauth2/callback),
# so it was dropped here and deleted from the realm. Re-add it in the same commit that actually
# deploys oauth2-proxy, not before.
VAULTWARDEN_REDIRECTS="${VAULTWARDEN_REDIRECTS:-https://vault.example.com/identity/connect/oidc-signin}"
# example-hub internal app portal — OIDC login gate. No PKCE (confidential client with client_secret, like argocd/harbor).
EXAMPLE_HUB_REDIRECTS="${EXAMPLE_HUB_REDIRECTS:-https://hub.example.com/oidc/callback}"
# Post-logout return target. Without this attribute Keycloak falls back to the redirectUris list, which
# only holds the /oidc/callback URL — so RP-initiated logout back to the portal landing page is rejected
# with "Invalid parameter: redirect_uri". Wildcard keeps it working if the portal's landing path changes.
EXAMPLE_HUB_POST_LOGOUT="${EXAMPLE_HUB_POST_LOGOUT:-https://hub.example.com/*}"
# Grafana — OIDC login via the chart's auth.generic_oauth (2026-07-30, replaced a shared admin
# password). Path is fixed by Grafana itself: <root_url>/login/<provider name>, and root_url is set
# in observability/monitoring/kube-prometheus-stack/values/dev.yaml. No PKCE (confidential client
# with client_secret, like argocd/harbor).
#
# Group -> Grafana role is decided by Grafana's role_attribute_path over the groups claim
# (global-admin -> Admin, server -> Editor, else Viewer), so this client needs the same groups
# wiring as the others — which it gets automatically by being in CANONICAL_CLIENTS below.
GRAFANA_REDIRECTS="${GRAFANA_REDIRECTS:-https://grafana.example.com/login/generic_oauth}"
# NOTE: keycloak-ops has NO OIDC client on purpose.
# It moved to the reverse-proxy model (2026-07-24): example-hub authenticates and proxies it, so
# the app carries zero OIDC code and its Secret holds only KEYCLOAK_ADMIN_*. Its client was deleted
# then. Re-adding it here would resurrect a dead client pointing at keycloak-ops.example.com, a host
# that no longer resolves to anything. If self-login ever returns, restore the redirect vars, the
# client_redirects/client_attrs cases and the CANONICAL_CLIENTS entry together.
# (Found by the keycloak-ops console realm check on 2026-07-30 — the script had kept upserting it.)

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
# Space-separated Keycloak usernames to place in the `global-admin` group.
#
# THIS LIST IS LOAD-BEARING. Two systems now gate admin access on this group, so an empty
# `global-admin` locks people out of both rather than degrading quietly:
#   ArgoCD        `g, global-admin, role:global-admin` (cicd/argo-cd/values/dev.yaml) — empty
#                 group means nobody holds role:global-admin there.
#   keycloak-ops  example-hub gates it on `global-admin` (APP_KEYCLOAKOPS_GROUPS) — empty group
#                 means nobody can reach the console, including to fix this.
#
# Both switched to the group on 2026-07-30. Before that the group was empty, so each had fallen
# back to something broader or hand-written — ArgoCD to a hardcoded `g, admin@example.com`, and
# example-hub to `server`. That is the failure mode this list exists to prevent.
#
# Membership only sticks for users that already exist in the realm. Brokered users are created on
# their FIRST login, so on a fresh realm this step logs a skip and must be re-run (or the user
# added by hand) after that first login.
GLOBAL_ADMIN_MEMBERS="${GLOBAL_ADMIN_MEMBERS:-admin}"
# 1 to print client secrets in full. Default 0 masks them — see the rationale in upsert_client.
SHOW_CLIENT_SECRETS="${SHOW_CLIENT_SECRETS:-0}"

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

# ---- Shared helpers (used by both --client minimal mode and the full reconcile below) ----

# upsert_client creates a client (idempotent — keep existing) and prints its secret on stdout.
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

  # Attributes are reconciled on EVERY run, not just at create time. The create branch above only
  # applies them to brand-new clients, so an already-registered client would never pick up an
  # attribute added later (this is exactly how example-hub ended up without post.logout.redirect.uris).
  # Merge into the existing map rather than replacing it, so Keycloak-managed defaults survive.
  if [[ -n "$extra_attrs_json" ]]; then
    local current_attrs merged_attrs
    current_attrs=$($KCADM get "clients/$id" -r "$REALM" --fields attributes 2>/dev/null || echo '{}')
    merged_attrs=$(CURRENT_ATTRS="$current_attrs" EXTRA_ATTRS="$extra_attrs_json" python3 -c '
import json, os
current = json.loads(os.environ["CURRENT_ATTRS"] or "{}").get("attributes") or {}
current.update(json.loads(os.environ["EXTRA_ATTRS"]))
print(json.dumps(current))
')
    if [[ -n "$merged_attrs" ]]; then
      $KCADM update "clients/$id" -r "$REALM" -s "attributes=$merged_attrs" >/dev/null
      log "  attributes reconciled."
    else
      log "  WARN: attribute merge produced nothing — leaving attributes untouched."
    fi
  fi

  # Secret retrieval — MASKED by default.
  #
  # A full run upserts every CANONICAL_CLIENTS entry, so printing every secret meant one command
  # dumped all of them into the terminal scrollback, and from there into CI job logs, chat
  # pastes, and MR descriptions. The secret is readable from Keycloak at any time (see the hint
  # printed after the clients step), so echoing it here is convenience, not the delivery path.
  #
  # Set SHOW_CLIENT_SECRETS=1 when you genuinely need to copy them (e.g. first-time wiring of a new
  # client into its consumer's config).
  local secret_json
  secret_json=$($KCADM get "clients/$id/client-secret" -r "$REALM" 2>/dev/null || true)
  local secret
  secret=$(json_field "$secret_json" value)
  if [[ "$SHOW_CLIENT_SECRETS" == "1" ]]; then
    echo "  $cid: clientId=$cid id=$id secret=$secret"
  elif [[ -n "$secret" ]]; then
    echo "  $cid: clientId=$cid id=$id secret=<hidden, ${#secret} chars — set SHOW_CLIENT_SECRETS=1 to print>"
  else
    echo "  $cid: clientId=$cid id=$id secret=<not returned by Keycloak>"
  fi
}

# Groups protocol-mapper config: 6 fields. With Keycloak 26.x an empty config `{}` is interpreted as
# all-false → the mapper silently drops the claim from every token type. Always write all 6 explicitly.
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

# IdP-level group mappers, one per GITLAB_MAPPED_GROUPS entry: put a brokered GitLab user into
# `/<group>` ONLY when their `groups_direct` claim contains `<group>` ("Advanced Claim to Group").
#
# Why not the simpler hardcoded mapper: until 2026-07-30 this was
# `oidc-hardcoded-group-idp-mapper`, which grants `/server` to EVERY brokered user with no claim
# check at all. That is an over-grant — `/server` gates ArgoCD `role:server-admin`, Harbor login,
# and the example-hub privileged-tool proxies (account-tool, keycloak-ops, ...). Measured impact
# was 8 intended members vs 43 active GitLab accounts.
#
# `syncMode: FORCE` re-evaluates the claim on EVERY login, so dropping a user from the GitLab
# `server` group revokes their access on the next login. (FORCE also *removes* the group when the
# claim stops matching — that is the revocation path, and it is why the claim must be verified
# before changing this mapper.)
#
# `groups_direct` (direct memberships) is chosen over `groups`: GitLab groups are currently flat
# (no subgroups) so both match identically, but if a subgroup is ever added `groups_direct` fails
# CLOSED for subgroup-only members, which is the right default for a privilege gate.
# Groups whose membership is driven by a GitLab claim — one IdP mapper each (see
# group_mapper_json below). Adding a name here creates the Keycloak group AND its mapper, so a
# GitLab group of the SAME NAME must exist or the mapper matches nobody and the group stays empty.
GITLAB_MAPPED_GROUPS="${GITLAB_MAPPED_GROUPS:-server client gamedesign}"

# Groups with NO mapper — membership is managed by hand (see GLOBAL_ADMIN_MEMBERS). Keep these out
# of GITLAB_MAPPED_GROUPS: attaching a FORCE mapper would wipe hand-added members on next login.
MANUAL_GROUPS="${MANUAL_GROUPS:-global-admin}"

# Clients this script owns. Listed once — it was previously spelled out in four places (usage text,
# the --client error message, the mapper loop and the scope loop), and a client removed from one
# copy stayed in the others. keycloak-ops is deliberately absent; see the NOTE above.
CANONICAL_CLIENTS="argocd harbor vaultwarden example-hub grafana"

# group_mapper_json emits the IdP mapper definition for one group.
#
# Written to a file and passed with `-f`: `are.claim.values.regex` contains dots, which kcadm's
# `-s` would parse as a nested config path.
group_mapper_json() {
  cat <<JSON
{
  "name": "$1-group-map",
  "identityProviderAlias": "gitlab",
  "identityProviderMapper": "oidc-advanced-group-idp-mapper",
  "config": {
    "syncMode": "FORCE",
    "group": "/$1",
    "claims": "[{\"key\":\"groups_direct\",\"value\":\"$1\"}]",
    "are.claim.values.regex": "false"
  }
}
JSON
}

# ensure_group creates one realm group when absent. Reads $EXISTING_GROUPS (fetched by the caller).
ensure_group() {
  local group="$1"
  if ! grep -q "\"name\" : \"$group\"" <<< "$EXISTING_GROUPS"; then
    log "Creating group $group..."
    $KCADM create groups -r "$REALM" -s name="$group" >/dev/null
  else
    log "Group $group exists — skip."
  fi
}

# reconcile_group_mapper converges the IdP group mapper for ONE group.
# Reads $existing_idp_mappers (fetched once by the caller — re-fetching per group would only widen
# the window in which the list and the verdict disagree).
reconcile_group_mapper() {
  local group="$1"
  # python3 for the JSON walk: kcadm cannot filter mappers server-side, and matching a single
  # object inside kcadm's pretty-printed array needs real parsing (multi-char awk RS is
  # gawk-only, so it is not portable to macOS BSD awk).
  # The group name is passed as argv, not interpolated into the program text — interpolation
  # would let a group name containing a quote rewrite the script.
  mapper_verdict=$(printf '%s' "$existing_idp_mappers" | python3 -c '
import json, sys
WANT_TYPE = "oidc-advanced-group-idp-mapper"
GROUP = sys.argv[1]
NAME = GROUP + "-group-map"
PATH = "/" + GROUP

def matches(m):
  if m.get("identityProviderMapper") != WANT_TYPE:
      return False
  cfg = m.get("config") or {}
  if cfg.get("group") != PATH or cfg.get("syncMode") != "FORCE":
      return False
  # Pin regex off: with regex on, the group name would be a pattern, not a literal.
  if str(cfg.get("are.claim.values.regex")).lower() == "true":
      return False
  try:
      claims = json.loads(cfg.get("claims") or "[]")
  except Exception:
      return False
  return any(c.get("key") == "groups_direct" and c.get("value") == GROUP for c in claims)

mappers = json.load(sys.stdin)          # a parse error must propagate -> "error" verdict
hits = [m for m in mappers if m.get("name") == NAME]
# A hardcoded mapper targeting this group grants it to EVERY brokered user no matter what it is
# named, so a leftover under a different name is just as broad and must go too. Scoped to this
# group on purpose: each iteration owns exactly one group and its membership policy, so a
# hardcoded mapper aimed at another group is left to that other iteration.
# (No apostrophes in this program text: the whole block is inside a single-quoted shell string.)
rogue = [m for m in mappers
       if m.get("identityProviderMapper") == "oidc-hardcoded-group-idp-mapper"
       and (m.get("config") or {}).get("group") == PATH
       and m.get("name") != NAME]
if not hits and not rogue:
  print("absent")
elif len(hits) == 1 and matches(hits[0]) and not rogue:
  print("ok")
else:
  print("stale " + " ".join(m["id"] for m in hits + rogue))
' "$group" || echo error)

  case "$mapper_verdict" in
    ok)
      log "  IdP mapper $group-group-map matches the expected shape — skip."
      ;;
    absent|stale*)
      if [[ "$mapper_verdict" != absent ]]; then
        # `< /dev/null` is precautionary: $KCADM is `kubectl exec -i`, so it inherits the script's
        # own stdin (e.g. `bash < script.sh`, or a CI heredoc-fed invocation) and could drain it.
        # A `for` over a word list is not itself at risk — a `while read` loop would be.
        # Splitting form matters here — measured, not assumed:
        #   `for x in $var`      bash splits, zsh does NOT (2 ids arrive as one word)
        #   `read -ra arr`       bash fine, zsh has no -a -> non-zero -> `set -e` kills the script
        #   `for x in $(cmd)`    BOTH split on IFS  <- the only form that behaves identically
        # shellcheck disable=SC2046  # word splitting is the intent, and it is shell-portable here
        for mid in $(printf '%s' "${mapper_verdict#stale }"); do
          log "  IdP mapper $group-group-map does not match the expected shape — deleting $mid."
          $KCADM delete "identity-provider/instances/gitlab/mappers/$mid" -r "$REALM" < /dev/null >/dev/null
        done
      fi
      # Between the delete above and the create below, a first-time brokered login would get no
      # group. Existing memberships are untouched (no mapper -> no leaveGroup call).
      log "  Adding IdP mapper $group-group-map (advanced: groups_direct=$group → /$group)..."
      group_mapper_json "$group" | kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -c "cat > /tmp/$group-group-map.json"
      $KCADM create "identity-provider/instances/gitlab/mappers" -r "$REALM" -f "/tmp/$group-group-map.json" >/dev/null
      ;;
    *)
      log "ERROR: cannot determine the state of IdP mapper $group-group-map (verdict: '$mapper_verdict')."
      log "       Refusing to touch the /$group privilege gate on an unknown state — inspect with:"
      log "         kubectl -n $NAMESPACE exec -i $POD -- /opt/keycloak/bin/kcadm.sh \\"
      log "           get identity-provider/instances/gitlab/mappers -r $REALM --fields id,name,identityProviderMapper"
      exit 1
      ;;
  esac
}


# client_redirects maps a known clientId to its default redirect URIs (from the *_REDIRECTS env vars).
client_redirects() {
  case "$1" in
    argocd)       echo "$ARGOCD_REDIRECTS" ;;
    harbor)       echo "$HARBOR_REDIRECTS" ;;
    vaultwarden)  echo "$VAULTWARDEN_REDIRECTS" ;;
    example-hub)  echo "$EXAMPLE_HUB_REDIRECTS" ;;
    grafana)      echo "$GRAFANA_REDIRECTS" ;;
    *) return 1 ;;
  esac
}

# client_attrs echoes the per-client extra-attributes JSON (empty when none).
client_attrs() {
  case "$1" in
    vaultwarden)              echo '{"pkce.code.challenge.method":"S256"}' ;;
    example-hub)              echo "{\"post.logout.redirect.uris\":\"$EXAMPLE_HUB_POST_LOGOUT\"}" ;;
    *) echo "" ;;
  esac
}

# attach_groups_to_client wires the groups claim onto a single client: a client-direct mapper plus
# attaching the realm 'groups' client-scope (which must already exist — created in the full reconcile).
attach_groups_to_client() {
  local client_id="$1"
  local existing_mappers
  existing_mappers=$($KCADM get "clients/$client_id/protocol-mappers/models" -r "$REALM" 2>/dev/null || echo "[]")
  if grep -q "\"name\" : \"groups\"" <<< "$existing_mappers"; then
    log "  groups mapper exists — skip."
  else
    log "  adding groups mapper..."
    kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -c "cat > /tmp/groups-mapper.json" <<< "$GROUPS_MAPPER_JSON"
    $KCADM create "clients/$client_id/protocol-mappers/models" -r "$REALM" -f /tmp/groups-mapper.json >/dev/null
  fi
  local gsid
  gsid=$($KCADM get client-scopes -r "$REALM" --fields id,name 2>/dev/null | python3 -c 'import sys,json; m=json.loads(sys.stdin.read()); print(next((x["id"] for x in m if x["name"]=="groups"),""))' 2>/dev/null || true)
  if [[ -n "$gsid" ]]; then
    $KCADM update "clients/$client_id/default-client-scopes/$gsid" -r "$REALM" >/dev/null 2>&1 || true
    log "  groups scope attached."
  else
    log "  WARN: realm 'groups' client-scope not found — run a full bootstrap first."
  fi
}

# ---- --group minimal mode: create one group + its IdP mapper, then exit (no admin/realm/client changes) ----
if [[ -n "$ONLY_GROUP" ]]; then
  # Restricted to GITLAB_MAPPED_GROUPS on purpose: a mapper created for a name outside that list
  # would never be reconciled by a later full run, so the two paths would drift immediately.
  case " $GITLAB_MAPPED_GROUPS " in
    *" $ONLY_GROUP "*) ;;
    *) echo "ERROR: '$ONLY_GROUP' is not in GITLAB_MAPPED_GROUPS ($GITLAB_MAPPED_GROUPS)" >&2
       echo "       Add it there first, otherwise a full run would not manage the mapper you are about to create." >&2
       exit 1 ;;
  esac
  # The mapper attaches to the gitlab IdP, so that IdP must already exist. Creating it needs the
  # GitLab OAuth credentials, which is a full-run concern — refuse rather than half-configure.
  if ! $KCADM get "identity-provider/instances/gitlab" -r "$REALM" >/dev/null 2>&1; then
    echo "ERROR: IdP 'gitlab' does not exist — run a full bootstrap with GITLAB_BROKERING_CLIENT_ID/_SECRET first." >&2
    exit 1
  fi
  log "Minimal mode: reconciling group '$ONLY_GROUP' + its IdP mapper only (skipping admin/realm/client reconcile)..."
  EXISTING_GROUPS=$($KCADM get "groups?briefRepresentation=true" -r "$REALM" 2>/dev/null || echo "[]")
  ensure_group "$ONLY_GROUP"
  existing_idp_mappers=$($KCADM get "identity-provider/instances/gitlab/mappers" -r "$REALM" 2>/dev/null || echo "[]")
  reconcile_group_mapper "$ONLY_GROUP"
  log "Minimal mode complete for group '$ONLY_GROUP'."
  exit 0
fi

# ---- --delete-group minimal mode: drop one group + its IdP mapper, then exit ----
if [[ -n "$DELETE_GROUP" ]]; then
  # Guard 1: a declared group would be recreated by the next full run, so deleting it here only
  # makes the two paths disagree until someone re-runs the script. Refuse and name the fix.
  case " $GITLAB_MAPPED_GROUPS $MANUAL_GROUPS " in
    *" $DELETE_GROUP "*)
      echo "ERROR: '$DELETE_GROUP' is declared in GITLAB_MAPPED_GROUPS/MANUAL_GROUPS — a full run would recreate it." >&2
      echo "       Remove it from that list first (and from SCRIPT_MANAGED_GROUPS in keycloak-ops), then re-run." >&2
      exit 1 ;;
  esac

  # EXACT name match, not json_field. `-q search=` is a substring query, so asking for "client"
  # also returns "client-qa"; json_field would then hand back whichever id came first and this
  # would delete the wrong group. Nothing else in this script deletes by name, so the sloppiness
  # is only survivable in the create paths.
  gid=$(GROUPS_JSON="$($KCADM get groups -r "$REALM" -q search="$DELETE_GROUP" --fields id,name 2>/dev/null || echo '[]')" \
        TARGET="$DELETE_GROUP" python3 -c '
import json, os, sys
try:
    groups = json.loads(os.environ["GROUPS_JSON"] or "[]")
except json.JSONDecodeError:
    sys.exit(1)
target = os.environ["TARGET"]
print(next((g["id"] for g in groups if g.get("name") == target), ""))
') || { echo "ERROR: could not parse the group list returned by Keycloak" >&2; exit 1; }
  if [[ -z "$gid" ]]; then
    log "Group '$DELETE_GROUP' does not exist — nothing to delete."
    exit 0
  fi

  # Guard 2: members lose access the moment the group goes. Show who, and require an explicit opt-in.
  gmembers=$(MEMBERS_JSON="$($KCADM get "groups/$gid/members" -r "$REALM" --fields username 2>/dev/null || echo '[]')" python3 -c '
import json, os, sys
try:
    users = json.loads(os.environ["MEMBERS_JSON"] or "[]")
except json.JSONDecodeError:
    sys.exit(1)
print(", ".join(u.get("username", "") for u in users))
') || { echo "ERROR: could not parse the member list returned by Keycloak" >&2; exit 1; }
  if [[ -n "$gmembers" && "${DELETE_GROUP_CONFIRM:-0}" != "1" ]]; then
    echo "ERROR: group '$DELETE_GROUP' still has members: $gmembers" >&2
    echo "       They lose whatever this group grants the moment it is deleted." >&2
    echo "       Re-run with DELETE_GROUP_CONFIRM=1 to proceed." >&2
    exit 1
  fi

  # Mapper first: deleting the group first would leave a window where a brokered login tries to
  # join a group that no longer exists.
  if $KCADM get "identity-provider/instances/gitlab" -r "$REALM" >/dev/null 2>&1; then
    mid=$(MAPPERS_JSON="$($KCADM get "identity-provider/instances/gitlab/mappers" -r "$REALM" --fields id,name 2>/dev/null || echo '[]')" \
          TARGET="$DELETE_GROUP-group-map" python3 -c '
import json, os, sys
try:
    mappers = json.loads(os.environ["MAPPERS_JSON"] or "[]")
except json.JSONDecodeError:
    sys.exit(1)
target = os.environ["TARGET"]
print(next((m["id"] for m in mappers if m.get("name") == target), ""))
') || { echo "ERROR: could not parse the IdP mapper list returned by Keycloak" >&2; exit 1; }
    if [[ -n "$mid" ]]; then
      $KCADM delete "identity-provider/instances/gitlab/mappers/$mid" -r "$REALM" < /dev/null >/dev/null
      log "Deleted IdP mapper '$DELETE_GROUP-group-map'."
    fi
  fi
  $KCADM delete "groups/$gid" -r "$REALM" < /dev/null >/dev/null
  log "Deleted group '$DELETE_GROUP'. Former members must re-login for the change to show in their token."
  exit 0
fi

# ---- --client minimal mode: upsert one client + wire groups, then exit (no admin/realm/IdP changes) ----
if [[ -n "$ONLY_CLIENT" ]]; then
  redirects=$(client_redirects "$ONLY_CLIENT") || {
    echo "ERROR: unknown client '$ONLY_CLIENT' (known: $CANONICAL_CLIENTS)" >&2
    exit 1
  }
  log "Minimal mode: upserting client '$ONLY_CLIENT' only (skipping admin/realm/IdP reconcile)..."
  upsert_client "$ONLY_CLIENT" "$redirects" "$(client_attrs "$ONLY_CLIENT")"
  cid_id=$(json_field "$($KCADM get clients -r "$REALM" -q clientId="$ONLY_CLIENT" --fields id 2>/dev/null)" id)
  attach_groups_to_client "$cid_id"
  log "Minimal mode complete for '$ONLY_CLIENT'."
  exit 0
fi

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

# 1. Realm.
if ! $KCADM get "realms/$REALM" >/dev/null 2>&1; then
  log "Creating realm $REALM..."
  $KCADM create realms -s realm="$REALM" -s enabled=true -s sslRequired=external
else
  log "Realm $REALM exists — skip."
fi

# 2. Groups.
EXISTING_GROUPS=$($KCADM get "groups?briefRepresentation=true" -r "$REALM" 2>/dev/null || echo "[]")
for group in $GITLAB_MAPPED_GROUPS $MANUAL_GROUPS; do
  ensure_group "$group"
done

# 2b. global-admin members — see GLOBAL_ADMIN_MEMBERS above for why an empty group is a problem.
#
# ENSURE-MEMBER ONLY, never remove: dropping a username from GLOBAL_ADMIN_MEMBERS does NOT revoke
# membership. Removing an admin is a deliberate act — do it in the Keycloak Admin UI.
#
# Failures here are logged and skipped rather than fatal. This is the least critical step in the
# script, and aborting on it (under `set -e`) would stop the run before the clients (step 3) and
# before the `/server` IdP mapper convergence (step 5) — i.e. a convenience feature could block a
# security fix.
#
# `search=` is a SUBSTRING match and can also return a matching subgroup wrapped in its parent, so
# the id is resolved by exact name in the parser rather than by taking the first "id" in the blob.
# This is the one code path here that grants admin, so it gets the strictest lookup.
GLOBAL_ADMIN_GID=$(printf '%s' "$($KCADM get groups -r "$REALM" -q search=global-admin --fields id,name 2>/dev/null || echo '[]')" \
  | python3 -c 'import json,sys
try:
    groups = json.load(sys.stdin)
except Exception:
    groups = []
print(next((g["id"] for g in groups if g.get("name") == "global-admin"), ""))' 2>/dev/null || echo "")
if [[ -z "$GLOBAL_ADMIN_GID" ]]; then
  log "WARN: group global-admin not resolvable — skipping member reconcile."
else
  # See the splitting note in reconcile_group_mapper above: `$(...)` is the one form bash and zsh
  # split identically (`read -ra` does not exist in zsh, and `for x in $var` does not split there).
  # shellcheck disable=SC2046  # word splitting is the intent, and it is shell-portable here
  for member in $(printf '%s' "$GLOBAL_ADMIN_MEMBERS"); do
    # exact=true: without it the username query is a substring match, so 'admin' could resolve to 'admin2'.
    member_uid=$(json_field "$($KCADM get users -r "$REALM" -q username="$member" -q exact=true --fields id 2>/dev/null)" id)
    if [[ -z "$member_uid" ]]; then
      log "  global-admin: user '$member' not found (brokered users appear on first login; could also be an API error) — skip."
      continue
    fi
    if $KCADM update "users/$member_uid/groups/$GLOBAL_ADMIN_GID" -r "$REALM" \
        -s realm="$REALM" -s userId="$member_uid" -s groupId="$GLOBAL_ADMIN_GID" -n < /dev/null >/dev/null 2>&1; then
      log "  global-admin: '$member' is a member."
    else
      log "  WARN: global-admin join failed for '$member' — continuing."
    fi
  done
fi

# 3. Clients — upsert each (upsert_client + helpers defined above).
log "Reconciling clients..."
upsert_client argocd "$ARGOCD_REDIRECTS"
upsert_client harbor "$HARBOR_REDIRECTS"
upsert_client vaultwarden "$VAULTWARDEN_REDIRECTS" '{"pkce.code.challenge.method":"S256"}'
upsert_client example-hub "$EXAMPLE_HUB_REDIRECTS"
upsert_client grafana "$GRAFANA_REDIRECTS"
if [[ "$SHOW_CLIENT_SECRETS" != "1" ]]; then
  log "  Client secrets are masked. To read one on demand (per client, no full dump):"
  log "    kubectl -n $NAMESPACE exec -i $POD -- /opt/keycloak/bin/kcadm.sh \\"
  log "      get clients/<client-uuid>/client-secret -r $REALM"
  log "  Or re-run this script with SHOW_CLIENT_SECRETS=1 to print all of them."
fi

# 4. Groups protocol-mapper — defense in depth: client-direct mapper + 'groups' client-scope.
# GROUPS_MAPPER_JSON and its config rationale are defined above (shared with --client mode).

# 4a. Per-client direct mapper.
log "Reconciling groups protocol-mappers (client-direct)..."
for cid in $CANONICAL_CLIENTS; do
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
for cid in $CANONICAL_CLIENTS; do
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

  # IdP-level group mappers — one per GITLAB_MAPPED_GROUPS entry (see group_mapper_json above).
  #
  # Converge on the FULL SHAPE, not just the name. The original version of this block matched on
  # name only, so a mapper carrying the right name but the wrong providerId was skipped forever and
  # the over-grant could never be corrected by re-running this script. Matching on type alone has
  # the same hole one level deeper (right type, tampered `claims`/`group`/`syncMode`), so the
  # verdict below compares every field that decides who gets the group.
  #
  # Target state is exactly ONE fully-matching mapper per group. Anything else — wrong type, wrong
  # config, duplicates, or a correct one alongside a stale one — deletes every same-named mapper and
  # recreates a single known-good one. That keeps convergence deterministic instead of trying to
  # decide which of several near-matches to keep.
  #
  # FAIL CLOSED. A parse failure or a missing python3 must NOT be reported as "absent": that would
  # take the create-without-delete path, leaving an over-granting mapper attached while the log
  # claims success. `set -e` cannot catch it either, because `||` disarms it. Hence the explicit
  # `error` verdict and the `exit 1` below. stderr is deliberately NOT silenced so the traceback
  # reaches the operator (it does not pollute the verdict — only stdout is captured).
  #
  # Fetched once and reused for every group: the mapper list is realm-wide, and re-fetching per
  # group would only widen the window in which the list and the verdict disagree.
  existing_idp_mappers=$($KCADM get "identity-provider/instances/gitlab/mappers" -r "$REALM" 2>/dev/null || echo "[]")

  for group in $GITLAB_MAPPED_GROUPS; do
    reconcile_group_mapper "$group"
  done
else
  log "GitLab IdP step skipped (set GITLAB_BROKERING_CLIENT_ID / _SECRET to enable)."
fi

log "Bootstrap complete. Run scripts/kcadm-verify.sh for an end-to-end check."
