#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "local-with-templates" upgrade.sh body.
# Used by LOCAL Helm charts (Chart.yaml in repo) that need:
#   - Custom templates preserved across upstream sync (CUSTOM_TEMPLATES)
#   - _pod.tpl patches re-applied after upstream sync (CUSTOM_POD_PATCH)
#   - Extra upstream dirs synced (EXTRA_DIRS)
# Two upstream source modes:
#   1. helm repo (default): set HELM_REPO_NAME/URL/HELM_CHART, leave CHART_GIT_REPO empty
#   2. git source: set CHART_GIT_REPO/CHART_GIT_PATH (used for charts not in any helm repo)
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

# Optional: git source mode (used when chart is not in any helm repo)
# When CHART_GIT_REPO is non-empty, the script uses git clone instead of helm pull.
# CHART_GIT_PATH is the path within the repo where the chart directory lives.
CHART_GIT_REPO=""
CHART_GIT_PATH=""

# Custom templates that do NOT exist in upstream (will be preserved)
CUSTOM_TEMPLATES=("__CUSTOM_TEMPLATE__")

# Patch for _pod.tpl: PVC volume block to inject into upstream template
# Inserted before the extraVolumes block in the volumes section
CUSTOM_POD_PATCH='__CUSTOM_POD_PATCH__'
# ============================================================

# zsh nomatch compat: don't fail when "$dir"/2*/ has no matches.
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CHART_DIR/backup"
VALUES_DIR="$CHART_DIR/values"
TEMPLATES_DIR="$CHART_DIR/templates"
EXTRA_DIRS=("ci" "dashboards")  # Additional upstream dirs to sync
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Number of backups to retain. Override via env: `KEEP_BACKUPS=1 ./upgrade.sh`.
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

# Detect helmfile flavor (helmfile.yaml or helmfile.yaml.gotmpl).
# Prefer .gotmpl when both exist (.gotmpl is the templated source of truth).
HELMFILE_PATH=""
HELMFILE_NAME=""
if [ -f "$CHART_DIR/helmfile.yaml.gotmpl" ]; then
  HELMFILE_PATH="$CHART_DIR/helmfile.yaml.gotmpl"
  HELMFILE_NAME="helmfile.yaml.gotmpl"
elif [ -f "$CHART_DIR/helmfile.yaml" ]; then
  HELMFILE_PATH="$CHART_DIR/helmfile.yaml"
  HELMFILE_NAME="helmfile.yaml"
fi

# -----------------------------------------------
# Functions
# -----------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

$SCRIPT_NAME
Checks for new versions, backs up current files (including templates),
downloads the upstream chart, and applies the upgrade while preserving
custom templates (pv.yaml, pvc.yaml) and _pod.tpl patches.

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
  $(basename "$0") --version 0.49.0               # Upgrade to specific version
  $(basename "$0") --exclude old-release,test     # Skip files with 'old-release' or 'test' in name
  $(basename "$0") --dry-run --version 0.49.0     # Combine flags
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
  # Reverse-sorted glob via sort -r: backup dirs use YYYYMMDD_HHMMSS so name desc == time desc.
  # 백업 디렉토리는 YYYYMMDD_HHMMSS 형식이라 이름 내림차순 == 시간 내림차순.
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    local dirname=""; dirname=$(basename "$dir")
    local chart_ver="unknown"
    [ -f "$dir/Chart.yaml" ] && chart_ver=$(grep '^version:' "$dir/Chart.yaml" | awk '{print $2}')
    local tpl_count=0
    [ -d "$dir/templates" ] && tpl_count=$(ls "$dir/templates/" 2>/dev/null | wc -l | tr -d ' ')
    local val_count=""
    val_count=$(find "$dir" -maxdepth 1 -type f -name '*.yaml' \
      ! -name Chart.yaml ! -name helmfile.yaml 2>/dev/null | wc -l | tr -d ' ')
    printf "  [%d] %s (Chart: %s) — templates: %s, values: %s\n" "$i" "$dirname" "$chart_ver" "$tpl_count" "$val_count"
    i=$((i + 1))
  done < <(printf "%s\n" "$BACKUP_DIR"/2*/ | sort -r)
  echo ""
}

