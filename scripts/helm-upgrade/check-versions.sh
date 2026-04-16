#!/bin/bash
set -euo pipefail

# ============================================================
# helm-upgrade/check-versions.sh
#
# Read-only preflight: scans every managed upgrade.sh, reads its
# CONFIG block, queries the upstream source, and prints which
# charts have an upgrade available. Does NOT modify any files.
#
# Intended flow:
#   ./scripts/helm-upgrade/check-versions.sh      # see what's upgradable
#   cd <chart-dir> && ./upgrade.sh --dry-run      # inspect one chart
#   cd <chart-dir> && ./upgrade.sh                # apply
#
# Supported upstream sources (by template header):
#   external-standard        -> helm search repo
#   external-with-image-tag  -> helm search repo
#   local-with-templates     -> helm search repo OR git ls-remote --tags
#                               (git mode when CHART_GIT_REPO is non-empty)
#   local-cr-version         -> VERSION_SOURCE feed (e.g. elastic-artifacts)
#
# Portability: bash 3.2+ (macOS default), POSIX-ish awk, no `sed -i`.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Scans all managed upgrade.sh files and reports charts that have an
upstream upgrade available. Read-only; no files are modified.

Options:
  --only <substring>   Only check paths whose relative path contains
                       <substring>. Repeatable.
  --no-update          Skip 'helm repo update' (faster on repeated runs).
  --updates-only       Only print rows with status UPDATE or ERROR.
  -h, --help           Show this help.

Exit codes:
  0  All scans succeeded (regardless of whether upgrades were found).
  1  One or more scans failed (network, missing helm, bad config, etc).

Examples:
  $(basename "$0")
  $(basename "$0") --updates-only
  $(basename "$0") --only observability/monitoring
  $(basename "$0") --only argo-cd --only valkey
EOF
  exit 0
}

# -----------------------------------------------
# File discovery (mirrors sync.sh rules)
# -----------------------------------------------

find_managed_files() {
  find "$REPO_ROOT" \
    -type f \
    -name 'upgrade.sh' \
    -not -path '*/backup/*' \
    -not -path '*/_deprecated/*' \
    -not -path '*/scripts/helm-upgrade/*' \
    | sort
}

read_template_header() {
  sed -n '2s/^# upgrade-template: //p' "$1"
}

# Extract the CONFIG block (first `# ===` through third, inclusive).
# The returned text is safe to eval in a subshell because it only
# contains variable assignments (plus comments/markers).
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

# Source the CONFIG block in a subshell and emit the fields we care
# about as shell-quoted KEY=VAL lines. The caller `eval`s the output
# to pull those vars into its own scope.
dump_config_vars() {
  local f="$1"
  local block
  block=$(extract_config_block "$f")
  (
    set +u
    SCRIPT_NAME=""; HELM_REPO_NAME=""; HELM_REPO_URL=""; HELM_CHART=""
    CHART_TYPE=""; CHART_GIT_REPO=""; CHART_GIT_PATH=""
    VERSION_SOURCE=""; VERSION_SOURCE_ARG=""
    VALUES_FILE=""; VERSION_KEY=""; MAJOR_PIN=""
    CONTAINER_IMAGE=""
    # CONFIG block lives in our own repo, so eval is safe here.
    eval "$block" 2>/dev/null || true
    printf 'SCRIPT_NAME=%q\n' "${SCRIPT_NAME:-}"
    printf 'HELM_REPO_NAME=%q\n' "${HELM_REPO_NAME:-}"
    printf 'HELM_REPO_URL=%q\n' "${HELM_REPO_URL:-}"
    printf 'HELM_CHART=%q\n' "${HELM_CHART:-}"
    printf 'CHART_TYPE=%q\n' "${CHART_TYPE:-}"
    printf 'CHART_GIT_REPO=%q\n' "${CHART_GIT_REPO:-}"
    printf 'CHART_GIT_PATH=%q\n' "${CHART_GIT_PATH:-}"
    printf 'VERSION_SOURCE=%q\n' "${VERSION_SOURCE:-}"
    printf 'VERSION_SOURCE_ARG=%q\n' "${VERSION_SOURCE_ARG:-}"
    printf 'VALUES_FILE=%q\n' "${VALUES_FILE:-}"
    printf 'VERSION_KEY=%q\n' "${VERSION_KEY:-}"
    printf 'MAJOR_PIN=%q\n' "${MAJOR_PIN:-}"
    printf 'CONTAINER_IMAGE=%q\n' "${CONTAINER_IMAGE:-}"
  )
}

