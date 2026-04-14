#!/bin/bash
# upgrade-template: local-cr-version
set -euo pipefail

# ============================================================
# Configuration (ONLY section that differs between scripts)
# ============================================================
SCRIPT_NAME="Kibana (ECK CR) Version Upgrade Script"
COMPONENT_LABEL="kibana"
VERSION_SOURCE="elastic-artifacts"
VALUES_FILE="values/mgmt.yaml"
VERSION_KEY="version"
MAJOR_PIN="9"
CHANGELOG_URL="https://www.elastic.co/guide/en/kibana/current/release-notes.html"
# ============================================================

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CHART_DIR/backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
KEEP_BACKUPS=5

# -----------------------------------------------
# Functions
# -----------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

$SCRIPT_NAME
Tracks the upstream version of a Custom Resource's component and bumps the
version field inside values/<env>.yaml (plus Chart.yaml appVersion).

Commands:
  (default)           Check latest version and upgrade
  --version <VER>     Upgrade to a specific version (skips upstream query)
  --dry-run           Preview changes only (no files will be modified)
  --rollback          Restore from a previous backup
  --list-backups      List available backups
  --cleanup-backups   Keep only the last $KEEP_BACKUPS backups, remove older ones
  -h, --help          Show this help message

Examples:
  $(basename "$0")                                # Upgrade to latest GA
  $(basename "$0") --dry-run                      # Preview upgrade without changes
  $(basename "$0") --version 9.1.2                # Pin to a specific version
  $(basename "$0") --rollback                     # Restore from backup
EOF
  exit 0
}

list_backups() {
  echo "Available backups:"
  echo ""
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "  No backups found."
    exit 0
  fi

  local i=1
  for dir in $(ls -dt "$BACKUP_DIR"/2*/); do
    local dirname=$(basename "$dir")
    local chart_ver="unknown"
    [ -f "$dir/Chart.yaml" ] && chart_ver=$(grep '^appVersion:' "$dir/Chart.yaml" | awk '{print $2}' | tr -d '"')
    local files=$(ls "$dir" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (appVersion: %s) — %s\n" "$i" "$dirname" "$chart_ver" "$files"
    i=$((i + 1))
  done
  echo ""
}

do_rollback() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "No backups found."
    exit 1
  fi

  list_backups

  local backups=()
  for dir in $(ls -dt "$BACKUP_DIR"/2*/); do
    backups+=("$dir")
  done

  read -rp "Select backup number to restore [1]: " choice
  choice=${choice:-1}

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi

  local selected="${backups[$((choice - 1))]}"
  local dirname=$(basename "$selected")
  echo ""
  echo "Restoring from backup/$dirname..."

  [ -f "$selected/Chart.yaml" ] && cp "$selected/Chart.yaml" "$CHART_DIR/Chart.yaml" && echo "  Restored Chart.yaml"
  if [ -f "$selected/$(basename "$VALUES_FILE")" ]; then
    cp "$selected/$(basename "$VALUES_FILE")" "$CHART_DIR/$VALUES_FILE"
    echo "  Restored $VALUES_FILE"
  fi

  echo ""
  echo "Rollback complete! Run 'helmfile diff' to verify."
}

cleanup_backups() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "No backups found."
    exit 0
  fi

  local total=$(ls -d "$BACKUP_DIR"/2*/ 2>/dev/null | wc -l | tr -d ' ')
  echo "Total backups: $total (keeping last $KEEP_BACKUPS)"

  if [ "$total" -le "$KEEP_BACKUPS" ]; then
    echo "Nothing to clean up."
    exit 0
  fi

  local to_delete=$((total - KEEP_BACKUPS))
  echo "Removing $to_delete old backup(s)..."

  ls -dt "$BACKUP_DIR"/2*/ | tail -n "$to_delete" | while read -r dir; do
    local dirname=$(basename "$dir")
    rm -rf "$dir"
    echo "  Removed: $dirname"
  done

  echo "Done."
}

