# Elasticsearch Operations Scripts

This directory holds shell scripts used for irregular Elasticsearch operations. All scripts follow [shell-script-conventions](../../../../docs/shell-script-conventions.md) (`bash -n` + `zsh -n` + `shellcheck` must all pass).

Detailed per-script operations guides live as KO/EN pairs under [`../docs/`](../docs/).

> 🔴 **Every script here requires `--context CTX`.** (`kibana_saved_objects_migrate.sh` is the one exception: it only needs the flag when it has to auto-fetch the SOURCE password from a secret, i.e. when `--source-password` is not given.)
>
> None of them falls back to the current kubectl context, and the flag is enforced for `--dry-run` and for read-only actions such as `--list` too. A missing or unknown context exits `2` and prints the available contexts.
>
> ⚠️ The `onprem-dev` in the examples below is **this machine's kubeconfig alias**, not a fixed name. A context name is not a property of the cluster — it is whatever the local kubeconfig calls it, so it differs per machine and can be renamed or repointed at any time. List yours with `kubectl config get-contexts -o name`, and note that **the thing that actually identifies the target is the `cluster=` half** each script prints at startup (on-prem `example-cluster.local` vs AWS `arn:aws:eks:...:cluster/prod-example-app-v1`).
>
> These scripts reach the cluster over a `kubectl port-forward` (or a `kubectl exec`) against `logging/elasticsearch-es-http` — a name the AWS `prod-example-app` cluster carries identically, as do `elasticsearch-es-default-0`, the `fluent-bit` DaemonSet, and the `elasticsearch-es-elastic-user` secret. A bare `kubectl` therefore succeeds against whichever context is current, so `delete_old_indices.sh --delete-index` would irreversibly drop indices on the wrong cluster with exit code 0. On 2026-08-03 an AWS-targeted Kibana apply ran against on-prem for exactly this reason.
>
> A read-only `--list` is gated as well, deliberately: it is the step you read before choosing what to delete, so it has to describe the same cluster the deletion will hit.
>
> **A port-forward you did not start is never reused.** If something already answers on the local port, the script cannot tell which cluster that tunnel reaches, so it aborts instead of guessing — a leftover tunnel to the other cluster would otherwise redirect every call while the banner still shows your `--context`. Close the stale tunnel, or set `ES_PF=off` if you are managing it yourself.

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

[`scripts/lib/kube-context.sh`](../../../../scripts/lib/kube-context.sh) — the repo-wide `--context` gate (`require_kube_context`, the `kctl` chokepoint, `kube_context_cluster`, `kube_context_prescan`), sourced by every script in this directory via `lib/es-helpers.sh` or directly. Kept as a single definition so this component, `elasticsearch-aws`, and the shared [`scripts/elasticsearch/`](../../../../scripts/elasticsearch) role/user scripts cannot drift into separate copies of the same safety check.

<br/>

## Quick usage

```bash
# Index reset — ES-side reset (transform stop → cohort DELETE → mapping PUT → raw DELETE → fluent-bit rollout → transform _reset + start)
./reset-example-project-cohort.sh --context onprem-dev --env qa
#   Details: ../docs/reset-example-project-cohort-en.md
#   If you need to wipe in-flight fluent-bit / fluentd state too, see the
#   "Manual cleanup" section in that doc.

# Restart a single transform (canonical workflow after a mapping change)
./restart-transform.sh --context onprem-dev dev-example-project-game-user-cohort
#   --stop-only: first step of the DELETE dest + apply.sh --replace workflow
#   --dry-run -y: inspect the planned calls only

# Inspect indices before deciding what to clean, then act on the SAME cluster
./delete_old_indices.sh --context onprem-dev --status
./delete_old_indices.sh --context onprem-dev -d 60 dev-example-project-game

# Kibana saved-objects migrate — --context only needed for the SOURCE password fetch
./kibana_saved_objects_migrate.sh --context onprem-dev --list
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
shellcheck --severity=error reset-example-project-cohort.sh restart-transform.sh delete_old_indices.sh kibana_saved_objects_migrate.sh lib/es-helpers.sh ../../../../scripts/lib/kube-context.sh

# Full repo lint
make -C ../../../.. shell-lint STRICT=1
```

<br/>

## Related documentation

- [shell-script-conventions](../../../../docs/shell-script-conventions.md) — repo-wide shell-script conventions.
- [../transforms/README-en.md](../transforms/README.md) — cohort transform definitions and the `apply.sh` / `export.sh` guide.
- [../docs/](../docs/) — full Elasticsearch component docs (upgrade / rollback / HA verification + the per-script guides for this directory).
