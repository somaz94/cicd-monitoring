# ArgoCD dex → Keycloak OIDC migration (Phase 6, 2026-04-29)

> **Status**: 2026-04-29 — procedure finalized. Cluster apply requires user approval.

Switches the ArgoCD dex GitLab connector to Keycloak OIDC. Keycloak brokers GitLab as IdP, so user credentials remain GitLab — the only user action is **a single re-login**.

The same change adds an `argocd-https-redirect` HTTPRoute via chart `extraObjects` to bring ArgoCD in line with Harbor

<br/>

## Prerequisites (all complete)

- ✅ Phase 2: Keycloak instance + PostgreSQL up, `auth.example.com` HTTP/2 200
- ✅ Phase 3: realm `example` + client `argocd` (Standard Flow + PKCE) + groups mapper + GitLab IdP brokering
- ✅ Keycloak `argocd` client redirectUris registered: `https://argocd.example.com/api/dex/callback`, `https://argocd.example.com/auth/callback`
- ✅ Keycloak `argocd` client secret recovered from Phase 3 bootstrap output (or re-fetch via `kcadm.sh get clients/<id>/client-secret -r example`)
- ✅ Phase 4 (Harbor) IdP fix complete → GitLab brokering healthy (providerId=oidc + trustEmail=true)

<br/>

## User impact

| Item | Before | After | User action |
| --- | --- | --- | --- |
| URL | `argocd.example.com` | **same** | none |
| `http://argocd.example.com` access | served as HTTP | **301 → HTTPS** | none (browser auto) |
| Login button | "Login with GitLab" | "Login with Keycloak" | one click difference |
| Login flow | ArgoCD → dex(gitlab) → GitLab | ArgoCD → dex(oidc) → Keycloak → GitLab (broker) | re-login once |
| Credentials | existing GitLab account | **same** (Keycloak brokering) | none |
| group claim | `server`, `global-admin` | **same** (Keycloak group mapper) | none |
| `policy.csv` | `g, server, role:server-admin` | **untouched** | none |
| Downtime | dex pod rollout ~30 s after `helmfile apply` | — | brief retry |

→ Even with more ArgoCD users, the ceiling is **one re-login** per user.

<br/>

## Change summary (3 files)

1. [`cicd/argo-cd/values/mgmt.yaml`](../../../cicd/argo-cd/values/mgmt.yaml)
   - `configs.cm.dex.config`: GitLab connector → OIDC connector (Keycloak, `insecureSkipVerify: true`)
   - `configs.secrets`: comment out `dex.gitlab.*`, add `dex.keycloak.clientSecret`
   - `extraObjects`: one new `argocd-https-redirect` HTTPRoute
2. [`cicd/argo-cd/helmfile.yaml`](../../../cicd/argo-cd/helmfile.yaml) — refresh values comment (mention extraObjects)
3. [`security/keycloak/docs/argocd-migration.md`](./argocd-migration.md) — this stub → procedure

> Legacy GitLab `dex.config` and `secrets` are **kept commented** in the same values file (swap to roll back).

<br/>

## Procedure

> All cluster mutations require user approval beforehand (`feedback_cluster_apply_confirm`).

### Step 1. Snapshot current state (read-only)

```bash
kubectl -n argocd get cm argocd-cm -o yaml > /tmp/argocd-pre-phase6-cm.yaml
kubectl -n argocd get secret argocd-secret -o yaml > /tmp/argocd-pre-phase6-secret.yaml
kubectl -n argocd get httproute > /tmp/argocd-pre-phase6-httproutes.txt
```

### Step 2. helmfile diff (review chart-level diff)

```bash
cd kuberntes-infra
helmfile -f cicd/argo-cd/helmfile.yaml -e mgmt diff
```

Expected diff:
- ConfigMap `argocd-cm`: `dex.config` key changes (gitlab connector → oidc connector)
- Secret `argocd-secret`: `dex.gitlab.clientId/Secret` removed, `dex.keycloak.clientSecret` added
- HTTPRoute `argocd-https-redirect`: created (extraObjects)

### Step 3. Apply (after user approval)

```bash
helmfile -f cicd/argo-cd/helmfile.yaml -e mgmt apply
```

