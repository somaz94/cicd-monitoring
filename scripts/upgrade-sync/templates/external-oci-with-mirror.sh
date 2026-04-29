#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-oci-with-mirror" upgrade.sh body.
#
# Variant of "external-oci" that adds an optional Step 7 mirror stage:
# upstream container images referenced by the chart are copied to a private
# registry (e.g. Harbor) before values rewrite, so air-gapped / private
# clusters can pull from the mirror instead of upstream Docker Hub / ghcr.io.
#
# Required CONFIG vars (same set as external-oci):
#   HELM_CHART, GITHUB_REPO, GITHUB_TAG_PREFIX, CHANGELOG_URL, CHART_TYPE
#
# Optional CONFIG plumbing for the mirror stage:
#   do_mirror()      Bash function defined in CONFIG. Receives no args.
#                    Has access to $TEMP_DIR/Chart.yaml, $TEMP_DIR/values-new.yaml,
#                    $LATEST_VERSION, $LATEST_APP_VERSION, $VALUES_DIR.
#                    Should call mirror_image() for each upstream→harbor pair
#                    and rewrite values keys via yq. Return non-zero to abort
#                    the upgrade (Step 8 apply will not run).
#                    If do_mirror is undefined, Step 7 is skipped silently.
#
# Helpers exposed to do_mirror() (defined in this body):
#   mirror_image <upstream-ref> <harbor-ref> [--insecure]
#                    Compares digests; copies via `crane copy` only when
#                    different; verifies digest match after copy.
#
# Real per-chart upgrade.sh files are kept in sync via:
#   scripts/upgrade-sync/sync.sh --apply
# Only the body below the third `# ===` marker is propagated.
set -euo pipefail

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.sh)
# ============================================================
SCRIPT_NAME="__SCRIPT_NAME__"
HELM_REPO_NAME="__HELM_REPO_NAME__"   # informational only for OCI
HELM_REPO_URL="__HELM_REPO_URL__"     # informational only for OCI
HELM_CHART="__HELM_CHART__"           # oci://... URL
GITHUB_REPO="__GITHUB_REPO__"         # owner/repo for Releases API
GITHUB_TAG_PREFIX="${GITHUB_TAG_PREFIX:-v}"  # strip from tag_name; "" for bare tags
CHANGELOG_URL="__CHANGELOG_URL__"
CHART_TYPE="__CHART_TYPE__"  # "local" = manages Chart.yaml + values.yaml / "external" = helmfile + values/ only

# Optional: define do_mirror() here in the per-chart CONFIG block to enable
# the Step 7 mirror stage. Contract is documented in the template header
# docstring. If undefined, Step 7 is skipped silently.
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

# Mirror an upstream image reference to a private registry using `crane copy`.
# Idempotent: if the destination digest already matches upstream, copy is
# skipped. Verifies digest match after copy. Aborts (non-zero) on failure.
#
# Usage: mirror_image <upstream-ref> <harbor-ref> [--insecure]
#   --insecure  Pass through to all crane invocations (skips TLS verify).
#               Required for registries with non-standards-compliant certs.
mirror_image() {
  local UPSTREAM_REF="$1"
  local HARBOR_REF="$2"
  local CRANE_FLAGS=()
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --insecure) CRANE_FLAGS+=("--insecure"); shift ;;
      *) echo "  ERROR: mirror_image: unknown flag $1" >&2; return 2 ;;
    esac
  done

  if ! command -v crane > /dev/null; then
    echo "  ERROR: 'crane' is required for the mirror stage." >&2
    echo "         Install: brew install crane (macOS) or" >&2
    echo "         go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
    return 2
  fi

  local upstream_digest=""
  local harbor_digest=""
  upstream_digest=$(crane digest "${CRANE_FLAGS[@]}" "$UPSTREAM_REF" 2>/dev/null || true)
  harbor_digest=$(crane digest "${CRANE_FLAGS[@]}" "$HARBOR_REF" 2>/dev/null || true)

  if [ -z "$upstream_digest" ]; then
    echo "  ERROR: cannot resolve upstream digest for $UPSTREAM_REF" >&2
    return 1
  fi

  if [ -n "$harbor_digest" ] && [ "$upstream_digest" = "$harbor_digest" ]; then
    echo "  SKIP   $UPSTREAM_REF -> $HARBOR_REF (already mirrored, digest=$harbor_digest)"
    return 0
  fi

  echo "  COPY   $UPSTREAM_REF -> $HARBOR_REF"
  if ! crane copy "${CRANE_FLAGS[@]}" "$UPSTREAM_REF" "$HARBOR_REF"; then
    echo "  ERROR: crane copy failed ($UPSTREAM_REF -> $HARBOR_REF)" >&2
    return 1
  fi

  harbor_digest=$(crane digest "${CRANE_FLAGS[@]}" "$HARBOR_REF" 2>/dev/null || true)
  if [ "$upstream_digest" != "$harbor_digest" ]; then
    echo "  ERROR: digest mismatch after copy ($upstream_digest vs $harbor_digest)" >&2
    return 1
  fi
  echo "  OK     $HARBOR_REF (digest=$harbor_digest)"
}

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
  $(basename "$0") --version 1.0.0                # Upgrade to specific version
  $(basename "$0") --exclude old-release,test     # Skip files with 'old-release' or 'test' in name
  $(basename "$0") --dry-run --version 1.0.0      # Combine flags
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
echo "[Step 1/8] Checking current version..."
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

