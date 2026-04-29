# Realm initial setup (example realm)

Phase 3 procedure for creating the **realm + groups + clients + GitLab Identity Provider**. Run after `helmfile apply` once the Keycloak Pod is Ready.

Both the UI and `kcadm.sh` paths are supported. Prefer `kcadm.sh` for repeatability and automation.

<br/>

## Prerequisites

- `helmfile -f helmfile.yaml -e mgmt apply` completed
- Keycloak Pod Ready: `kubectl -n keycloak get pod keycloak-0` → `1/1 Running`
- Initial admin credentials (auto-rendered by the operator on first boot):
  ```bash
  kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d
  kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d
  ```

<br/>

## kcadm.sh-driven path (recommended)

```bash
# When the GitLab IdP step is desired, supply the Application ID + Secret.
export GITLAB_BROKERING_CLIENT_ID=...
export GITLAB_BROKERING_CLIENT_SECRET=...
./scripts/kcadm-bootstrap.sh
```

The script reconciles (idempotent — re-runs safely):
1. **Master-realm permanent admin user** + Cluster Secret `keycloak-master-admin` (default username `admin` / password `exampleAdminPassword`, override with `REAL_ADMIN_USERNAME` / `REAL_ADMIN_PASSWORD`). Recover password later with `kubectl -n keycloak get secret keycloak-master-admin -o jsonpath='{.data.password}' | base64 -d`
2. Realm `example`
3. Groups `server`, `global-admin`
4. Clients `argocd`, `harbor`, `oauth2-proxy`, `vaultwarden` (secrets printed to stdout)
5. Per-client group-membership protocol-mapper (so tokens carry the `groups` claim)
6. **GitLab Identity Provider** — only when `GITLAB_BROKERING_CLIENT_ID` / `_SECRET` env vars are set; otherwise this step is skipped (useful for LDAP-only flows)

Out of scope (do separately):
- Disabling the operator's bootstrap admin (`temp-admin`) — verify login with the permanent admin first, then disable via UI/kcadm in plan v2 Phase 7
- Creating end users (e.g. `admin@example.com`) — they are auto-imported on first GitLab brokered login, or add explicitly via UI
- Realm export → git commit — call `./scripts/realm-export.sh`

Once bootstrap finishes, run the read-only verifier:
```bash
./scripts/kcadm-verify.sh   # exit 0 = all good, 1 = something missing
```

<br/>

## UI path (manual)

### 1. Create realm

1. Log in at `https://auth.example.com` (master-realm admin)
2. Top-left realm dropdown → "Create realm"
3. Realm name `example`, Enabled ON → Save

### 2. Create groups

1. realm `example` → Groups → Create group → `server`
2. Repeat for `global-admin`

### 3. Add user

1. realm `example` → Users → Add user
2. Username `somaz`, Email `admin@example.com`, Email verified ON → Save
3. Credentials → Set password (Temporary OFF)
4. Groups → Join `global-admin`

### 4. Create clients

#### `argocd`
- Client type OpenID Connect, Client ID `argocd`, Client authentication ON
- Standard flow ON, Direct access grants OFF
- Valid redirect URIs: `https://argocd.example.com/auth/callback`, `https://argocd.example.com/api/dex/callback`
- Web origins: `+`
- Save → Credentials tab → copy Client Secret (used in Phase 4 ArgoCD config)

#### `harbor`
- Client ID `harbor`, Standard flow ON
- Valid redirect URIs: `https://harbor.example.com/c/oidc/callback`
- Save → copy Client Secret

#### `oauth2-proxy`
- Client ID `oauth2-proxy`, Standard flow ON, PKCE ON
- Valid redirect URIs: `https://*.example.com/oauth2/callback` (or per-app explicit URIs)
- Save → copy Client Secret

### 5. Group → token claim mapping

To preserve ArgoCD's `g, server, role:server-admin` policy, the access/ID token must carry a `groups` claim. On Keycloak 26.x you need **two mappers in parallel**: a client-direct mapper (covers consumers like Harbor that don't request scopes) and a realm-level `groups` client-scope (covers consumers like dex that request `groups` explicitly).

#### 5-1. Realm-level `groups` client-scope (UI)

1. realm `example` → Client scopes → **Create client scope**
   - Name `groups`, Type Default, Protocol openid-connect
   - `display.on.consent.screen`: ON, `include.in.token.scope`: ON
2. The new `groups` scope → Mappers tab → Add mapper → By configuration → **Group Membership**
   - Name `groups`, Token Claim Name `groups`, Full group path OFF
   - Add to ID token ON, Add to access token ON, Add to userinfo ON, Add to introspection ON ✱
3. For each client (argocd, harbor, oauth2-proxy, vaultwarden) → Client scopes tab → Add client scope → pick `groups` → **Default** (not Optional)

#### 5-2. Client-direct mapper (per client)

1. Each client → Client scopes → Dedicated scope (`<client>-dedicated`) → Add mapper → **Group Membership**
2. **All six fields must be explicit** ✱:
   - Name `groups`
   - Token Claim Name `groups`
   - Full group path OFF (`full.path: false`)
   - Add to ID token ON (`id.token.claim: true`)
   - Add to access token ON (`access.token.claim: true`)
   - Add to userinfo ON (`userinfo.token.claim: true`)
   - Add to token introspection ON (`introspection.token.claim: true`)

#### 5-3. ✱ Why all six fields (Keycloak 26.x silent-disable trap)

When creating mappers via kcadm/Admin API, omitting fields creates a mapper with `config: {}`. **Keycloak 26.x interprets an empty config as all-fields-false** → the mapper injects nothing into any token kind (silent fail).

- kcadm's `--fields config` cannot render dot-keys (`claim.name`, etc.), so even a correctly-configured mapper looks like `{}` in this output — making visual inspection misleading.
- Recommended: create mappers via JSON file (`-f`) and verify with raw GET (don't trust `--fields config`).
- Automation: [scripts/kcadm-bootstrap.sh](../scripts/kcadm-bootstrap.sh) (idempotent) + [scripts/kcadm-verify.sh](../scripts/kcadm-verify.sh) (38 checks including all six fields).

<br/>

## Verification

```bash
curl -s -X POST https://auth.example.com/realms/example/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=admin-cli \
  -d username=somaz \
  -d password=<temp password>

# Decode the access_token at jwt.io → expect "groups": ["global-admin"]
```

<br/>

## Next steps

- [gitlab-brokering-en.md](gitlab-brokering-en.md) — Add GitLab Identity Provider (existing GitLab accounts as login source)
- [argocd-migration-en.md](argocd-migration-en.md) — ArgoCD dex connector → Keycloak OIDC (Phase 4)
- [harbor-migration-en.md](harbor-migration-en.md) — Harbor OIDC endpoint → Keycloak (Phase 5)

<br/>

## Realm export (declarative GitOps)

After UI/kcadm setup, capture the realm declaratively:

```bash
./scripts/realm-export.sh                                    # writes manifests/realm-example.json
git add manifests/realm-example.json && git commit -m "feat(keycloak): export example realm"

helmfile -f helmfile.yaml -e mgmt apply \
  --set realmImport.enabled=true \
  --set-file realmImport.realm=manifests/realm-example.json
```

> The export includes client secrets — be aware when committing to git (private repo, but rotation requires git history rewrite).
