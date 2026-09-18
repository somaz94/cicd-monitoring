# Backup / restore

Two pieces of state to capture for this component:

1. **PostgreSQL DB** — Keycloak's user / session / token / realm data
2. **Realm configuration** — `example` realm's clients / IdPs / groups / mappers (the declarative GitOps target)

PostgreSQL is captured via pg_dump; the realm via `kc.sh export`.

<br/>

## PostgreSQL backup

### Manual one-shot

```bash
TS=$(date +%Y%m%d_%H%M%S)
kubectl -n keycloak exec deploy/keycloak-postgresql -- \
  pg_dump -U keycloak -d keycloak --clean --if-exists -Fp \
  > backup/${TS}-keycloak-pgdump.sql

ls -lh backup/${TS}-keycloak-pgdump.sql
```

> 🔴 Plain SQL (`-Fp`) is required. `scripts/restore.sh` has no `pg_restore` path and no format detection — it always `kubectl cp`s the dump into the pod and pipes it through `psql -v ON_ERROR_STOP=1 --single-transaction`. A dump taken with `-Fc` (custom format) cannot be restored by the only restore tool in this repo.

### Automatic (chart's backup CronJob — enabled)

Configured in `values/dev-postgresql.yaml` under `backup:` — daily at KST 03:00, 30-day retention, on its own 20Gi PVC.

Live since 2026-08-04. It was documented as "optional" before that, which meant the daily dump did not exist while `scripts/restore.sh latest` claimed to read one — the recovery path looked available but could not run.

What it produces:
- CronJob `keycloak-postgresql-backup`, daily at KST 03:00
- Dumps on a **separate PVC** `keycloak-postgresql-backup` (mounted at `/backup-data` in the CronJob pod), named `postgres-<db>-<date>.sql`
- 30-day retention, auto-pruned by the same job

🔴 The dumps are **not** inside the database pod, and nothing mounts that PVC between runs. That is why `restore.sh latest` starts a short-lived helper pod to read it — see the restore section.

Check it is alive:
```bash
kubectl -n keycloak get cronjob keycloak-postgresql-backup
kubectl -n keycloak get job -l app.kubernetes.io/name=postgresql   # retained run history
```

How many successful Jobs are retained is set by `backup.successfulJobsHistoryLimit` in `values/dev-postgresql.yaml`. That is only the visible run record — dump retention is a separate knob (`backup.retentionDays`).

Manual trigger:
```bash
kubectl -n keycloak create job --from=cronjob/keycloak-postgresql-backup manual-$(date +%s)
```

<br/>

## PostgreSQL restore

### Pre-flight

Restore mid-flight while Keycloak is writing breaks the schema. Scale Keycloak instances to 0:

```bash
kubectl -n keycloak patch keycloak keycloak --type=merge -p '{"spec":{"instances":0}}'
kubectl -n keycloak rollout status sts/keycloak --timeout=60s
```

### From an external dump file

```bash
./scripts/restore.sh backup/20260428_030000-keycloak-pgdump.sql
```

The script:
1. Copies the dump into the postgres Pod
2. Runs `psql -v ON_ERROR_STOP=1 --single-transaction` (plain SQL only — there is no `pg_restore` path)
3. Tells you to scale Keycloak back to 1

> 🔴 `ON_ERROR_STOP=1` must not be dropped. psql defaults to **continue-on-error and still exits 0**, so without the flag a restore in which every statement failed still ends with "Restore complete." For the IdP the whole platform federates through, **a restore that lies about succeeding is worse than one that fails** — it is only discovered when nobody can log in. `--single-transaction` goes with it because the dump is taken with `--clean --if-exists` and therefore drops and recreates objects: breaking off midway without a transaction leaves the realm in neither the old nor the new state. On error the restore rolls back, the script exits 1, and Keycloak stays scaled down.

### From the latest CronJob backup

```bash
./scripts/restore.sh --dry-run latest   # inspect first
./scripts/restore.sh latest
```

`latest` resolves the newest dump on the backup PVC. Since nothing mounts that PVC between CronJob runs, the script starts a short-lived helper pod (`pg-restore-fetch-<pid>`, busybox, read-only mount), copies the dump out, deletes the helper, then proceeds exactly like the external-file path.

Env overrides: `NAMESPACE`, `POD`, `BACKUP_PVC`, `DB_NAME`, `DB_USER`.

> The postgres pod name is resolved by label (`app.kubernetes.io/name=postgresql`), not hard-coded. The chart renders a **Deployment**, so the name carries a ReplicaSet hash — an earlier default of `keycloak-postgresql-0` assumed a StatefulSet and never matched.

### Post-restore

```bash
kubectl -n keycloak patch keycloak keycloak --type=merge -p '{"spec":{"instances":1}}'
kubectl -n keycloak rollout status sts/keycloak --timeout=120s

curl -kI https://auth.example.com/realms/master                # expect 200
```

<br/>

## Realm config backup (declarative export)

After UI/kcadm setup, export to commit the realm:

```bash
./scripts/realm-export.sh
# → manifests/realm-example.json updated
git diff manifests/realm-example.json
git add manifests/realm-example.json && git commit -m "feat(keycloak): export example realm"
```

Restore (declarative re-deploy):

```bash
helmfile -f helmfile.yaml -e dev apply \
  --set realmImport.enabled=true \
  --set-file realmImport.realm=manifests/realm-example.json
```

> The realm export contains client secrets. **gitlab-project is an internal repo so plaintext is acceptable**, but rotation leaves traces in git history — use `git filter-repo` to scrub, or migrate to ExternalSecrets later.

<br/>

## DR scenario

Whole cluster is gone, recover on a fresh cluster:

1. Apply the operator + this component
   ```bash
   helmfile -f ../keycloak-operator/helmfile.yaml -e dev apply
   helmfile -f helmfile.yaml -e dev apply
   ```
2. Wait for PostgreSQL Pod Ready (`kubectl -n keycloak rollout status deploy/keycloak-postgresql`)
3. Scale Keycloak instances to 0 (pre-flight, above)
4. Apply the latest backup with `scripts/restore.sh`
5. Scale Keycloak back to 1
6. Realm settings are inside the DB — no separate import needed. Verify client redirect URIs still align with the GitLab application configuration

<br/>

## Periodic check-list

| Frequency | Task |
|---|---|
| Daily | (Automated) Verify backup CronJob completed — `kubectl -n keycloak get jobs` |
| Weekly | Confirm `backup/` retention (only the last 30 days remain) |
| Monthly | Restore the latest dump into a dev environment to verify integrity |
| Quarterly | Refresh realm export and commit (avoid drift accumulation) |
| Pre-major-change | Take an immediate backup before bumping PostgreSQL or Keycloak chart |
