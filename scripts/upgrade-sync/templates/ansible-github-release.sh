#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "ansible-github-release" upgrade.sh body.
#
# Used by components deployed via Ansible (NOT Helm) that:
#   - Track versions from a GitHub Releases feed.
#   - Keep the version in a single YAML file (e.g. group_vars/all.yml).
#
# Typical shape:
#   - ansible/group_vars/all.yml (has `<COMPONENT>_version: "X.Y.Z"`)
#   - ansible/playbook.yml, upgrade.yml (reference the version var via group_vars)
#   - No Chart.yaml, no helmfile.yaml
#
# What this script does:
#   1. Reads current version from <CHART_DIR>/<VERSION_FILE>.
#   2. Queries GitHub Releases for the latest GA version (respecting MAJOR_PIN).
#   3. Diffs and, on apply, updates the version field in VERSION_FILE + backs up.
#   4. Prints next step: run ansible-playbook upgrade.yml.
#
# Real per-component upgrade.sh files are kept in sync via:
#   scripts/upgrade-sync/sync.sh --apply
# Only the body below the third `# ===` marker is propagated.
set -euo pipefail

# ============================================================
# Configuration (per-component placeholders — replaced in real upgrade.sh)
# ============================================================
SCRIPT_NAME="__SCRIPT_NAME__"
# Human-readable component name (e.g. "node_exporter", "blackbox_exporter")
COMPONENT_NAME="__COMPONENT_NAME__"
# GitHub repo in "owner/repo" form (e.g. "prometheus/node_exporter")
GITHUB_REPO="__GITHUB_REPO__"
# YAML file holding the version field, relative to CHART_DIR
# (e.g. "ansible/group_vars/all.yml")
VERSION_FILE="__VERSION_FILE__"
# Top-level YAML key holding the version string (e.g. "node_exporter_version")
VERSION_KEY="__VERSION_KEY__"
# Ansible paths relative to CHART_DIR, used in "next steps" guidance only.
ANSIBLE_DIR="__ANSIBLE_DIR__"
ANSIBLE_INVENTORY="__ANSIBLE_INVENTORY__"
ANSIBLE_UPGRADE_PLAYBOOK="__ANSIBLE_UPGRADE_PLAYBOOK__"
CHANGELOG_URL="__CHANGELOG_URL__"
# Major-line pin. Empty = any. E.g. "1" to lock to 1.x.
MAJOR_PIN="__MAJOR_PIN__"
# ============================================================

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CHART_DIR/backup"
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
Tracks the upstream version of an Ansible-deployed component and bumps the
version field in the Ansible variables file.

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
  $(basename "$0") --version 1.12.0               # Pin to a specific version
  $(basename "$0") --rollback                     # Restore from backup
EOF
  exit 0
}

