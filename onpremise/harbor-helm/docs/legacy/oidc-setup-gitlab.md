# Harbor GitLab SSO (OIDC) Setup — Archived (pre-Phase 4)

> ⚠️ **Archived (as of 2026-04-28)**: Harbor's OIDC IdP was switched from GitLab to Keycloak in Phase 4.
> - Current standard procedure: [`../oidc-setup-keycloak-en.md`](../oidc-setup-keycloak-en.md) ([한국어](../oidc-setup-keycloak.md))
> - Migration history / rollback: [`security/keycloak/docs/harbor-migration-en.md`](../../../../security/keycloak/docs/harbor-migration-en.md)
>
> This document preserves the GitLab-direct procedure verbatim as a reference. Use it only when reproducing a GitLab-direct setup elsewhere or temporarily rolling back during a Keycloak outage.

<br/>

Harbor ships with a native OIDC client, so **no Dex is needed** (difference from ArgoCD).
OIDC settings are not exposed through Helm values; they live in the **Harbor core database** and must be injected via the **Harbor REST API or the Web UI**.

This document documents the **API-based declarative injection procedure** as the standard (re-runnable, easier to audit than UI clicks). The [`scripts/harbor-admin.sh`](../scripts/harbor-admin.sh) helper wraps most of these operations.

<br/>

## Prerequisites

- Harbor is exposed over HTTPS — see [`tls-setup-en.md`](./tls-setup-en.md)
- GitLab admin access to create an OAuth Application
- Harbor admin DB credentials (see `harborAdminPassword` in [`../values/mgmt.yaml`](../values/mgmt.yaml))
- Policy: **only GitLab `server` group members may log in**, and **only `admin@example.com`** is manually promoted to sysadmin (same as ArgoCD)

<br/>

## 1. Create the GitLab OAuth Application

GitLab (`http://gitlab.example.com`) → **Admin Area → Applications → New application**

| Field | Value |
| --- | --- |
| Name | `Harbor` |
| Redirect URI | `https://harbor.example.com/c/oidc/callback` |
| Confidential | ✅ Yes |
| Scopes | `openid`, `profile`, `email` |

Copy the **Application ID** (= `client_id`) and **Secret** for the next step.

<br/>

## 2. Inject OIDC Configuration (Harbor API)

Pass the GitLab values via env vars and PUT to `/api/v2.0/configurations`.

```bash
# Admin password (extracted from values/mgmt.yaml)
ADMIN_PW=$(grep '^harborAdminPassword:' ../values/mgmt.yaml | awk -F'"' '{print $2}')

# Values from the GitLab OAuth app
OIDC_CLIENT_ID="<GitLab Application ID>"
OIDC_CLIENT_SECRET="<GitLab Application Secret>"

# 192.168.1.55 is the ingress-nginx LoadBalancer IP — use --resolve from inside the cluster
curl -sk -u "admin:$ADMIN_PW" -H "Content-Type: application/json" \
  -X PUT --data @- \
  -w "HTTP %{http_code}\n" \
  --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/configurations <<EOF
{
  "oidc_name": "GitLab",
  "oidc_endpoint": "http://gitlab.example.com",
  "oidc_client_id": "${OIDC_CLIENT_ID}",
  "oidc_client_secret": "${OIDC_CLIENT_SECRET}",
  "oidc_groups_claim": "groups",
  "oidc_admin_group": "",
  "oidc_group_filter": "server",
  "oidc_scope": "openid,profile,email",
  "oidc_user_claim": "preferred_username",
  "oidc_verify_cert": false,
  "oidc_auto_onboard": true
}
EOF
```

### Field Reference

