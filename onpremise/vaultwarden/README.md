# Vaultwarden

Bitwarden-compatible password management server written in Rust

<br/>

## Components

| Component | Description |
|-----------|-------------|
| Vaultwarden Server | Password management web application |
| SQLite | Default embedded database |
| Backup CronJob | Daily automatic SQLite backup |

<br/>

## Chart Info

| Item | Value |
|------|-------|
| Chart | [guerzon/vaultwarden](https://github.com/guerzon/vaultwarden) |
| Version | 0.35.1 |
| App Version | 1.35.4 |
| Access URL | `http://vault.example.com` |

<br/>

## Install / Upgrade

```bash
# Install
helmfile apply

# Preview changes
helmfile diff

# Chart version upgrade
./upgrade.sh              # Check and upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --version X  # Specific version
./upgrade.sh --rollback   # Rollback
```

<br/>

## Backup / Restore

### Automatic Backup

A CronJob runs daily at **KST 03:00** (UTC 18:00) to back up SQLite data.

- **Image**: `skeen/bitwarden_rs_backup`
- **Data PVC**: `vaultwarden-data-vaultwarden-0` (readOnly)
- **Backup PVC**: `vaultwarden-backup-data` (readWrite)

```bash
# Manual backup
kubectl create job --from=cronjob/vaultwarden-backup manual-backup -n vaultwarden

# Check backup status
kubectl get jobs -n vaultwarden
kubectl get cronjobs -n vaultwarden
```

<br/>

### Data Restore

```bash
# 1. Stop Vaultwarden
kubectl scale deploy vaultwarden --replicas=0 -n vaultwarden

# 2. Run restore (backup -> data)
kubectl run restore --rm -it --image=busybox -n vaultwarden \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "restore",
        "image": "busybox",
        "command": ["sh", "-c", "cp /backup/db.sqlite3 /data/db.sqlite3 && echo Restore complete"],
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
kubectl scale deploy vaultwarden --replicas=1 -n vaultwarden
```

<br/>

## Switching to HTTPS

After installing cert-manager, update `values/mgmt.yaml`:

```yaml
# 1. Update domain
domain: "https://vault.example.com"

# 2. Enable ingress TLS
ingress:
  tls: true
  tlsSecret: "vaultwarden-tls"
  additionalAnnotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "cloudflare-issuer"
```

<br/>

## Reference

- [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
- [Vaultwarden Helm Chart (guerzon)](https://github.com/guerzon/vaultwarden)
- [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
