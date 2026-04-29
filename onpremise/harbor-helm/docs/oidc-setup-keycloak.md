# Harbor SSO (OIDC) Setup — Keycloak

Harbor ships with a native OIDC client, so **no Dex is needed** (difference from ArgoCD).
OIDC settings are not exposed through Helm values; they live in the **Harbor core database** and must be injected via the **Harbor REST API or the Web UI**.

This document covers the **Keycloak (current production IdP)** procedure, automated via [`scripts/harbor/admin/harbor-admin-en.sh`](../../../scripts/harbor/admin/harbor-admin-en.sh) `set-oidc`. The legacy GitLab-direct procedure is preserved in [§7 Rollback / Legacy GitLab procedure](#7-rollback--legacy-gitlab-procedure).

> The first-time GitLab → Keycloak migration is documented separately in [`security/keycloak/docs/harbor-migration-en.md`](../../../security/keycloak/docs/harbor-migration-en.md).

<br/>

## Prerequisites

- Harbor exposed over HTTPS — see [`tls-setup-en.md`](./tls-setup-en.md)
- Keycloak instance running — Phase 2 of [`security/keycloak/`](../../../security/keycloak/) complete
- Realm `example` + client `harbor` + group claim mapper exist — Phase 3 complete
- Harbor `harbor` client secret in hand ([§2 Retrieve client secret](#2-retrieve-client-secret))
- Harbor admin DB password (see `harborAdminPassword` in [`../values/mgmt.yaml`](../values/mgmt.yaml))
- Policy: **only Keycloak `server` group members may log in**, and **only `admin@example.com`** is manually promoted to sysadmin

<br/>

## 1. (Already done) Keycloak client registration

Phase 3 of [`security/keycloak/scripts/kcadm-bootstrap.sh`](../../../security/keycloak/scripts/kcadm-bootstrap.sh) auto-creates:

| Field | Value |
| --- | --- |
| Realm | `example` |
| Client ID | `harbor` |
| Client Type | OpenID Connect (Confidential) |
| Standard Flow | ON (Authorization Code + PKCE) |
| Valid Redirect URIs | `https://harbor.example.com/c/oidc/callback` |
| Web Origins | `https://harbor.example.com` |
| Mappers | `groups` (Group Membership, claim name `groups`) |

GitLab is wired into Keycloak as an **Identity Provider (alias `gitlab`)**, so the user flow is Harbor → Keycloak → GitLab (brokered login).

<br/>

## 2. Retrieve client secret

Use the value captured during Phase 3 (e.g. `dg75ZmB20aP3XJKFBtSgHqG80PEp7mif`). If lost, query Keycloak:

```bash
KC_NS=keycloak
KC_REALM=example
ADMIN_PW=$(kubectl -n $KC_NS get secret keycloak-master-admin -o jsonpath='{.data.password}' | base64 -d)

kubectl -n $KC_NS exec -it keycloak-0 -- bash -lc "
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password '$ADMIN_PW' >/dev/null
  CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r $KC_REALM -q clientId=harbor --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh get clients/\$CID/client-secret -r $KC_REALM
"
# .value in the output is the client_secret
```

<br/>

## 3. Inject OIDC config (recommended: `harbor-admin-en.sh set-oidc`)

`set-oidc` previews the PUT body (secret masked), prompts for confirmation, then applies. Use `--dry-run` to validate without mutating.

```bash
cd kuberntes-infra/scripts/harbor/admin

# 1) Pre-validation (no PUT)
HARBOR_OIDC_CLIENT_SECRET='<harbor client secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name Keycloak \
    --endpoint https://auth.example.com/realms/example \
    --client-id harbor \
    --dry-run

# 2) Apply (interactive confirm; add -y for non-interactive)
HARBOR_OIDC_CLIENT_SECRET='<harbor client secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name Keycloak \
    --endpoint https://auth.example.com/realms/example \
    --client-id harbor

# 3) Verify (secret never printed)
./harbor-admin-en.sh config
```

Default PUT body sent by `set-oidc`:

| Field | Value | Notes |
| --- | --- | --- |
| `oidc_name` | `Keycloak` | Login button label |
| `oidc_endpoint` | `https://auth.example.com/realms/example` | `/.well-known/openid-configuration` discovery |
| `oidc_client_id` | `harbor` | Phase 3 client |
| `oidc_groups_claim` | `groups` | Matches the client mapper |
| `oidc_admin_group` | `""` (empty) | No auto-promotion — `admin@example.com` promoted manually |
| `oidc_group_filter` | `server` | Only Keycloak `server` group members onboard |
| `oidc_scope` | `openid,profile,email` | groups requires no extra scope |
| `oidc_user_claim` | `preferred_username` | Maps Keycloak username |
| `oidc_verify_cert` | `false` (this cluster) | ⚠️ The wildcard-example-tls cert is self-signed (no cert-manager). Harbor pod's system CA bundle does not trust it → **must pass `--verify-cert false` explicitly**. Switch to `true` once cert-manager / a trusted CA is adopted |
| `oidc_auto_onboard` | `true` | Only users passing the group filter are auto-created |

Override via CLI flags: `--groups-claim`, `--group-filter`, `--admin-group`, `--scope`, `--user-claim`, `--auto-onboard`, `--verify-cert`.

### Direct curl (reference)

What `set-oidc` calls under the hood:

```bash
ADMIN_PW=$(grep '^harborAdminPassword:' ../../../cicd/harbor-helm/values/mgmt.yaml | awk -F'"' '{print $2}')
HARBOR_CLIENT_SECRET="<harbor client secret>"

curl -sk -u "admin:$ADMIN_PW" -H "Content-Type: application/json" \
  -X PUT --data @- \
  -w "HTTP %{http_code}\n" \
  --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/configurations <<EOF
{
  "oidc_name": "Keycloak",
  "oidc_endpoint": "https://auth.example.com/realms/example",
  "oidc_client_id": "harbor",
  "oidc_client_secret": "${HARBOR_CLIENT_SECRET}",
  "oidc_groups_claim": "groups",
  "oidc_admin_group": "",
  "oidc_group_filter": "server",
  "oidc_scope": "openid,profile,email",
  "oidc_user_claim": "preferred_username",
  "oidc_verify_cert": true,
  "oidc_auto_onboard": true
}
EOF
```

### Verify the injection (secret excluded)

```bash
./harbor-admin-en.sh config
# or raw:
curl -sk -u "admin:$ADMIN_PW" --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/configurations \
  | python3 -m json.tool | grep -A1 -E 'oidc_|auth_mode'
```

> `oidc_client_secret` is write-only — the API never returns it on GET (intentional).

<br/>

## 4. Flip auth_mode (skip if already `oidc_auth`)

> This cluster is **already at `auth_mode = oidc_auth`** (flipped during the GitLab-direct era). Endpoint-only switch to Keycloak does not need this step.
>
> Only run this on a fresh Harbor where OIDC is being enabled for the first time:

```bash
curl -sk -u "admin:$ADMIN_PW" -H "Content-Type: application/json" \
  -X PUT --data '{"auth_mode":"oidc_auth"}' \
  --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/configurations
```

**Notes**

- Once flipped to `oidc_auth`, you cannot revert to DB mode via the UI (requires DB editing)
- After the flip, **admin DB login continues to work** (Harbor preserves an admin escape hatch)
- Existing DB users (except `admin`) lose login ability — check `GET /api/v2.0/users` before flipping

### Confirm

```bash
./harbor-admin-en.sh systeminfo | grep auth_mode
# "auth_mode": "oidc_auth"
```

The login page will show **`LOGIN VIA OIDC PROVIDER Keycloak`**.

<br/>

## 5. First OIDC login per user

Each user must log in once via OIDC to create their Harbor record.

1. Open `https://harbor.example.com` in a fresh incognito window
2. Click **LOGIN VIA OIDC PROVIDER Keycloak** → redirected to Keycloak
3. Click **Sign in with GitLab** → log in & authorize
4. Redirected back to Keycloak → Harbor home → user auto-onboarded

If the user is not in the `server` group filter, no Harbor user record is created.

> Existing users who onboarded during the GitLab-direct era will be **created as new users** because the OIDC `sub` changes. See [`security/keycloak/docs/harbor-migration-en.md`](../../../security/keycloak/docs/harbor-migration-en.md) for permission/membership re-mapping.

<br/>

## 6. Promote to sysadmin (API)

Newly onboarded OIDC users have normal privileges. Promote via API:

```bash
./harbor-admin-en.sh users
./harbor-admin-en.sh promote admin@example.com

# Verify
./harbor-admin-en.sh user-info admin@example.com | grep sysadmin_flag
```

Cluster policy: **only `admin@example.com` is promoted**. Other accounts remain standard and are granted per-project roles.

<br/>

## 7. Rollback / Legacy GitLab procedure

> ⚠️ The **full pre-Phase-4 procedure** is preserved verbatim in [`legacy/oidc-setup-gitlab-en.md`](./legacy/oidc-setup-gitlab-en.md) ([한국어](./legacy/oidc-setup-gitlab.md)) — GitLab Application creation, redirect URI, user impact, troubleshooting, all there.

### 7.1. Quick rollback (existing GitLab Application still alive)

```bash
HARBOR_OIDC_CLIENT_SECRET='<gitlab app secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name GitLab \
    --endpoint http://gitlab.example.com \
    --client-id '<gitlab application id>' \
    --verify-cert false
```

### 7.2. Field differences

| Field | GitLab (legacy) | Keycloak (current) |
| --- | --- | --- |
| `oidc_name` | `GitLab` | `Keycloak` |
| `oidc_endpoint` | `http://gitlab.example.com` | `https://auth.example.com/realms/example` |
| `oidc_verify_cert` | `false` (HTTP) | `true` (HTTPS + wildcard cert) |
| `oidc_groups_claim` | `groups` (try `groups_direct` on GitLab 17+) | `groups` |
| Login flow | Harbor → GitLab | Harbor → Keycloak → GitLab |

### 7.3. Rollback user impact

Reverting the endpoint to GitLab flips the OIDC `sub` back to GitLab basis:
- Users onboarded under Keycloak become new users again
- See [`security/keycloak/docs/harbor-migration-en.md`](../../../security/keycloak/docs/harbor-migration-en.md) for the same user re-mapping procedure (in either direction)

<br/>

## 8. Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| `failed to get token` on OIDC click | `oidc_verify_cert` does not match endpoint scheme (https→true
| Login succeeds but no Harbor user created | User is not in `oidc_group_filter` (`server`). Check the Keycloak group mapping (`server-group-map` IdP mapper) |
| Groups claim is empty | On the Keycloak `harbor` client, ensure the group mapper has `Add to ID token` / `Add to userinfo` ON |
| Harbor returns `invalid_state` after Keycloak | Pod clock skew (NTP) or cookie domain issue. Check `kubectl -n harbor logs deploy/harbor-core` |
| `admin` cannot log in | Admin uses DB login even in OIDC mode. Verify password |
| Bad config injection | Re-run `set-oidc` or `PUT /api/v2.0/configurations`. Only `auth_mode` is irreversible |

<br/>

## Alternative: Web UI Path (reference)

For a GUI-only run, go to `Administration → Configuration → Authentication` and fill the same fields → click **Test OIDC Server** → Save.
The result is identical to the API, but it is not re-runnable/scriptable, so the API method is the standard.

<br/>

## References

- Harbor OIDC docs: https://goharbor.io/docs/latest/administration/configure-authentication/oidc-auth/
- Keycloak SSO component: [`security/keycloak/`](../../../security/keycloak/)
- Phase 4 migration procedure (GitLab → Keycloak): [`security/keycloak/docs/harbor-migration-en.md`](../../../security/keycloak/docs/harbor-migration-en.md)
- ArgoCD SSO (currently GitLab dex; will switch to Keycloak in Phase 6): [`../../argo-cd/values/mgmt.yaml`](../../argo-cd/values/mgmt.yaml)
- Harbor API reference: `https://harbor.example.com/devcenter-api-2.0`
