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
  latest       restore from the most recent dump on the backup PVC written by
               the daily CronJob (see "Where backups live" below)

Options:
  --dry-run    Print every kubectl invocation that would mutate cluster state
               (helper pod + cp into the pod + psql restore) without executing
               them. The pre-flight Keycloak-instances check still runs against
               the live cluster so the dry-run reports realistic state.
  -h, --help   Show this help and exit.

Where backups live:
  The daily CronJob (values/dev-postgresql.yaml \`backup.enabled\`) writes
  pg_dump output to a SEPARATE PVC — \$BACKUP_PVC, mounted at /backup-data in
  the CronJob pod. It is NOT inside the database pod, and nothing mounts it
  between runs, so "latest" spins up a short-lived helper pod to read it.

Env overrides (with defaults):
  NAMESPACE   keycloak namespace                      (default: keycloak)
  POD         postgres pod name        (default: resolved by label — see below)
  BACKUP_PVC  PVC holding the dumps    (default: keycloak-postgresql-backup)
  DB_NAME     database to restore into                (default: keycloak)
  DB_USER     psql user                               (default: keycloak)

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
BACKUP_PVC="${BACKUP_PVC:-keycloak-postgresql-backup}"
DB_NAME="${DB_NAME:-keycloak}"
DB_USER="${DB_USER:-keycloak}"
DUMP_FILE="${1:-}"

if [[ -z "$DUMP_FILE" ]]; then
  echo "Usage: $0 [--dry-run] <dump-file|latest>"
  exit 1
fi

# The chart renders a Deployment, not a StatefulSet, so the pod name carries a
# ReplicaSet hash and cannot be hard-coded (an earlier default of
# `keycloak-postgresql-0` never matched anything). Resolve it by label; POD=
# still overrides for the odd case of two postgres pods in one namespace.
if [[ -z "${POD:-}" ]]; then
  POD=$(kubectl -n "$NAMESPACE" get pod \
        -l app.kubernetes.io/name=postgresql \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$POD" ]]; then
    echo "ERROR: no pod with label app.kubernetes.io/name=postgresql in namespace '$NAMESPACE'." >&2
    echo "       Set POD=<pod-name> explicitly if the label differs." >&2
    exit 1
  fi
fi

# Local scratch file for the "latest" path; removed on exit.
LOCAL_DUMP=""
cleanup() {
  [[ -n "$LOCAL_DUMP" && -f "$LOCAL_DUMP" ]] && rm -f "$LOCAL_DUMP"
  return 0
}
trap cleanup EXIT

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

# 2a. Resolve "latest" to a local file.
#
# The daily CronJob writes to the backup PVC, not into the database pod, and
# nothing mounts that PVC between runs — the CronJob pod has already exited, so
# there is nothing to exec into. Reading it takes a short-lived helper pod.
if [[ "$DUMP_FILE" == "latest" ]]; then
  HELPER="pg-restore-fetch-$$"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    (dry-run) would start helper pod '$HELPER' mounting PVC '$BACKUP_PVC'"
    echo "    (dry-run) would copy the newest /backup-data/postgres-*.sql out of it"
    DUMP_FILE="<newest-dump-on-$BACKUP_PVC>"
  else
    echo "  Reading backup PVC '$BACKUP_PVC' via helper pod '$HELPER'..."
    kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HELPER
  labels:
    app.kubernetes.io/name: keycloak-restore-helper
spec:
  restartPolicy: Never
  containers:
    - name: fetch
      image: busybox:latest
      command: ["sleep", "300"]
      volumeMounts:
        - name: backup
          mountPath: /backup-data
          readOnly: true
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: $BACKUP_PVC
        readOnly: true
EOF
    kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$HELPER" --timeout=120s >/dev/null

    NEWEST=$(kubectl -n "$NAMESPACE" exec "$HELPER" -- \
             sh -c 'ls -t /backup-data/postgres-*.sql 2>/dev/null | head -1' || echo "")

    if [[ -z "$NEWEST" ]]; then
      kubectl -n "$NAMESPACE" delete pod "$HELPER" --ignore-not-found >/dev/null 2>&1 || true
      echo "ERROR: no dump on PVC '$BACKUP_PVC'. Has the backup CronJob run yet?" >&2
      echo "       kubectl -n $NAMESPACE get cronjob,job | grep backup" >&2
      exit 1
    fi

    LOCAL_DUMP=$(mktemp "${TMPDIR:-/tmp}/keycloak-restore.XXXXXX")
    kubectl -n "$NAMESPACE" cp "$HELPER:$NEWEST" "$LOCAL_DUMP" >/dev/null
    kubectl -n "$NAMESPACE" delete pod "$HELPER" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    echo "  Using $NEWEST ($(wc -c <"$LOCAL_DUMP" | tr -d ' ') bytes)"
    DUMP_FILE="$LOCAL_DUMP"
  fi
fi

# 2b. Copy the dump into the database pod. Both paths land here — "latest" was
#     turned into a local file above, so there is only one copy path to reason about.
if [[ "$DRY_RUN" == "1" ]]; then
  echo "    (dry-run) kubectl -n $NAMESPACE cp $DUMP_FILE $POD:/tmp/restore.sql"
else
  kubectl -n "$NAMESPACE" cp "$DUMP_FILE" "$POD:/tmp/restore.sql"
fi
REMOTE_FILE="/tmp/restore.sql"

# 3. Restore.
#
# 🔴 -v ON_ERROR_STOP=1 is not optional. psql's default is continue-on-error AND
# it still exits 0, so without this flag a restore in which every single
# statement failed prints nothing alarming and this script goes on to report
# "Restore complete." For the IdP the whole platform federates through, a restore
# that lies about succeeding is worse than one that fails — the failure is only
# discovered when someone cannot log in, long after the dump has been trusted.
#
# --single-transaction pairs with it: on any error the whole restore rolls back
# instead of leaving the realm half-written. The dump is taken with
# --clean --if-exists, so it drops and recreates objects; aborting midway through
# that without a transaction leaves the database in neither the old nor the new
# state.
PSQL_FLAGS="-v ON_ERROR_STOP=1 --single-transaction"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "    (dry-run) kubectl -n $NAMESPACE exec -i $POD -- bash -c \"psql $PSQL_FLAGS -U $DB_USER -d $DB_NAME < $REMOTE_FILE\""
else
  if ! kubectl -n "$NAMESPACE" exec -i "$POD" -- \
      bash -c "psql $PSQL_FLAGS -U $DB_USER -d $DB_NAME < $REMOTE_FILE"; then
    echo "[$(date)] ERROR: restore failed — the transaction was rolled back, the database is unchanged." >&2
    echo "  Keycloak is still scaled down. Investigate before re-scaling:" >&2
    echo "    kubectl -n $NAMESPACE exec -i $POD -- psql -U $DB_USER -d $DB_NAME -c '\\dt'" >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[$(date)] (dry-run) complete — no changes made. Re-run without --dry-run to actually restore."
else
  echo "[$(date)] Restore complete. Re-scale Keycloak:"
  echo "  kubectl -n $NAMESPACE patch keycloak keycloak --type=merge -p '{\"spec\":{\"instances\":1}}'"
fi
