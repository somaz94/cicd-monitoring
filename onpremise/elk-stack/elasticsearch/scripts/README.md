# Elasticsearch Operations Scripts

This directory holds shell scripts used for irregular Elasticsearch operations. All scripts follow [shell-script-conventions](../../../../docs/shell-script-conventions.md) (`bash -n` + `zsh -n` + `shellcheck` must all pass).

Detailed per-script operations guides live as KO/EN pairs under [`../docs/`](../docs/).

<br/>

## Scripts

| Script | One-line summary | Guide (KO) | Guide (EN) |
|---|---|---|---|
| [`reset-example-project-cohort.sh`](reset-example-project-cohort.sh) | ES-side reset of the ExampleProject raw + cohort indices (transform stop → cohort/raw DELETE → fluent-bit DaemonSet rollout restart → transform start). Arbitrary env prefix (`--env qa\|dev\|stg\|...`). DaemonSet-only after the 2026-05-22 cleanup. | [reset-example-project-cohort.md](../docs/reset-example-project-cohort.md) | [reset-example-project-cohort-en.md](../docs/reset-example-project-cohort-en.md) |
| [`create-elastic-role.sh`](create-elastic-role.sh) | Idempotent `PUT /_security/role/<name>` via the Security API. Defaults compose a read-only role; flags switch to read-write / Kibana-only / index-restricted variants. | [create-elastic-role.md](../docs/create-elastic-role.md) | [create-elastic-role-en.md](../docs/create-elastic-role-en.md) |
| [`create-kibana-readonly-user.sh`](create-kibana-readonly-user.sh) | Create / update a user mapped to an existing role + verify authentication. Aborts in step 0 when the role is missing. | [create-kibana-readonly-user.md](../docs/create-kibana-readonly-user.md) | [create-kibana-readonly-user-en.md](../docs/create-kibana-readonly-user-en.md) |
| [`delete_old_indices.sh`](delete_old_indices.sh) (+ [`-en`](delete_old_indices-en.sh)) | Delete docs older than the retention window in the named indices, or delete the indices outright; also `total_fields.limit` tuning and a `--status` cluster-wide listing. See `--help`. | — | — |
| [`kibana_saved_objects_migrate.sh`](kibana_saved_objects_migrate.sh) (+ [`-en`](kibana_saved_objects_migrate-en.sh)) | Export Kibana saved-objects (dashboard

[`lib/es-common.sh`](lib/es-common.sh) — shared environment defaults + helper functions (`log/ok/warn/err/step`, `load_admin_pass`, `es_call`, `es_status`, `csv_to_json_array`, `json_escape`, `mask_payload`) sourced by the newer scripts. Not directly executable.

<br/>

## Quick usage

```bash
# Index reset — ES-side reset (transform stop → DELETE → fluent-bit rollout → transform start)
./reset-example-project-cohort.sh --env qa
#   Details: ../docs/reset-example-project-cohort-en.md
#   If you need to wipe in-flight fluent-bit / fluentd state too, see the
#   "Manual cleanup" section in that doc.

# Create a read-only role (default)
./create-elastic-role.sh --yes
#   Details: ../docs/create-elastic-role-en.md

# Create a Kibana user account (interactive prompt, default role=read_only_role)
./create-kibana-readonly-user.sh -u viewer
#   Details: ../docs/create-kibana-readonly-user-en.md
```

Each script's `-h` / `--help` exposes the same quick reference.

<br/>

## Shared configuration (`lib/es-common.sh`)

The two newer scripts (`create-elastic-role.sh`, `create-kibana-readonly-user.sh`) source the same lib. Set the env once and both scripts target the same cluster / pod:

```bash
export NAMESPACE_ES=logging
export ES_POD=elasticsearch-es-default-0
export ES_CONTAINER=elasticsearch
export ES_SECRET=elasticsearch-es-elastic-user

./create-elastic-role.sh --role-name pm_viewer --indices 'example-project-*' --yes
./create-kibana-readonly-user.sh -u pm-viewer --role-name pm_viewer
```

`reset-example-project-cohort.sh` is not yet lib-ified — it uses the same env-var names but does not source the lib (follow-up).

<br/>

## Validation

Whenever a script in this directory is edited:

```bash
cd observability/logging/elasticsearch/scripts

bash -n reset-example-project-cohort.sh create-elastic-role.sh create-kibana-readonly-user.sh
zsh  -n reset-example-project-cohort.sh create-elastic-role.sh create-kibana-readonly-user.sh
shellcheck --severity=error reset-example-project-cohort.sh create-elastic-role.sh create-kibana-readonly-user.sh lib/es-common.sh

# Full repo lint
make -C ../../../.. shell-lint STRICT=1
```

<br/>

## Related documentation

- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../transforms/README-en.md](../transforms/README-en.md) — cohort transform definitions and the `apply.sh` / `export.sh` guide.
- [../docs/](../docs/) — full Elasticsearch component docs (upgrade / rollback / HA verification + the per-script guides for this directory).
