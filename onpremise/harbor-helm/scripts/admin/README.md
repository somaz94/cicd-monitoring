# Harbor Admin Helper

CLI script for managing Harbor users, project members, and OIDC group mappings.
Uses the Harbor v2.0 REST API, tailored for the example.com self-signed HTTPS setup.

한국어 버전: [`harbor-admin.sh`](./harbor-admin.sh) / [README.md](./README.md)

<br/>

## Directory Layout

```
cicd/harbor-helm/scripts/admin/
├── harbor-admin.sh          # Korean UI (default)
├── harbor-admin-en.sh       # English UI
├── README.md
└── README-en.md             # This file
```

Dependencies: `curl`, `python3` (stdlib only)

<br/>

## Usage

```bash
./harbor-admin-en.sh <command> [args...]
```

### User management

| Command | Description |
| --- | --- |
| `whoami` | Show the calling principal (admin sanity check) |
| `users` | List all users |
| `user-info <user\|email>` | Show user details |
| `promote <user\|email>` | Promote to sysadmin |
| `demote <user\|email>` | Demote from sysadmin |

### Project / membership

| Command | Description |
| --- | --- |
| `projects` | List projects |
| `project-members <project>` | List project members |
| `add-member <project> <target> <role>` | Add a member (see below) |
| `remove-member <project> <user\|mid>` | Remove a member |

**Target**: `username`, `email`, or `group:<oidc-group-name>`
**Role**: `project-admin`, `maintainer`, `developer`, `guest`, `limited-guest`

### OIDC groups

| Command | Description |
| --- | --- |
| `groups` | List user groups (LDAP/HTTP/OIDC) |
| `add-group <oidc-group-name>` | Register an OIDC group (type=3). Usually unnecessary — `add-member` registers groups lazily |

### OIDC config update

| Command | Description |
| --- | --- |
| `set-oidc --name N --endpoint E --client-id ID --client-secret S [opts]` | PUT OIDC settings. `--dry-run` previews the body, `-y`/`--no-confirm` skips the prompt |

**Optional flags**: `--verify-cert true\|false` (auto-true on https), `--groups-claim`, `--group-filter`, `--user-claim`, `--admin-group`, `--scope`, `--auto-onboard true\|false`
**Secret env alternative**: `HARBOR_OIDC_CLIENT_SECRET` env var replaces `--client-secret` (avoids shell history exposure)

```bash
# Switch to Keycloak (Phase 4 standard)
HARBOR_OIDC_CLIENT_SECRET='<harbor client secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name Keycloak \
    --endpoint https://auth.example.com/realms/example \
    --client-id harbor \
    --dry-run            # preview the PUT body first
# If OK, drop --dry-run (or add -y for non-interactive)

# Rollback to GitLab-direct
HARBOR_OIDC_CLIENT_SECRET='<gitlab application secret>' \
  ./harbor-admin-en.sh set-oidc \
    --name GitLab \
    --endpoint http://gitlab.example.com \
    --client-id '<gitlab application id>' \
    --verify-cert false
```

> Detailed procedure + user impact: [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../../../cicd/harbor-helm/docs/oidc-setup-keycloak-en.md), [Phase 4 migration](../../../security/keycloak/docs/harbor-migration-en.md)

### Diagnostics

| Command | Description |
| --- | --- |
| `config` | Dump OIDC-related configuration (secret excluded) |
| `systeminfo` | Public systeminfo (auth_mode etc., no auth required) |

<br/>

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `HARBOR_URL` | `https://harbor.example.com` | Harbor base URL |
| `HARBOR_IP` | `192.168.1.55` | Target IP for `--resolve` (ingress LoadBalancer) |
| `HARBOR_ADMIN` | `admin` | Admin username |
| `HARBOR_ADMIN_PASSWORD` | Auto-extracted from `../../../cicd/harbor-helm/values/dev.yaml` (`harborAdminPassword`) | Admin password |
| `HARBOR_OIDC_CLIENT_SECRET` | unset | Env replacement for `set-oidc --client-secret` (avoids CLI history exposure) |
| `HARBOR_NO_RESOLVE` | unset | Set to `1` to use OS DNS instead of `--resolve` |

<br/>

## Examples

```bash
# 1) List current users
./harbor-admin-en.sh users

# 2) Promote somaz to sysadmin (user must have logged in via OIDC at least once)
./harbor-admin-en.sh promote admin@example.com

# 3) Map GitLab 'server' group to 'library' project as developer
./harbor-admin-en.sh add-member library group:server developer

# 4) Add an individual user as maintainer of 'example-project'
./harbor-admin-en.sh add-member example-project admin@example.com maintainer

# 5) Verify OIDC configuration was injected correctly
./harbor-admin-en.sh config

# 6) Target a different admin account / different harbor instance
HARBOR_ADMIN_PASSWORD="xxx" HARBOR_URL="https://harbor.example.com" HARBOR_NO_RESOLVE=1 \
  ./harbor-admin-en.sh users
```

<br/>

## Caveats

- When using `demote` to strip admin, avoid demoting yourself (keep at least one other sysadmin)
- `auth_mode` changes are intentionally NOT exposed in this script — it is irreversible. Follow the manual procedure in [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../../../cicd/harbor-helm/docs/oidc-setup-keycloak-en.md)
- Harbor versions before 2.7 do not support `oidc_group_filter` — rely purely on per-project group role grants via `groups` in that case

<br/>

## Related Docs

- Harbor OIDC setup: [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../../../cicd/harbor-helm/docs/oidc-setup-keycloak-en.md)
- Harbor HTTPS setup: [`cicd/harbor-helm/docs/tls-setup-en.md`](../../../cicd/harbor-helm/docs/tls-setup-en.md)
- Harbor API reference: `https://harbor.example.com/devcenter-api-2.0`
