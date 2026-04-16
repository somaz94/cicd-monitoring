#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-with-image-tag" upgrade.sh body.
# Used by external Helm charts that also need automatic image tag updates
# in their values/*.yaml files (looks for `tag: vX.Y.Z` patterns and rewrites
# them to match the new appVersion).
# See "Update image tags in values files" block near the bottom of this file.
# Real per-chart upgrade.sh files are kept in sync via:
#   scripts/sync-upgrade-scripts.sh --apply
# Only the body below the second `# ===` marker is propagated.
set -euo pipefail

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.sh)
# ============================================================
SCRIPT_NAME="__SCRIPT_NAME__"
HELM_REPO_NAME="__HELM_REPO_NAME__"
HELM_REPO_URL="__HELM_REPO_URL__"
HELM_CHART="__HELM_CHART__"
CHANGELOG_URL="__CHANGELOG_URL__"
CHART_TYPE="__CHART_TYPE__"  # "local" = manages Chart.yaml + values.yaml / "external" = helmfile + values/ only
# ============================================================

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CHART_DIR/backup"
VALUES_DIR="$CHART_DIR/values"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Number of backups to retain. Override via env: `KEEP_BACKUPS=1 ./upgrade.sh`.
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

# -----------------------------------------------
# Functions
# -----------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

$SCRIPT_NAME
Checks for new versions, backs up current files, and applies the upgrade.

Commands:
  (default)           Check latest version and upgrade
  --version <VER>     Upgrade to a specific chart version
  --exclude <PATTERN> Exclude values files whose name contains PATTERN (substring match,
                      comma-separated; also skipped from backup copy)
  --dry-run           Preview changes only (no files will be modified)
  --rollback          Restore from a previous backup
  --list-backups      List available backups
  --cleanup-backups   Keep only the last $KEEP_BACKUPS backups, remove older ones
  -h, --help          Show this help message

Examples:
  $(basename "$0")                                # Upgrade to latest
  $(basename "$0") --dry-run                      # Preview upgrade without changes
  $(basename "$0") --version 1.18.0               # Upgrade to specific version
  $(basename "$0") --exclude old-release,test     # Skip files with 'old-release' or 'test' in name
  $(basename "$0") --dry-run --version 1.18.0     # Combine flags
  $(basename "$0") --rollback                     # Restore from backup
  $(basename "$0") --list-backups                 # Show available backups
  $(basename "$0") --cleanup-backups              # Remove old backups (keep last $KEEP_BACKUPS)
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
    [ -f "$dir/Chart.yaml" ] && chart_ver=$(grep '^version:' "$dir/Chart.yaml" | awk '{print $2}')
    local files=$(ls "$dir" | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (Chart: %s) — %s\n" "$i" "$dirname" "$chart_ver" "$files"
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
  [ -f "$selected/values.yaml" ] && cp "$selected/values.yaml" "$CHART_DIR/values.yaml" && echo "  Restored values.yaml"
  [ -f "$selected/helmfile.yaml" ] && cp "$selected/helmfile.yaml" "$CHART_DIR/helmfile.yaml" && echo "  Restored helmfile.yaml"

  for f in "$selected"/*.yaml; do
    local fname=$(basename "$f")
    if [ "$fname" != "Chart.yaml" ] && [ "$fname" != "values.yaml" ] && [ "$fname" != "helmfile.yaml" ]; then
      cp "$f" "$VALUES_DIR/$fname"
      echo "  Restored values/$fname"
    fi
  done

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

# Silent variant called at the end of a successful upgrade. Prunes old
# backups to KEEP_BACKUPS without verbose output when there is nothing to do.
auto_prune_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local total
  total=$(ls -d "$BACKUP_DIR"/2*/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$total" -le "$KEEP_BACKUPS" ] && return 0
  local to_delete=$((total - KEEP_BACKUPS))
  ls -dt "$BACKUP_DIR"/2*/ | tail -n "$to_delete" | while read -r dir; do
    rm -rf "$dir"
  done
  echo "  Auto-pruned $to_delete old backup(s) (KEEP_BACKUPS=$KEEP_BACKUPS)."
}