do_rollback() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "No backups found."
    exit 1
  fi

  list_backups

  local backups=()
  # Reverse-sorted glob: backup dirs use YYYYMMDD_HHMMSS so name desc == time desc.
  # 백업 디렉토리는 YYYYMMDD_HHMMSS 형식이라 이름 내림차순 == 시간 내림차순.
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    backups+=("$dir")
  done < <(printf "%s\n" "$BACKUP_DIR"/2*/ | sort -r)

  read -rp "Select backup number to restore [1]: " choice
  choice=${choice:-1}

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi

  local selected="${backups[$((choice - 1))]}"
  local dirname=""; dirname=$(basename "$selected")
  echo ""
  echo "Restoring from backup/$dirname..."

  # Restore Chart.yaml and helmfile (plain or gotmpl variant)
  [ -f "$selected/Chart.yaml" ] && cp "$selected/Chart.yaml" "$CHART_DIR/Chart.yaml" && echo "  Restored Chart.yaml"
  [ -f "$selected/values.yaml" ] && cp "$selected/values.yaml" "$CHART_DIR/values.yaml" && echo "  Restored values.yaml"
  if [ -f "$selected/helmfile.yaml.gotmpl" ]; then
    cp "$selected/helmfile.yaml.gotmpl" "$CHART_DIR/helmfile.yaml.gotmpl"
    echo "  Restored helmfile.yaml.gotmpl"
  elif [ -f "$selected/helmfile.yaml" ]; then
    cp "$selected/helmfile.yaml" "$CHART_DIR/helmfile.yaml"
    echo "  Restored helmfile.yaml"
  fi

  # Restore templates
  if [ -d "$selected/templates" ]; then
    rm -rf "$TEMPLATES_DIR"
    cp -r "$selected/templates" "$TEMPLATES_DIR"
    echo "  Restored templates/ ($(ls "$TEMPLATES_DIR" | wc -l | tr -d ' ') files)"
  fi

  # Restore extra dirs (ci, dashboards, etc.)
  for edir in "${EXTRA_DIRS[@]}"; do
    if [ -d "$selected/$edir" ]; then
      rm -rf "${CHART_DIR:?}/$edir"
      cp -r "$selected/$edir" "$CHART_DIR/$edir"
      echo "  Restored $edir/"
    else
      echo "  Skipped $edir/ (not in this backup)"
    fi
  done

  # Restore custom values
  for f in "$selected"/*.yaml; do
    local fname=""; fname=$(basename "$f")
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

  local total=""; total=$(ls -d "$BACKUP_DIR"/2*/ 2>/dev/null | wc -l | tr -d ' ')
  echo "Total backups: $total (keeping last $KEEP_BACKUPS)"

  if [ "$total" -le "$KEEP_BACKUPS" ]; then
    echo "Nothing to clean up."
    exit 0
  fi

  local to_delete=$((total - KEEP_BACKUPS))
  echo "Removing $to_delete old backup(s)..."

  ls -dt "$BACKUP_DIR"/2*/ | tail -n "$to_delete" | while read -r dir; do
    local dirname=""; dirname=$(basename "$dir")
    rm -rf "$dir"
    echo "  Removed: $dirname"
  done

  echo "Done."
}

# Silent variant called at the end of a successful upgrade. Prunes old
# backups to KEEP_BACKUPS without verbose output when there is nothing to do.
auto_prune_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local total=""
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