# Read a top-level YAML string value. Handles "X" / 'X' / bare.
# (Mirrors the helper in the local-cr-version canonical.)
read_yaml_value() {
  local file="$1" key="$2"
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

# -----------------------------------------------
# Upstream fetchers
# -----------------------------------------------

fetch_latest_helm_repo() {
  local chart="$1"
  helm search repo "$chart" --output json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d:
    print(d[0].get('version', ''))
" 2>/dev/null
}

fetch_latest_git_tags() {
  local repo="$1"
  git ls-remote --tags --refs --sort='-v:refname' "$repo" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//'
}

fetch_ga_versions_source() {
  local src="$1" major_pin="$2" src_arg="${3:-}"
  case "$src" in
    elastic-artifacts)
      curl -sSfL "https://artifacts-api.elastic.co/v1/versions" 2>/dev/null \
        | MAJOR_PIN="$major_pin" python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
versions = d.get('versions', [])
ga = [v for v in versions if re.fullmatch(r'\d+\.\d+\.\d+', v)]
major = os.environ.get('MAJOR_PIN', '').strip()
if major:
    ga = [v for v in ga if v.startswith(major + '.')]
ga.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
for v in ga:
    print(v)
" 2>/dev/null
      ;;
    github-releases)
      [ -z "$src_arg" ] && return 0
      curl -sSfL "https://api.github.com/repos/$src_arg/releases?per_page=100" 2>/dev/null \
        | MAJOR_PIN="$major_pin" python3 -c "
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
      ;;
    docker-hub-tags)
      [ -z "$src_arg" ] && return 0
      curl -sSfL "https://hub.docker.com/v2/repositories/$src_arg/tags?page_size=100&ordering=last_updated" 2>/dev/null \
        | MAJOR_PIN="$major_pin" python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tags = [t.get('name', '') for t in d.get('results', [])]
tags = [re.sub(r'^v', '', t) for t in tags]
ga = [t for t in tags if re.fullmatch(r'\d+\.\d+\.\d+', t)]
major = os.environ.get('MAJOR_PIN', '').strip()
if major:
    ga = [t for t in ga if t.startswith(major + '.')]
ga.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
for v in ga:
    print(v)
" 2>/dev/null
      ;;
    *)
      ;;
  esac
}

fetch_latest_version_source() {
  local src="$1" major_pin="$2" src_arg="${3:-}"
  fetch_ga_versions_source "$src" "$major_pin" "$src_arg" | head -1
}

# Find newest version with a published image by walking the GA list.
# Caps at max_attempts to avoid long waits.
find_latest_available_source() {
  local src="$1" major_pin="$2" image="$3" src_arg="${4:-}"
  local max_attempts=15
  local attempt=0
  while IFS= read -r v; do
    attempt=$((attempt + 1))
    [ "$attempt" -gt "$max_attempts" ] && break
    if verify_image_exists "$image" "$v"; then
      echo "$v"
      return 0
    fi
  done < <(fetch_ga_versions_source "$src" "$major_pin" "$src_arg")
  return 1
}

# Verify that a container image tag exists in the registry.
# Uses Docker Registry HTTP API v2 with bearer token authentication.
# Returns 0 if found (or image is empty), 1 if not found.
verify_image_exists() {
  local image="$1" tag="$2"
  [ -z "$image" ] || [ -z "$tag" ] && return 0
  local registry="${image%%/*}"
  local repo="${image#*/}"
  local manifest_url="https://${registry}/v2/${repo}/manifests/${tag}"
  local auth_header
  auth_header=$(curl -sSL -I "$manifest_url" 2>/dev/null \
    | grep -i '^www-authenticate:' | head -1) || true
  local http_code
  if [ -n "$auth_header" ]; then
    local realm service scope
    realm=$(echo "$auth_header" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
    service=$(echo "$auth_header" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
    scope=$(echo "$auth_header" | sed -n 's/.*scope="\([^"]*\)".*/\1/p')
    if [ -n "$realm" ]; then
      local token
      token=$(curl -sSL "${realm}?service=${service}&scope=${scope}" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null) || true
      if [ -n "$token" ]; then
        http_code=$(curl -sSL -o /dev/null -w '%{http_code}' \
          -H "Authorization: Bearer $token" \
          -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
          "$manifest_url" 2>/dev/null) || true
        [ "$http_code" = "200" ] && return 0
        return 1
      fi
    fi
  fi
  http_code=$(curl -sSL -o /dev/null -w '%{http_code}' \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "$manifest_url" 2>/dev/null) || true
  [ "$http_code" = "200" ]
}

# -----------------------------------------------
# Argument parsing
# -----------------------------------------------

ONLY_PATTERNS=()
NO_UPDATE=false
UPDATES_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage ;;
    --only)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --only requires a substring" >&2
        exit 2
      fi
      ONLY_PATTERNS+=("$2"); shift 2 ;;
    --no-update)    NO_UPDATE=true; shift ;;
    --updates-only) UPDATES_ONLY=true; shift ;;
    *)              echo "Unknown option: $1"; echo ""; usage ;;
  esac