is_excluded() {
  local filename="$1"
  if [ -z "$EXCLUDE_PATTERNS" ]; then
    return 1
  fi
  IFS=',' read -ra patterns <<< "$EXCLUDE_PATTERNS"
  for pattern in "${patterns[@]}"; do
    if [[ "$filename" == *"$pattern"* ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------
# Argument parsing
# -----------------------------------------------

DRY_RUN=false
TARGET_VERSION=""
EXCLUDE_PATTERNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage ;;
    --list-backups)     list_backups; exit 0 ;;
    --rollback)         do_rollback; exit 0 ;;
    --cleanup-backups)  cleanup_backups; exit 0 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --exclude)
      EXCLUDE_PATTERNS="${2:-}"
      if [ -z "$EXCLUDE_PATTERNS" ]; then
        echo "ERROR: --exclude requires a pattern (e.g., --exclude old-release,test)"
        exit 1
      fi
      shift 2
      ;;
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
if [ -n "$EXCLUDE_PATTERNS" ]; then
  echo " Exclude: $EXCLUDE_PATTERNS"
fi
echo "================================================"

# Step 1: Check current version
echo ""
echo "[Step 1/7] Checking current version..."
CURRENT_VERSION=$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
CURRENT_APP_VERSION=$(grep '^appVersion:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
echo "  Installed - Chart: $CURRENT_VERSION / App: $CURRENT_APP_VERSION"

if [ -f "$CHART_DIR/helmfile.yaml" ]; then
  echo ""
  echo "  Helmfile releases:"
  awk '/^releases:/,0' "$CHART_DIR/helmfile.yaml" | grep -v '#' | awk '
    /- name:/ { name=$3 }
    /version:/ { if (name != "") { printf "    - %-30s version: %s\n", name, $2; name="" } }
  '
fi

# Step 2: Fetch latest version from helm repo
echo ""
echo "[Step 2/7] Checking latest version..."

helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1 || true

LATEST_INFO=$(helm search repo "$HELM_CHART" --output json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data:
    print(data[0].get('version', ''))
    print(data[0].get('app_version', ''))
" 2>/dev/null || true)

LATEST_VERSION_FOUND=$(echo "$LATEST_INFO" | head -1)
LATEST_APP_VERSION=$(echo "$LATEST_INFO" | tail -1)

if [ -z "$LATEST_VERSION_FOUND" ]; then
  echo "  ERROR: Failed to fetch latest version."
  echo "  Try: helm repo add $HELM_REPO_NAME $HELM_REPO_URL && helm repo update"
  exit 1
fi

if [ -n "$TARGET_VERSION" ]; then
  echo "  Latest available - Chart: $LATEST_VERSION_FOUND / App: $LATEST_APP_VERSION"
  LATEST_VERSION="$TARGET_VERSION"
  echo "  Using target     - Chart: $TARGET_VERSION"
else
  LATEST_VERSION="$LATEST_VERSION_FOUND"
  echo "  Latest    - Chart: $LATEST_VERSION / App: $LATEST_APP_VERSION"
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo ""
  echo "  Already up to date! Nothing to do."
  exit 0
fi

echo ""
echo "  Upgrade: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Changelog: $CHANGELOG_URL"

# Step 3: Fetch Chart.yaml and values.yaml for target version
echo ""
echo "[Step 3/7] Fetching Chart.yaml and values.yaml for version $LATEST_VERSION..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

helm show chart "$HELM_CHART" --version "$LATEST_VERSION" > "$TEMP_DIR/Chart.yaml" 2>/dev/null
helm show values "$HELM_CHART" --version "$LATEST_VERSION" > "$TEMP_DIR/values-new.yaml" 2>/dev/null

# Fetch values.schema.json if the chart includes one
helm pull "$HELM_CHART" --version "$LATEST_VERSION" --untar --untardir "$TEMP_DIR/pulled" 2>/dev/null || true
PULLED_CHART_DIR=$(find "$TEMP_DIR/pulled" -maxdepth 1 -mindepth 1 -type d | head -1)
if [ -n "$PULLED_CHART_DIR" ] && [ -f "$PULLED_CHART_DIR/values.schema.json" ]; then
  cp "$PULLED_CHART_DIR/values.schema.json" "$TEMP_DIR/values.schema.json"
fi

if [ "$CHART_TYPE" = "local" ]; then
  cp "$CHART_DIR/values.yaml" "$TEMP_DIR/values-old.yaml"
else
  helm show values "$HELM_CHART" --version "$CURRENT_VERSION" > "$TEMP_DIR/values-old.yaml" 2>/dev/null || true
fi

if [ ! -s "$TEMP_DIR/Chart.yaml" ] || [ ! -s "$TEMP_DIR/values-new.yaml" ]; then
  echo "  ERROR: Failed to fetch chart for version $LATEST_VERSION"
  exit 1
fi

LATEST_APP_VERSION=$(grep '^appVersion:' "$TEMP_DIR/Chart.yaml" | awk '{print $2}')
echo "  Downloaded successfully (App: $LATEST_APP_VERSION)"

# Step 4: Show Chart.yaml changes
echo ""
echo "[Step 4/7] Chart.yaml diff (current vs target)..."
echo "------------------------------------------------"
diff "$CHART_DIR/Chart.yaml" "$TEMP_DIR/Chart.yaml" || true
echo "------------------------------------------------"

# Step 5: Show values.yaml changes
echo ""
echo "[Step 5/7] values.yaml diff (current vs target)..."
if [ -s "$TEMP_DIR/values-old.yaml" ]; then
  DIFF_LINES=$( (diff "$TEMP_DIR/values-old.yaml" "$TEMP_DIR/values-new.yaml" || true) | wc -l | tr -d ' ')
  echo "  Total diff lines: $DIFF_LINES (showing first 80)"
  echo "------------------------------------------------"
  (diff "$TEMP_DIR/values-old.yaml" "$TEMP_DIR/values-new.yaml" || true) | head -80
  echo "------------------------------------------------"
else
  echo "  Could not fetch old version values for comparison"
fi

# Step 6: Check custom values for breaking changes
echo ""
echo "[Step 6/7] Checking custom values for breaking changes..."

if [ -n "$EXCLUDE_PATTERNS" ]; then
  echo "  Excluding patterns: $EXCLUDE_PATTERNS"
fi

for values_file in "$VALUES_DIR"/*.yaml; do
  [ ! -f "$values_file" ] && continue
  filename=$(basename "$values_file")

  if is_excluded "$filename"; then
    echo ""
    echo "=== values/$filename === (SKIPPED)"
    continue
  fi

  echo ""
  echo "=== values/$filename ==="

  if [ -s "$TEMP_DIR/values-old.yaml" ]; then
    REMOVED_KEYS=$( (diff \
      <(grep -E '^[a-zA-Z]' "$TEMP_DIR/values-old.yaml" | sed 's/:.*//' | sort -u) \
      <(grep -E '^[a-zA-Z]' "$TEMP_DIR/values-new.yaml" | sed 's/:.*//' | sort -u) \
      || true) | grep '^<' | sed 's/^< //' || true)

    if [ -n "$REMOVED_KEYS" ]; then
      echo "  !!  Removed top-level keys in target values.yaml:"
      echo "$REMOVED_KEYS" | while read -r key; do
        if grep -q "^$key:" "$values_file" 2>/dev/null; then
          echo "    - $key  <-- USED in your $filename!"
        else
          echo "    - $key"
        fi
      done
    fi

    NEW_KEYS=$( (diff \
      <(grep -E '^[a-zA-Z]' "$TEMP_DIR/values-old.yaml" | sed 's/:.*//' | sort -u) \
      <(grep -E '^[a-zA-Z]' "$TEMP_DIR/values-new.yaml" | sed 's/:.*//' | sort -u) \
      || true) | grep '^>' | sed 's/^> //' || true)

    if [ -n "$NEW_KEYS" ]; then
      echo "  ++  New top-level keys in target values.yaml:"
      echo "$NEW_KEYS" | while read -r key; do echo "    - $key"; done
    fi

    if [ -z "$REMOVED_KEYS" ] && [ -z "$NEW_KEYS" ]; then
      echo "  OK  No breaking top-level key changes detected"
    fi
  else
    echo "  SKIP  Could not compare (old version values unavailable)"
  fi
