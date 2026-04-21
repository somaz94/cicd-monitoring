#!/bin/bash
# upgrade-template: external-oci-cr-version
set -euo pipefail

# ============================================================
# Configuration (ONLY section that differs between scripts)
# ============================================================
SCRIPT_NAME="Kibana (ECK CR, OCI chart) Stack Version Upgrade Script"
COMPONENT_LABEL="kibana"
VERSION_SOURCE="elastic-artifacts"
VERSION_SOURCE_ARG=""
VALUES_FILE="values/mgmt.yaml"
VERSION_KEY="version"
MAJOR_PIN="9"
CHANGELOG_URL="https://www.elastic.co/guide/en/kibana/current/release-notes.html"
CONTAINER_IMAGE="docker.elastic.co/kibana/kibana"
CR_WEBHOOK_NAME="elastic-operator.elastic-system.k8s.elastic.co"
CR_OPERATOR_NS="elastic-system"
CR_OPERATOR_STS="elastic-operator"
CR_OPERATOR_CHART_DIR="eck-operator"
DEPENDENCY_CR_KIND="elasticsearch"
DEPENDENCY_CR_NAME="elasticsearch"
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
Tracks the upstream version of a Custom Resource's component (Stack/app version)
and bumps the version field inside $VALUES_FILE. The OCI chart version in
helmfile.yaml is NOT touched — bump that manually after reviewing chart notes.

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