# Step 1 hook: surface the actual image tag(s) used by the cluster (helpful when
# chart appVersion differs from the values file's image.tag override).
#
# Default behavior: print `.image.tag` for each `values/*.yaml`. Per-chart
# CONFIG may override by defining `print_values_summary` (e.g., to show nested
# keys like ghost's `mysql.image.tag`, or to add a BYOI suffix as unity-mcp does).
# yq missing → graceful fallback message.
echo ""
echo "  Values image overrides:"
if declare -F print_values_summary > /dev/null; then
  print_values_summary
elif [ -d "$VALUES_DIR" ] && ls "$VALUES_DIR"/*.yaml > /dev/null 2>&1; then
  if ! command -v yq > /dev/null; then
    echo "    (yq not installed — install with: brew install yq)"
  else
    for _f in "$VALUES_DIR"/*.yaml; do
      [ -f "$_f" ] || continue
      _tag=$(yq '.image.tag // "(unset)"' "$_f" 2>/dev/null || echo "(error)")
      _tag=$(printf '%s' "$_tag" | tr -d '"')
      printf "    %s: image.tag=%s\n" "$(basename "$_f")" "${_tag:-(unset)}"
    done
    unset _f _tag
  fi
else
  echo "    (no values/*.yaml found)"
fi

# Step 2: Fetch latest version from GitHub Releases API (OCI charts have no
# `helm search repo` equivalent, so we read the upstream release feed instead).
# Multi-chart repos (e.g. somaz94/helm-charts) tag releases as
# "<chart>-<version>"; in that case GITHUB_TAG_PREFIX is non-empty and we
# pick the newest release whose tag starts with that prefix. Single-chart
# repos leave GITHUB_TAG_PREFIX as the default "v" and we just take the
# repo's `releases/latest` tag.
echo ""
echo "[Step 2/8] Checking latest version (GitHub Releases: $GITHUB_REPO)..."

# When the prefix matches a chart name (anything other than "v" / ""), the
# repo is multi-chart and `releases/latest` is meaningless for our chart →
# scan up to 30 recent releases and pick the newest matching the prefix.
if [ -n "$GITHUB_TAG_PREFIX" ] && [ "$GITHUB_TAG_PREFIX" != "v" ]; then
  GH_API="https://api.github.com/repos/$GITHUB_REPO/releases?per_page=30"
  LATEST_TAG=$(curl -fsSL \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    -H 'Accept: application/vnd.github+json' \
    "$GH_API" 2>/dev/null \
    | python3 -c "
import json, sys
prefix = '$GITHUB_TAG_PREFIX'
try:
    rels = json.load(sys.stdin)
    for r in rels:
        tag = r.get('tag_name', '')
        if tag.startswith(prefix):
            print(tag)
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null || true)
else
  GH_API="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
  LATEST_TAG=$(curl -fsSL \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    -H 'Accept: application/vnd.github+json' \
    "$GH_API" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tag_name', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

if [ -z "$LATEST_TAG" ]; then
  echo "  ERROR: Failed to fetch latest release from GitHub: $GITHUB_REPO"
  echo "  API: $GH_API"
  if [ -n "$GITHUB_TAG_PREFIX" ] && [ "$GITHUB_TAG_PREFIX" != "v" ]; then
    echo "  (No release within last 30 matched prefix '$GITHUB_TAG_PREFIX'.)"
  fi
  echo "  (If rate-limited, set GITHUB_TOKEN=ghp_... in your environment.)"
  exit 1
fi

# Strip optional tag prefix (default "v") to derive chart version
LATEST_VERSION_FOUND="${LATEST_TAG#$GITHUB_TAG_PREFIX}"

if [ -n "$TARGET_VERSION" ]; then
  echo "  Latest tag       - $LATEST_TAG (chart: $LATEST_VERSION_FOUND)"
  LATEST_VERSION="$TARGET_VERSION"
  echo "  Using target     - Chart: $TARGET_VERSION"
else
  LATEST_VERSION="$LATEST_VERSION_FOUND"
  echo "  Latest    - tag: $LATEST_TAG / Chart: $LATEST_VERSION"
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
echo "[Step 3/8] Fetching Chart.yaml and values.yaml for version $LATEST_VERSION..."
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
echo "[Step 4/8] Chart.yaml diff (current vs target)..."
echo "------------------------------------------------"
diff "$CHART_DIR/Chart.yaml" "$TEMP_DIR/Chart.yaml" || true
echo "------------------------------------------------"

# Step 5: Show values.yaml changes
echo ""
echo "[Step 5/8] values.yaml diff (current vs target)..."
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
echo "[Step 6/8] Checking custom values for breaking changes..."

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
  echo "[Step 7/8] Mirror stage SKIPPED in dry-run."
  echo ""
  echo "[Step 8/8] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

# Step 7: Mirror upstream images to private registry (optional)
# Requires the per-chart CONFIG to define a `do_mirror` Bash function. If
# undefined, this step is silently skipped (matches plain external-oci flow).
if declare -F do_mirror > /dev/null; then
  echo ""
  echo "[Step 7/8] Mirroring upstream images to private registry..."
  if ! do_mirror; then
    echo ""
    echo "  ERROR: mirror stage failed. Aborting upgrade (no files modified)." >&2
    exit 1
  fi
else
  echo ""
  echo "[Step 7/8] Mirror stage skipped (do_mirror not defined in CONFIG)."
fi

echo "[Step 8/8] Applying upgrade..."

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
