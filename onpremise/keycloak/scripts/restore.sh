#!/usr/bin/env bash
# Restore Keycloak's PostgreSQL database from a pg_dump file.
usage() {
  cat <<EOF
Usage: $(basename "$0") <dump-file|latest> [-h]

Restore the Keycloak PostgreSQL database from a pg_dump file. The Keycloak
StatefulSet must be scaled to 0 instances first (the script verifies and aborts
otherwise) — restoring while Keycloak is running corrupts the live schema.

Arguments:
  <dump-file>  path to a local pg_dump .sql file (kubectl cp into the pod)
  latest       restore from the most recent /var/lib/postgresql/backup/*.sql
               file already inside the postgres pod

Env overrides (with defaults):
  NAMESPACE  keycloak namespace                       (default: keycloak)
  POD        postgres pod name                        (default: keycloak-postgresql-0)
  DB_NAME    database to restore into                 (default: keycloak)
  DB_USER    psql user                                (default: keycloak)

Prereqs:
  - keycloak-postgresql Pod is Running
  - Keycloak CR scaled to 0:
      kubectl -n \$NAMESPACE patch keycloak keycloak --type=merge -p '{"spec":{"instances":0}}'
  - DB password loaded into the postgres pod env (chart-managed)

After restore, scale Keycloak back up:
  kubectl -n \$NAMESPACE patch keycloak keycloak --type=merge -p '{"spec":{"instances":1}}'
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-postgresql-0}"   # adjust if PVC chart renders Deployment
DB_NAME="${DB_NAME:-keycloak}"
DB_USER="${DB_USER:-keycloak}"
DUMP_FILE="${1:-}"

if [[ -z "$DUMP_FILE" ]]; then
  echo "Usage: $0 <dump-file|latest>"
  exit 1
fi

echo "[$(date)] Restoring DB '$DB_NAME' on pod '$POD' from '$DUMP_FILE'..."

# 1. Confirm Keycloak is scaled down (otherwise restore corrupts running schema).
INSTANCES=$(kubectl -n "$NAMESPACE" get keycloak keycloak -o jsonpath='{.spec.instances}' 2>/dev/null || echo "0")
if [[ "$INSTANCES" != "0" ]]; then
  echo "ERROR: Keycloak CR has instances=$INSTANCES. Scale down first:"
  echo "  kubectl -n $NAMESPACE patch keycloak keycloak --type=merge -p '{\"spec\":{\"instances\":0}}'"
  exit 1
fi

# 2. Copy dump to pod (skip if "latest" — assumed already in pod).
if [[ "$DUMP_FILE" != "latest" ]]; then
  kubectl -n "$NAMESPACE" cp "$DUMP_FILE" "$POD:/tmp/restore.sql"
  REMOTE_FILE="/tmp/restore.sql"
else
  REMOTE_FILE=$(kubectl -n "$NAMESPACE" exec "$POD" -- ls -t /var/lib/postgresql/backup 2>/dev/null | head -1 || echo "")
  [[ -z "$REMOTE_FILE" ]] && { echo "ERROR: no in-pod backup found"; exit 1; }
  REMOTE_FILE="/var/lib/postgresql/backup/$REMOTE_FILE"
fi

# 3. Restore.
kubectl -n "$NAMESPACE" exec -i "$POD" -- \
  bash -c "psql -U $DB_USER -d $DB_NAME < $REMOTE_FILE"

echo "[$(date)] Restore complete. Re-scale Keycloak:"
echo "  kubectl -n $NAMESPACE patch keycloak keycloak --type=merge -p '{\"spec\":{\"instances\":1}}'"