done

matches_only() {
  local rel="$1"
  if [ "${#ONLY_PATTERNS[@]}" -eq 0 ]; then
    return 0
  fi
  local pat
  for pat in "${ONLY_PATTERNS[@]}"; do
    [[ "$rel" == *"$pat"* ]] && return 0
  done
  return 1
}

# -----------------------------------------------
# Phase 1: parse every managed upgrade.sh
# -----------------------------------------------

ROWS=()         # rel \t tpl \t label \t current \t fetcher \t fetcher_arg \t extra_arg \t container_image \t version_source_arg
HELM_REPOS=()   # "name=url" pairs (deduped later)

echo "Collecting managed upgrade.sh configs..."
total=0
skipped=0
filtered=0
while IFS= read -r f; do
  total=$((total + 1))
  rel="${f#$REPO_ROOT/}"

  tpl=$(read_template_header "$f")
  if [ -z "$tpl" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  if ! matches_only "$rel"; then
    filtered=$((filtered + 1))
    continue
  fi

  # Pull CONFIG vars into this scope (temporarily; overwritten per file).
  eval "$(dump_config_vars "$f")"

  current=""
  fetcher=""
  fetcher_arg=""
  extra_arg=""
  label="${SCRIPT_NAME:-$(basename "$(dirname "$f")")}"
  chart_dir=$(dirname "$f")

  case "$tpl" in
    external-standard|external-with-image-tag)
      [ -f "$chart_dir/Chart.yaml" ] && current=$(read_yaml_value "$chart_dir/Chart.yaml" "version")
      fetcher="helm-repo"
      fetcher_arg="$HELM_CHART"
      if [ -n "$HELM_REPO_NAME" ] && [ -n "$HELM_REPO_URL" ]; then
        HELM_REPOS+=("$HELM_REPO_NAME=$HELM_REPO_URL")
      fi
      ;;
    local-with-templates)
      [ -f "$chart_dir/Chart.yaml" ] && current=$(read_yaml_value "$chart_dir/Chart.yaml" "version")
      if [ -n "$CHART_GIT_REPO" ]; then
        fetcher="git-tags"
        fetcher_arg="$CHART_GIT_REPO"
      else
        fetcher="helm-repo"
        fetcher_arg="$HELM_CHART"
        if [ -n "$HELM_REPO_NAME" ] && [ -n "$HELM_REPO_URL" ]; then
          HELM_REPOS+=("$HELM_REPO_NAME=$HELM_REPO_URL")
        fi
      fi
      ;;
    local-cr-version)
      if [ -n "$VALUES_FILE" ] && [ -f "$chart_dir/$VALUES_FILE" ] && [ -n "$VERSION_KEY" ]; then
        current=$(read_yaml_value "$chart_dir/$VALUES_FILE" "$VERSION_KEY")
      fi
      fetcher="version-source"
      fetcher_arg="$VERSION_SOURCE"
      extra_arg="$MAJOR_PIN"
      ;;
    *)
      fetcher="unknown"
      ;;
  esac

  ROWS+=("$rel"$'\t'"$tpl"$'\t'"$label"$'\t'"$current"$'\t'"$fetcher"$'\t'"$fetcher_arg"$'\t'"$extra_arg"$'\t'"${CONTAINER_IMAGE:-}"$'\t'"${VERSION_SOURCE_ARG:-}")
done < <(find_managed_files)

managed=$((total - skipped))
if [ "$filtered" -gt 0 ]; then
  echo "  Managed: $managed  Skipped (no header): $skipped  Filtered out by --only: $filtered"
else
  echo "  Managed: $managed  Skipped (no header): $skipped"
fi

if [ "${#ROWS[@]}" -eq 0 ]; then
  echo ""
  echo "No files to check."
  exit 0
fi

# -----------------------------------------------
# Phase 2: set up helm repos once (register + update)
# -----------------------------------------------

HELM_AVAILABLE=false
if command -v helm >/dev/null 2>&1; then
  HELM_AVAILABLE=true
  if [ "${#HELM_REPOS[@]}" -gt 0 ]; then
    uniq_repos=()
    for pair in "${HELM_REPOS[@]}"; do
      exists=false
      for u in "${uniq_repos[@]:-}"; do
        [ "$u" = "$pair" ] && exists=true && break
      done
      $exists || uniq_repos+=("$pair")
    done
    echo "Registering ${#uniq_repos[@]} helm repo(s)..."
    for pair in "${uniq_repos[@]}"; do
      name="${pair%%=*}"
      url="${pair#*=}"
      helm repo add "$name" "$url" > /dev/null 2>&1 || true
    done
    if ! $NO_UPDATE; then
      echo "Running 'helm repo update'..."
      helm repo update > /dev/null 2>&1 || echo "  WARN: helm repo update failed (stale cache will be used)"
    fi
  fi