# Read a top-level YAML string value. Handles quoted and unquoted values.
# Usage: read_yaml_value <file> <key>
read_yaml_value() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    $0 ~ "^" k ":" {
      sub("^" k ":[[:space:]]*", "")
      gsub(/^["\x27]|["\x27]$/, "")
      sub(/[[:space:]]+#.*$/, "")
      print
      exit
    }
  ' "$file"
}

# Replace a top-level YAML string value (quotes preserved where possible).
# Usage: update_yaml_value <file> <key> <new_value>
update_yaml_value() {
  local file="$1"
  local key="$2"
  local new="$3"
  local tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$new" '
    BEGIN { done = 0 }
    {
      if (!done && $0 ~ "^" k ":") {
        # Preserve leading indentation + key, preserve quoting style.
        line = $0
        if (match(line, /: *"[^"]*"/)) {
          sub(/"[^"]*"/, "\"" v "\"", line)
        } else if (match(line, /: *\x27[^\x27]*\x27/)) {
          sub(/\x27[^\x27]*\x27/, "\x27" v "\x27", line)
        } else {
          sub(/:[[:space:]].*$/, ": " v, line)
        }
        print line
        done = 1
        next
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Fetch latest GA version from the configured source.
# Prints version to stdout, empty on failure.
fetch_latest_version() {
  case "$VERSION_SOURCE" in
    elastic-artifacts)
      local url="https://artifacts-api.elastic.co/v1/versions"
      curl -sSfL "$url" 2>/dev/null | python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
versions = d.get('versions', [])
# Keep strict X.Y.Z GA (exclude SNAPSHOT, rc, alpha, etc.)
ga = [v for v in versions if re.fullmatch(r'\d+\.\d+\.\d+', v)]
major = os.environ.get('MAJOR_PIN', '').strip()
if major:
    ga = [v for v in ga if v.startswith(major + '.')]
ga.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
print(ga[0] if ga else '')
" 2>/dev/null
      ;;
    *)
      echo ""
      ;;
  esac
}

# -----------------------------------------------
# Argument parsing
# -----------------------------------------------

DRY_RUN=false
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage ;;
    --list-backups)     list_backups; exit 0 ;;
    --rollback)         do_rollback; exit 0 ;;
    --cleanup-backups)  cleanup_backups; exit 0 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --version)
      TARGET_VERSION="${2:-}"
      if [ -z "$TARGET_VERSION" ]; then
        echo "ERROR: --version requires a version number"
        exit 1
      fi
      shift 2
      ;;
    *)   echo "Unknown option: $1"; echo ""; usage ;;
  esac
done

# -----------------------------------------------
# Main upgrade flow
# -----------------------------------------------

echo "================================================"
echo " $SCRIPT_NAME"
if $DRY_RUN; then
  echo " Mode: DRY-RUN (no files will be changed)"
fi
if [ -n "$TARGET_VERSION" ]; then
  echo " Target: v$TARGET_VERSION"
fi
if [ -n "$MAJOR_PIN" ]; then
  echo " Major pin: $MAJOR_PIN.x"
fi
echo "================================================"

# Step 1: Read current version
echo ""
echo "[Step 1/5] Reading current version from $VALUES_FILE..."
if [ ! -f "$CHART_DIR/$VALUES_FILE" ]; then
  echo "  ERROR: values file not found: $CHART_DIR/$VALUES_FILE"
  exit 1
fi
CURRENT_VERSION=$(read_yaml_value "$CHART_DIR/$VALUES_FILE" "$VERSION_KEY")
if [ -z "$CURRENT_VERSION" ]; then
  echo "  ERROR: could not read '$VERSION_KEY' from $VALUES_FILE"
  exit 1
fi
echo "  Current $COMPONENT_LABEL version: $CURRENT_VERSION"

