#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "local-cr-version" upgrade.sh body.
#
# Used by LOCAL Helm charts that wrap a Custom Resource and have NO upstream
# Helm chart to sync from. Typical shape:
#   - Chart.yaml (local metadata, appVersion tracks component version)
#   - helmfile.yaml (chart: .)
#   - values/<env>.yaml (holds .<VERSION_KEY> — e.g. .version)
#   - templates/*.yaml (owned by us, not synced from upstream)
#
# What this script does:
#   1. Reads the current version from <CHART_DIR>/<VALUES_FILE>.
#   2. Queries the component's version feed for the latest GA version.
#   3. Verifies the container image exists in the registry before applying.
#   4. Diffs and, on apply, updates both <VALUES_FILE> and Chart.yaml appVersion.
#
# Supported VERSION_SOURCE values (set per chart):
#   - elastic-artifacts : GETs https://artifacts-api.elastic.co/v1/versions
#                         Applies to all Elastic Stack components
#                         (Elasticsearch, Kibana, APM Server, Logstash, Beats).
#
# Real per-chart upgrade.sh files are kept in sync via:
#   scripts/upgrade-sync/sync.sh --apply
# Only the body below the second `# ===` marker is propagated.
set -euo pipefail

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.sh)
# ============================================================
SCRIPT_NAME="__SCRIPT_NAME__"
COMPONENT_LABEL="__COMPONENT_LABEL__"
# One of: elastic-artifacts | github-releases | docker-hub-tags
VERSION_SOURCE="__VERSION_SOURCE__"
# Argument for the selected VERSION_SOURCE. Interpretation varies:
#   elastic-artifacts : ignored
#   github-releases   : "<owner>/<repo>" (e.g. "cloudnative-pg/cloudnative-pg")
#   docker-hub-tags   : "<namespace>/<repository>" (e.g. "bitnami/redis")
VERSION_SOURCE_ARG="__VERSION_SOURCE_ARG__"
# Path relative to CHART_DIR holding the version field (e.g. values/mgmt.yaml)
VALUES_FILE="__VALUES_FILE__"
# Top-level YAML key holding the version string (e.g. version)
VERSION_KEY="__VERSION_KEY__"
# Major-line pin. Empty = any. E.g. "9" to lock to 9.x.
MAJOR_PIN="__MAJOR_PIN__"
CHANGELOG_URL="__CHANGELOG_URL__"
# Container image to verify before upgrading (registry/repository format).
# Tag is appended automatically from the target version.
# E.g. "docker.elastic.co/elasticsearch/elasticsearch"
# Leave empty ("") to skip image verification.
CONTAINER_IMAGE="__CONTAINER_IMAGE__"
# Operator webhook handling for rollback (all four required to enable).
# When set, --rollback detects admission webhooks that block version
# downgrades and offers automatic handling.
#   CR_WEBHOOK_NAME       : name of the ValidatingWebhookConfiguration
#   CR_OPERATOR_NS        : namespace of the operator StatefulSet
#   CR_OPERATOR_STS       : StatefulSet name of the operator
#   CR_OPERATOR_CHART_DIR : sibling directory name holding the operator chart
#                           (used to recreate the webhook via helmfile sync)
CR_WEBHOOK_NAME="__CR_WEBHOOK_NAME__"
CR_OPERATOR_NS="__CR_OPERATOR_NS__"
CR_OPERATOR_STS="__CR_OPERATOR_STS__"
CR_OPERATOR_CHART_DIR="__CR_OPERATOR_CHART_DIR__"
# Dependency CR: ensures the target version is <= this CR's current version.
# E.g., Kibana must be <= the linked Elasticsearch version. Set both to enable.
# Leave empty ("") to skip.
DEPENDENCY_CR_KIND="__DEPENDENCY_CR_KIND__"
DEPENDENCY_CR_NAME="__DEPENDENCY_CR_NAME__"
# Mirror appVersion into Chart.yaml 'version' field. Useful for single-CR
# wrapper charts where chart version and app version are functionally the same.
# Set to "true" to enable, anything else to keep chart version manual.
MIRROR_CHART_VERSION="__MIRROR_CHART_VERSION__"
# ============================================================