else
  echo "WARN: 'helm' not found on PATH — helm-repo checks will error out."
fi

# -----------------------------------------------
# Phase 3: query upstream + print table
# -----------------------------------------------

echo ""
printf '  %-7s  %-24s  %-15s  %-15s  %s\n' "STATUS" "TEMPLATE" "CURRENT" "LATEST" "PATH"
printf '  %-7s  %-24s  %-15s  %-15s  %s\n' "-------" "------------------------" "---------------" "---------------" "----"

any_update=0
any_error=0
ok_count=0
update_count=0
error_count=0

no_image_count=0

for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r rel tpl label current fetcher fetcher_arg extra_arg container_image version_source_arg <<< "$row"

  latest=""
  err=""

  case "$fetcher" in
    helm-repo)
      if $HELM_AVAILABLE; then
        if [ -z "$fetcher_arg" ]; then
          err="HELM_CHART empty in CONFIG"
        else
          latest=$(fetch_latest_helm_repo "$fetcher_arg")
          [ -z "$latest" ] && err="helm search repo '$fetcher_arg' returned nothing"
        fi
      else
        err="helm not installed"
      fi
      ;;
    git-tags)
      if ! command -v git >/dev/null 2>&1; then
        err="git not installed"
      else
        latest=$(fetch_latest_git_tags "$fetcher_arg")
        [ -z "$latest" ] && err="git ls-remote --tags '$fetcher_arg' returned no semver"
      fi
      ;;
    version-source)
      if [ -z "$fetcher_arg" ]; then
        err="VERSION_SOURCE empty in CONFIG"
      else
        latest=$(fetch_latest_version_source "$fetcher_arg" "$extra_arg" "$version_source_arg")
        [ -z "$latest" ] && err="version-source '$fetcher_arg' failed or unsupported"
      fi
      ;;
    unknown|*)
      err="unknown template '$tpl'"
      ;;
  esac

  if [ -n "$err" ]; then
    status="ERROR"
    error_count=$((error_count + 1))
    any_error=1
    latest="${latest:-—}"
  elif [ -z "$current" ]; then
    status="ERROR"
    err="could not read current version"
    error_count=$((error_count + 1))
    any_error=1
    current="—"
  elif [ "$current" = "$latest" ]; then
    status="OK"
    ok_count=$((ok_count + 1))
  else
    # Verify container image exists for local-cr-version charts.
    if [ -n "$container_image" ] && ! verify_image_exists "$container_image" "$latest"; then
      # Search for the newest version with a published image.
      available=$(find_latest_available_source "$fetcher_arg" "$extra_arg" "$container_image" "$version_source_arg" 2>/dev/null) || true
      if [ -n "$available" ] && [ "$available" != "$current" ]; then
        status="NO_IMG"
        err="$latest image missing; latest available: $available (use --version $available)"
        latest="$latest (→$available)"
      else
        status="NO_IMG"
        err="image $container_image:$latest not found; no older published image found"
      fi
      no_image_count=$((no_image_count + 1))
    else
      status="UPDATE"
      update_count=$((update_count + 1))
      any_update=1
    fi
  fi

  if $UPDATES_ONLY && [ "$status" = "OK" ]; then
    continue
  fi
  # NO_IMG is relevant when filtering for updates — show it.
  # (It signals "upgrade available but not safe to apply yet.")

  printf '  %-7s  %-24s  %-15s  %-15s  %s\n' \
    "$status" "$tpl" "${current:-—}" "${latest:-—}" "$rel"
  if [ -n "$err" ]; then
    printf '           -> %s\n' "$err"
  fi
done

echo ""
if [ "$no_image_count" -gt 0 ]; then
  echo "Summary: OK=$ok_count  UPDATE=$update_count  NO_IMG=$no_image_count  ERROR=$error_count  (total=${#ROWS[@]})"
else
  echo "Summary: OK=$ok_count  UPDATE=$update_count  ERROR=$error_count  (total=${#ROWS[@]})"
fi
if [ "$any_update" -eq 1 ]; then
  echo "Upgrades are available. Run 'cd <path> && ./upgrade.sh --dry-run' in each directory above."
elif [ "$any_error" -eq 0 ] && [ "$no_image_count" -eq 0 ]; then
  echo "All managed charts are up to date."
fi
if [ "$no_image_count" -gt 0 ]; then
  echo "NO_IMG: version listed in upstream feed but container image not published yet. Wait or skip."
fi

if [ "$any_error" -eq 1 ]; then
  exit 1
fi
exit 0
