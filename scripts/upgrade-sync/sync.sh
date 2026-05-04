#!/bin/bash
set -euo pipefail

# ============================================================
# upgrade-sync/sync.sh
#
# Keeps all per-chart `upgrade.sh` files in sync with their canonical
# templates under `scripts/upgrade-sync/templates/`.
#
# Each managed `upgrade.sh` declares its template via a header comment
# on line 2:
#     # upgrade-template: external-standard
#     # upgrade-template: external-with-image-tag
#     # upgrade-template: local-with-templates
#
# Naming convention: <chart-type>-<feature>.sh
#   chart-type: external (helm repo) | local (Chart.yaml in repo)
#   feature:    standard | with-image-tag | with-templates | ...
# New template variants follow the same convention.
#
# A managed file's structure is:
#     line 1:           #!/bin/bash
#     line 2:           # upgrade-template: <name>
#     line 3:           set -euo pipefail
#     line 4:           (blank)
#     line 5..M:        # ============================================================  (marker 1: doc opens)
#                       # Configuration (per-chart, sync-managed body below)
#                       # ============================================================  (marker 2: doc closes / vars opens)
#                       SCRIPT_NAME=...
#                       ...
#                       # ============================================================  (marker 3: vars closes)
#     line M+1..end:    body (canonical-owned, sync replaces this)
#
# The CONFIG block spans markers 1 through 3 (inclusive) and is user-owned
# (preserved by sync). Everything below marker 3 is canonical-owned and
# replaced from the template's body during --apply.
#
# Portability: works on bash 3.2+ (macOS default) and bash 4+ (Linux).
# No associative arrays, no `sed -i` (uses awk + temp files).
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# -----------------------------------------------
# Helpers
# -----------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  --check              Diff each managed upgrade.sh against its canonical.
                       Exits non-zero if any drift is found. (CI-friendly)
  --apply [--force]    Rewrite each managed upgrade.sh from its canonical.
                       Aborts if the working tree is dirty (use --force to skip).
  --status             Print template assignment + drift summary table.
  --print-expected <file>
                       Print what <file> would look like after sync (stdout).
  --insert-headers     One-shot Phase 2 migration. Inserts the
                       "# upgrade-template: <name>" line on line 2 of every
                       managed upgrade.sh that does not yet have one.
                       Auto-detects template type from file content.
  --no-header          Used with --check before headers are inserted.
                       Skips the header read; auto-detects template type.
  -h, --help           Show this help.

Examples:
  $(basename "$0") --check
  $(basename "$0") --status
  $(basename "$0") --apply
EOF
  exit 0
}

