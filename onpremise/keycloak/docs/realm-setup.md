# Realm initial setup (example realm)

Phase 3 procedure for creating the **realm + groups + clients + GitLab Identity Provider**. Run after `helmfile apply` once the Keycloak Pod is Ready.

Both the UI and `kcadm.sh` paths are supported. Prefer `kcadm.sh` for repeatability and automation.

<br/>

## Prerequisites

- `helmfile -f helmfile.yaml -e dev apply` completed
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
3. Groups — GitLab-mapped `server`, `client`, `gamedesign` (each with its IdP group mapper) plus manually-managed `global-admin` (override via `GITLAB_MAPPED_GROUPS` / `MANUAL_GROUPS`)
4. Clients `argocd`, `harbor`, `vaultwarden`, `example-hub`, `grafana` (secrets masked by default — set `SHOW_CLIENT_SECRETS=1` to print)
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

### Minimal modes (one object, no full re-run)

A full run also re-reconciles the master admin password, so use a minimal mode when touching one thing.

```bash
./scripts/kcadm-bootstrap.sh --client grafana        # upsert one client
./scripts/kcadm-bootstrap.sh --group gamedesign      # create one group + its IdP mapper
./scripts/kcadm-bootstrap.sh --delete-group qa       # delete a group + its IdP mapper
```

`--group` only accepts names in `GITLAB_MAPPED_GROUPS` — a mapper created for a name outside that list would never be reconciled by a later full run, so the two paths would drift immediately.

`--delete-group` does the reverse: it **refuses a name still in the declared lists.** A full run would recreate it via `ensure_group`, so the deletion would not stick — remove it from `GITLAB_MAPPED_GROUPS` / `MANUAL_GROUPS` first. When the group has members it names who would lose access and requires `DELETE_GROUP_CONFIRM=1`.

> ℹ️ The keycloak-ops console enforces the same rules (`SCRIPT_MANAGED_GROUPS` / `PROTECTED_GROUPS`). Keep the lists in step so both paths reach the same verdict.

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
2. Username `admin`, Email `admin@example.com`, Email verified ON → Save
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

> **Do not create `oauth2-proxy`.** The first revision of this document (2026-04) walked through
> creating it and the client was in fact created, but oauth2-proxy itself was never deployed — there
> is no workload, no chart and no Secret. An unused confidential client holding the broadest redirect
> in the realm (`https://*.example.com/oauth2/callback`) was cleaned up in 2026-08. If it is ever
> actually deployed, restore this step and `CANONICAL_CLIENTS` in `kcadm-bootstrap.sh` in that
> same commit.

### 5. Group → token claim mapping

To preserve ArgoCD's `g, server, role:server-admin` policy, the access/ID token must carry a `groups` claim. On Keycloak 26.x you need **two mappers in parallel**: a client-direct mapper (covers consumers like Harbor that don't request scopes) and a realm-level `groups` client-scope (covers consumers like dex that request `groups` explicitly).

#### 5-1. Realm-level `groups` client-scope (UI)

1. realm `example` → Client scopes → **Create client scope**
   - Name `groups`, Type Default, Protocol openid-connect
   - `display.on.consent.screen`: ON, `include.in.token.scope`: ON
2. The new `groups` scope → Mappers tab → Add mapper → By configuration → **Group Membership**
   - Name `groups`, Token Claim Name `groups`, Full group path OFF
   - Add to ID token ON, Add to access token ON, Add to userinfo ON, Add to introspection ON ✱
3. For each client (argocd, harbor, vaultwarden, example-hub) → Client scopes tab → Add client scope → pick `groups` → **Default** (not Optional)

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
- Automation: [scripts/kcadm-bootstrap.sh](../scripts/kcadm-bootstrap.sh) (idempotent) + [scripts/kcadm-verify.sh](../scripts/kcadm-verify.sh) (covers all six fields; the script prints its own pass count as `Result: N passed`, which grows as `VERIFY_CLIENTS` / `GITLAB_MAPPED_GROUPS` grow).

<br/>

## Verification

```bash
curl -s -X POST https://auth.example.com/realms/example/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=admin-cli \
  -d username=admin \
  -d password=<temp password>

# Decode the access_token at jwt.io → expect "groups": ["global-admin"]
```

<br/>

## Next steps

- [gitlab-brokering-en.md](gitlab-brokering.md) — Add GitLab Identity Provider (existing GitLab accounts as login source)
- [harbor-migration-en.md](harbor-migration.md) — Harbor OIDC endpoint → Keycloak (Phase 4)
- [argocd-migration-en.md](argocd-migration.md) — ArgoCD dex connector → Keycloak OIDC (Phase 6)

<br/>

## Realm export (declarative GitOps)

After UI/kcadm setup, capture the realm declaratively:

```bash
./scripts/realm-export.sh                                    # writes manifests/realm-example.json
git add manifests/realm-example.json && git commit -m "feat(keycloak): export example realm"

helmfile -f helmfile.yaml -e dev apply \
  --set realmImport.enabled=true \
  --set-file realmImport.realm=manifests/realm-example.json
```

> The export includes client secrets — be aware when committing to git (private repo, but rotation requires git history rewrite).
