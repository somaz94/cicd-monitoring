#!/bin/bash
set -euo pipefail

# ============================================================
# Vaultwarden Backup Restore Script
#
# Usage:
#   ./restore.sh              # List available backups
#   ./restore.sh latest       # Restore from most recent backup
#   ./restore.sh 20260408     # Restore from specific date
# ============================================================

NAMESPACE="vaultwarden"
DATA_PVC="vaultwarden-data-vaultwarden-0"
BACKUP_PVC="vaultwarden-backup-data"
STATEFULSET="vaultwarden"
RESTORE_IMAGE="busybox:latest"

# -----------------------------------------------
# Functions
# -----------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATE|latest]

Vaultwarden Backup Restore Script

Commands:
  (no args)     List available backups
  latest        Restore from the most recent backup
  YYYYMMDD      Restore from a specific date (e.g., 20260408)

Examples:
  $(basename "$0")              # List backups
  $(basename "$0") latest       # Restore latest
  $(basename "$0") 20260408     # Restore from April 8, 2026
EOF
  exit 0
}

list_backups() {
  echo "Fetching available backups from PVC '$BACKUP_PVC'..."
  echo ""

  kubectl run vw-list-backups --rm -it --restart=Never \
    --image="$RESTORE_IMAGE" -n "$NAMESPACE" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"list\",
          \"image\": \"$RESTORE_IMAGE\",
          \"command\": [\"sh\", \"-c\", \"echo 'Available backups:' && echo '' && ls -lh /backup-data/db-*.sqlite3 2>/dev/null | awk '{print \\\"  \\\" \\\$NF \\\" (\\\" \\\$5 \\\")\\\"}' && echo '' && echo 'Total:' && ls /backup-data/db-*.sqlite3 2>/dev/null | wc -l\"],
          \"volumeMounts\": [{\"name\": \"backup\", \"mountPath\": \"/backup-data\", \"readOnly\": true}]
        }],
        \"volumes\": [{\"name\": \"backup\", \"persistentVolumeClaim\": {\"claimName\": \"$BACKUP_PVC\"}}]
      }
    }" 2>/dev/null

  echo ""
  echo "To restore: $(basename "$0") [YYYYMMDD|latest]"
}

do_restore() {
  local DATE="$1"

  if [ "$DATE" = "latest" ]; then
    echo "Finding most recent backup..."
    DATE=$(kubectl run vw-find-latest --rm -it --restart=Never \
      --image="$RESTORE_IMAGE" -n "$NAMESPACE" \
      --overrides="{
        \"spec\": {
          \"containers\": [{
            \"name\": \"find\",
            \"image\": \"$RESTORE_IMAGE\",
            \"command\": [\"sh\", \"-c\", \"ls -1 /backup-data/db-*.sqlite3 2>/dev/null | sort -r | head -1 | sed 's|.*/db-||;s|.sqlite3||'\"],
            \"volumeMounts\": [{\"name\": \"backup\", \"mountPath\": \"/backup-data\", \"readOnly\": true}]
          }],
          \"volumes\": [{\"name\": \"backup\", \"persistentVolumeClaim\": {\"claimName\": \"$BACKUP_PVC\"}}]
        }
      }" 2>/dev/null | tr -d '[:space:]')

    if [ -z "$DATE" ]; then
      echo "ERROR: No backups found."
      exit 1
    fi
    echo "Latest backup: $DATE"
  fi

  # Validate date format
  if ! [[ "$DATE" =~ ^[0-9]{8}$ ]]; then
    echo "ERROR: Invalid date format. Use YYYYMMDD (e.g., 20260408)"
    exit 1
  fi

  echo ""
  echo "============================================"
  echo " Vaultwarden Restore"
  echo " Date: $DATE"
  echo " Files: db-${DATE}.sqlite3, rsa_key-${DATE}.pem"
  echo "============================================"
  echo ""
  echo "WARNING: This will:"
  echo "  1. Stop Vaultwarden"
  echo "  2. Overwrite current data with backup from $DATE"
  echo "  3. Restart Vaultwarden"
  echo ""
  read -rp "Continue? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Cancelled."
    exit 0
  fi

  # Step 1: Scale down
  echo ""
  echo "[Step 1/4] Stopping Vaultwarden..."
  kubectl scale statefulset "$STATEFULSET" --replicas=0 -n "$NAMESPACE"
  echo "  Waiting for pod to terminate..."
  kubectl wait --for=delete pod/"${STATEFULSET}-0" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
  echo "  Stopped."

  # Step 2: Restore
  echo ""
  echo "[Step 2/4] Restoring from backup db-${DATE}.sqlite3..."
  kubectl run vw-restore --rm -it --restart=Never \
    --image="$RESTORE_IMAGE" -n "$NAMESPACE" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"restore\",
          \"image\": \"$RESTORE_IMAGE\",
          \"command\": [\"sh\", \"-c\", \"set -e; if [ ! -f /backup-data/db-${DATE}.sqlite3 ]; then echo 'ERROR: db-${DATE}.sqlite3 not found'; exit 1; fi; cp /backup-data/db-${DATE}.sqlite3 /data/db.sqlite3; cp /backup-data/rsa_key-${DATE}.pem /data/rsa_key.pem 2>/dev/null || echo 'WARNING: rsa_key not found in backup, keeping current'; echo 'Restore complete: db-${DATE}.sqlite3 -> /data/db.sqlite3'\"],
          \"volumeMounts\": [
            {\"name\": \"data\", \"mountPath\": \"/data\"},
            {\"name\": \"backup\", \"mountPath\": \"/backup-data\", \"readOnly\": true}
          ]
        }],
        \"volumes\": [
          {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$DATA_PVC\"}},
          {\"name\": \"backup\", \"persistentVolumeClaim\": {\"claimName\": \"$BACKUP_PVC\"}}
        ]
      }
    }"

  # Step 3: Scale up
  echo ""
  echo "[Step 3/4] Starting Vaultwarden..."
  kubectl scale statefulset "$STATEFULSET" --replicas=1 -n "$NAMESPACE"

  # Step 4: Wait for ready
  echo ""
  echo "[Step 4/4] Waiting for pod to be ready..."
  kubectl wait --for=condition=ready pod/"${STATEFULSET}-0" -n "$NAMESPACE" --timeout=120s

  echo ""
  echo "============================================"
  echo " Restore complete!"
  echo " Restored from: db-${DATE}.sqlite3"
  echo " Verify: https://vault.example.com"
  echo "============================================"
}

# -----------------------------------------------
# Main
# -----------------------------------------------

case "${1:-}" in
  -h|--help) usage ;;
  "")        list_backups ;;
  *)         do_restore "$1" ;;
esac
