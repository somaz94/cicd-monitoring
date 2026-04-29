# GitLab Identity Brokering (example realm)

Registering **GitLab as an Identity Provider** on the Keycloak `example` realm gives users a "Login with GitLab" button at the realm login screen — existing GitLab accounts work unchanged, with zero downtime.

<br/>

## Sequence

```
User → ArgoCD/Harbor → "Login with Keycloak" → Keycloak `example` realm
                                                  → "Login with GitLab" button
                                                  → GitLab OAuth 2.0 (gitlab.example.com)
                                                  → Keycloak federates user/groups
                                                  → token issued → ArgoCD/Harbor in
```

<br/>

## GitLab side

Do not reuse the existing ArgoCD

GitLab Admin → Applications → New Application:

| Field | Value |
|---|---|
| Name | `Keycloak Brokering (example)` |
| Redirect URI | `https://auth.example.com/realms/example/broker/gitlab/endpoint` |
| Confidential | ON |
| Scopes | `openid`, `email`, `profile`, `read_user` |

→ After save, copy the **Application ID** and **Secret**.

> The legacy ArgoCD / Harbor applications are removed in Phase 7 cleanup (after the migration).

<br/>

## Keycloak side (UI)

1. realm `example` → Identity providers → Add provider → **GitLab**
2. Settings:
   - Alias: `gitlab` (URL exposes as `/broker/gitlab/...`)
   - Display name: `GitLab`
   - Use discovery endpoint: ON, URL: `https://gitlab.example.com/.well-known/openid-configuration`
   - Client ID: GitLab Application ID
   - Client Secret: GitLab Application Secret
   - Default scopes: `openid email profile read_user`
   - Trust email: ON (signupsMatchEmail effect)
   - Sync mode: `IMPORT` (Keycloak DB caches the user — first login imports, subsequent GitLab changes sync on federation refresh)
3. Save

<br/>

## Keycloak side (kcadm.sh)

```bash
KCADM="kubectl -n keycloak exec -i keycloak-0 -- /opt/keycloak/bin/kcadm.sh"

$KCADM config credentials --server http://localhost:8080 --realm master \
  --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

$KCADM create identity-provider/instances -r example \
  -s alias=gitlab \
  -s providerId=gitlab \
  -s enabled=true \
  -s displayName=GitLab \
  -s "config.clientId=<gitlab-app-id>" \
  -s "config.clientSecret=<gitlab-app-secret>" \
  -s "config.useJwksUrl=true" \
  -s "config.syncMode=IMPORT"
```

<br/>

## Group claim mapper

To preserve ArgoCD's `g, server, role:server-admin` policy, federated users must surface their `server` group membership.

1. Identity providers → `gitlab` → Mappers → Add mapper
2. Type: **Group Membership Mapper** (or **Hardcoded Group**)
3. Name: `server-group-map`
4. Mode: `IMPORT` (or `FORCE` to refresh on every login)
5. Group: `/server`
6. Sync mode override: `FORCE` (apply GitLab-side group changes immediately)

> The OAuth scope must include `read_user` to receive group info. If GitLab `/api/v4/user` returns no `groups`, check the application's scopes.

<br/>

## Verification

1. Visit `https://auth.example.com/realms/example/account` → expect a "Sign in with GitLab" button
2. Click → log in via GitLab → first-login consent → user appears under realm `example` → Users
3. Token introspect:
   ```bash
   curl -s -X POST https://auth.example.com/realms/example/protocol/openid-connect/token \
     -d grant_type=password \
     -d client_id=admin-cli \
     -d username=somaz \
     -d password=<keycloak password>
   # Decode access_token → expect "groups" claim to include "server"
   ```

<br/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Login with GitLab" succeeds at GitLab but doesn't return to Keycloak | Redirect URI mismatch. Confirm GitLab Application's redirect URI is exactly `https://auth.example.com/realms/example/broker/gitlab/endpoint` |
| `groups` claim is empty | Missing `read_user` scope, or group mapper not configured |
| `Trust email: OFF` and `signupsMatchEmail` has no effect | Set Trust email ON — required to match federated email against existing realm users |
| Sync mode `LEGACY` (deprecated) | Switch to `IMPORT` or `FORCE`. LEGACY was removed in Keycloak 25+ |

<br/>

## Next

- [argocd-migration-en.md](argocd-migration-en.md) — switch ArgoCD dex from GitLab to Keycloak OIDC
- [harbor-migration-en.md](harbor-migration-en.md) — switch the Harbor OIDC endpoint
