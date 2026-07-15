# Shared Elasticsearch operations scripts

repo-root `scripts/elasticsearch/` — **cluster-agnostic** Elasticsearch Security API operations scripts, shared by both the on-prem [`observability/logging/elasticsearch`](../../onpremise/elk-stack/elasticsearch) and the AWS [`observability/logging/elasticsearch-aws`](../../observability/logging/elasticsearch-aws) component (both run the same `elasticsearch-eck` OCI chart).

Behavior is driven entirely by `ES_*` env vars, so switching the target `kubectl` context and setting `ES_POD` etc. applies the same script to any ECK cluster. Scripts whose defaults encode a cluster-specific data layout (e.g. the AWS `bootstrap-ilm-template.sh`, tied to the `example-app` index layout) are NOT kept here — they stay in their owning component.

All scripts follow the [shell-script-conventions](../../docs/shell-script-conventions.md) (`bash -n` + `zsh -n` + `shellcheck` all pass).

<br/>

## Scripts

| Script | One-liner | Guide (KO) | Guide (EN) |
|---|---|---|---|
| [`create-elastic-role.sh`](create-elastic-role.sh) | Idempotent role PUT via the Elasticsearch Security API. Read-only by default; flags compose read-write / Kibana-only / index-restricted roles. | [create-elastic-role.md](docs/create-elastic-role.md) | [create-elastic-role-en.md](docs/create-elastic-role.md) |
| [`create-kibana-readonly-user.sh`](create-kibana-readonly-user.sh) | Create / update a user account mapped to an existing role + verify auth. Aborts at step 0 if the role is missing. | [create-kibana-readonly-user.md](docs/create-kibana-readonly-user.md) | [create-kibana-readonly-user-en.md](docs/create-kibana-readonly-user.md) |

[`scripts/lib/es-common.sh`](../lib/es-common.sh) — shared environment defaults + helper functions (`log/ok/warn/err/step`, `load_admin_pass`, `es_call`, `es_status`, `csv_to_json_array`, `json_escape`, `mask_payload`) sourced by both scripts. Not runnable on its own.

<br/>

## Documentation

| Doc | Description |
|---|---|
| [create-elastic-role.md](docs/create-elastic-role.md) (+ [EN](docs/create-elastic-role.md)) | Idempotent role PUT guide (read-only / read-write / Kibana-only / index-restricted patterns). |
| [create-kibana-readonly-user.md](docs/create-kibana-readonly-user.md) (+ [EN](docs/create-kibana-readonly-user.md)) | Guide for creating a user mapped to an existing role + auth verification. |

<br/>

## Quick usage (selecting the target cluster)

Both scripts hit the ES pod of the **current kubectl context** via `es_call` (`kubectl exec ... curl` under the hood). Select the target cluster by switching context + setting `ES_*`.

```bash
# on-prem (dev) cluster
kubectl config use-context <dev-context>
export NAMESPACE_ES=logging
export ES_POD=elasticsearch-es-default-0
export ES_CONTAINER=elasticsearch
export ES_SECRET=elasticsearch-es-elastic-user

# Create a read-only role (default)
./create-elastic-role.sh --yes

# Create a Kibana user mapped to an existing role (default role=read_only_role)
./create-kibana-readonly-user.sh -u viewer

# AWS (EKS) cluster — same scripts, just switch context
kubectl config use-context <eks-context>
ES_POD=<eks-es-pod> ./create-elastic-role.sh --role-name read_only_role --yes
```

Each script's `-h` / `--help` provides the same quick reference.

<br/>

## Validation

Any script change must pass all of:

```bash
cd scripts/elasticsearch

bash -n create-elastic-role.sh create-kibana-readonly-user.sh
zsh  -n create-elastic-role.sh create-kibana-readonly-user.sh
shellcheck --severity=error create-elastic-role.sh create-kibana-readonly-user.sh ../lib/es-common.sh

# repo-wide validation
make -C ../.. shell-lint STRICT=1
```

<br/>

## Related docs

- [shell-script-conventions](../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../lib/es-common.sh](../lib/es-common.sh) — shared ES helper (repo-root shared lib).
- For on-prem-only operations scripts (transform / cohort / index cleanup), see [`observability/logging/elasticsearch/scripts`](../../onpremise/elk-stack/elasticsearch/scripts).
