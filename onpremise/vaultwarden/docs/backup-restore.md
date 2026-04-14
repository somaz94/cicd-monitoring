# Backup & Restore Guide

## Backup Strategy

- **Schedule**: Daily at KST 03:00 (UTC 18:00)
- **File format**: `db-YYYYMMDD.sqlite3`, `rsa_key-YYYYMMDD.pem`
- **Retention**: 30 days (older backups auto-deleted)
- **Storage**: `vaultwarden-backup-data` PVC (25Gi, NFS)

<br/>

## Backup Files

| File | Description |
|------|-------------|
| `db-YYYYMMDD.sqlite3` | SQLite database (all vault data, users, orgs) |
| `rsa_key-YYYYMMDD.pem` | RSA private key for JWT token signing |

> **Important**: `rsa_key.pem` is critical. If lost, all existing sessions become invalid
> and users must re-authenticate.

<br/>

## Manual Backup

```bash
# Trigger backup immediately
kubectl create job --from=cronjob/vaultwarden-backup manual-backup -n vaultwarden

# Check job status
kubectl get jobs -n vaultwarden

# View backup logs
kubectl logs job/manual-backup -n vaultwarden

# List available backups
./scripts/restore.sh
```

<br/>

## Restore

### Using restore.sh (Recommended)

```bash
# List available backups
./scripts/restore.sh

# Restore from specific date
./scripts/restore.sh 20260408

# Restore from most recent backup
./scripts/restore.sh latest
```

The script automatically:
1. Stops Vaultwarden (scale to 0)
2. Copies backup files to data PVC
3. Restarts Vaultwarden (scale to 1)
4. Waits for pod ready

<br/>

### Manual Restore

```bash
# 1. Stop Vaultwarden
kubectl scale statefulset vaultwarden --replicas=0 -n vaultwarden

# 2. Run restore pod
kubectl run restore --rm -it --image=busybox -n vaultwarden \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "restore",
        "image": "busybox",
        "command": ["sh", "-c",
          "cp /backup/db-20260408.sqlite3 /data/db.sqlite3 && echo Done"],
        "volumeMounts": [
          {"name": "data", "mountPath": "/data"},
          {"name": "backup", "mountPath": "/backup"}
        ]
      }],
      "volumes": [
        {"name": "data", "persistentVolumeClaim": {"claimName": "vaultwarden-data-vaultwarden-0"}},
        {"name": "backup", "persistentVolumeClaim": {"claimName": "vaultwarden-backup-data"}}
      ]
    }
  }'

# 3. Restart Vaultwarden
kubectl scale statefulset vaultwarden --replicas=1 -n vaultwarden
```

<br/>

## Changing Retention

Edit `values/mgmt.yaml` and change `RETENTION_DAYS` in the CronJob args:

```yaml
# Current: 30 days
RETENTION_DAYS=30

# Example: keep 90 days
RETENTION_DAYS=90
```

Then apply: `helmfile apply`

<br/>

## Monitoring

```bash
# Check CronJob schedule
kubectl get cronjobs -n vaultwarden

# Check recent backup jobs
kubectl get jobs -n vaultwarden --sort-by=.metadata.creationTimestamp

# Check backup PVC usage
kubectl exec -n vaultwarden vaultwarden-0 -- du -sh /backup-data/ 2>/dev/null || \
  kubectl run check-size --rm -it --restart=Never --image=busybox -n vaultwarden \
    --overrides='{"spec":{"containers":[{"name":"check","image":"busybox","command":["du","-sh","/backup"],"volumeMounts":[{"name":"b","mountPath":"/backup"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"vaultwarden-backup-data"}}]}}'
```