> ⚠️ **First-time note**: extraObjects is integrated into the chart, so no separate `helmfile sync` is needed — a single `apply` covers the chart diff plus extraObjects.

### Step 4. Component health check

```bash
# dex pod rollout (picks up new dex.config)
kubectl -n argocd rollout status deploy/argocd-dex-server --timeout=120s

# argocd-server (configmap reload)
kubectl -n argocd rollout status deploy/argocd-server --timeout=120s

# Both HTTPRoutes present
kubectl -n argocd get httproute
# Expect: argocd-server, argocd-https-redirect

# Gateway parent attach status
kubectl -n argocd get httproute argocd-https-redirect -o jsonpath='{.status.parents[0].conditions}' | jq
# Expect: Accepted=True, ResolvedRefs=True
```

### Step 5. End-to-end verification

**HTTP→HTTPS 301 redirect**

```bash
curl -sI -H 'Host: argocd.example.com' http://argocd.example.com | head -3
# Expect: HTTP/1.1 301 Moved Permanently
#         Location: https://argocd.example.com/
```

**Browser login (user action)**

1. Visit `https://argocd.example.com` → confirm previous session is expired
2. Click **"Login with Keycloak"** (changed)
3. On Keycloak's screen click **"Sign in with GitLab"** (brokering)
4. Sign in to GitLab → land on the ArgoCD dashboard
5. Top-right profile → confirm `server` or `global-admin` group is shown

**argocd CLI**

```bash
argocd login argocd.example.com --sso
argocd account get-user-info
# Expect: groups: [server, global-admin] etc.
```

<br/>

## Rollback

dex-only rollback:

```bash
git revert <phase6 commit>
helmfile -f cicd/argo-cd/helmfile.yaml -e mgmt apply
```

Or a quick hot rollback (without touching git):

1. In [`cicd/argo-cd/values/mgmt.yaml`](../../../cicd/argo-cd/values/mgmt.yaml), comment out the oidc `dex.config` block and uncomment the **legacy GitLab block** kept below it
2. Comment out `secrets.dex.keycloak.clientSecret`, uncomment `secrets.dex.gitlab.*`
3. `helmfile apply`

The GitLab Application stays alive throughout the brokering phase, so the legacy connector recovers immediately. The redirect HTTPRoute does not need to be reverted (security hardening, OIDC-independent).

<br/>

## Follow-up cleanup

[Phase 8 cleanup](../../../docs/keycloak-rollout-2026-04.md):
- Refresh `cicd/argo-cd/README.md` SSO section (GitLab-direct → Keycloak)
- Consider removing the legacy GitLab Application (ArgoCD-direct) — consolidate to a single Keycloak-brokering Application

<br/>

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Login click → "Failed to query provider" | dex cannot reach Keycloak `auth.example.com` | From the dex pod: `curl -k https://auth.example.com/realms/example/.well-known/openid-configuration` — suspect TLS/network or missing `insecureSkipVerify` |
| Past Keycloak but infinite redirect on the GitLab step | Keycloak's GitLab IdP regressed to `providerId=gitlab` (built-in) | Re-run Phase 4 fix's `kcadm-bootstrap.sh` — ensures providerId=oidc + trustEmail=true |
| Logged in but "Forbidden" | group claim mapper missing or group name mismatch | Verify the user is mapped to `server`/`global-admin` in Keycloak. Also re-check `g, server, role:server-admin` in `policy.csv` |
| `http://argocd.example.com` not redirected | extraObjects not applied

<br/>

## Lessons learned (uncovered during the 2026-04-29 cutover)

Five traps tripped in sequence during cutover. Documented so the next migration (or a fresh cluster rebuild with the same config) can pre-empt them.

### 1. argo-cd chart 9.x secrets path is `configs.secret.extra`, not `configs.secrets`

**Symptom**: `dex.config: ... clientSecret: $dex.keycloak.clientSecret` (secret reference) → on dex boot, `failed to get signing algorithm: no signing key found` and the token endpoint rejects with an empty client secret.

**Cause**: argo-cd 9.5.4's `templates/argocd-configs/argocd-secret.yaml` only ingests keys from `.Values.configs.secret.extra`. The legacy path `.Values.configs.secrets` (plural `s`) is silently ignored by the chart.

