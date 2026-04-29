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
  pg_dump -U keycloak -d keycloak --clean --if-exists -Fc \
  > backup/${TS}-keycloak-pgdump.dump

ls -lh backup/${TS}-keycloak-pgdump.dump
```

> Use `-Fc` (custom format) — compressed + parallel restore via `pg_restore --jobs N`. For plain SQL use `-Fp`.

### Automatic (chart's backup CronJob — optional)

Enable the postgresql chart's CronJob:

```yaml
# Add to values/mgmt-postgresql.yaml
backup:
  enabled: true
  schedule: "0 18 * * *"          # KST 03:00 = UTC 18:00
  retentionDays: 30
  persistence:
    enabled: true
    storageClass: nfs-client-server
    size: 20Gi
```

After `helmfile apply`:
- CronJob `keycloak-postgresql-backup` runs daily at KST 03:00
- Backups stored in a separate PVC `keycloak-postgresql-backup`
- 30-day retention auto-cleanup

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
./scripts/restore.sh backup/20260428_030000-keycloak-pgdump.dump
```

The script:
1. Copies the dump into the postgres Pod
2. Runs `pg_restore --clean --if-exists` (for custom format) or `psql` (for plain SQL)
3. Tells you to scale Keycloak back to 1

### From an in-pod CronJob backup

```bash
./scripts/restore.sh latest
```

> Requires `backup.enabled: true` so the backup PVC is mounted in the cluster.

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
helmfile -f helmfile.yaml -e mgmt apply \
  --set realmImport.enabled=true \
  --set-file realmImport.realm=manifests/realm-example.json
```

> The realm export contains client secrets. **gitlab-project is an internal repo so plaintext is acceptable**, but rotation leaves traces in git history — use `git filter-repo` to scrub, or migrate to ExternalSecrets later.

<br/>

## DR scenario

Whole cluster is gone, recover on a fresh cluster:

1. Apply the operator + this component
   ```bash
   helmfile -f ../keycloak-operator/helmfile.yaml -e mgmt apply
   helmfile -f helmfile.yaml -e mgmt apply
   ```
2. Wait for PostgreSQL Pod Ready (`kubectl -n keycloak rollout status deploy/keycloak-postgresql`)
3. Scale Keycloak instances to 0 (pre-flight, above)
4. `pg_restore` the latest backup
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
