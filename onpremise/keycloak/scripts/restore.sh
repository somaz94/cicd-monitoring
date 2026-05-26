#!/usr/bin/env bash
# Restore Keycloak's PostgreSQL database from a pg_dump file.
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] <dump-file|latest> [-h]

Restore the Keycloak PostgreSQL database from a pg_dump file. The Keycloak
StatefulSet must be scaled to 0 instances first (the script verifies and aborts
otherwise) — restoring while Keycloak is running corrupts the live schema.

Arguments:
  <dump-file>  path to a local pg_dump .sql file (kubectl cp into the pod)
  latest       restore from the most recent /var/lib/postgresql/backup/*.sql
               file already inside the postgres pod

Options:
  --dry-run    Print every kubectl invocation that would mutate cluster state
               (cp into the pod + psql restore) without executing them. The
               pre-flight Keycloak-instances check still runs against the live
               cluster so the dry-run reports realistic state.
  -h, --help   Show this help and exit.

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
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  break ;;
  esac
done
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-postgresql-0}"   # adjust if PVC chart renders Deployment (drop the -0 suffix)
DB_NAME="${DB_NAME:-keycloak}"
DB_USER="${DB_USER:-keycloak}"
DUMP_FILE="${1:-}"

if [[ -z "$DUMP_FILE" ]]; then
  echo "Usage: $0 [--dry-run] <dump-file|latest>"
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[$(date)] (dry-run) Would restore DB '$DB_NAME' on pod '$POD' from '$DUMP_FILE'..."
else
  echo "[$(date)] Restoring DB '$DB_NAME' on pod '$POD' from '$DUMP_FILE'..."
fi

# 1. Confirm Keycloak is scaled down (otherwise restore corrupts running schema).
INSTANCES=$(kubectl -n "$NAMESPACE" get keycloak keycloak -o jsonpath='{.spec.instances}' 2>/dev/null || echo "0")
if [[ "$INSTANCES" != "0" ]]; then
  echo "ERROR: Keycloak CR has instances=$INSTANCES. Scale down first:"
  echo "  kubectl -n $NAMESPACE patch keycloak keycloak --type=merge -p '{\"spec\":{\"instances\":0}}'"
  exit 1
fi

# 2. Copy dump to pod (skip if "latest" — assumed already in pod).
if [[ "$DUMP_FILE" != "latest" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    (dry-run) kubectl -n $NAMESPACE cp $DUMP_FILE $POD:/tmp/restore.sql"
  else
    kubectl -n "$NAMESPACE" cp "$DUMP_FILE" "$POD:/tmp/restore.sql"
  fi
  REMOTE_FILE="/tmp/restore.sql"
else
  REMOTE_FILE=$(kubectl -n "$NAMESPACE" exec "$POD" -- ls -t /var/lib/postgresql/backup 2>/dev/null | head -1 || echo "")
  [[ -z "$REMOTE_FILE" ]] && { echo "ERROR: no in-pod backup found"; exit 1; }
  REMOTE_FILE="/var/lib/postgresql/backup/$REMOTE_FILE"
fi

# 3. Restore.
if [[ "$DRY_RUN" == "1" ]]; then
  echo "    (dry-run) kubectl -n $NAMESPACE exec -i $POD -- bash -c \"psql -U $DB_USER -d $DB_NAME < $REMOTE_FILE\""
else
  kubectl -n "$NAMESPACE" exec -i "$POD" -- \
    bash -c "psql -U $DB_USER -d $DB_NAME < $REMOTE_FILE"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[$(date)] (dry-run) complete — no changes made. Re-run without --dry-run to actually restore."
else
  echo "[$(date)] Restore complete. Re-scale Keycloak:"
  echo "  kubectl -n $NAMESPACE patch keycloak keycloak --type=merge -p '{\"spec\":{\"instances\":1}}'"
fi