**Fix**: inline the client secret as **plaintext in dex.config** (same convention as the previous GitLab era). Or correct the path to `configs.secret.extra.<key>`. This cluster chose plaintext inline — consistent with the existing convention of plaintext secrets in values.

### 2. Main HTTPRoute without sectionName collides with the redirect sibling

**Symptom**: After adding `argocd-https-redirect` (sectionName=http) via extraObjects, `curl -I http://argocd.example.com` still returned 200 instead of 301.

**Cause**: The chart-native `argocd-server` HTTPRoute has `parentRefs[].sectionName` unset → auto-attaches to both HTTP and HTTPS listeners. On the HTTP listener, the main route's backend rule and the redirect's filter both match path `/` → NGF prefers the backend route → redirect ignored.

**Fix**: explicitly set `server.httproute.parentRefs[0].sectionName: https` so the main route only attaches to the HTTPS listener. Conflict resolved.

### 3. Specifying `scopes:` in dex.config gets rejected by Keycloak

**Symptom**: `scopes: [openid, profile, email, groups]` → Keycloak responds `Invalid scopes: openid openid profile email groups` (LOGIN_ERROR).

**Cause 1 (duplicate `openid`)**: dex auto-prepends `openid` to its connector scopes, so a user-specified `openid` becomes a duplicate.

**Cause 2 (unknown `groups`)**: Keycloak realm `example` had no `groups` client-scope defined, so dex's scope request was rejected. (Phase 3 bootstrap created only client-direct mappers, no realm-level client-scope.)

**Fix**: omit the `scopes` block — let dex use its default (`openid profile email`). Pair with the client-scope addition from Step 5 below.

### 4. Keycloak 26.x `oidc-group-membership-mapper` with config `{}` = silent disable

**Symptom**: kcadm reports the mapper was added successfully, but no token (ID token, access token, userinfo) carries the groups claim. Keycloak's `evaluate-scopes/generate-example-id-token` even shows the claim correctly — yet dex receives nothing.

**Cause**: Phase 3 `kcadm-bootstrap.sh` created the mapper via `kcadm.sh create ... -s 'config."key"=value' ...`, but the nested-config syntax dropped silently and the mapper was created with `config: {}`. Keycloak 26.x interprets an empty config as all-fields-false → the mapper injects nothing into any token kind. To compound, kcadm's `--fields config` cannot render dot-keys (`claim.name` etc.), so a correctly-set mapper looks like `{}` in this output too — making it hard to confirm visually.

**Fix**: create the mapper from a JSON file (`-f`) with all six fields explicit: `claim.name, full.path, id.token.claim, access.token.claim, userinfo.token.claim, introspection.token.claim`. Verify with raw GET (don't trust `--fields config`). Both bootstrap and verify scripts now check all six.

### 5. dex `oidc` connector ignores groups claim unless `insecureEnableGroups: true`

**Symptom**: Keycloak token contains `groups: ["server"]`, but dex logs `groups=[]` — dex doesn't forward the groups claim to ArgoCD.

**Cause**: dex `oidc` connector's secure default. From the docs: *"With `insecureEnableGroups: true`, the connector will assume the upstream has returned a list of groups (either through claim or through userinfo) and will pass this group list onto Dex."* → without it, dex discards groups entirely.

**Fix**: add `insecureEnableGroups: true` to the dex.config connector config. (The "insecure" prefix is misleading — it's standard for setups trusting a self-hosted Keycloak.) Pair with `getUserInfo: true` so dex hits the userinfo endpoint as well, which is robust against various mapper config variations.

### Additional verification scenario (proves RBAC enforcement)

When `g, admin@example.com, role:global-admin` and `g, server, role:server-admin` are both active, you cannot tell which match actually applies. Verification procedure:

1. Comment out `g, admin@example.com, role:global-admin` → apply → confirm somaz still operates with server-admin only (proves the server group claim works)
2. Comment out the four `secondary-project/*` permission lines → apply → confirm secondary-project apps disappear from the UI (proves server-admin policy enforcement)
3. Restore both immediately after verification

This cutover ran the procedure above and confirmed end-to-end correctness. **Never commit the temporary policy.csv changes** — restore immediately after apply.
