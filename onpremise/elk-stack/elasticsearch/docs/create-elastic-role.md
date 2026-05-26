# Elasticsearch role creation guide

Operations doc for [`../scripts/create-elastic-role.sh`](../scripts/create-elastic-role.sh). Idempotent `PUT /_security/role/<name>` via the Elasticsearch Security API. Defaults compose a safe read-only role, but flags let the same script handle read-write / Kibana-only / index-restricted / Dev-Tools-included roles too.

<br/>

## What it does

| Step | Action |
|---|---|
| 1 | `PUT /_security/role/<role_name>` — cluster / indices / applications privileges assembled from the flags |

The PUT returns `"created":true` (new) or `"role":{...}` (update); the script asserts one of those before declaring success.

<br/>

## Permission model

The payload the script PUTs:

```json
{
  "cluster":      ["monitor"],
  "indices":      [{ "names": ["*"], "privileges": ["read", "view_index_metadata"] }],
  "applications": [{ "application": "kibana-.kibana", "privileges": ["read"], "resources": ["*"] }]
}
```

Each section is opt-out — set the corresponding flag to `''` (empty string) to drop the whole section. If all three end up empty the script aborts.

| Section | Flag | Default | Opt-out |
|---|---|---|---|
| Cluster privileges | `--cluster PRIV[,PRIV]` | `monitor` | `--cluster ''` |
| Index patterns | `--indices PAT[,PAT2...]` | `*` | `--indices ''` (drops the whole `indices` block) |
| Index privileges | `--index-privileges PRIV[,PRIV]` | `read,view_index_metadata` | (cleaner to drop the whole `indices` block) |
| Kibana application | `--kibana-application NAME` | `kibana-.kibana` | `--kibana-application ''` (drops the whole `applications` block) |
| Kibana privileges | `--kibana-privileges PRIV[,PRIV]` | `read` | (cleaner to drop the whole `applications` block) |
| Kibana resources | `--kibana-resources RES[,RES...]` | `*` (all spaces) | `space:<id>` for a specific space |

<br/>

## Usage

```bash
# Show help
./create-elastic-role.sh -h

# === Default — read_only_role over all indices ===
./create-elastic-role.sh --yes

# === Restrict to a specific index family ===
./create-elastic-role.sh \
  --role-name pm_viewer \
  --indices 'example-project-*,dev-example-project-game*,qa-example-project-game*' \
  --yes

# === Read-write role ===
./create-elastic-role.sh \
  --role-name dev_writer \
  --indices 'dev-*' \
  --index-privileges 'read,write,create,create_index,view_index_metadata' \
  --kibana-privileges all \
  --yes

# === Include Dev Tools (admin-grade) — be deliberate ===
./create-elastic-role.sh \
  --role-name kibana_power_user \
  --kibana-privileges all \
  --yes

# === Kibana-only role (no ES indices privileges) ===
./create-elastic-role.sh \
  --role-name kibana_only \
  --indices '' \
  --kibana-privileges read \
  --yes

# === ES-only role (no Kibana access) ===
./create-elastic-role.sh \
  --role-name es_search \
  --kibana-application '' \
  --yes

# === Dry-run ===
./create-elastic-role.sh --role-name foo --dry-run --yes
```

<br/>

## Flags

| Flag | Description |
|---|---|
| `--role-name NAME` | role name. Default `read_only_role` |
| `--cluster PRIV[,PRIV]` | comma-separated cluster privileges. Default `monitor`. `''` removes the block |
| `--indices PAT[,PAT2...]` | comma-separated index patterns. Default `*`. `''` removes the indices block |
| `--index-privileges PRIV[,PRIV]` | comma-separated index privileges. Default `read,view_index_metadata` |
| `--kibana-application NAME` | Kibana application. Default `kibana-.kibana`. `''` removes the applications block |
| `--kibana-privileges PRIV[,PRIV]` | comma-separated Kibana privileges. Default `read`. Other values: `all`, `read_dashboard`, `feature_discover.read`, ... |
| `--kibana-resources RES[,RES...]` | Kibana resources. Default `*` (all spaces) |
| `--dry-run` | print the payload without contacting ES |
| `--yes` | skip the interactive prompt (CI use) |
| `-h`, `--help` | usage |

<br/>

## Env overrides

```
NAMESPACE_ES=logging
ES_POD=elasticsearch-es-default-0    ES_CONTAINER=elasticsearch
ES_SVC=localhost   ES_PORT=9200   ES_SCHEME=https
ES_SECRET=elasticsearch-es-elastic-user   ES_USER=elastic
```

These defaults are defined in [`../scripts/lib/es-common.sh`](../scripts/lib/es-common.sh) and shared across the other scripts in this directory.

<br/>

## Security checklist

With defaults the safe read-only profile is guaranteed:

- ✅ Cluster privilege is `monitor` only — never `all`
- ✅ Indices privileges are `read` + `view_index_metadata` only — no write / delete
- ✅ Kibana privilege is application-level `read` — Dev Tools / Management are excluded by design (Dev Tools' Console would let the user run arbitrary ES queries, effectively bypassing the read-only intent)

When you widen privileges via flags:

- 🔒 `--kibana-privileges all` grants Dev Tools and Stack Management — admin-grade. Only for users who truly need it
- 🔒 Once `--index-privileges` includes `write`, `delete`, or `manage`, the role is no longer read-only — rename it accordingly (`*_writer`, `*_admin`)
- 🔒 Field-level masking is out of scope here — layer it with a separate PUT that adds `field_security.grant: [...], except: [...]` to the role definition
- 🔒 Document-level security (DLS, Platinum license) likewise gets a separate PUT

<br/>

## Operations notes

### Inspect a role

```bash
ADMIN_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ADMIN_PASS" \
    'https://localhost:9200/_security/role/read_only_role?pretty'
```

<br/>

### Delete a role

```bash
ADMIN_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ADMIN_PASS" \
    -X DELETE 'https://localhost:9200/_security/role/<role_name>'
```

> Users that still reference the deleted role will fail authorization on their next request. Reassign or remove those users first.

<br/>

### Layer on field masking (optional)

```bash
ADMIN_PASS=$(kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging exec -i elasticsearch-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ADMIN_PASS" -H 'Content-Type: application/json' \
    -X PUT 'https://localhost:9200/_security/role/pm_viewer' --data-binary @- <<'EOF'
{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["example-project-*"],
      "privileges": ["read", "view_index_metadata"],
      "field_security": {
        "grant": ["*"],
        "except": ["password", "token", "secret"]
      }
    }
  ],
  "applications": [
    { "application": "kibana-.kibana", "privileges": ["read"], "resources": ["*"] }
  ]
}
EOF
```

<br/>

## Related documentation

- [create-kibana-readonly-user-en.md](create-kibana-readonly-user-en.md) — guide for attaching a role made by this script to a user account.
- [scripts/README-en.md](../scripts/README-en.md) — directory index.
- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [Elasticsearch Security API — Create or update role](https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-put-role.html)
- [Kibana — Built-in role privileges](https://www.elastic.co/guide/en/kibana/current/kibana-privileges.html)