CURRENT_APP_VERSION=""
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  CURRENT_APP_VERSION=$(grep '^appVersion:' "$CHART_DIR/Chart.yaml" | awk '{print $2}' | tr -d '"')
  echo "  Chart.yaml appVersion:       $CURRENT_APP_VERSION"
fi

# Step 2: Fetch latest version
echo ""
echo "[Step 2/5] Checking latest upstream version (source: $VERSION_SOURCE)..."

if [ -n "$TARGET_VERSION" ]; then
  LATEST_VERSION="$TARGET_VERSION"
  echo "  Using explicit target: $TARGET_VERSION"
else
  LATEST_VERSION=$(MAJOR_PIN="$MAJOR_PIN" fetch_latest_version)
  if [ -z "$LATEST_VERSION" ]; then
    echo "  ERROR: failed to fetch latest version from '$VERSION_SOURCE'."
    echo "  Verify network access and the source endpoint."
    exit 1
  fi
  echo "  Latest available:      $LATEST_VERSION"
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ] && { [ -z "$CURRENT_APP_VERSION" ] || [ "$CURRENT_APP_VERSION" = "$LATEST_VERSION" ]; }; then
  echo ""
  echo "  Already up to date! Nothing to do."
  exit 0
fi

echo ""
echo "  Upgrade: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Changelog: $CHANGELOG_URL"

# Step 3: ECK / compatibility reminder
echo ""
echo "[Step 3/5] Compatibility reminder"
cat <<EOF
  * Verify the currently installed ECK Operator supports $COMPONENT_LABEL $LATEST_VERSION.
    Compatibility matrix: https://www.elastic.co/support/matrix
  * For Stack major bumps (e.g. 8.x -> 9.x) review breaking changes before applying.
  * Keep Elasticsearch and Kibana on the same Stack version (Kibana <= Elasticsearch).
EOF

# Step 4: Dry-run exit
echo ""
if $DRY_RUN; then
  echo "[Step 4/5] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

echo "[Step 4/5] Backing up current files..."
mkdir -p "$BACKUP_DIR/$TIMESTAMP"
cp "$CHART_DIR/$VALUES_FILE" "$BACKUP_DIR/$TIMESTAMP/$(basename "$VALUES_FILE")"
[ -f "$CHART_DIR/Chart.yaml" ] && cp "$CHART_DIR/Chart.yaml" "$BACKUP_DIR/$TIMESTAMP/Chart.yaml"
echo "  Backed up to: backup/$TIMESTAMP/"
ls "$BACKUP_DIR/$TIMESTAMP/" | while read -r f; do echo "    - $f"; done

# Step 5: Apply version updates
echo ""
echo "[Step 5/5] Applying version update..."

update_yaml_value "$CHART_DIR/$VALUES_FILE" "$VERSION_KEY" "$LATEST_VERSION"
echo "  Updated $VALUES_FILE ($VERSION_KEY: $CURRENT_VERSION -> $LATEST_VERSION)"

if [ -f "$CHART_DIR/Chart.yaml" ]; then
  update_yaml_value "$CHART_DIR/Chart.yaml" "appVersion" "$LATEST_VERSION"
  echo "  Updated Chart.yaml (appVersion: ${CURRENT_APP_VERSION:-unset} -> $LATEST_VERSION)"
fi

echo ""
echo "================================================"
echo " Upgrade complete! ($CURRENT_VERSION -> $LATEST_VERSION)"
echo ""
echo " Changelog: $CHANGELOG_URL"
echo ""
echo " Next steps:"
echo "   1. Verify ECK Operator supports the new Stack version."
echo "   2. Run: helmfile diff"
echo "   3. Run: helmfile apply"
echo "   4. Watch CR: kubectl -n <ns> get $COMPONENT_LABEL -w"
echo ""
echo " To rollback:"
echo "   ./upgrade.sh --rollback"
echo "================================================"