patch_pod_tpl() {
  local pod_tpl="$1"

  # Check if patch already exists
  if grep -q "persistentVolumeClaims.enabled" "$pod_tpl" 2>/dev/null; then
    echo "  _pod.tpl: PVC patch already present, skipping"
    return 0
  fi

  # Find the insertion point: before the extraVolumes block
  # The pattern is: {{- if .Values.extraVolumes }}
  local marker='{{- if .Values.extraVolumes }}'
  if ! grep -qF "$marker" "$pod_tpl"; then
    echo "  WARNING: Could not find extraVolumes marker in _pod.tpl"
    echo "  Manual patching may be required for PVC volume support"
    return 1
  fi

  # Insert PVC block before the extraVolumes block using a temp patch file
  local patchfile=""; patchfile=$(mktemp)
  echo "$CUSTOM_POD_PATCH" > "$patchfile"

  local tmpfile=""; tmpfile=$(mktemp)
  while IFS= read -r line; do
    if [[ "$line" == *"if .Values.extraVolumes"* ]]; then
      cat "$patchfile"
    fi
    echo "$line"
  done < "$pod_tpl" > "$tmpfile"
  mv "$tmpfile" "$pod_tpl"
  rm -f "$patchfile"

  echo "  _pod.tpl: PVC patch applied successfully"
  return 0
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
echo "[Step 1/8] Checking current version..."
CURRENT_VERSION=$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
CURRENT_APP_VERSION=$(grep '^appVersion:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
echo "  Installed - Chart: $CURRENT_VERSION / App: $CURRENT_APP_VERSION"

if [ -n "$HELMFILE_PATH" ]; then
  echo ""
  echo "  Helmfile releases ($HELMFILE_NAME):"
  awk '/^releases:/,0' "$HELMFILE_PATH" | grep -v '#' | awk '
    /- name:/ { name=$3 }
    /version:/ { if (name != "") { printf "    - %-30s version: %s\n", name, $2; name="" } }
  '
fi

# Step 2: Fetch latest version (from helm repo or git tags)
echo ""
echo "[Step 2/8] Checking latest version..."

if [ -n "${CHART_GIT_REPO:-}" ]; then
  # Git source mode: use latest semver-looking tag
  LATEST_VERSION_FOUND=$(git ls-remote --tags --refs --sort='-v:refname' "$CHART_GIT_REPO" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//')
  LATEST_APP_VERSION="(from-git)"
  if [ -z "$LATEST_VERSION_FOUND" ]; then
    echo "  ERROR: Failed to list tags from $CHART_GIT_REPO"
    exit 1
  fi
else
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

# Step 3: Download upstream chart (helm pull or git clone)
echo ""
echo "[Step 3/8] Downloading upstream chart v$LATEST_VERSION..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ -n "${CHART_GIT_REPO:-}" ]; then
  # Git source mode
  GIT_TAG="v$LATEST_VERSION"
  if ! git ls-remote --tags --refs "$CHART_GIT_REPO" "$GIT_TAG" 2>/dev/null | grep -q .; then
    GIT_TAG="$LATEST_VERSION"  # try without v prefix
  fi
  git clone --depth 1 --branch "$GIT_TAG" "$CHART_GIT_REPO" "$TEMP_DIR/git-src" > /dev/null 2>&1
  UPSTREAM_DIR="$TEMP_DIR/git-src/${CHART_GIT_PATH:-}"
else
  # Helm repo mode
  helm pull "$HELM_CHART" --version "$LATEST_VERSION" --untar --untardir "$TEMP_DIR" 2>/dev/null
  # Auto-detect the unpacked chart directory (chart-name agnostic)
  UPSTREAM_DIR=$(find "$TEMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
fi

if [ ! -d "$UPSTREAM_DIR/templates" ]; then
  echo "  ERROR: Failed to download chart for version $LATEST_VERSION"
  exit 1
fi

LATEST_APP_VERSION=$(grep '^appVersion:' "$UPSTREAM_DIR/Chart.yaml" | awk '{print $2}')
UPSTREAM_TPL_COUNT=$(find "$UPSTREAM_DIR/templates" -type f | wc -l | tr -d ' ')
echo "  Downloaded successfully (App: $LATEST_APP_VERSION, Templates: $UPSTREAM_TPL_COUNT files)"

# Step 4: Show Chart.yaml changes
echo ""
echo "[Step 4/8] Chart.yaml diff (current vs target)..."
echo "------------------------------------------------"
diff "$CHART_DIR/Chart.yaml" "$UPSTREAM_DIR/Chart.yaml" || true
echo "------------------------------------------------"

# Step 5: Show values.yaml and template changes
echo ""
echo "[Step 5/8] values.yaml diff (current vs target)..."
DIFF_LINES=$( (diff "$CHART_DIR/values.yaml" "$UPSTREAM_DIR/values.yaml" || true) | wc -l | tr -d ' ')
echo "  Total diff lines: $DIFF_LINES (showing first 80)"
echo "------------------------------------------------"
(diff "$CHART_DIR/values.yaml" "$UPSTREAM_DIR/values.yaml" || true) | head -80
echo "------------------------------------------------"

echo ""
echo "  Template changes:"
CHANGED=0
ADDED=0
REMOVED=0

# Check modified and removed templates
for local_tpl in "$TEMPLATES_DIR"/*.yaml "$TEMPLATES_DIR"/*.tpl "$TEMPLATES_DIR"/*.txt; do
  [ ! -f "$local_tpl" ] && continue
  local_name=$(basename "$local_tpl")

  # Skip custom templates
  is_custom=false
  for ct in "${CUSTOM_TEMPLATES[@]}"; do
    [ "$local_name" = "$ct" ] && is_custom=true && break
  done
  $is_custom && continue

  if [ -f "$UPSTREAM_DIR/templates/$local_name" ]; then
    if ! diff -q "$local_tpl" "$UPSTREAM_DIR/templates/$local_name" > /dev/null 2>&1; then
      echo "    MODIFIED: templates/$local_name"
      CHANGED=$((CHANGED + 1))
    fi
  else
    echo "    REMOVED:  templates/$local_name (not in upstream)"
    REMOVED=$((REMOVED + 1))
  fi
done

# Check for new templates in upstream
for upstream_tpl in "$UPSTREAM_DIR/templates"/*.yaml "$UPSTREAM_DIR/templates"/*.tpl "$UPSTREAM_DIR/templates"/*.txt; do
  [ ! -f "$upstream_tpl" ] && continue
  upstream_name=$(basename "$upstream_tpl")
  if [ ! -f "$TEMPLATES_DIR/$upstream_name" ]; then
    echo "    NEW:      templates/$upstream_name"
    ADDED=$((ADDED + 1))
  fi
done

# Check tests subdirectory
for upstream_tpl in "$UPSTREAM_DIR/templates/tests"/*.yaml; do
  [ ! -f "$upstream_tpl" ] && continue
  upstream_name=$(basename "$upstream_tpl")
  if [ -f "$TEMPLATES_DIR/tests/$upstream_name" ]; then
    if ! diff -q "$TEMPLATES_DIR/tests/$upstream_name" "$upstream_tpl" > /dev/null 2>&1; then
      echo "    MODIFIED: templates/tests/$upstream_name"
      CHANGED=$((CHANGED + 1))
    fi
  else
    echo "    NEW:      templates/tests/$upstream_name"
    ADDED=$((ADDED + 1))
  fi
done

echo "  Summary: $CHANGED modified, $ADDED new, $REMOVED removed"
echo "  Custom templates preserved: ${CUSTOM_TEMPLATES[*]}"

# Step 6: Show _pod.tpl patch diff (only if this chart uses _pod.tpl patching)
echo ""
echo "[Step 6/8] Custom _pod.tpl patch check..."
if [ -z "${CUSTOM_POD_PATCH:-}" ] || [ ! -f "$UPSTREAM_DIR/templates/_pod.tpl" ]; then
  echo "  Skipped (this chart does not use _pod.tpl patching)."
elif grep -q "persistentVolumeClaims.enabled" "$UPSTREAM_DIR/templates/_pod.tpl" 2>/dev/null; then
  echo "  Upstream _pod.tpl already includes PVC support! No patching needed."
else
  echo "  Upstream _pod.tpl does NOT include PVC support."
  echo "  Will inject PVC volume block after upgrade."
  echo ""
  echo "  Patch to apply:"
  echo "  ------------------------------------------------"
  echo "$CUSTOM_POD_PATCH" | sed 's/^/  /'
  echo "  ------------------------------------------------"
fi

# Step 7: Check custom values for breaking changes
echo ""
echo "[Step 7/8] Checking custom values for breaking changes..."

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

  REMOVED_KEYS=$( (diff \
    <(grep -E '^[a-zA-Z]' "$CHART_DIR/values.yaml" | sed 's/:.*//' | sort -u) \
    <(grep -E '^[a-zA-Z]' "$UPSTREAM_DIR/values.yaml" | sed 's/:.*//' | sort -u) \
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
    <(grep -E '^[a-zA-Z]' "$CHART_DIR/values.yaml" | sed 's/:.*//' | sort -u) \
    <(grep -E '^[a-zA-Z]' "$UPSTREAM_DIR/values.yaml" | sed 's/:.*//' | sort -u) \
    || true) | grep '^>' | sed 's/^> //' || true)

  if [ -n "$NEW_KEYS" ]; then
    echo "  ++  New top-level keys in target values.yaml:"
    echo "$NEW_KEYS" | while read -r key; do echo "    - $key"; done
  fi

  if [ -z "$REMOVED_KEYS" ] && [ -z "$NEW_KEYS" ]; then
    echo "  OK  No breaking top-level key changes detected"
  fi
done

# Step 8: Apply changes (or exit if dry-run)
echo ""
if $DRY_RUN; then
  echo "[Step 8/8] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

echo "[Step 8/8] Applying upgrade..."

# Create backup (includes templates)
mkdir -p "$BACKUP_DIR/$TIMESTAMP/templates"
cp "$CHART_DIR/Chart.yaml" "$BACKUP_DIR/$TIMESTAMP/Chart.yaml"
cp "$CHART_DIR/values.yaml" "$BACKUP_DIR/$TIMESTAMP/values.yaml"
if [ -f "$CHART_DIR/values.schema.json" ]; then
  cp "$CHART_DIR/values.schema.json" "$BACKUP_DIR/$TIMESTAMP/values.schema.json"
fi
[ -n "$HELMFILE_PATH" ] && cp "$HELMFILE_PATH" "$BACKUP_DIR/$TIMESTAMP/$HELMFILE_NAME"

# Backup all templates (including subdirectories)
cp -r "$TEMPLATES_DIR"/* "$BACKUP_DIR/$TIMESTAMP/templates/" 2>/dev/null || true
if [ -d "$TEMPLATES_DIR/tests" ]; then
  mkdir -p "$BACKUP_DIR/$TIMESTAMP/templates/tests"
  cp -r "$TEMPLATES_DIR/tests"/* "$BACKUP_DIR/$TIMESTAMP/templates/tests/" 2>/dev/null || true
fi

# Backup extra dirs (ci, dashboards, etc.)
for edir in "${EXTRA_DIRS[@]}"; do
  if [ -d "$CHART_DIR/$edir" ]; then
    cp -r "$CHART_DIR/$edir" "$BACKUP_DIR/$TIMESTAMP/$edir"
  fi
done

# Backup custom values
for values_file in "$VALUES_DIR"/*.yaml; do
  [ -f "$values_file" ] || continue
  is_excluded "$(basename "$values_file")" && continue
  cp "$values_file" "$BACKUP_DIR/$TIMESTAMP/$(basename "$values_file")"
done

echo "  Backed up to: backup/$TIMESTAMP/"
echo "    - Chart.yaml, values.yaml"
echo "    - templates/ ($(find "$BACKUP_DIR/$TIMESTAMP/templates" -type f | wc -l | tr -d ' ') files)"
for edir in "${EXTRA_DIRS[@]}"; do
  [ -d "$BACKUP_DIR/$TIMESTAMP/$edir" ] && echo "    - $edir/"
done

# Save custom templates to temp
for ct in "${CUSTOM_TEMPLATES[@]}"; do
  if [ -f "$TEMPLATES_DIR/$ct" ]; then
    cp "$TEMPLATES_DIR/$ct" "$TEMP_DIR/custom_$ct"
  fi
done

# Replace templates with upstream
rm -rf "$TEMPLATES_DIR"
cp -r "$UPSTREAM_DIR/templates" "$TEMPLATES_DIR"
echo ""
echo "  Replaced templates/ with upstream ($(find "$TEMPLATES_DIR" -type f | wc -l | tr -d ' ') files)"

# Restore custom templates
for ct in "${CUSTOM_TEMPLATES[@]}"; do
  if [ -f "$TEMP_DIR/custom_$ct" ]; then
    cp "$TEMP_DIR/custom_$ct" "$TEMPLATES_DIR/$ct"
    echo "  Preserved custom: templates/$ct"
  fi
done

# Patch _pod.tpl (only if this chart uses _pod.tpl patching)
if [ -z "${CUSTOM_POD_PATCH:-}" ] || [ ! -f "$TEMPLATES_DIR/_pod.tpl" ]; then
  echo "  _pod.tpl: skipped (this chart does not use _pod.tpl patching)"
elif ! grep -q "persistentVolumeClaims.enabled" "$TEMPLATES_DIR/_pod.tpl" 2>/dev/null; then
  patch_pod_tpl "$TEMPLATES_DIR/_pod.tpl" || true
else
  echo "  _pod.tpl: PVC support already in upstream, no patch needed"
fi

# Update extra dirs (ci, dashboards, etc.)
for edir in "${EXTRA_DIRS[@]}"; do
  if [ -d "$UPSTREAM_DIR/$edir" ]; then
    rm -rf "${CHART_DIR:?}/$edir"
    cp -r "$UPSTREAM_DIR/$edir" "$CHART_DIR/$edir"
    echo "  Updated $edir/"
  fi
done

# Update Chart.yaml and values.yaml
cp "$UPSTREAM_DIR/Chart.yaml" "$CHART_DIR/Chart.yaml"
echo ""
echo "  Updated Chart.yaml ($CURRENT_VERSION -> $LATEST_VERSION / App: $LATEST_APP_VERSION)"

cp "$UPSTREAM_DIR/values.yaml" "$CHART_DIR/values.yaml"
echo "  Updated values.yaml"

# Update values.schema.json (if upstream chart includes one)
if [ -f "$UPSTREAM_DIR/values.schema.json" ]; then
  cp "$UPSTREAM_DIR/values.schema.json" "$CHART_DIR/values.schema.json"
  echo "  Updated values.schema.json"
fi

# Update helmfile (portable sed: works on macOS BSD sed and GNU sed).
# Handles three pin forms: literal `version: X.Y.Z`, quoted `version: "X.Y.Z"`,
# and gotmpl hoist `{{- $chartVersion := "X.Y.Z" }}`. / gotmpl hoist `{{- $chartVersion := "X.Y.Z" }}`.
if [ -n "$HELMFILE_PATH" ]; then
  UPDATED_COUNT=$(grep -cE "(version:[[:space:]]+\"?${CURRENT_VERSION}\"?([[:space:]]|$)|\\\$chartVersion[[:space:]]*:=[[:space:]]+\"${CURRENT_VERSION}\")" "$HELMFILE_PATH" || true)
  HELMFILE_TMP=$(mktemp)
  sed -E \
    -e "s|(version:[[:space:]]+)\"${CURRENT_VERSION}\"|\1\"${LATEST_VERSION}\"|g" \
    -e "s|(version:[[:space:]]+)${CURRENT_VERSION}([[:space:]]+)|\1${LATEST_VERSION}\2|g" \
    -e "s|(version:[[:space:]]+)${CURRENT_VERSION}\$|\1${LATEST_VERSION}|g" \
    -e "s|(\\\$chartVersion[[:space:]]*:=[[:space:]]+)\"${CURRENT_VERSION}\"|\1\"${LATEST_VERSION}\"|g" \
    "$HELMFILE_PATH" > "$HELMFILE_TMP"
  mv "$HELMFILE_TMP" "$HELMFILE_PATH"
  echo "  Updated $HELMFILE_NAME ($UPDATED_COUNT pin(s): $CURRENT_VERSION -> $LATEST_VERSION)"
fi

# Auto-prune backups to KEEP_BACKUPS (silent on no-op).
auto_prune_backups

echo ""
echo "================================================"
echo " Upgrade complete! ($CURRENT_VERSION -> $LATEST_VERSION)"
echo ""
echo " Changelog: $CHANGELOG_URL"
echo ""
echo " Custom templates preserved:"
for ct in "${CUSTOM_TEMPLATES[@]}"; do
  echo "   - templates/$ct"
done
echo "   - templates/_pod.tpl (PVC patch)"
echo ""
echo " Next steps:"
echo "   1. Review values/ files for any needed changes"
echo "   2. Run: helmfile diff"
echo "   3. Run: helmfile apply"
echo ""
echo " To rollback:"
echo "   ./upgrade.sh --rollback"
echo "================================================"