| Field | Value | Notes |
| --- | --- | --- |
| `oidc_name` | `GitLab` | Login button label |
| `oidc_endpoint` | `http://gitlab.example.com` | Used for `/.well-known/openid-configuration` discovery |
| `oidc_groups_claim` | `groups` | Switch to `groups_direct` on GitLab 17+ if not matching |
| `oidc_admin_group` | `""` (empty) | No auto-promotion — `admin@example.com` is promoted manually |
| `oidc_group_filter` | `server` | Only GitLab `server` group members may onboard |
| `oidc_scope` | `openid,profile,email` | GitLab does not require an explicit `groups` scope |
| `oidc_user_claim` | `preferred_username` | Maps GitLab username |
| `oidc_verify_cert` | `false` | GitLab runs on HTTP; TLS verify is moot |
| `oidc_auto_onboard` | `true` | Only users passing the group filter are auto-created |

### Verify the Injection (secret excluded)

```bash
scripts/harbor-admin.sh config
# or:
curl -sk -u "admin:$ADMIN_PW" --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/configurations \
  | python3 -m json.tool | grep -A1 -E 'oidc_|auth_mode'
```

> `oidc_client_secret` is write-only — the API never returns it on GET (intentional).

<br/>

## 3. Flip auth_mode (⚠️ irreversible)

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

### Confirm the Flip

```bash
scripts/harbor-admin.sh systeminfo | grep auth_mode
# "auth_mode": "oidc_auth"
```

Browsing to `https://harbor.example.com` will now show the **`LOGIN VIA OIDC PROVIDER`** button on the login page.

<br/>

## 4. First OIDC Login per User

Each user must log in once via OIDC to create their Harbor record.

1. Open `https://harbor.example.com` in a fresh incognito window (accept the self-signed warning)
2. Click **LOGIN VIA OIDC PROVIDER** → redirected to GitLab
3. Log in as the user and authorize the app
4. Redirected back to Harbor home → user auto-onboarded

If the user is not in the `server` group filter, no Harbor user record is created after the redirect.

<br/>

## 5. Promote to sysadmin (API)

A freshly onboarded OIDC user has normal privileges. Promote via API:

```bash
scripts/harbor-admin.sh promote admin@example.com
```

Equivalent raw calls:

```bash
# Find the user_id
curl -sk -u "admin:$ADMIN_PW" --resolve harbor.example.com:443:192.168.1.55 \
  "https://harbor.example.com/api/v2.0/users?page_size=100" | python3 -m json.tool

# Promote (user_id=3 in this example)
curl -sk -u "admin:$ADMIN_PW" -H "Content-Type: application/json" \
  -X PUT --data '{"sysadmin_flag":true}' \
  --resolve harbor.example.com:443:192.168.1.55 \
  https://harbor.example.com/api/v2.0/users/3/sysadmin
```

Cluster policy: **only `admin@example.com` is promoted**. Other accounts remain standard and are granted per-project roles.

<br/>

## 6. Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| `failed to get token` on OIDC click | `oidc_verify_cert: false` not set, or GitLab's Redirect URI does not exactly match `https://harbor.example.com/c/oidc/callback` |
| Login succeeds but no Harbor user is created | User is not in the `oidc_group_filter` group. Check GitLab group membership |
| Groups claim is empty | GitLab 17+ — switch `oidc_groups_claim` to `groups_direct` |
| admin cannot log in | Admin uses DB login even in OIDC mode. Verify password. For Harbor 2.13+ see CLI secret mechanism |
| Settings are wrong | Re-run the `PUT /api/v2.0/configurations` call. Only `auth_mode` is irreversible |

<br/>

## Alternative: Web UI Path (reference)

For a GUI-only run, go to `Administration → Configuration → Authentication` and fill the same fields → click **Test OIDC Server** → Save.
The result is identical to the API, but it is not re-runnable/scriptable, so the API method is the standard.

<br/>

## References

- Harbor OIDC docs: https://goharbor.io/docs/latest/administration/configure-authentication/oidc-auth/
- ArgoCD GitLab SSO (same GitLab, same `server` group): [`../../argo-cd/values/mgmt.yaml`](../../argo-cd/values/mgmt.yaml)
- Harbor API reference: `https://harbor.example.com/devcenter-api-2.0`
