#!/usr/bin/env bash
# Export the `example` realm config from a running Keycloak server to manifests/realm-example.json.
#
# Used after Phase 3 (realm + brokering created via UI/kcadm) to capture state for declarative re-deploy.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]

Export the running Keycloak realm to a JSON file (kc.sh export). The output is
intended to be re-applied via the realmImport CRD on the next helmfile run, e.g.:

  git diff manifests/realm-example.json
  helmfile -f helmfile.yaml diff \\
    --set realmImport.enabled=true \\
    --set-file realmImport.realm=manifests/realm-example.json

Env overrides (with defaults):
  NAMESPACE  keycloak namespace                                  (default: keycloak)
  POD        operator-spawned StatefulSet pod                    (default: keycloak-0)
  REALM      realm to export                                     (default: example)
  OUTPUT     output path, relative to the component dir          (default: manifests/realm-example.json)

Note: the export contains client secrets — keep the file out of public repos.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
POD="${POD:-keycloak-0}"                          # operator-spawned StatefulSet pod / operator-spawned StatefulSet pod
REALM="${REALM:-example}"
OUTPUT="${OUTPUT:-manifests/realm-example.json}"

# Resolve script root (repo-relative).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="$COMPONENT_DIR/$OUTPUT"

echo "[$(date)] Exporting realm '$REALM' from pod '$POD' to '$OUTPUT_PATH'..."

# kc.sh export — operator-spawned Keycloak Pod has the binary at /opt/keycloak/bin/.
# Outputs to /tmp/realm-export-<realm>/ then concatenates into a single JSON.
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "
  rm -rf /tmp/realm-export
  /opt/keycloak/bin/kc.sh export --dir /tmp/realm-export --realm $REALM --users realm_file
  cat /tmp/realm-export/$REALM-realm.json
" > "$OUTPUT_PATH"

echo "[$(date)] Wrote $OUTPUT_PATH ($(wc -l < "$OUTPUT_PATH") lines, $(wc -c < "$OUTPUT_PATH") bytes)."
echo ""
echo "Next steps:"
echo "  git diff $OUTPUT"
echo "  helmfile -f helmfile.yaml -e mgmt diff --set realmImport.enabled=true --set-file realmImport.realm=$OUTPUT"