# zsh nomatch compat: don't fail when "$dir"/2*/ has no matches.
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CHART_DIR/backup"
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
  # Reverse-sorted glob via sort -r: name desc == time desc.
  # 백업 디렉토리는 YYYYMMDD_HHMMSS 형식이라 이름 내림차순 == 시간 내림차순.
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    local dirname=""; dirname=$(basename "$dir")
    local chart_ver="unknown"
    [ -f "$dir/Chart.yaml" ] && chart_ver=$(grep '^appVersion:' "$dir/Chart.yaml" | awk '{print $2}' | tr -d '"')
    local files=""; files=$(ls "$dir" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (appVersion: %s) — %s\n" "$i" "$dirname" "$chart_ver" "$files"
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
  # Reverse-sorted glob via sort -r: name desc == time desc.
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

  # Read the backup version to detect downgrades.
  local backup_ver=""
  if [ -f "$selected/Chart.yaml" ]; then
    backup_ver=$(grep '^appVersion:' "$selected/Chart.yaml" | awk '{print $2}' | tr -d '"')
  fi

  # Detect live CR version via kubectl (best-effort).
  local live_ver=""
  local is_downgrade=false
  if command -v kubectl >/dev/null 2>&1 && [ -n "$COMPONENT_LABEL" ]; then
    local ns=""
    if [ -n "$HELMFILE_PATH" ]; then
      ns=$(awk '/namespace:/ {print $2; exit}' "$HELMFILE_PATH" | tr -d '"' | tr -d "'")
    fi
    if [ -n "$ns" ]; then
      live_ver=$(kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" \
        -o jsonpath='{.spec.version}' 2>/dev/null) || true
    fi
  fi

  if [ -n "$live_ver" ] && [ -n "$backup_ver" ] && [ "$live_ver" != "$backup_ver" ]; then
    local live_tuple="" backup_tuple=""
    live_tuple=$(echo "$live_ver" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
    backup_tuple=$(echo "$backup_ver" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
    if [ "$backup_tuple" -lt "$live_tuple" ]; then
      is_downgrade=true
    fi
  fi

  echo ""
  echo "Restoring from backup/$dirname..."

  [ -f "$selected/Chart.yaml" ] && cp "$selected/Chart.yaml" "$CHART_DIR/Chart.yaml" && echo "  Restored Chart.yaml"
  if [ -f "$selected/$(basename "$VALUES_FILE")" ]; then
    cp "$selected/$(basename "$VALUES_FILE")" "$CHART_DIR/$VALUES_FILE"
    echo "  Restored $VALUES_FILE"
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
  # Read release name and namespace from helmfile for Helm state recovery.
  local release_name="" release_ns=""
  if [ -n "$HELMFILE_PATH" ]; then
    release_name=$(awk '/- name:/ {print $3; exit}' "$HELMFILE_PATH" | tr -d '"' | tr -d "'")
    release_ns=$(awk '/namespace:/ {print $2; exit}' "$HELMFILE_PATH" | tr -d '"' | tr -d "'")
  fi

  echo ""
  echo "  [1/7] Scaling down operator ($CR_OPERATOR_NS/$CR_OPERATOR_STS)..."
  kubectl -n "$CR_OPERATOR_NS" scale statefulset "$CR_OPERATOR_STS" --replicas=0
  # Wait for operator pod to terminate.
  kubectl -n "$CR_OPERATOR_NS" wait --for=delete pod/"${CR_OPERATOR_STS}-0" --timeout=60s 2>/dev/null || true

  echo "  [2/7] Removing admission webhook ($CR_WEBHOOK_NAME)..."
  kubectl delete validatingwebhookconfiguration "$CR_WEBHOOK_NAME" --ignore-not-found

  # Recover Helm release from 'failed' state.
  # When a previous helmfile apply was blocked by the webhook, Helm creates a
  # failed revision. Subsequent helmfile diff compares against the failed
  # revision (which already has the target version) and sees no changes.
  # Roll back to the last successful revision so helmfile can detect the diff.
  echo "  [3/7] Recovering Helm release state..."
  if [ -n "$release_name" ] && [ -n "$release_ns" ]; then
    local helm_status=""
    helm_status=$(helm status "$release_name" -n "$release_ns" -o json 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null) || true
    if [ "$helm_status" = "failed" ]; then
      echo "    Helm release '$release_name' is in 'failed' state. Rolling back to last successful revision..."
      local last_good=""
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
    echo "    WARN: could not read release info from helmfile. Skipping Helm recovery."
  fi

  echo "  [4/7] Applying rollback via helmfile..."
  (cd "$CHART_DIR" && helmfile apply)

  echo "  [5/7] Recreating webhook via operator helmfile sync..."
  # Locate the operator chart directory relative to this chart.
  # The operator chart typically lives as a sibling (or grandparent sibling).
  local operator_dir=""
  if [ -n "$CR_OPERATOR_CHART_DIR" ]; then
    local search_base="$CHART_DIR"
    while [ "$search_base" != "/" ]; do
      if [ -f "$search_base/$CR_OPERATOR_CHART_DIR/helmfile.yaml" ] || [ -f "$search_base/$CR_OPERATOR_CHART_DIR/helmfile.yaml.gotmpl" ]; then
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
  local tmp=""
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

# Fetch sorted list of GA versions (newest first, respecting MAJOR_PIN).
# Prints one version per line to stdout.
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
# Keep strict X.Y.Z GA (exclude SNAPSHOT, rc, alpha, etc.)
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
      # VERSION_SOURCE_ARG = "owner/repo"
      [ -z "$VERSION_SOURCE_ARG" ] && return 0
      local url="https://api.github.com/repos/$VERSION_SOURCE_ARG/releases?per_page=100"
      curl -sSfL "$url" 2>/dev/null | python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Exclude prereleases and drafts; strip leading 'v'.
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
      # VERSION_SOURCE_ARG = "namespace/repository"
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

# Fetch latest GA version from the configured source.
# Prints version to stdout, empty on failure.
fetch_latest_version() {
  fetch_ga_versions | head -1
}

# Search older GA versions for the newest one with a published container image.
# Caps at MAX_ATTEMPTS to avoid long waits. Prints version to stdout, empty if
# none found. Also prints per-attempt status to stderr for user feedback.
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

# Compare two semver strings. Echoes -1 if a<b, 0 if a=b, 1 if a>b.
semver_compare() {
  local a_tuple="" b_tuple=""
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

# Resolve the release namespace from helmfile (yaml or gotmpl). Empty if not found.
get_release_namespace() {
  [ -n "$HELMFILE_PATH" ] || return 0
  awk '/namespace:/ {print $2; exit}' "$HELMFILE_PATH" | tr -d '"' | tr -d "'"
}

# Best-effort cluster health check. Returns 0 if safe to upgrade, 1 otherwise.
# Skips silently if kubectl is unavailable or the CR does not exist yet.
check_cluster_health() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "  Skipped (kubectl not available)."
    return 0
  fi
  [ -z "$COMPONENT_LABEL" ] && return 0
  local ns=""
  ns=$(get_release_namespace)
  if [ -z "$ns" ]; then
    echo "  Skipped (namespace not readable from helmfile)."
    return 0
  fi
  if ! kubectl -n "$ns" get "$COMPONENT_LABEL" "$COMPONENT_LABEL" >/dev/null 2>&1; then
    echo "  CR not found in ns/$ns (first install?). Skipping health check."
    return 0
  fi
  local phase="" health=""
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

# Check dependency CR version constraint. Target must be <= dependency CR's version.
# Used to prevent e.g. Kibana > Elasticsearch (which breaks the connection).
check_dependency_version() {
  [ -z "$DEPENDENCY_CR_KIND" ] || [ -z "$DEPENDENCY_CR_NAME" ] && return 0
  command -v kubectl >/dev/null 2>&1 || return 0
  local target="$1"
  local ns=""
  ns=$(get_release_namespace)
  [ -z "$ns" ] && return 0
  local dep_ver=""
  dep_ver=$(kubectl -n "$ns" get "$DEPENDENCY_CR_KIND" "$DEPENDENCY_CR_NAME" \
    -o jsonpath='{.spec.version}' 2>/dev/null) || return 0
  [ -z "$dep_ver" ] && return 0
  echo "  Dependency $DEPENDENCY_CR_KIND/$DEPENDENCY_CR_NAME version: $dep_ver"
  local cmp=""
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

# Wait for CR to reach the Ready phase. Returns 0 if reached, 1 on timeout.
wait_for_cr_ready() {
  command -v kubectl >/dev/null 2>&1 || return 0
  [ -z "$COMPONENT_LABEL" ] && return 0
  local ns=""
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

# Wait for operator pod to become Ready after scale-up.
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

# Verify that a container image tag exists in the registry.
# Uses the Docker Registry HTTP API v2 with bearer token authentication.
# Returns 0 if the image exists (or if CONTAINER_IMAGE is empty), 1 otherwise.
verify_image_exists() {
  local tag="$1"
  if [ -z "$CONTAINER_IMAGE" ] || [ -z "$tag" ]; then
    return 0
  fi
  local registry="${CONTAINER_IMAGE%%/*}"
  local repo="${CONTAINER_IMAGE#*/}"
  local manifest_url="https://${registry}/v2/${repo}/manifests/${tag}"

  # Step 1: Unauthenticated probe to get the WWW-Authenticate challenge.
  local auth_header=""
  auth_header=$(curl -sSL -I "$manifest_url" 2>/dev/null \
    | grep -i '^www-authenticate:' | head -1) || true

  local http_code
  if [ -n "$auth_header" ]; then
    # Parse realm, service, and scope from the challenge header.
    local realm="" service="" scope=""
    realm=$(echo "$auth_header" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
    service=$(echo "$auth_header" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
    scope=$(echo "$auth_header" | sed -n 's/.*scope="\([^"]*\)".*/\1/p')
    if [ -n "$realm" ]; then
      local token_url="${realm}?service=${service}&scope=${scope}"
      local token=""
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

  # Fallback: try without authentication (works for some registries).
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

CURRENT_APP_VERSION=""
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  CURRENT_APP_VERSION=$(grep '^appVersion:' "$CHART_DIR/Chart.yaml" | awk '{print $2}' | tr -d '"')
  echo "  Chart.yaml appVersion:       $CURRENT_APP_VERSION"
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

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ] && { [ -z "$CURRENT_APP_VERSION" ] || [ "$CURRENT_APP_VERSION" = "$LATEST_VERSION" ]; }; then
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

    # If the user explicitly picked this version, don't auto-search.
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
      echo "  Retry later or check the Elastic release notes manually."
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
  * Verify the currently installed ECK Operator supports $COMPONENT_LABEL $LATEST_VERSION.
    Compatibility matrix: https://www.elastic.co/support/matrix
  * For Stack major bumps (e.g. 8.x -> 9.x) review breaking changes before applying.
  * Keep Elasticsearch and Kibana on the same Stack version (Kibana <= Elasticsearch).
EOF

# Dependency CR version constraint (e.g. Kibana <= Elasticsearch).
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
[ -f "$CHART_DIR/Chart.yaml" ] && cp "$CHART_DIR/Chart.yaml" "$BACKUP_DIR/$TIMESTAMP/Chart.yaml"
echo "  Backed up to: backup/$TIMESTAMP/"
ls "$BACKUP_DIR/$TIMESTAMP/" | while read -r f; do echo "    - $f"; done

# Step 7: Apply version updates
echo ""
echo "[Step 7/7] Applying version update..."

update_yaml_value "$CHART_DIR/$VALUES_FILE" "$VERSION_KEY" "$LATEST_VERSION"
echo "  Updated $VALUES_FILE ($VERSION_KEY: $CURRENT_VERSION -> $LATEST_VERSION)"

if [ -f "$CHART_DIR/Chart.yaml" ]; then
  update_yaml_value "$CHART_DIR/Chart.yaml" "appVersion" "$LATEST_VERSION"
  echo "  Updated Chart.yaml (appVersion: ${CURRENT_APP_VERSION:-unset} -> $LATEST_VERSION)"

  # Mirror into chart `version` when enabled. Useful for single-CR wrapper
  # charts where the chart version and app version are functionally the same.
  if [ "$MIRROR_CHART_VERSION" = "true" ]; then
    CURRENT_CHART_VERSION=$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}' | tr -d '"')
    if [ "$CURRENT_CHART_VERSION" != "$LATEST_VERSION" ]; then
      update_yaml_value "$CHART_DIR/Chart.yaml" "version" "$LATEST_VERSION"
      echo "  Updated Chart.yaml (version: ${CURRENT_CHART_VERSION:-unset} -> $LATEST_VERSION) [mirrored]"
    fi
  fi
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
echo "   1. Verify ECK Operator supports the new Stack version."
echo "   2. Run: helmfile diff"
echo "   3. Run: helmfile apply"
echo "   4. Watch CR: kubectl -n <ns> get $COMPONENT_LABEL -w"
echo ""
echo " To rollback:"
echo "   ./upgrade.sh --rollback"
echo "================================================"
