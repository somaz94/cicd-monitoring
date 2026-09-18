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

## Documentation

| Document | Description |
|----------|-------------|
| [Client Setup](docs/client-setup.md) | Chrome Extension, app setup |
| [Account Management](docs/account-management.md) | User/org/permission management |
| [Backup/Restore](docs/backup-restore.md) | Backup strategy and restore guide |
| [TLS Setup](docs/tls-setup.md) | TLS termination (NGF Gateway) and the legacy self-signed certificate |

<br/>

## Chart Info

| Item | Value |
|------|-------|
| Chart | [guerzon/vaultwarden](https://github.com/guerzon/vaultwarden) |
| Version | `version` in `helmfile.yaml` + `Chart.yaml` |
| App Version | `appVersion` in `Chart.yaml` |
| Access URL | `https://vault.example.com` (`domain` in `values/dev.yaml`) |

<br/>

## Install / Upgrade

```bash
# Install
helmfile apply

# Preview changes
helmfile diff

# Chart version upgrade
./upgrade.py              # Check and upgrade to latest
./upgrade.py --dry-run    # Preview only
./upgrade.py --version X  # Specific version
./upgrade.py --rollback   # Rollback
```

<br/>

## Backup / Restore

### Automatic Backup

A CronJob runs daily at **KST 03:00** (UTC 18:00) to back up SQLite data.

- **Method**: `sqlite3 VACUUM INTO`, not a plain `cp`. vaultwarden runs SQLite in WAL mode, so copying only the main database file drops any commit that has not been checkpointed yet — and this database is small enough that it rarely reaches the 1000-page auto-checkpoint threshold, leaving that window permanently open.
- **Verification**: `PRAGMA integrity_check` runs on the fresh copy, which is renamed to its dated filename only on success. A failure fails the Job.
- **Image**: `alpine:3.21` (`sqlite3` is required and busybox does not ship it)
- **Filenames**: `db-YYYYMMDD.sqlite3`, `rsa_key-YYYYMMDD.pem`
- **Retention**: 30 days (older backups auto-deleted)
- **PVCs**: data `vaultwarden-data-vaultwarden-0` (readWrite — a WAL database cannot be opened read-only because of its `-shm` index), backup `vaultwarden-backup-data` (25Gi)
- **Alerts**: `VaultwardenBackupStale` / `VaultwardenBackupMissing`

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
# List available backups
./scripts/restore.sh

# Preview the restore plan without executing (recommended first step)
./scripts/restore.sh --dry-run latest

# Restore from a specific date
./scripts/restore.sh 20260408

# Restore from the most recent backup
./scripts/restore.sh latest
```

Detailed guide: [Backup & Restore Guide](docs/backup-restore.md)

<br/>

## TLS Setup

HTTPS is terminated by the NGF `ngf` Gateway in the `nginx-gateway` namespace using the `wildcard-example-tls` certificate.
This component owns no certificate — `ingress.enabled` is `false` in `values/dev.yaml`, and the
self-signed `vaultwarden-tls` Secret was removed on 2026-04-17 as unused.

> Vaultwarden Web Vault requires HTTPS because the browser's SubtleCrypto API is only available in a secure context.

Certificate issuance/renewal belongs to `network/nginx-gateway-fabric`: [TLS Wildcard Setup](../../network/nginx-gateway-fabric/docs/tls-wildcard-setup.md)

Detailed guide: [TLS Setup](docs/tls-setup.md) (includes the retired Ingress + self-signed path)

<br/>

## Reference

- [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
- [Vaultwarden Helm Chart (guerzon)](https://github.com/guerzon/vaultwarden)
- [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
