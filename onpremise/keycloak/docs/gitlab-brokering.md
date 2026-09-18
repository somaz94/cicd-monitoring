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

Do not reuse the existing ArgoCD / Harbor GitLab Applications (`cd5caacf...`, `gloas-...`) — create a **new application dedicated to Keycloak brokering**.

GitLab Admin → Applications → New Application:

| Field | Value |
|---|---|
| Name | `Keycloak Brokering (example)` |
| Redirect URI | `https://auth.example.com/realms/example/broker/gitlab/endpoint` |
| Confidential | ON |
| Scopes | `openid`, `email`, `profile` (`read_user` is **not** needed for the group claim — measured 2026-07-30) |

→ After save, copy the **Application ID** and **Secret**.

> The legacy ArgoCD / Harbor applications are removed in Phase 7 cleanup (after the migration).

<br/>

## Keycloak side (UI)

> 🔴 The authoritative procedure is `./scripts/kcadm-bootstrap.sh`. The UI / kcadm steps below only reproduce by hand what that script converges on; where they disagree, the script wins (and `./scripts/kcadm-verify.sh` is what checks it).

1. realm `example` → Identity providers → Add provider → **OpenID Connect v1.0**
   - Do NOT use the built-in **GitLab** provider (`providerId=gitlab`): it hardcodes its endpoints to gitlab.com and cannot point at a self-hosted GitLab, and `kcadm-verify.sh` **fails** on `providerId != oidc`. `kcadm-bootstrap.sh` deletes and recreates an IdP found in that state.
2. Settings:
   - Alias: `gitlab` (URL exposes as `/broker/gitlab/...`)
   - Display name: `GitLab`
   - Use discovery endpoint: **OFF** — enter the endpoints explicitly (derived from `GITLAB_BASE_URL`)
     - Authorization URL: `https://gitlab.example.com/oauth/authorize`
     - Token URL: `https://gitlab.example.com/oauth/token`
     - User Info URL: `https://gitlab.example.com/oauth/userinfo`
     - JWKS URL: `https://gitlab.example.com/oauth/discovery/keys`
     - Issuer: `https://gitlab.example.com`
   - Client ID: GitLab Application ID
   - Client Secret: GitLab Application Secret
   - Default scopes: `openid email profile` (same as `config.defaultScope` in `kcadm-bootstrap.sh`. With this scope set the `groups_direct` claim **arrives via the userinfo endpoint**; `read_user` is not required — measured 2026-07-30)
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
  -s providerId=oidc \
  -s enabled=true \
  -s displayName=GitLab \
  -s trustEmail=true \
  -s "config.clientId=<gitlab-app-id>" \
  -s "config.clientSecret=<gitlab-app-secret>" \
  -s "config.issuer=https://gitlab.example.com" \
  -s "config.authorizationUrl=https://gitlab.example.com/oauth/authorize" \
  -s "config.tokenUrl=https://gitlab.example.com/oauth/token" \
  -s "config.userInfoUrl=https://gitlab.example.com/oauth/userinfo" \
  -s "config.jwksUrl=https://gitlab.example.com/oauth/discovery/keys" \
  -s "config.clientAuthMethod=client_secret_post" \
  -s "config.validateSignature=true" \
  -s "config.useJwksUrl=true" \
  -s "config.syncMode=IMPORT" \
  -s "config.defaultScope=openid email profile"
```

> This block is a hand-transcription of what `./scripts/kcadm-bootstrap.sh` does. In practice, run the script — it owns these values and the doc is the copy.

<br/>

## Group claim mapper

To preserve ArgoCD's `g, server, role:server-admin` policy, federated users must surface their `server` group membership.

1. Identity providers → `gitlab` → Mappers → Add mapper
2. Type: **Advanced Claim to Group** (`oidc-advanced-group-idp-mapper`)
3. Name: `server-group-map`
4. Claims: key `groups_direct` / value `server` (regex off)
5. Group: `/server`
6. Sync mode override: `FORCE` (apply GitLab-side group changes immediately — dropping a user from the GitLab group revokes `/server` on their next login)

`kcadm-bootstrap.sh` creates these mappers, so the UI steps are normally unnecessary. There is not one mapper but **one per entry in `GITLAB_MAPPED_GROUPS`** (`<group>-group-map`) — `server-group-map` above is one example — and `kcadm-verify.sh` asserts one per group. The script compares **type as well as name**, and deletes/recreates a same-named mapper whose type differs.

> ⚠️ **Do not use the Hardcoded Group type.** `oidc-hardcoded-group-idp-mapper` reads no claim at all and grants `/server` to **every** brokered user. `/server` simultaneously opens ArgoCD `role:server-admin`, the Harbor login gate, and the example-hub privileged-tool proxies (account-tool, keycloak-ops, ...). As measured on 2026-07-30 that meant 8 intended members vs 43 active GitLab accounts — the hardcoded type was in use and has been replaced with the advanced one.

> `groups_direct` carries **direct memberships only**. `groups` is not used because GitLab groups are currently flat (no subgroups) so both match identically, but once a subgroup exists `groups_direct` will **not** grant `/server` to a subgroup-only member (fail-closed) — the safer default for a privilege gate.

> To confirm claim delivery: GitLab's `/.well-known/openid-configuration` must list `groups` / `groups_direct` in `claims_supported`, and the IdP must have `userInfoUrl` set (group claims sometimes arrive via userinfo rather than the ID token — the same reason ArgoCD's dex connector needs `getUserInfo: true`).

<br/>

## Verification

1. Visit `https://auth.example.com/realms/example/account` → expect a "Sign in with GitLab" button
2. Click → log in via GitLab → first-login consent → user appears under realm `example` → Users
3. Token introspect:
   ```bash
   curl -s -X POST https://auth.example.com/realms/example/protocol/openid-connect/token \
     -d grant_type=password \
     -d client_id=admin-cli \
     -d username=admin \
     -d password=<keycloak password>
   # Decode access_token → expect "groups" claim to include "server"
   ```

