# Vaultwarden OIDC → Keycloak migration

Switch vaultwarden's SSO endpoint from a direct GitLab integration to the Keycloak `example` realm. Existing GitLab-account users keep signing in transparently via Keycloak → GitLab brokering — minimal user impact, ~30s pod restart only.

vaultwarden's SSO support comes from [PR #3899](https://github.com/dani-garcia/vaultwarden/pull/3899) (community fork). This cluster already runs with `sso.enabled=true` ([security/vaultwarden/values/mgmt.yaml:39-49](../../vaultwarden/values/mgmt.yaml#L39-L49)) — only the `authority`/`clientId`/`clientSecret` change.

<br/>

## Prerequisites

- Phase 3 complete: Keycloak `example` realm + `vaultwarden` client (Standard Flow + PKCE) + group claim mapper
- `vaultwarden` client secret (printed by the Phase 3 bootstrap script, or fetched with the admin in `keycloak-master-admin` Secret)
- vaultwarden admin token (Helm values' `adminToken` or persistent Secret)

<br/>

## redirect URI

vaultwarden SSO fork's default callback path is `/identity/connect/oidc-signin`. Keycloak `vaultwarden` client redirectUris must include (Phase 3 bootstrap auto-registers this):

```
https://vault.example.com/identity/connect/oidc-signin
```

Override `SSO_CALLBACK_PATH` in vaultwarden + the redirectUris list in lockstep if you need a different path.

<br/>

## values diff

In [security/vaultwarden/values/mgmt.yaml](../../vaultwarden/values/mgmt.yaml), replace the `sso` block:

**Before (direct GitLab)**

```yaml
sso:
  enabled: true
  authority: "http://gitlab.example.com"
  scopes: "openid email profile"
  signupsMatchEmail: true
  ignoreEmailVerification: true
  pkce: true
  clientId:
    value: "<gitlab-application-id>"
  clientSecret:
    value: "<gitlab-application-secret>"
```

**After (Keycloak)**

```yaml
sso:
  enabled: true
  authority: "https://auth.example.com/realms/example"
  scopes: "openid email profile"
  signupsMatchEmail: true
  ignoreEmailVerification: true
  pkce: true
  clientId:
    value: "vaultwarden"
  clientSecret:
    value: "<keycloak-vaultwarden-client-secret>"
```

Key fields:
- `authority`: GitLab issuer → `https://auth.example.com/realms/example`
- `clientId`: GitLab Application ID → `vaultwarden` (the Keycloak client created in Phase 3)
- `clientSecret`: replace with the Keycloak `vaultwarden` client secret

<br/>

## Apply

```bash
helmfile -f security/vaultwarden/helmfile.yaml diff
helmfile -f security/vaultwarden/helmfile.yaml apply   # user must approve
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=120s
```

**Downtime**: ~30s SSO login outage during pod rollout. Already-unlocked vault sessions are unaffected.

<br/>

## Verification

1. Visit `https://vault.example.com/#/sso` → click "Enterprise single sign-on (SSO)"
2. Enter the SSO Identifier (vaultwarden_rs uses the user's email or any organization-level identifier)
3. **You are redirected to the Keycloak `example` realm login page** (previously: directly to GitLab)
4. Click "Sign in with GitLab" → finish GitLab auth → land back in vaultwarden
5. Confirm account.bitwarden.com → SSO Association now shows `auth.example.com` as the IdP

<br/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Keycloak "Invalid redirect URI" | `vaultwarden` client missing `https://vault.example.com/identity/connect/oidc-signin` in redirectUris. Re-run Phase 3 bootstrap, or add via UI |
| vaultwarden "OIDC client not configured" | Helm values' `sso.clientSecret.value` empty or out of sync with the Keycloak `vaultwarden` client's secret |
| Existing GitLab user can't sign in | If vaultwarden maps users by `sub`, the new Keycloak `sub` breaks the link. `signupsMatchEmail: true` + `ignoreEmailVerification: true` (already set) make matching fall back to `email` claim |
| Empty `groups` claim | The `vaultwarden` client is missing the group-membership protocol-mapper. Run `./scripts/kcadm-verify.sh` |

<br/>

## Rollback

```bash
git checkout HEAD~1 -- security/vaultwarden/values/mgmt.yaml
helmfile -f security/vaultwarden/helmfile.yaml apply   # user must approve
```

The GitLab Application stays alive for vaultwarden until plan v2's Phase 7 cleanup, so rollback is one revert away.

<br/>

## Phase 7 cleanup

In [plan v2](../../../../../.claude/plans/gitlab-project-kubernetes-infra-keycloa-scalable-bachman.md)'s Phase 7:
- Drop the vaultwarden-only GitLab Application (collapse onto the single `Keycloak Brokering (example)` application)
- Tidy stale SSO Associations on previously-cutover users (newly logging-in users get re-mapped automatically)
