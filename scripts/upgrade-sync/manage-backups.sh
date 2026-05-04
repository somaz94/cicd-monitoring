#!/bin/bash
set -euo pipefail

# zsh nomatch compat: don't fail when "$dir"/2*/ has no matches.
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

# ============================================================
# upgrade-sync/manage-backups.sh
#
# Cross-chart visibility and bulk operations for upgrade.sh-managed backups.
#
# Each managed chart dir produces backups under `<chart>/backup/<TIMESTAMP>/`.
# This tool scans every managed upgrade.sh (same discovery rules as sync.sh)
# and operates on their backup directories collectively.
#
# Commands:
#   --list                List all backup directories with counts and sizes.
#   --total-size          Show total disk usage across all backup/ dirs.
#   --cleanup [--keep N]  Keep last N backups per chart, remove older ones.
#                         Default N=5. Use N=1 to keep only the latest.
#   --purge               Remove ALL backups (requires confirmation).
#
# Portability: bash 3.2+ (macOS default) and bash 4+ (Linux).
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Manage backup directories created by upgrade.sh scripts across all charts.

Commands:
  --list                    List backups per chart (count, size, oldest, newest).
  --total-size              Show total disk usage of all backup/ directories.
  --cleanup [--keep N]      Keep last N backups per chart (default 5).
  --purge                   Remove ALL backups (requires confirmation).
  -h, --help                Show this help.

Examples:
  $(basename "$0") --list
  $(basename "$0") --cleanup --keep 1        # keep only the latest backup
  $(basename "$0") --cleanup --keep 3
  $(basename "$0") --purge                    # remove everything (destructive)
  $(basename "$0") --total-size
EOF
  exit 0
}

# -----------------------------------------------
# Helpers
# -----------------------------------------------

# Find all managed upgrade.sh files (mirrors sync.sh discovery rules).
find_managed_files() {
  find "$REPO_ROOT" \
    -type f \
    -name 'upgrade.sh' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/scripts/upgrade-sync/*' \
    | sort
}

# Human-readable size (bytes -> KB/MB/GB).
human_size() {
  local bytes="$1"
  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes}B"
  elif [ "$bytes" -lt 1048576 ]; then
    echo "$((bytes / 1024))K"
  elif [ "$bytes" -lt 1073741824 ]; then
    printf "%.1fM" "$(awk "BEGIN{print $bytes/1048576}")"
  else
    printf "%.1fG" "$(awk "BEGIN{print $bytes/1073741824}")"
  fi
}

# Count backup dirs and total byte size under a chart's backup/ directory.
# Prints: "<count>\t<bytes>\t<oldest>\t<newest>"
# Returns empty fields if no backups.
chart_backup_stats() {
  local chart_dir="$1"
  local backup_dir="$chart_dir/backup"
  [ -d "$backup_dir" ] || { echo -e "0\t0\t\t"; return; }

  local count=0
  local total_bytes=0
  local oldest=""
  local newest=""

  # Glob is asc by name; backup dirs use YYYYMMDD_HHMMSS so name == time order.
  # 백업 디렉토리는 YYYYMMDD_HHMMSS 형식이라 이름순 == 시간순.
  for d in "$backup_dir"/2*/; do
    [ -d "$d" ] || continue
    count=$((count + 1))
    local name=""
    name=$(basename "$d")
    [ -z "$oldest" ] && oldest="$name"
    newest="$name"
    local size=""
    size=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    total_bytes=$((total_bytes + size * 1024))
  done

  echo -e "${count}\t${total_bytes}\t${oldest}\t${newest}"
}

# Prune old backups in a single chart dir, keep last N.
# Prints: "<removed_count>\t<freed_bytes>"
chart_prune() {
  local chart_dir="$1"
  local keep="$2"
  local backup_dir="$chart_dir/backup"
  [ -d "$backup_dir" ] || { echo -e "0\t0"; return; }

  local total=""
  total=$(ls -d "$backup_dir"/2*/ 2>/dev/null | wc -l | tr -d ' ')
  if [ "$total" -le "$keep" ]; then
    echo -e "0\t0"
    return
  fi
  local to_delete=$((total - keep))
  local freed_bytes=0
  ls -dt "$backup_dir"/2*/ | tail -n "$to_delete" | while read -r d; do
    local size=""
    size=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    rm -rf "$d"
    echo "$size"
  done | while read -r s; do
    freed_bytes=$((freed_bytes + s * 1024))
    echo "$freed_bytes"
  done | tail -1 | {
    read -r total_freed || total_freed=0
    echo -e "${to_delete}\t${total_freed:-0}"
  }
}

# Purge all backups under a chart.
# Prints: "<removed_count>\t<freed_bytes>"
chart_purge() {
  local chart_dir="$1"
  local backup_dir="$chart_dir/backup"
  [ -d "$backup_dir" ] || { echo -e "0\t0"; return; }

  local count=0
  local freed_bytes=0
  for d in "$backup_dir"/2*/; do
    [ -d "$d" ] || continue
    local size=""
    size=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    rm -rf "$d"
    count=$((count + 1))
    freed_bytes=$((freed_bytes + size * 1024))
  done
  # Remove empty backup/ directory too.
  rmdir "$backup_dir" 2>/dev/null || true
  echo -e "${count}\t${freed_bytes}"
}