done

# Step 7: Apply changes (or exit if dry-run)
echo ""
if $DRY_RUN; then
  echo "[Step 7/7] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

echo "[Step 7/7] Applying upgrade..."

# Create backup
mkdir -p "$BACKUP_DIR/$TIMESTAMP"
cp "$CHART_DIR/Chart.yaml" "$BACKUP_DIR/$TIMESTAMP/Chart.yaml"
[ -f "$CHART_DIR/helmfile.yaml" ] && cp "$CHART_DIR/helmfile.yaml" "$BACKUP_DIR/$TIMESTAMP/helmfile.yaml"
if [ -f "$CHART_DIR/values.yaml" ]; then
  cp "$CHART_DIR/values.yaml" "$BACKUP_DIR/$TIMESTAMP/values.yaml"
fi
if [ -f "$CHART_DIR/values.schema.json" ]; then
  cp "$CHART_DIR/values.schema.json" "$BACKUP_DIR/$TIMESTAMP/values.schema.json"
fi
for values_file in "$VALUES_DIR"/*.yaml; do
  [ -f "$values_file" ] || continue
  is_excluded "$(basename "$values_file")" && continue
  cp "$values_file" "$BACKUP_DIR/$TIMESTAMP/$(basename "$values_file")"
done
echo "  Backed up to: backup/$TIMESTAMP/"
ls "$BACKUP_DIR/$TIMESTAMP/" | while read -r f; do echo "    - $f"; done

# Update Chart.yaml
cp "$TEMP_DIR/Chart.yaml" "$CHART_DIR/Chart.yaml"
echo ""
echo "  Updated Chart.yaml ($CURRENT_VERSION -> $LATEST_VERSION / App: $LATEST_APP_VERSION)"

# Update values.yaml
cp "$TEMP_DIR/values-new.yaml" "$CHART_DIR/values.yaml"
echo "  Updated values.yaml"

# Update values.schema.json (if upstream chart includes one)
if [ -f "$TEMP_DIR/values.schema.json" ]; then
  cp "$TEMP_DIR/values.schema.json" "$CHART_DIR/values.schema.json"
  echo "  Updated values.schema.json"
fi

# Update helmfile.yaml version (portable sed: works on macOS BSD sed and GNU sed)
if [ -f "$CHART_DIR/helmfile.yaml" ]; then
  UPDATED_COUNT=$(grep -c "version: $CURRENT_VERSION" "$CHART_DIR/helmfile.yaml" || true)
  HELMFILE_TMP=$(mktemp)
  sed "s/version: $CURRENT_VERSION/version: $LATEST_VERSION/g" "$CHART_DIR/helmfile.yaml" > "$HELMFILE_TMP"
  mv "$HELMFILE_TMP" "$CHART_DIR/helmfile.yaml"
  echo "  Updated helmfile.yaml ($UPDATED_COUNT release(s): $CURRENT_VERSION -> $LATEST_VERSION)"
fi

# Update image tags in values files (appVersion based)
# Detect current tag from values files if Chart.yaml appVersion doesn't match
if [ -n "$LATEST_APP_VERSION" ]; then
  for values_file in "$VALUES_DIR"/*.yaml; do
    [ -f "$values_file" ] || continue
    is_excluded "$(basename "$values_file")" && continue
    # Find the most common tag pattern in the values file
    VALUES_TAG=$(grep -oE 'tag: v[0-9]+\.[0-9]+\.[0-9]+' "$values_file" 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
    if [ -n "$VALUES_TAG" ] && [ "$VALUES_TAG" != "$LATEST_APP_VERSION" ]; then
      TAG_COUNT=$(grep -c "tag: v$VALUES_TAG" "$values_file" || true)
      VALUES_TMP=$(mktemp)
      sed "s/tag: v$VALUES_TAG/tag: v$LATEST_APP_VERSION/g" "$values_file" > "$VALUES_TMP"
      mv "$VALUES_TMP" "$values_file"
      echo "  Updated values/$(basename "$values_file") ($TAG_COUNT image tag(s): v$VALUES_TAG -> v$LATEST_APP_VERSION)"
    fi
  done
fi

# Auto-prune backups to KEEP_BACKUPS (silent on no-op).
auto_prune_backups

echo ""
echo "================================================"
echo " Upgrade complete! ($CURRENT_VERSION -> $LATEST_VERSION)"
echo ""
echo " Changelog: $CHANGELOG_URL"
echo ""
echo " Next steps:"
echo "   1. Review values/ files for any needed changes"
echo "   2. Run: helmfile diff"
echo "   3. Run: helmfile apply"
echo ""
echo " To rollback:"
echo "   ./upgrade.sh --rollback"
echo "================================================"