# Find all managed upgrade.sh files (skip backups, deprecated, optional, and the
# canonical templates themselves). `_optional/` charts are activated by moving them
# out of `_optional/`; until then they are out of sync drift scope.
# Backup convention: only `backup/` (no leading underscore). See the
# "backup governance" section in README.md.
find_managed_files() {
  find "$REPO_ROOT" \
    -type f \
    -name 'upgrade.sh' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/_optional/*' \
    -not -path '*/scripts/upgrade-sync/*' \
    | sort
}

# Find chart directories (have Chart.yaml) that do NOT have an upgrade.sh.
find_unmanaged_charts() {
  find "$REPO_ROOT" \
    -type f \
    -name 'Chart.yaml' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/_optional/*' \
    -not -path '*/templates/*' \
    | while read -r chart; do
        local dir=""; dir=$(dirname "$chart")
        if [ ! -f "$dir/upgrade.sh" ]; then
          # Strip repo root prefix for cleaner output
          echo "${dir#$REPO_ROOT/}"
        fi
      done | sort -u
}

# Read the "# upgrade-template: <name>" header from line 2.
# Returns empty string if not present.
read_template_header() {
  local f="$1"
  sed -n '2s/^# upgrade-template: //p' "$f"
}

# Auto-detect template type from file content.
# Used by --insert-headers and --check --no-header.
detect_template() {
  local f="$1"
  # external-oci must precede ansible-github-release: both define GITHUB_REPO=,
  # but only OCI charts have HELM_CHART starting with oci://.
  # Within OCI: external-oci-with-mirror is a superset that defines a
  # `do_mirror()` Bash function for image mirroring; without it, the file
  # uses the plain external-oci body.
  if grep -qE '^HELM_CHART=("|'"'"')?oci://' "$f"; then
    if grep -qE '^do_mirror\(\)' "$f"; then
      echo "external-oci-with-mirror"
    else
      echo "external-oci"
    fi
  elif grep -q '^GITHUB_REPO=' "$f"; then
    echo "ansible-github-release"
  elif grep -q '^VERSION_SOURCE=' "$f"; then
    # local-cr-version owns Chart.yaml (and therefore has MIRROR_CHART_VERSION=);
    # external-oci-cr-version consumes an upstream OCI chart and has no Chart.yaml.
    if grep -q '^MIRROR_CHART_VERSION=' "$f"; then
      echo "local-cr-version"
    else
      echo "external-oci-cr-version"
    fi
  elif grep -q '^CUSTOM_TEMPLATES=' "$f"; then
    echo "local-with-templates"
  elif grep -q 'Update image tags in values files' "$f"; then
    echo "external-with-image-tag"
  else
    echo "external-standard"
  fi
}

# Resolve template name → canonical file path. Aborts if missing.
canonical_path() {
  local name="$1"
  local path="$TEMPLATES_DIR/${name}.sh"
  if [ ! -f "$path" ]; then
    echo "ERROR: canonical template '$name' not found at $path" >&2
    exit 2
  fi
  echo "$path"
}

# Extract the CONFIG block from a file: from the first "# ===" marker
# through the third "# ===" marker (all inclusive). The 3-marker layout is:
#   marker 1: opens the doc comment
#   marker 2: closes the doc comment / opens the variables section
#   marker 3: closes the variables section
extract_config_block() {
  awk '
    /^# ={10,}$/ {
      c++
      print
      if (c == 3) exit
      next
    }
    c >= 1 { print }
  ' "$1"
}

# Extract the body from a file: everything strictly AFTER the third
# "# ===" marker.
extract_body() {
  awk '
    /^# ={10,}$/ { c++; next }
    c >= 3 { print }
  ' "$1"
}

# Build the expected file content for a managed file given its template name.
# Output is written to stdout.
#
# Format:
#   #!/bin/bash
#   # upgrade-template: <name>
#   set -euo pipefail
#   <blank>
#   <CONFIG block extracted from target>
#   <body extracted from canonical>
build_expected() {
  local target="$1"
  local template="$2"
  local canonical=""
  canonical=$(canonical_path "$template")

  printf '#!/bin/bash\n'
  printf '# upgrade-template: %s\n' "$template"
  printf 'set -euo pipefail\n'
  printf '\n'
  extract_config_block "$target"
  extract_body "$canonical"
}

# As above, but used during --check --no-header (before Phase 2 headers exist).
# Skips emitting the drift header line so the output matches a pre-Phase-2 file.
build_expected_no_header() {
  local target="$1"
  local template="$2"
  local canonical=""
  canonical=$(canonical_path "$template")

  printf '#!/bin/bash\n'
  printf 'set -euo pipefail\n'
  printf '\n'
  extract_config_block "$target"
  extract_body "$canonical"
}

# Resolve the template for a target file. Either reads the header (default)
# or auto-detects (if --no-header was passed).
resolve_template() {
  local f="$1"
  local mode="$2"  # "header" or "detect"
  if [ "$mode" = "detect" ]; then
    detect_template "$f"
  else
    local tpl=""
    tpl=$(read_template_header "$f")
    if [ -z "$tpl" ]; then
      echo "ERROR: $f has no '# upgrade-template:' header on line 2" >&2
      echo "       Run with --insert-headers first, or use --check --no-header." >&2
      exit 2
    fi
    echo "$tpl"
  fi
}

# -----------------------------------------------
# Commands
# -----------------------------------------------

cmd_check() {
  local mode="header"
  if [ "${1:-}" = "--no-header" ]; then
    mode="detect"
  fi

  local drift=0
  local total=0
  local skipped=0
  while IFS= read -r f; do
    total=$((total + 1))

    # In header mode, files without a `# upgrade-template:` header are silently
    # skipped (not an error). This lets a repo partially adopt the sync system
    # without forcing all upgrade.sh files to be managed at once.
    if [ "$mode" = "header" ]; then
      local hdr=""; hdr=$(read_template_header "$f")
      if [ -z "$hdr" ]; then
        skipped=$((skipped + 1))
        local rel="${f#$REPO_ROOT/}"
        printf "  SKIP  [no-header        ] %s\n" "$rel"
        continue
      fi
    fi

    local tpl=""
    tpl=$(resolve_template "$f" "$mode")
    local expected
    if [ "$mode" = "detect" ]; then
      expected=$(build_expected_no_header "$f" "$tpl")
    else
      expected=$(build_expected "$f" "$tpl")
    fi
    local rel="${f#$REPO_ROOT/}"
    if diff -q <(printf '%s\n' "$expected") "$f" > /dev/null 2>&1; then
      printf "  OK    [%-16s] %s\n" "$tpl" "$rel"
    else
      printf "  DRIFT [%-16s] %s\n" "$tpl" "$rel"
      drift=$((drift + 1))
    fi
  done < <(find_managed_files)

  echo ""
  local managed=$((total - skipped))
  if [ "$drift" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
      echo "$managed managed file(s) in sync. $skipped skipped (no header)."
    else
      echo "All $total managed file(s) are in sync."
    fi
    return 0
  else
    echo "$drift of $managed managed file(s) have drift. ($skipped skipped, no header)"
    echo "To inspect a specific file:"
    echo "  $(basename "$0") --print-expected <file> | diff - <file>"
    [ "$mode" = "header" ] && echo "To fix: $(basename "$0") --apply"
    return 1
  fi
}

cmd_apply() {
  local force="${1:-}"
  # Guard: working tree must be clean (unless --force)
  if [ "$force" != "--force" ]; then
    if ! git -C "$REPO_ROOT" diff --quiet HEAD -- 2>/dev/null; then
      echo "ERROR: working tree is dirty. Commit or stash before --apply." >&2
      echo "       Use '$(basename "$0") --apply --force' to override." >&2
      echo "       (Run 'git -C $REPO_ROOT status' to see changes.)" >&2
      exit 3
    fi
  fi

  local changed=0
  local total=0
  local skipped=0
  while IFS= read -r f; do
    total=$((total + 1))

    # Skip files without a `# upgrade-template:` header (they are intentionally
    # not managed by sync — e.g., charts with incompatible chart types).
    local hdr=""; hdr=$(read_template_header "$f")
    if [ -z "$hdr" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    local tpl=""
    tpl=$(resolve_template "$f" "header")
    local expected=""
    expected=$(build_expected "$f" "$tpl")
    if ! diff -q <(printf '%s\n' "$expected") "$f" > /dev/null 2>&1; then
      printf '%s\n' "$expected" > "$f"
      chmod +x "$f"
      changed=$((changed + 1))
      printf "  WROTE [%-16s] %s\n" "$tpl" "${f#$REPO_ROOT/}"
    fi
  done < <(find_managed_files)

  echo ""
  local managed=$((total - skipped))
  echo "Updated $changed of $managed managed file(s). ($skipped skipped, no header)"
  if [ "$changed" -gt 0 ]; then
    echo "Review the changes with: git -C $REPO_ROOT diff"
  fi
}

cmd_status() {
  local total=0
  local templates_seen=""
  while IFS= read -r f; do
    total=$((total + 1))
    local tpl=""
    tpl=$(read_template_header "$f")
    [ -z "$tpl" ] && tpl="(no header)"
    templates_seen="$templates_seen$tpl"$'\n'
  done < <(find_managed_files)

  echo "Managed upgrade.sh files: $total"
  if [ -n "$templates_seen" ]; then
    printf '%s' "$templates_seen" | sort | uniq -c | while read -r count name; do
      printf "  %-24s %d\n" "$name:" "$count"
    done
  fi

  echo ""
  echo "Available canonicals:"
  for c in "$TEMPLATES_DIR"/*.sh; do
    [ -f "$c" ] && printf "  %s\n" "$(basename "$c" .sh)"
  done

  echo ""
  echo "Unmanaged chart directories (have Chart.yaml but no upgrade.sh):"
  local unmanaged=""
  unmanaged=$(find_unmanaged_charts)
  if [ -z "$unmanaged" ]; then
    echo "  (none)"
  else
    echo "$unmanaged" | sed 's/^/  - /'
  fi
}

cmd_print_expected() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "ERROR: --print-expected requires a valid file path" >&2
    exit 1
  fi
  # Convert relative path to absolute
  f=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
  local tpl=""
  tpl=$(resolve_template "$f" "header")
  build_expected "$f" "$tpl"
}

cmd_insert_headers() {
  local inserted=0
  local skipped=0
  while IFS= read -r f; do
    if [ -n "$(read_template_header "$f")" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    local tpl=""
    tpl=$(detect_template "$f")
    # Insert "# upgrade-template: <tpl>" after line 1 (after shebang)
    local tmp=""
    tmp=$(mktemp)
    awk -v tpl="$tpl" 'NR==1 {print; print "# upgrade-template: " tpl; next} {print}' "$f" > "$tmp"
    mv "$tmp" "$f"
    inserted=$((inserted + 1))
    printf "  INSERTED [%-16s] %s\n" "$tpl" "${f#$REPO_ROOT/}"
  done < <(find_managed_files)

  echo ""
  echo "Inserted headers in $inserted file(s). Skipped $skipped (already had header)."
}

# -----------------------------------------------
# Main
# -----------------------------------------------

if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  -h|--help)         usage ;;
  --check)           cmd_check "${2:-}" ;;
  --apply)           cmd_apply "${2:-}" ;;
  --status)          cmd_status ;;
  --print-expected)  cmd_print_expected "${2:-}" ;;
  --insert-headers)  cmd_insert_headers ;;
  *)                 echo "Unknown command: $1"; echo ""; usage ;;
esac
