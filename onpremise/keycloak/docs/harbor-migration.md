# Harbor OIDC → Keycloak migration (Phase 4, 2026-04-28)

> **Plan order**: Plan v2 had this as Phase 5; user moved it forward to **Phase 4** (Harbor before ArgoCD).
> **Status**: 2026-04-28 — procedure finalized. Cluster apply pending user approval.

Switches the Harbor OIDC IdP from GitLab to Keycloak. **Harbor's OIDC settings live in the UI/API, not in Helm values**, so chart changes are limited to comments/docs; only runtime cluster reconfiguration is required.

The OIDC `sub` of existing users changes — they re-onboard as new accounts, requiring sysadmin re-promotion and (where applicable) project membership re-mapping.

<br/>

## Prerequisites (all complete)

- ✅ Phase 2: Keycloak + PostgreSQL running, `auth.example.com` returns HTTP/2 200
- ✅ Phase 3: realm `example` + client `harbor` (Standard Flow + PKCE) + groups mapper + GitLab IdP brokering
- ✅ Harbor already at `auth_mode = oidc_auth` (flipped during the GitLab-direct era) — no extra flip needed
- ✅ Harbor `harbor` client secret captured: Phase 3 output (`<HARBOR_OIDC_CLIENT_SECRET>` — or re-fetch via the kcadm procedure in [`docs/oidc-setup-keycloak-en.md` §2](../../harbor-helm/docs/oidc-setup-keycloak.md#2-retrieve-client-secret))
- ✅ Harbor admin access (DB password = `harborAdminPassword` in [`cicd/harbor-helm/values/dev.yaml`](../../harbor-helm/values/dev.yaml))

<br/>

## User impact (current inventory)

From `cicd/harbor-helm/scripts/admin/harbor-admin-en.sh users / projects / project-members`:

| Item | Value | Impact |
| --- | --- | --- |
| Existing OIDC user | `admin@example.com` (1 user, sysadmin=True) | Re-onboards as a new user → **manual sysadmin re-promotion required** |
| OIDC group `server` | Registered (id=1, type=OIDC) | Not bound to any project → no impact |
| Project members (`library`, `example-project`, `secondary-project`) | Only `admin` (Harbor's built-in admin) | No OIDC users mapped → no re-mapping work |
| Downtime | ~1s after the `set-oidc` PUT (cache refresh) | Effectively zero |

→ User impact in this cluster is minimal: somaz logs in once and gets re-promoted. Done.

<br/>

## Procedure

> All cluster mutations require user approval before execution.

### Step 1. Snapshot pre-migration state (read-only)

```bash
cd kuberntes-infra/cicd/harbor-helm/scripts/admin

./harbor-admin-en.sh config        > /tmp/harbor-pre-phase4-config.txt
./harbor-admin-en.sh users         > /tmp/harbor-pre-phase4-users.txt
./harbor-admin-en.sh groups        > /tmp/harbor-pre-phase4-groups.txt
for p in library example-project secondary-project; do
  echo "=== $p ==="
  ./harbor-admin-en.sh project-members "$p"
done > /tmp/harbor-pre-phase4-members.txt

mkdir -p ~/harbor-backup-phase4
cp /tmp/harbor-pre-phase4-*.txt ~/harbor-backup-phase4/
```

### Step 2. (Optional) Pre-flight on the Keycloak side

```bash
cd kuberntes-infra/security/keycloak
./scripts/kcadm-verify.sh

curl -s https://auth.example.com/realms/example/.well-known/openid-configuration \
  | python3 -m json.tool | grep -E 'issuer|authorization_endpoint|token_endpoint'
```

### Step 3. Dry-run the PUT body

```bash
cd kuberntes-infra/cicd/harbor-helm/scripts/admin

# Pass secret via env var (no shell history)
# ⚠️ This cluster uses a self-signed wildcard cert → must pass --verify-cert false
HARBOR_OIDC_CLIENT_SECRET='<HARBOR_OIDC_CLIENT_SECRET>' \
  ./harbor-admin-en.sh set-oidc \
    --name Keycloak \
    --endpoint https://auth.example.com/realms/example \
    --client-id harbor \
    --verify-cert false \
    --dry-run
```

Review the printed body (secret masked). Confirm the policy fields: `oidc_admin_group=""`, `oidc_group_filter=server`, `oidc_verify_cert=false`.

> Without `--verify-cert`, set-oidc auto-derives `true` from the https scheme — Harbor pod cannot trust the self-signed cert, producing `tls: failed to verify certificate: x509: certificate signed by unknown authority` + `internal server error` during browser login. Switch back to `true` once cert-manager / a trusted CA is adopted.

### Step 4. Apply (real PUT) — user approval required

```bash
HARBOR_OIDC_CLIENT_SECRET='<HARBOR_OIDC_CLIENT_SECRET>' \
  ./harbor-admin-en.sh set-oidc \
    --name Keycloak \
    --endpoint https://auth.example.com/realms/example \
    --client-id harbor \
    --verify-cert false
# → interactive confirm: y
```

### Step 5. Verify

```bash
./harbor-admin-en.sh config
# Expected:
#   oidc_name              = Keycloak
#   oidc_endpoint          = https://auth.example.com/realms/example
#   oidc_client_id         = harbor...
#   oidc_groups_claim      = groups
#   oidc_group_filter      = server
#   oidc_verify_cert       = True
#   oidc_auto_onboard      = True
#   oidc_admin_group       = (empty)
```

### Step 6. Browser login check (user)

1. Open `https://harbor.example.com` in a fresh incognito window
2. Confirm the **`LOGIN VIA OIDC PROVIDER Keycloak`** button on the login page
3. Click → Keycloak page → **Sign in with GitLab** → log in & authorize
4. Redirected back to Keycloak → Harbor home → new user auto-onboarded

### Step 7. Handle the legacy user

For this environment (1 user, yourself) the simpler **Option B (re-join)** is sufficient:

```bash
cd kuberntes-infra/cicd/harbor-helm/scripts/admin

# 7-1. Confirm new user appears (after Step 6's first login)
./harbor-admin-en.sh users
# Expect: a new user alongside the legacy 'somaz' (id=3)

# 7-2. Promote the new user to sysadmin
./harbor-admin-en.sh promote admin@example.com
# If two users share the email, target by username (e.g. 'somaz2') or new user_id

# 7-3. Verify
./harbor-admin-en.sh user-info admin@example.com
./harbor-admin-en.sh whoami    # always shows admin (call is by admin)

# 7-4. (Optional) Disable the old GitLab-OIDC user
./harbor-admin-en.sh demote <legacy-username-or-email>   # revoke admin only
# Or delete via Web UI Users → Delete (full removal)
```

> **Option A (direct DB rewrite) for environments with many users**: bulk-update `oidc_user_meta.subiss` to the new issuer to preserve users + memberships.
> ```sql
> UPDATE harbor_user
>    SET oidc_user_meta = jsonb_set(
>        oidc_user_meta::jsonb, '{subiss}',
>        '"https://auth.example.com/realms/example"')
>  WHERE oidc_user_meta IS NOT NULL;
> ```
> This cluster has 1 user, so Option A is unnecessary.

<br/>

## Verification checklist

- [ ] `./harbor-admin-en.sh config` shows the Keycloak endpoint
- [ ] `./harbor-admin-en.sh systeminfo \| grep auth_mode` still `oidc_auth`
- [ ] Incognito browser shows `LOGIN VIA OIDC PROVIDER Keycloak`
- [ ] Click redirects to Keycloak, which shows `Sign in with GitLab`
- [ ] GitLab login completes, returns to Harbor home
- [ ] `./harbor-admin-en.sh users` lists a new user
- [ ] After `promote` the new user has `sysadmin_flag=True`
- [ ] `harbor login harbor.example.com` (Docker / podman OIDC token auth) works
- [ ] A non-`server` GitLab user attempting login → no Harbor user created (group filter works)

<br/>

## Rollback

Reverting to GitLab is one `set-oidc` call (no helm change):

```bash
cd kuberntes-infra/cicd/harbor-helm/scripts/admin

# GitLab Application creds (recover from admin/Applications)
HARBOR_OIDC_CLIENT_SECRET='<gitlab application secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name GitLab \
    --endpoint http://gitlab.example.com \
    --client-id '<gitlab application id>' \
    --verify-cert false
```

Rollback flips the OIDC `sub` back to GitLab basis → re-run Step 7 to clean users.

<br/>

## Follow-ups (after Phase 4)

- ✅ [`cicd/harbor-helm/values/dev.yaml`](../../harbor-helm/values/dev.yaml) SSO comment block rewritten for Keycloak (GitLab procedure preserved as a commented rollback section)
- ✅ [`cicd/harbor-helm/docs/oidc-setup-keycloak.md`](../../harbor-helm/docs/oidc-setup-keycloak.md) + [`oidc-setup-keycloak-en.md`](../../harbor-helm/docs/oidc-setup-keycloak.md) rewritten for Keycloak (full legacy GitLab procedure preserved at [`docs/legacy/oidc-setup-gitlab-en.md`](../../harbor-helm/docs/legacy/oidc-setup-gitlab.md))
- ✅ [`cicd/harbor-helm/scripts/admin/harbor-admin.sh`](../../harbor-helm/scripts/admin/harbor-admin.sh) gained the `set-oidc` command
- ⏳ Phase 8: decide whether to remove the legacy GitLab `Harbor` Application — keep through Phase 5/6 in case rollback is needed, then prune

<br/>

## References

- [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../../harbor-helm/docs/oidc-setup-keycloak.md) — Keycloak OIDC standard procedure (§7 rollback + legacy full link)
- [`cicd/harbor-helm/scripts/admin/README-en.md`](../../harbor-helm/scripts/admin/README.md) — `harbor-admin-en.sh` command reference (incl. `set-oidc`)
- [Phase 5 vaultwarden migration](./vaultwarden-migration.md), [Phase 6 ArgoCD migration](./argocd-migration.md) — follow-up phases
- [architecture-en.md](./architecture.md) — auth flow & user impact summary
