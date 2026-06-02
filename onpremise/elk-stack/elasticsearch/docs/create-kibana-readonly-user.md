# Kibana / Elasticsearch user creation guide

Operations doc for [`../scripts/create-kibana-readonly-user.sh`](../scripts/create-kibana-readonly-user.sh). PUTs a **user account mapped to an existing role** via the Security API, idempotently. Role creation itself lives in a sibling script — see [create-elastic-role-en.md](create-elastic-role.md). Keeping them split lets a single role back many users (e.g. `viewer`, `qa-viewer`, `pm-viewer` all mapped to `read_only_role`).

> Script name says "readonly-user", but the user can be attached to any existing role via `--role-name`. `read_only_role` is just the default.

<br/>

## What it does

| Step | Action |
|---|---|
| 0 | Pre-flight — `GET /_security/role/<role_name>`. If it returns anything other than 200, abort with a clear message pointing to `create-elastic-role.sh`. |
| 1 | `PUT /_security/user/<username>` — password + roles=[\<role_name\>] (+ optional full_name / email) |
| 2 | `GET /_security/_authenticate` as the new user — verifies auth succeeds and that the assigned role is present |

The PUT is idempotent — re-running with the same arguments overwrites the password / roles.

<br/>

## Prerequisite — the role must exist first

This script does not create roles. Step 0 aborts cleanly when the role is missing:

```
✗ role 'read_only_role' not found — create it first:
    ./create-elastic-role.sh --role-name 'read_only_role' [permission flags] --yes
```

Create the role first via [create-elastic-role-en.md](create-elastic-role.md) and then attach a user with this script.

<br/>

## Usage

```bash
# Show help
./create-kibana-readonly-user.sh -h

# Interactive prompt (safest — password lands nowhere)
./create-kibana-readonly-user.sh -u viewer

# Stdin (CI / wrapper)
echo "$NEW_PASSWORD" | ./create-kibana-readonly-user.sh -u viewer --password-stdin --yes

# Env var (avoids process-list leak)
NEW_PW='...' ./create-kibana-readonly-user.sh -u viewer --password-env NEW_PW --yes

# Direct flag (discouraged — leaks via ps / history)
./create-kibana-readonly-user.sh -u viewer -p 'StrongPassword123!' --yes

# Attach to a different role (must exist first)
./create-elastic-role.sh --role-name pm_viewer --indices 'example-project-*' --yes
./create-kibana-readonly-user.sh -u pm-viewer --role-name pm_viewer

# Validate the call flow without PUT
NEW_PW='...' ./create-kibana-readonly-user.sh -u viewer --password-env NEW_PW --dry-run --yes
```

<br/>

## Flags

| Flag | Description |
|---|---|
| `-u`, `--username NAME` | (required) account name to create / update |
| `-p`, `--password STR` | pass the password directly — visible via ps / history, discouraged |
| `--password-stdin` | read the password from stdin (one line) |
| `--password-env VAR` | read the password from environment variable `VAR` |
| `--role-name NAME` | existing role to attach the user to. Default `read_only_role`. The script aborts in step 0 if the role does not exist |
| `--full-name NAME` | optional account metadata — `full_name` field |
| `--email EMAIL` | optional account metadata — `email` field |
| `--dry-run` | print the payloads (password masked) without contacting ES |
| `--yes` | skip the interactive 'create user' confirmation prompt (CI use) |
| `-h`, `--help` | usage |

> Provide at most one password input flag (none ⇒ prompt). The script aborts when the password is shorter than 8 characters and warns under 12. Backslash / double-quote are auto-escaped for JSON.

<br/>

## Env overrides

```
NAMESPACE_ES=logging
ES_POD=elasticsearch-es-default-0    ES_CONTAINER=elasticsearch
ES_SVC=localhost   ES_PORT=9200   ES_SCHEME=https
ES_SECRET=elasticsearch-es-elastic-user   ES_USER=elastic
```

These defaults live in [`../scripts/lib/es-common.sh`](../scripts/lib/es-common.sh) and are shared across the other scripts in this directory.

<br/>

## Security checklist

This script only creates users — the actual privileges come from the attached role. Role-side guards are documented in [create-elastic-role-en.md](create-elastic-role.md) "Security checklist".

Enforced automatically by this script:
- ✅ Password < 8 chars aborts; 8..11 chars warns
- ✅ Prefer prompt / stdin / env over `-p` to avoid leaking the password to ps / history
- ✅ Step 0 aborts if the role does not exist (no orphaned accounts)

Operator's responsibility:
- 🔒 Prefer prompt / stdin / env over `-p`
- 🔒 Re-running the script for the same username overwrites both password and roles — be deliberate
- 🔒 Disable accounts that are no longer used (below). Disable, not delete, to preserve audit trail

<br/>

## Operations notes

### Password rotation

```bash
echo "$NEW_PASSWORD" | ./create-kibana-readonly-user.sh -u <username> --password-stdin --yes
```

For an existing user, the PUT overwrites the password (and the role). Right after rotation, the old password may still authenticate for a few seconds (ES-cached tokens).

<br/>

### Disable an account (lock instead of delete)

```bash
ADMIN_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ADMIN_PASS" \
    -X PUT 'https://localhost:9200/_security/user/<username>/_disable'
```

Re-enable with the `/_enable` endpoint.

<br/>

### Inspect / verify

```bash
ADMIN_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

# User definition
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ADMIN_PASS" \
    'https://localhost:9200/_security/user/<username>?pretty'

# Verify authentication as the new user
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "<username>:<password>" \
    'https://localhost:9200/_security/_authenticate?pretty'
```

<br/>

## Related documentation

- [create-elastic-role-en.md](create-elastic-role.md) — prerequisite. Role creation, permission flags, security guards.
- [scripts/README-en.md](../scripts/README.md) — directory index.
- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [Elasticsearch Security API — Create or update user](https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-put-user.html)