<br/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Login with GitLab" succeeds at GitLab but doesn't return to Keycloak | Redirect URI mismatch. Confirm GitLab Application's redirect URI is exactly `https://auth.example.com/realms/example/broker/gitlab/endpoint` |
| `groups` claim is empty (one user) | **Most common cause — not a direct member of the GitLab `server` group** (`groups_direct` lacks `server`). Check the GitLab group membership, then re-login. Next candidate is a missing group mapper |
| **Everyone loses `/server` at once** | The `groups_direct` claim is not arriving, combined with the mapper's `syncMode=FORCE`. Triggers: a change to the IdP's `defaultScope` / `userInfoUrl` / `disableUserInfo`, or the GitLab `server` group being moved under a parent so the claim value becomes `parent/server`. Diagnose with `./scripts/kcadm-verify.sh`. **Recovery is automatic on the next login once the claim returns** — do not revert to a hardcoded mapper (that reinstates the over-grant) |
| A brokered user was added to `/server` by hand in the UI, then lost it | Working as intended. `syncMode=FORCE` **removes** the group on every login where the claim does not match, and it cannot tell an admin's manual grant apart from a stale one. Grant temporary access by adding the user to the GitLab `server` group instead |
| `Trust email: OFF` and `signupsMatchEmail` has no effect | Set Trust email ON — required to match federated email against existing realm users |
| Sync mode `LEGACY` (deprecated) | Switch to `IMPORT` or `FORCE`. LEGACY was removed in Keycloak 25+ |

<br/>

## Break-glass — when `/server` is revoked fleet-wide

`/server` opens ArgoCD RBAC, the Harbor login gate, and the example-hub privileged-tool proxies **at the same time**. If the claim stops arriving, all three lock together, so know the bypasses before you need them.

| Target | Bypass |
|---|---|
| Keycloak itself | master realm admin (`keycloak-master-admin` Secret) — `kubectl -n keycloak get secret keycloak-master-admin -o jsonpath='{.data.password}' \| base64 -d` |
| ArgoCD | The local `admin` account (`admin.enabled: true`; password in the `argocd-initial-admin-secret` Secret). **There is no OIDC-side fallback**: since 2026-07-30 both roles are group subjects (`g, global-admin, ...` and `g, server, ...`) and `policy.default` is empty, so a missing groups claim leaves an OIDC user with no permissions at all. Before that date `g, admin@example.com, role:global-admin` acted as an email-based lifeline; the group switch traded that for a single source of truth |
| Harbor | `admin` can still log in against the DB even in OIDC mode (`harborAdminPassword` in `values/dev.yaml`) |
| example-hub | Portal login is not group-gated. Groups only decide app-card visibility, so login succeeds and only the cards disappear |

This is why `global-admin` must not be left empty — with no members, an admin-only gate is impossible, so consumers fall back to the far broader `/server` or to a hardcoded email. `GLOBAL_ADMIN_MEMBERS` in `kcadm-bootstrap.sh` populates it.

**Rolling back**: reverting to a hardcoded mapper is **not a fix** — it reinstates the full over-grant. Repair the claim instead; if it is urgent, resolve individually by adding the user to the GitLab `server` group.

<br/>

## Next

- [argocd-migration-en.md](argocd-migration.md) — switch ArgoCD dex from GitLab to Keycloak OIDC
- [harbor-migration-en.md](harbor-migration.md) — switch the Harbor OIDC endpoint