# Read the version field from a backup's values file.
# Usage: read_backup_version <backup_dir>
read_backup_version() {
  local dir="$1"
  local f="$dir/$(basename "$VALUES_FILE")"
  [ -f "$f" ] || { echo ""; return; }
  awk -v k="$VERSION_KEY" '
    $0 ~ "^" k ":" {
      sub("^" k ":[[:space:]]*", "")
      gsub(/^["\x27]|["\x27]$/, "")
      sub(/[[:space:]]+#.*$/, "")
      print
      exit
    }
  ' "$f"
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
    local ver=""
    ver=$(read_backup_version "$dir")
    local files=$(ls "$dir" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (%s: %s) — %s\n" "$i" "$dirname" "$VERSION_KEY" "${ver:-unknown}" "$files"
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

  # Read the backup version to detect downgrades.
  local backup_ver=""
  backup_ver=$(read_backup_version "$selected")

  # Detect live CR version via kubectl (best-effort).
  local live_ver=""
  local is_downgrade=false
  if command -v kubectl >/dev/null 2>&1 && [ -n "$COMPONENT_LABEL" ]; then
    local ns=""
    if [ -f "$CHART_DIR/helmfile.yaml" ]; then
      ns=$(awk '/namespace:/ {print $2; exit}' "$CHART_DIR/helmfile.yaml" | tr -d '"' | tr -d "'")
    fi
    if [ -n "$ns" ]; then
      live_ver=$(kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" \
        -o jsonpath='{.spec.version}' 2>/dev/null) || true
    fi
  fi

  if [ -n "$live_ver" ] && [ -n "$backup_ver" ] && [ "$live_ver" != "$backup_ver" ]; then
    local live_tuple backup_tuple
    live_tuple=$(echo "$live_ver" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
    backup_tuple=$(echo "$backup_ver" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
    if [ "$backup_tuple" -lt "$live_tuple" ]; then
      is_downgrade=true
    fi
  fi

  echo ""
  echo "Restoring from backup/$dirname..."

  if [ -f "$selected/$(basename "$VALUES_FILE")" ]; then
    cp "$selected/$(basename "$VALUES_FILE")" "$CHART_DIR/$VALUES_FILE"
    echo "  Restored $VALUES_FILE"
  else
    echo "  WARN: backup does not contain $(basename "$VALUES_FILE"); nothing to restore."
    exit 1
  fi

  if $is_downgrade; then
    echo ""
    echo "  WARNING: This is a version downgrade ($live_ver -> $backup_ver)."
    echo "  Operator admission webhooks typically block CR version downgrades."

    if [ -n "$CR_WEBHOOK_NAME" ] && [ -n "$CR_OPERATOR_NS" ] && [ -n "$CR_OPERATOR_STS" ]; then
      echo ""
      read -rp "  Automatically handle the webhook and apply rollback? [y/N]: " auto_apply
      if [[ "$auto_apply" =~ ^[Yy]$ ]]; then
        rollback_with_webhook_handling
        return
      fi
    fi

    echo ""
    echo "  To apply this rollback manually:"
    echo "    1. kubectl -n $CR_OPERATOR_NS scale sts $CR_OPERATOR_STS --replicas=0"
    echo "    2. kubectl delete validatingwebhookconfiguration $CR_WEBHOOK_NAME --ignore-not-found"
    echo "    3. If 'helm list -n <ns>' shows status=failed:"
    echo "         helm rollback <release> <last-good-revision> -n <ns>"
    echo "    4. helmfile apply"
    echo "    5. Recreate webhook: cd <eck-operator-dir> && helmfile sync"
    echo "    6. kubectl -n $CR_OPERATOR_NS scale sts $CR_OPERATOR_STS --replicas=1"
    echo "    7. Wait for CR: kubectl -n <ns> wait $COMPONENT_LABEL/$COMPONENT_LABEL --for=jsonpath='{.status.phase}'=Ready --timeout=300s"
    return
  fi

  echo ""
  echo "Rollback complete! Run 'helmfile diff' to verify, then 'helmfile apply'."
}

# Handles the full rollback cycle when a version downgrade requires
# bypassing the operator admission webhook.
rollback_with_webhook_handling() {
  # Read release name and namespace from helmfile.yaml for Helm state recovery.
  local release_name="" release_ns=""
  if [ -f "$CHART_DIR/helmfile.yaml" ]; then
    release_name=$(awk '/- name:/ {print $3; exit}' "$CHART_DIR/helmfile.yaml" | tr -d '"' | tr -d "'")
    release_ns=$(awk '/namespace:/ {print $2; exit}' "$CHART_DIR/helmfile.yaml" | tr -d '"' | tr -d "'")
  fi

  echo ""
  echo "  [1/7] Scaling down operator ($CR_OPERATOR_NS/$CR_OPERATOR_STS)..."
  kubectl -n "$CR_OPERATOR_NS" scale statefulset "$CR_OPERATOR_STS" --replicas=0
  # Wait for operator pod to terminate.
  kubectl -n "$CR_OPERATOR_NS" wait --for=delete pod/"${CR_OPERATOR_STS}-0" --timeout=60s 2>/dev/null || true

  echo "  [2/7] Removing admission webhook ($CR_WEBHOOK_NAME)..."
  kubectl delete validatingwebhookconfiguration "$CR_WEBHOOK_NAME" --ignore-not-found

  # Recover Helm release from 'failed' state.
  echo "  [3/7] Recovering Helm release state..."
  if [ -n "$release_name" ] && [ -n "$release_ns" ]; then
    local helm_status
    helm_status=$(helm status "$release_name" -n "$release_ns" -o json 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null) || true
    if [ "$helm_status" = "failed" ]; then
      echo "    Helm release '$release_name' is in 'failed' state. Rolling back to last successful revision..."
      local last_good
      last_good=$(helm history "$release_name" -n "$release_ns" -o json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    h = json.load(sys.stdin)
    good = [r for r in h if r.get('status') in ('deployed', 'superseded')]
    good.sort(key=lambda r: r.get('revision', 0), reverse=True)
    print(good[0]['revision'] if good else '')
except Exception:
    pass
" 2>/dev/null) || true
      if [ -n "$last_good" ]; then
        helm rollback "$release_name" "$last_good" -n "$release_ns"
        echo "    Rolled back to revision $last_good."
      else
        echo "    WARN: no successful revision found. Proceeding with helmfile apply."
      fi
    else
      echo "    Helm release is clean (status: ${helm_status:-unknown})."
    fi
  else
    echo "    WARN: could not read release info from helmfile.yaml. Skipping Helm recovery."
  fi

  echo "  [4/7] Applying rollback via helmfile..."
  (cd "$CHART_DIR" && helmfile apply)

  echo "  [5/7] Recreating webhook via operator helmfile sync..."
  local operator_dir=""
  if [ -n "$CR_OPERATOR_CHART_DIR" ]; then
    local search_base="$CHART_DIR"
    while [ "$search_base" != "/" ]; do
      if [ -f "$search_base/$CR_OPERATOR_CHART_DIR/helmfile.yaml" ]; then
        operator_dir="$search_base/$CR_OPERATOR_CHART_DIR"
        break
      fi
      search_base=$(dirname "$search_base")
    done
  fi
  if [ -n "$operator_dir" ]; then
    (cd "$operator_dir" && helmfile sync)
  elif [ -n "$CR_OPERATOR_CHART_DIR" ]; then
    echo "    WARN: operator chart dir '$CR_OPERATOR_CHART_DIR' not found. Recreate the webhook manually."
  else
    echo "    SKIP: CR_OPERATOR_CHART_DIR not configured. Recreate the webhook manually."
  fi

  echo "  [6/7] Scaling operator back up and waiting for Ready..."
  kubectl -n "$CR_OPERATOR_NS" scale statefulset "$CR_OPERATOR_STS" --replicas=1
  wait_for_operator_ready 120

  echo "  [7/7] Waiting for CR to reach Ready state..."
  wait_for_cr_ready 300

  echo ""
  echo "Rollback complete! Cluster CR has been restored to the backup version."
  echo "Final status: kubectl -n <ns> get $COMPONENT_LABEL"
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

# Silent variant called at the end of a successful upgrade.
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
  local tmp
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

# Fetch sorted list of GA versions (newest first, respecting MAJOR_PIN).
fetch_ga_versions() {
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
      [ -z "$VERSION_SOURCE_ARG" ] && return 0
      local url="https://api.github.com/repos/$VERSION_SOURCE_ARG/releases?per_page=100"
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
      ;;
    docker-hub-tags)
      [ -z "$VERSION_SOURCE_ARG" ] && return 0
      local url="https://hub.docker.com/v2/repositories/$VERSION_SOURCE_ARG/tags?page_size=100&ordering=last_updated"
      curl -sSfL "$url" 2>/dev/null | python3 -c "
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

fetch_latest_version() {
  fetch_ga_versions | head -1
}

find_latest_available_version() {
  local max_attempts=15
  local attempt=0
  while IFS= read -r v; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$max_attempts" ]; then
      echo "    (stopped after $max_attempts attempts)" >&2
      break
    fi
    if verify_image_exists "$v"; then
      echo "    $v: available" >&2
      echo "$v"
      return 0
    fi
    echo "    $v: not found" >&2
  done < <(fetch_ga_versions)
  return 1
}

semver_compare() {
  local a_tuple b_tuple
  a_tuple=$(echo "$1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
  b_tuple=$(echo "$2" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
  if [ "$a_tuple" -lt "$b_tuple" ]; then
    echo -1
  elif [ "$a_tuple" -gt "$b_tuple" ]; then
    echo 1
  else
    echo 0
  fi
}

get_release_namespace() {
  [ -f "$CHART_DIR/helmfile.yaml" ] || return 0
  awk '/namespace:/ {print $2; exit}' "$CHART_DIR/helmfile.yaml" | tr -d '"' | tr -d "'"
}

check_cluster_health() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "  Skipped (kubectl not available)."
    return 0
  fi
  [ -z "$COMPONENT_LABEL" ] && return 0
  local ns
  ns=$(get_release_namespace)
  if [ -z "$ns" ]; then
    echo "  Skipped (namespace not readable from helmfile.yaml)."
    return 0
  fi
  if ! kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" >/dev/null 2>&1; then
    echo "  CR not found in ns/$ns (first install?). Skipping health check."
    return 0
  fi
  local phase health
  phase=$(kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" -o jsonpath='{.status.phase}' 2>/dev/null)
  health=$(kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" -o jsonpath='{.status.health}' 2>/dev/null)
  echo "  CR phase:  ${phase:-unknown}"
  echo "  CR health: ${health:-unknown}"
  local abort=false
  case "$phase" in
    Ready) ;;
    ApplyingChanges|MigratingData|ChangingStackVersion)
      echo "  ERROR: CR is in transient state '$phase'. A reconcile may be in progress."
      abort=true
      ;;
    Invalid)
      echo "  ERROR: CR is in 'Invalid' state. Fix the CR before upgrading."
      abort=true
      ;;
    "")
      echo "  WARN: CR phase is empty. Proceed with caution."
      ;;
    *)
      echo "  WARN: CR phase '$phase' is not 'Ready'. Proceed with caution."
      ;;
  esac
  if [ "$health" = "red" ]; then
    echo "  ERROR: CR health is 'red' (data loss risk). Fix cluster before upgrading."
    abort=true
  fi
  $abort && return 1
  return 0
}

check_dependency_version() {
  [ -z "$DEPENDENCY_CR_KIND" ] || [ -z "$DEPENDENCY_CR_NAME" ] && return 0
  command -v kubectl >/dev/null 2>&1 || return 0
  local target="$1"
  local ns
  ns=$(get_release_namespace)
  [ -z "$ns" ] && return 0
  local dep_ver
  dep_ver=$(kubectl -n "$ns" get "$DEPENDENCY_CR_KIND" "$DEPENDENCY_CR_NAME" \
    -o jsonpath='{.spec.version}' 2>/dev/null) || return 0
  [ -z "$dep_ver" ] && return 0
  echo "  Dependency $DEPENDENCY_CR_KIND/$DEPENDENCY_CR_NAME version: $dep_ver"
  local cmp
  cmp=$(semver_compare "$target" "$dep_ver")
  if [ "$cmp" = "1" ]; then
    echo ""
    echo "  ERROR: target version $target is HIGHER than $DEPENDENCY_CR_KIND version $dep_ver."
    echo "  $COMPONENT_LABEL must be <= $DEPENDENCY_CR_KIND version (otherwise connection fails)."
    echo "  Upgrade $DEPENDENCY_CR_KIND first, then retry."
    return 1
  fi
  echo "  OK ($target <= $dep_ver)."
  return 0
}

wait_for_cr_ready() {
  command -v kubectl >/dev/null 2>&1 || return 0
  [ -z "$COMPONENT_LABEL" ] && return 0
  local ns
  ns=$(get_release_namespace)
  [ -z "$ns" ] && return 0
  local timeout="${1:-300}"
  echo "    Waiting up to ${timeout}s for $COMPONENT_LABEL CR to reach Ready..."
  local elapsed=0 interval=5 phase=""
  while [ "$elapsed" -lt "$timeout" ]; do
    phase=$(kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$phase" = "Ready" ]; then
      echo "    CR phase=Ready after ${elapsed}s."
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "    WARN: CR did not reach Ready within ${timeout}s (current phase: ${phase:-unknown})."
  echo "    Investigate: kubectl -n $ns describe $COMPONENT_LABEL $COMPONENT_LABEL"
  return 1
}

wait_for_operator_ready() {
  { [ -z "$CR_OPERATOR_NS" ] || [ -z "$CR_OPERATOR_STS" ]; } && return 0
  command -v kubectl >/dev/null 2>&1 || return 0
  local timeout="${1:-120}"
  echo "    Waiting up to ${timeout}s for operator pod to become Ready..."
  kubectl -n "$CR_OPERATOR_NS" wait --for=condition=Ready \
    "pod/${CR_OPERATOR_STS}-0" --timeout="${timeout}s" 2>/dev/null || {
    echo "    WARN: operator pod did not become Ready within ${timeout}s."
    return 1
  }
}

verify_image_exists() {
  local tag="$1"
  if [ -z "$CONTAINER_IMAGE" ] || [ -z "$tag" ]; then
    return 0
  fi
  local registry="${CONTAINER_IMAGE%%/*}"
  local repo="${CONTAINER_IMAGE#*/}"
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
      local token_url="${realm}?service=${service}&scope=${scope}"
      local token
      token=$(curl -sSL "$token_url" 2>/dev/null \
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
echo "[Step 1/7] Reading current version from $VALUES_FILE..."
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

# Report the OCI chart pin for situational awareness (informational only).
if [ -f "$CHART_DIR/helmfile.yaml" ]; then
  CHART_PIN=$(awk '/^[[:space:]]*version:/ {print $2; exit}' "$CHART_DIR/helmfile.yaml" | tr -d '"' | tr -d "'")
  [ -n "$CHART_PIN" ] && echo "  OCI chart pin (helmfile.yaml): $CHART_PIN  (bump manually if needed)"
fi

# Step 2: Pre-flight cluster health check
echo ""
echo "[Step 2/7] Pre-flight cluster health check..."
if ! check_cluster_health; then
  echo ""
  read -rp "  Proceed anyway? [y/N]: " force_proceed
  if [[ ! "$force_proceed" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Step 3: Fetch latest version
echo ""
echo "[Step 3/7] Checking latest upstream version (source: $VERSION_SOURCE)..."

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

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo ""
  echo "  Already up to date! Nothing to do."
  exit 0
fi

echo ""
echo "  Upgrade: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Changelog: $CHANGELOG_URL"

# Step 4: Verify container image exists in registry
echo ""
echo "[Step 4/7] Verifying container image..."
if [ -n "$CONTAINER_IMAGE" ]; then
  echo "  Checking: $CONTAINER_IMAGE:$LATEST_VERSION"
  if verify_image_exists "$LATEST_VERSION"; then
    echo "  Image verified OK."
  else
    echo ""
    echo "  WARNING: Container image not found in registry."
    echo "    Image: $CONTAINER_IMAGE:$LATEST_VERSION"
    echo ""
    echo "  The version $LATEST_VERSION is listed in the upstream feed but the"
    echo "  container image has not been published yet."

    if [ -n "$TARGET_VERSION" ]; then
      echo ""
      echo "  Options:"
      echo "    - Wait for the image to be published and retry."
      echo "    - Choose a different version."
      exit 1
    fi

    echo ""
    echo "  Searching for the newest GA version with a published image..."
    AVAILABLE_VERSION=$(find_latest_available_version) || true

    if [ -z "$AVAILABLE_VERSION" ]; then
      echo ""
      echo "  ERROR: No GA version with a published image found within search limit."
      echo "  Retry later or check the release notes manually."
      exit 1
    fi

    if [ "$AVAILABLE_VERSION" = "$CURRENT_VERSION" ]; then
      echo ""
      echo "  Newest available version ($AVAILABLE_VERSION) matches the current version."
      echo "  Nothing to upgrade. Retry when $LATEST_VERSION image is published."
      exit 0
    fi

    echo ""
    echo "  Latest available (with published image): $AVAILABLE_VERSION"
    if $DRY_RUN; then
      echo ""
      echo "  [DRY-RUN] Would prompt to switch to $AVAILABLE_VERSION."
      echo "  To apply: ./upgrade.sh --version $AVAILABLE_VERSION"
      LATEST_VERSION="$AVAILABLE_VERSION"
    else
      echo ""
      read -rp "  Use $AVAILABLE_VERSION instead of $LATEST_VERSION? [y/N]: " use_alt
      if [[ ! "$use_alt" =~ ^[Yy]$ ]]; then
        echo ""
        echo "  Aborted. To apply manually:"
        echo "    ./upgrade.sh --version $AVAILABLE_VERSION"
        exit 1
      fi
      LATEST_VERSION="$AVAILABLE_VERSION"
      echo "  Proceeding with $LATEST_VERSION."
    fi
  fi
else
  echo "  Skipped (CONTAINER_IMAGE not configured)."
fi

# Step 5: Compatibility + dependency check + major bump warning
echo ""
echo "[Step 5/7] Compatibility checks"
cat <<EOF
  * Verify the currently installed operator supports $COMPONENT_LABEL $LATEST_VERSION.
  * For Stack major bumps (e.g. 8.x -> 9.x) review breaking changes before applying.
  * Verify the OCI chart pin in helmfile.yaml supports this component version.
EOF

if [ -n "$DEPENDENCY_CR_KIND" ] && [ -n "$DEPENDENCY_CR_NAME" ]; then
  echo ""
  echo "  Checking dependency CR version constraint..."
  if ! check_dependency_version "$LATEST_VERSION"; then
    exit 1
  fi
fi

# Major version bump warning — strongly recommend a backup.
CURRENT_MAJOR="${CURRENT_VERSION%%.*}"
LATEST_MAJOR="${LATEST_VERSION%%.*}"
if [ -n "$CURRENT_MAJOR" ] && [ -n "$LATEST_MAJOR" ] && [ "$CURRENT_MAJOR" != "$LATEST_MAJOR" ]; then
  echo ""
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  !! MAJOR VERSION BUMP: $CURRENT_MAJOR.x -> $LATEST_MAJOR.x"
  echo "  !!"
  echo "  !! STRONGLY RECOMMENDED: back up application data using"
  echo "  !! the component's native backup/snapshot mechanism"
  echo "  !! before proceeding."
  echo "  !!"
  echo "  !! Major bumps commonly include deprecated setting removals"
  echo "  !! and data format changes that are not reversible."
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

# Step 6: Dry-run exit / Backup
echo ""
if $DRY_RUN; then
  echo "[Step 6/7] DRY-RUN complete. No files were changed."
  echo ""
  echo "  To apply: ./upgrade.sh"
  [ -n "$TARGET_VERSION" ] && echo "  To apply: ./upgrade.sh --version $TARGET_VERSION"
  exit 0
fi

echo "[Step 6/7] Backing up current files..."
mkdir -p "$BACKUP_DIR/$TIMESTAMP"
cp "$CHART_DIR/$VALUES_FILE" "$BACKUP_DIR/$TIMESTAMP/$(basename "$VALUES_FILE")"
echo "  Backed up to: backup/$TIMESTAMP/"
ls "$BACKUP_DIR/$TIMESTAMP/" | while read -r f; do echo "    - $f"; done

# Step 7: Apply version updates
echo ""
echo "[Step 7/7] Applying version update..."

update_yaml_value "$CHART_DIR/$VALUES_FILE" "$VERSION_KEY" "$LATEST_VERSION"
echo "  Updated $VALUES_FILE ($VERSION_KEY: $CURRENT_VERSION -> $LATEST_VERSION)"

auto_prune_backups

echo ""
echo "================================================"
echo " Upgrade complete! ($CURRENT_VERSION -> $LATEST_VERSION)"
echo ""
echo " Changelog: $CHANGELOG_URL"
echo ""
echo " Next steps:"
echo "   1. Verify the OCI chart pin in helmfile.yaml supports this version."
echo "   2. Run: helmfile diff"
echo "   3. Run: helmfile apply"
echo "   4. Watch CR: kubectl -n <ns> get $COMPONENT_LABEL -w"
echo ""
echo " To rollback:"
echo "   ./upgrade.sh --rollback"
echo "================================================"
