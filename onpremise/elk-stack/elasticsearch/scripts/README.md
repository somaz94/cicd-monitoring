# Elasticsearch Operations Scripts

This directory holds shell scripts used for irregular Elasticsearch operations. All scripts follow [shell-script-conventions](../../../../docs/shell-script-conventions.md) (`bash -n` + `zsh -n` + `shellcheck` must all pass).

Detailed per-script operations guides live as KO/EN pairs under [`../docs/`](../docs/).

<br/>

## Scripts

| Script | One-line summary | Guide (KO) | Guide (EN) |
|---|---|---|---|
| [`reset-example-project-cohort.sh`](reset-example-project-cohort.sh) | ES-side reset of the ExampleProject raw + cohort indices (transform stop → cohort DELETE → cohort explicit-mapping PUT → raw DELETE → fluent-bit DaemonSet rollout restart → transform `_reset` → transform start). Arbitrary env prefix (`--env qa\|dev\|stg\|...`). DaemonSet-only after the 2026-05-22 cleanup, cohort mapping PUT added 2026-05-27. | [reset-example-project-cohort.md](../docs/reset-example-project-cohort.md) | [reset-example-project-cohort-en.md](../docs/reset-example-project-cohort.md) |
| [`restart-transform.sh`](restart-transform.sh) | Stop + `_reset` + start a single ES transform (`--stop-only` / `--dry-run` / `-y` / `--yes`). `_reset` clears the in-memory checkpoint + stats so the next start replays the full source. Canonical workflow after a dest-index mapping change. | — (script `-h`) | — |
| [`delete_old_indices.sh`](delete_old_indices.sh) | Delete docs older than the retention window in the named indices, or delete the indices outright; also `total_fields.limit` tuning and a `--status` cluster-wide listing. See `--help`. For the scheduled in-cluster counterpart, see the [`../index-retention/`](../index-retention) CronJob. | — | — |
| [`kibana_saved_objects_migrate.sh`](kibana_saved_objects_migrate.sh) | Export Kibana saved-objects (dashboard / lens / visualization / index-pattern etc.) from SOURCE and import into TARGET. Modes: `--list` / `--export` / `--import` / `--migrate`. SOURCE password auto-fetched. | — | — |

> **The role / user management scripts moved to a shared location.** `create-elastic-role.sh` / `create-kibana-readonly-user.sh` are cluster-agnostic and now live at repo-root [`scripts/elasticsearch/`](../../../../scripts/elasticsearch), shared by both this on-prem component and `elasticsearch-aws`. See that directory's README for usage.

[`lib/es-helpers.sh`](lib/es-helpers.sh) — local helper (`es_curl` + port-forward) sourced by `delete_old_indices.sh` / `kibana_saved_objects_migrate.sh`; they also source repo-root [`scripts/lib/prompts.sh`](../../../../scripts/lib/prompts.sh). Not directly executable.

<br/>

## Quick usage

```bash
# Index reset — ES-side reset (transform stop → cohort DELETE → mapping PUT → raw DELETE → fluent-bit rollout → transform _reset + start)
./reset-example-project-cohort.sh --env qa
#   Details: ../docs/reset-example-project-cohort-en.md
#   If you need to wipe in-flight fluent-bit / fluentd state too, see the
#   "Manual cleanup" section in that doc.

# Restart a single transform (canonical workflow after a mapping change)
./restart-transform.sh dev-example-project-game-user-cohort
#   --stop-only: first step of the DELETE dest + apply.sh --replace workflow
#   --dry-run -y: inspect the planned calls only
```

For role / user creation, use the shared [`scripts/elasticsearch/`](../../../../scripts/elasticsearch) `create-elastic-role.sh` / `create-kibana-readonly-user.sh`.

Each script's `-h` / `--help` exposes the same quick reference.

<br/>

## Validation

Whenever a script in this directory is edited:

```bash
cd observability/logging/elasticsearch/scripts

bash -n reset-example-project-cohort.sh restart-transform.sh delete_old_indices.sh kibana_saved_objects_migrate.sh
zsh  -n reset-example-project-cohort.sh restart-transform.sh delete_old_indices.sh kibana_saved_objects_migrate.sh
shellcheck --severity=error reset-example-project-cohort.sh restart-transform.sh delete_old_indices.sh kibana_saved_objects_migrate.sh lib/es-helpers.sh

# Full repo lint
make -C ../../../.. shell-lint STRICT=1
```

<br/>

## Related documentation

- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../transforms/README-en.md](../transforms/README.md) — cohort transform definitions and the `apply.sh` / `export.sh` guide.
- [../docs/](../docs/) — full Elasticsearch component docs (upgrade / rollback / HA verification + the per-script guides for this directory).
