#!/usr/bin/env bash
# Export the `example` realm from a running Keycloak server to a local backup outside the repo.
#
# A full export carries client secrets, IdP client secrets and user credentials, so it never lands in a tracked path by default.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]

Export the running Keycloak realm to a local JSON backup (kc.sh export, users
included). The file holds client secrets, IdP client secrets and user
credentials: it is a local backup / diff artefact. Never commit it.

Default output:
  \${REALM_EXPORT_DIR:-\$HOME/keycloak-exports}/realm-<REALM>-<YYYYmmdd_HHMMSS>.json
  The directory is created mode 0700, the file is written mode 0600.

Env overrides (with defaults):
  NAMESPACE         keycloak namespace                  (default: keycloak)
  POD               operator-spawned StatefulSet pod    (default: keycloak-0)
  REALM             realm to export                     (default: example)
  REALM_EXPORT_DIR  output directory                    (default: \$HOME/keycloak-exports)
  OUTPUT            explicit output file, replaces the default path entirely
                    (relative to the current directory; keep it outside the repo)

Compare two exports to see realm drift:
  diff <(jq -S . OLDER.json) <(jq -S . NEWER.json)

The realmImport path (--set-file realmImport.realm=...) needs a sanitized realm
file with secrets supplied separately. This raw export is not that file.

There is no --dry-run: any argument other than -h/--help is rejected. The export
is written to a temp file in the output directory and moved into place only on success.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)         echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"                          # operator-spawned StatefulSet pod
REALM="${REALM:-example}"
REALM_EXPORT_DIR="${REALM_EXPORT_DIR:-$HOME/keycloak-exports}"
OUTPUT_PATH="${OUTPUT:-$REALM_EXPORT_DIR/realm-$REALM-$(date +%Y%m%d_%H%M%S).json}"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"

mkdir -p "$OUTPUT_DIR"
if git -C "$OUTPUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[$(date)] WARN: $OUTPUT_DIR is inside a git work tree — never commit this export." >&2
fi

echo "[$(date)] Exporting realm '$REALM' from pod '$POD' to '$OUTPUT_PATH'..."

# Same directory as the output so the final mv is a rename; a failed export never touches an existing file.
TMP_PATH="$(mktemp "$OUTPUT_DIR/.$(basename "$OUTPUT_PATH").XXXXXX")"
trap 'rm -f "$TMP_PATH"' EXIT
chmod 600 "$TMP_PATH"

# kc.sh export — operator-spawned Keycloak Pod has the binary at /opt/keycloak/bin/.
# kc.sh export writes <realm>-realm.json into /tmp/realm-export; stream it back.
if ! kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "
  rm -rf /tmp/realm-export
  /opt/keycloak/bin/kc.sh export --dir /tmp/realm-export --realm $REALM --users realm_file
  cat /tmp/realm-export/$REALM-realm.json
" > "$TMP_PATH"; then
  echo "[$(date)] ERROR: export failed — nothing written to $OUTPUT_PATH." >&2
  exit 1
fi
if [[ ! -s "$TMP_PATH" ]]; then
  echo "[$(date)] ERROR: export produced no output — nothing written to $OUTPUT_PATH." >&2
  exit 1
fi
mv "$TMP_PATH" "$OUTPUT_PATH"

echo "[$(date)] Wrote $OUTPUT_PATH ($(wc -l < "$OUTPUT_PATH") lines, $(wc -c < "$OUTPUT_PATH") bytes, mode 0600)."
echo ""
echo "Keep it local — never commit it. To see drift against an earlier export:"
echo "  diff <(jq -S . <older>.json) <(jq -S . $OUTPUT_PATH)"