# Read a top-level YAML string value. Handles quoted and unquoted values.
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
update_yaml_value() {
  local file="$1"
  local key="$2"
  local new="$3"
  local tmp=""
  tmp=$(mktemp)
  awk -v k="$key" -v v="$new" '
    BEGIN { done = 0 }
    {
      if (!done && $0 ~ "^" k ":") {
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

list_backups() {
  echo "Available backups:"
  echo ""
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "  No backups found."
    exit 0
  fi

  local i=1
  local vfile_base=""
  vfile_base=$(basename "$VERSION_FILE")
  # Reverse-sorted glob via sort -r: backup dirs use YYYYMMDD_HHMMSS so name desc == time desc.
  # 백업 디렉토리는 YYYYMMDD_HHMMSS 형식이라 이름 내림차순 == 시간 내림차순.
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    local dirname=""; dirname=$(basename "$dir")
    local ver="unknown"
    [ -f "$dir/$vfile_base" ] && ver=$(read_yaml_value "$dir/$vfile_base" "$VERSION_KEY")
    local files=""
    files=$(ls "$dir" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (version: %s) — %s\n" "$i" "$dirname" "$ver" "$files"
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
  local dirname=""
  dirname=$(basename "$selected")
  echo ""
  echo "Restoring from backup/$dirname..."

  local vfile_base=""
  vfile_base=$(basename "$VERSION_FILE")
  if [ -f "$selected/$vfile_base" ]; then
    cp "$selected/$vfile_base" "$CHART_DIR/$VERSION_FILE"
    echo "  Restored $VERSION_FILE"
  else
    echo "  ERROR: backup does not contain $vfile_base"
    exit 1
  fi

  echo ""
  echo "Rollback complete! Next steps to apply on hosts:"
  echo "   cd $ANSIBLE_DIR && ansible-playbook -i $ANSIBLE_INVENTORY $ANSIBLE_UPGRADE_PLAYBOOK"
}

cleanup_backups() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -d "$BACKUP_DIR"/2* 2>/dev/null)" ]; then
    echo "No backups found."
    exit 0
  fi

  local total=""
  total=$(ls -d "$BACKUP_DIR"/2*/ 2>/dev/null | wc -l | tr -d ' ')
  echo "Total backups: $total (keeping last $KEEP_BACKUPS)"

  if [ "$total" -le "$KEEP_BACKUPS" ]; then
    echo "Nothing to clean up."
    exit 0
  fi

  local to_delete=$((total - KEEP_BACKUPS))
  echo "Removing $to_delete old backup(s)..."

  ls -dt "$BACKUP_DIR"/2*/ | tail -n "$to_delete" | while read -r dir; do
    local dirname=""
    dirname=$(basename "$dir")
    rm -rf "$dir"
    echo "  Removed: $dirname"
  done

  echo "Done."
}

# Silent variant called at the end of a successful upgrade.
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

# Fetch sorted list of GA versions from GitHub Releases (newest first).
# Strips leading 'v' and excludes prereleases/drafts. Respects MAJOR_PIN.
fetch_ga_versions() {
  [ -z "$GITHUB_REPO" ] && return 0
  local url="https://api.github.com/repos/$GITHUB_REPO/releases?per_page=100"
  curl -sSfL "$url" 2>/dev/null | python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tags = [r.get('tag_name', '') for r in d
        if not r.get('prerelease') and not r.get('draft')]
tags = [re.sub(r'^v', '', t) for t in tags]
ga = [t for t in tags if re.fullmatch(r'\d+\.\d+\.\d+', t)]
major = os.environ.get('MAJOR_PIN', '').strip()
if major:
    ga = [t for t in ga if t.startswith(major + '.')]
ga.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
for v in ga:
    print(v)
" 2>/dev/null
}

fetch_latest_version() {
  fetch_ga_versions | head -1
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
echo "[Step 1/5] Reading current version from $VERSION_FILE..."
if [ ! -f "$CHART_DIR/$VERSION_FILE" ]; then
  echo "  ERROR: version file not found: $CHART_DIR/$VERSION_FILE"
  exit 1
fi
CURRENT_VERSION=$(read_yaml_value "$CHART_DIR/$VERSION_FILE" "$VERSION_KEY")
if [ -z "$CURRENT_VERSION" ]; then
  echo "  ERROR: could not read '$VERSION_KEY' from $VERSION_FILE"
  exit 1
fi
echo "  Current $COMPONENT_NAME version: $CURRENT_VERSION"

# Step 2: Fetch latest version
echo ""
echo "[Step 2/5] Checking latest upstream version (GitHub: $GITHUB_REPO)..."

if [ -n "$TARGET_VERSION" ]; then
  LATEST_VERSION="$TARGET_VERSION"
  echo "  Using explicit target: $TARGET_VERSION"
else
  LATEST_VERSION=$(MAJOR_PIN="$MAJOR_PIN" fetch_latest_version)
  if [ -z "$LATEST_VERSION" ]; then
    echo "  ERROR: failed to fetch latest version from GitHub."
    echo "  Verify network access and GITHUB_REPO='$GITHUB_REPO'."
    exit 1
  fi
  echo "  Latest available:      $LATEST_VERSION"
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo ""
  echo "  Already up to date! Nothing to do."
  exit 0
fi

echo ""
echo "  Upgrade: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Changelog: $CHANGELOG_URL"

# Step 3: Show diff preview + major bump warning
echo ""
echo "[Step 3/5] Diff preview for $VERSION_FILE..."
echo "------------------------------------------------"
echo "- $VERSION_KEY: \"$CURRENT_VERSION\""
echo "+ $VERSION_KEY: \"$LATEST_VERSION\""
echo "------------------------------------------------"

CURRENT_MAJOR="${CURRENT_VERSION%%.*}"
LATEST_MAJOR="${LATEST_VERSION%%.*}"
if [ -n "$CURRENT_MAJOR" ] && [ -n "$LATEST_MAJOR" ] && [ "$CURRENT_MAJOR" != "$LATEST_MAJOR" ]; then
  echo ""
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  !! MAJOR VERSION BUMP: $CURRENT_MAJOR.x -> $LATEST_MAJOR.x"
  echo "  !! Review breaking changes: $CHANGELOG_URL"
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  if ! $DRY_RUN; then
    echo ""
    read -rp "  Continue with major version upgrade? [y/N]: " major_confirm
    if [[ ! "$major_confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
fi

# Step 4: Dry-run exit / Backup
echo ""
if $DRY_RUN; then
  echo "[Step 4/5] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

echo "[Step 4/5] Backing up $VERSION_FILE..."
mkdir -p "$BACKUP_DIR/$TIMESTAMP"
cp "$CHART_DIR/$VERSION_FILE" "$BACKUP_DIR/$TIMESTAMP/$(basename "$VERSION_FILE")"
echo "  Backed up to: backup/$TIMESTAMP/$(basename "$VERSION_FILE")"

# Step 5: Apply version update
echo ""
echo "[Step 5/5] Applying version update..."

update_yaml_value "$CHART_DIR/$VERSION_FILE" "$VERSION_KEY" "$LATEST_VERSION"
echo "  Updated $VERSION_FILE ($VERSION_KEY: $CURRENT_VERSION -> $LATEST_VERSION)"

# Auto-prune backups to KEEP_BACKUPS (silent on no-op).
auto_prune_backups

echo ""
echo "================================================"
echo " Upgrade complete! ($CURRENT_VERSION -> $LATEST_VERSION)"
echo ""
echo " Changelog: $CHANGELOG_URL"
echo ""
echo " Next steps:"
echo "   1. Review the change: git diff $VERSION_FILE"
echo "   2. Apply to hosts:    cd $ANSIBLE_DIR && ansible-playbook -i $ANSIBLE_INVENTORY $ANSIBLE_UPGRADE_PLAYBOOK"
echo "   3. Verify on a host:  curl http://<host>:<port>/metrics | head"
echo ""
echo " To rollback (source file only, then re-run ansible-playbook):"
echo "   ./upgrade.sh --rollback"
echo "================================================"