# -----------------------------------------------
# Commands
# -----------------------------------------------

cmd_list() {
  printf '  %-50s %-7s %-8s %-17s %s\n' \
    "CHART" "COUNT" "SIZE" "OLDEST" "NEWEST"
  printf '  %-50s %-7s %-8s %-17s %s\n' \
    "-----" "-----" "----" "------" "------"
  local grand_count=0
  local grand_bytes=0
  while IFS= read -r f; do
    local chart_dir=""; chart_dir=$(dirname "$f")
    local rel="${chart_dir#$REPO_ROOT/}"
    local stats=""; stats=$(chart_backup_stats "$chart_dir")
    local count="" bytes="" oldest="" newest=""
    IFS=$'\t' read -r count bytes oldest newest <<< "$stats"
    [ "$count" -eq 0 ] && continue
    grand_count=$((grand_count + count))
    grand_bytes=$((grand_bytes + bytes))
    printf '  %-50s %-7s %-8s %-17s %s\n' \
      "$rel" "$count" "$(human_size "$bytes")" "$oldest" "$newest"
  done < <(find_managed_files)
  echo ""
  printf '  Total: %d backup(s) across all charts, %s\n' \
    "$grand_count" "$(human_size "$grand_bytes")"
}

cmd_total_size() {
  local grand_count=0
  local grand_bytes=0
  local chart_count=0
  while IFS= read -r f; do
    local chart_dir=""; chart_dir=$(dirname "$f")
    local stats=""; stats=$(chart_backup_stats "$chart_dir")
    local count="" bytes="" _="" _=""
    IFS=$'\t' read -r count bytes _ _ <<< "$stats"
    [ "$count" -eq 0 ] && continue
    chart_count=$((chart_count + 1))
    grand_count=$((grand_count + count))
    grand_bytes=$((grand_bytes + bytes))
  done < <(find_managed_files)
  printf 'Total: %d backup(s) in %d chart(s), %s\n' \
    "$grand_count" "$chart_count" "$(human_size "$grand_bytes")"
}

cmd_cleanup() {
  local keep="${1:-5}"
  if ! [[ "$keep" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --keep requires a non-negative integer (got: $keep)" >&2
    exit 2
  fi

  echo "Pruning backups across all charts (keep last $keep per chart)..."
  echo ""
  local total_removed=0
  local total_freed=0
  while IFS= read -r f; do
    local chart_dir=""; chart_dir=$(dirname "$f")
    local rel="${chart_dir#$REPO_ROOT/}"
    local result=""; result=$(chart_prune "$chart_dir" "$keep")
    local removed="" freed=""
    IFS=$'\t' read -r removed freed <<< "$result"
    [ "$removed" -eq 0 ] && continue
    total_removed=$((total_removed + removed))
    total_freed=$((total_freed + freed))
    printf '  %-50s removed=%d, freed=%s\n' \
      "$rel" "$removed" "$(human_size "$freed")"
  done < <(find_managed_files)
  echo ""
  if [ "$total_removed" -eq 0 ]; then
    echo "Nothing to clean up (all charts within retention)."
  else
    printf 'Removed %d backup(s) total, freed %s.\n' \
      "$total_removed" "$(human_size "$total_freed")"
  fi
}

cmd_purge() {
  echo "WARNING: This will REMOVE ALL backups under every managed chart's backup/ directory."
  echo "         Existing rollback snapshots will be lost."
  echo ""
  read -rp "Type 'PURGE' to confirm: " confirm
  if [ "$confirm" != "PURGE" ]; then
    echo "Aborted."
    exit 1
  fi

  echo ""
  local total_removed=0
  local total_freed=0
  while IFS= read -r f; do
    local chart_dir=""; chart_dir=$(dirname "$f")
    local rel="${chart_dir#$REPO_ROOT/}"
    local result=""; result=$(chart_purge "$chart_dir")
    local removed="" freed=""
    IFS=$'\t' read -r removed freed <<< "$result"
    [ "$removed" -eq 0 ] && continue
    total_removed=$((total_removed + removed))
    total_freed=$((total_freed + freed))
    printf '  %-50s removed=%d, freed=%s\n' \
      "$rel" "$removed" "$(human_size "$freed")"
  done < <(find_managed_files)
  echo ""
  if [ "$total_removed" -eq 0 ]; then
    echo "No backups found."
  else
    printf 'Purged %d backup(s) total, freed %s.\n' \
      "$total_removed" "$(human_size "$total_freed")"
  fi
}

# -----------------------------------------------
# Main
# -----------------------------------------------

if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  -h|--help)     usage ;;
  --list)        cmd_list ;;
  --total-size)  cmd_total_size ;;
  --cleanup)
    KEEP=5
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --keep)
          KEEP="${2:-}"
          if [ -z "$KEEP" ]; then
            echo "ERROR: --keep requires a number" >&2
            exit 2
          fi
          shift 2
          ;;
        *) echo "Unknown option: $1"; echo ""; usage ;;
      esac
    done
    cmd_cleanup "$KEEP"
    ;;
  --purge)       cmd_purge ;;
  *)             echo "Unknown command: $1"; echo ""; usage ;;
esac
