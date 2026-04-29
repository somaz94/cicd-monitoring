#!/bin/bash
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-oci-cr-version" upgrade.sh body.
#
# Used by CONSUMER repos that deploy a Custom Resource via an EXTERNAL Helm
# chart distributed over OCI (e.g. oci://ghcr.io/org/charts/foo). The consumer
# does NOT own the chart templates — chart upgrades happen in the publishing
# repo. This script only tracks the Stack/component version in values/<env>.yaml.
#
# Typical shape:
#   - helmfile.yaml        # chart: oci://..., version: "<chart semver>"
#   - values/<env>.yaml    # holds .<VERSION_KEY> — the Stack/component version
#   - upgrade.sh           # this script
#   - (NO Chart.yaml, NO templates/ — those live in the chart publisher repo)
#
# What this script does:
#   1. Reads the current version from <CHART_DIR>/<VALUES_FILE>.
#   2. Queries the component's version feed for the latest GA version.
#   3. Verifies the container image exists in the registry before applying.
#   4. Diffs and, on apply, updates <VALUES_FILE> only.
#
# Supported VERSION_SOURCE values (set per chart):
#   - elastic-artifacts : GETs https://artifacts-api.elastic.co/v1/versions
#                         Applies to all Elastic Stack components
#                         (Elasticsearch, Kibana, APM Server, Logstash, Beats).
#   - github-releases   : GitHub Releases API for a given owner/repo.
#   - docker-hub-tags   : Docker Hub tags API for a given namespace/repository.
#
# Difference vs "local-cr-version":
#   - No Chart.yaml manipulation (chart metadata lives upstream).
#   - No MIRROR_CHART_VERSION option (irrelevant without local Chart.yaml).
#   - Backup contains only the values file (Chart.yaml restore path removed).
#   - OCI chart version in helmfile.yaml is pinned manually (bumped via
#     `helm pull` + review, not by this script).
#
# Real per-chart upgrade.sh files are kept in sync via:
#   scripts/upgrade-sync/sync.sh --apply
# Only the body below the third `# ===` marker is propagated.
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
# OCI chart pin tracking (for --check-chart / --upgrade-chart).
# When all three are set, the script can detect and bump the chart version in
# helmfile.yaml. Leave CHART_SOURCE_TYPE empty ("") to disable chart tracking
# (the script then only manages the Stack/component version in VALUES_FILE).
#   CHART_SOURCE_TYPE : currently only "github-releases" is supported
#   CHART_SOURCE_REPO : "<owner>/<repo>" publishing the chart
#                       (e.g. "somaz94/helm-charts")
#   CHART_NAME        : release tag prefix for this chart
#                       (e.g. "elasticsearch-eck" for tags like
#                       "elasticsearch-eck-0.1.2")
CHART_SOURCE_TYPE="__CHART_SOURCE_TYPE__"
CHART_SOURCE_REPO="__CHART_SOURCE_REPO__"
CHART_NAME="__CHART_NAME__"
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
and bumps the version field inside $VALUES_FILE. When CHART_SOURCE_TYPE is set,
the --check-chart / --upgrade-chart commands also track the OCI chart pin in
helmfile.yaml (publisher release tag \`<CHART_NAME>-<semver>\`).

Commands (Stack/component version — default track):
  (default)              Check latest Stack version and upgrade VALUES_FILE
  --version <VER>        Upgrade Stack to a specific version
  --dry-run              Preview Stack changes only (no files will be modified)

Commands (OCI chart pin — requires CHART_SOURCE_TYPE set):
  --check-chart          Report current chart pin vs. latest upstream (read-only)
  --upgrade-chart        Download both chart versions, diff the rendered manifests,
                         prompt, then bump helmfile.yaml.version
  --chart-version <VER>  Target a specific chart version with --upgrade-chart

Commands (shared):
  --rollback             Restore from a previous backup (auto-detects stack vs chart)
  --list-backups         List available backups
  --cleanup-backups      Keep only the last $KEEP_BACKUPS backups, remove older ones
  -h, --help             Show this help message

Examples:
  $(basename "$0")                                # Stack upgrade to latest GA
  $(basename "$0") --dry-run                      # Preview Stack upgrade
  $(basename "$0") --version 9.1.2                # Stack pin to a specific version
  $(basename "$0") --check-chart                  # Report OCI chart pin status
  $(basename "$0") --upgrade-chart --dry-run      # Preview chart bump (render diff)
  $(basename "$0") --upgrade-chart                # Bump chart to latest publisher tag
  $(basename "$0") --upgrade-chart --chart-version 0.1.2  # Pin chart to specific tag
  $(basename "$0") --rollback                     # Restore from backup (Stack or chart)
EOF
  exit 0
}

# Backup type classifier. Chart-pin bumps use `<TIMESTAMP>-chart` directories
# and store helmfile.yaml; Stack bumps use plain `<TIMESTAMP>` and store the
# values file. Returns: "chart" | "stack" | "unknown".
classify_backup() {
  local dir="$1"
  local name
  name=$(basename "$dir")
  if [[ "$name" == *"-chart" ]] || [ -f "$dir/helmfile.yaml" ]; then
    echo "chart"
  elif [ -f "$dir/$(basename "$VALUES_FILE")" ]; then
    echo "stack"
  else
    echo "unknown"
  fi
}

# Read the tracked version from a backup, chosen by backup type.
#   stack : reads <VALUES_FILE>.<VERSION_KEY>
#   chart : reads helmfile.yaml's chart pin (first indented 'version:')
read_backup_version() {
  local dir="$1"
  local kind
  kind=$(classify_backup "$dir")
  local f=""
  local key=""
  case "$kind" in
    stack)
      f="$dir/$(basename "$VALUES_FILE")"
      key="$VERSION_KEY"
      [ -f "$f" ] || { echo ""; return; }
      awk -v k="$key" '
        $0 ~ "^" k ":" {
          sub("^" k ":[[:space:]]*", "")
          gsub(/^["\x27]|["\x27]$/, "")
          sub(/[[:space:]]+#.*$/, "")
          print
          exit
        }
      ' "$f"
      ;;
    chart)
      f="$dir/helmfile.yaml"
      [ -f "$f" ] || { echo ""; return; }
      awk '
        /^[[:space:]]+version:[[:space:]]/ {
          sub(/^[[:space:]]+version:[[:space:]]*/, "")
          gsub(/["\x27]/, "")
          sub(/[[:space:]]+#.*$/, "")
          print
          exit
        }
      ' "$f"
      ;;
    *)
      echo ""
      ;;
  esac
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
    local dirname
    dirname=$(basename "$dir")
    local kind ver label
    kind=$(classify_backup "$dir")
    ver=$(read_backup_version "$dir")
    case "$kind" in
      chart) label="chart" ;;
      stack) label="$VERSION_KEY" ;;
      *)     label="backup" ;;
    esac
    local files
    files=$(ls "$dir" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf "  [%d] %s (%s: %s) — %s\n" "$i" "$dirname" "$label" "${ver:-unknown}" "$files"
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
  local kind
  kind=$(classify_backup "$selected")

  # Chart-pin rollback takes a separate path: restore helmfile.yaml only,
  # no live-CR downgrade to worry about.
  if [ "$kind" = "chart" ]; then
    echo ""
    echo "Restoring chart pin from backup/$dirname..."
    if [ -f "$selected/helmfile.yaml" ]; then
      cp "$selected/helmfile.yaml" "$CHART_DIR/helmfile.yaml"
      echo "  Restored helmfile.yaml"
      echo ""
      echo "Chart pin rollback complete! Run 'helmfile diff', then 'helmfile apply'."
    else
      echo "  WARN: backup does not contain helmfile.yaml; nothing to restore."
      exit 1
    fi
    return
  fi

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
# OCI chart pin helpers (helmfile.yaml.version)
# -----------------------------------------------

# Read the OCI chart URL from helmfile.yaml (first 'chart:' key under releases).
read_helmfile_chart_url() {
  [ -f "$CHART_DIR/helmfile.yaml" ] || { echo ""; return; }
  awk '
    $1 == "chart:" {
      sub(/^[[:space:]]*chart:[[:space:]]*/, "")
      gsub(/["\x27]/, "")
      sub(/[[:space:]]+#.*$/, "")
      print
      exit
    }
  ' "$CHART_DIR/helmfile.yaml"
}

# Read the chart pin (first 'version:' under a release in helmfile.yaml).
read_helmfile_chart_pin() {
  [ -f "$CHART_DIR/helmfile.yaml" ] || { echo ""; return; }
  awk '
    /^[[:space:]]+version:[[:space:]]/ {
      sub(/^[[:space:]]+version:[[:space:]]*/, "")
      gsub(/["\x27]/, "")
      sub(/[[:space:]]+#.*$/, "")
      print
      exit
    }
  ' "$CHART_DIR/helmfile.yaml"
}

# Replace the chart pin in helmfile.yaml, preserving the original quoting style
# (double quotes, single quotes, or bare). Only touches the first indented
# 'version:' line so top-level YAML keys are safe.
update_helmfile_chart_pin() {
  local new="$1"
  local file="$CHART_DIR/helmfile.yaml"
  local tmp
  tmp=$(mktemp)
  awk -v v="$new" '
    BEGIN { done = 0 }
    {
      if (!done && $0 ~ /^[[:space:]]+version:[[:space:]]/) {
        line = $0
        if (match(line, /: *"[^"]*"/)) {
          sub(/"[^"]*"/, "\"" v "\"", line)
        } else if (match(line, /: *\x27[^\x27]*\x27/)) {
          sub(/\x27[^\x27]*\x27/, "\x27" v "\x27", line)
        } else {
          sub(/version:[[:space:]]+[^[:space:]#]+/, "version: " v, line)
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

# Fetch sorted list of chart versions from the publisher (newest first).
# Filters by CHART_NAME prefix (e.g. "elasticsearch-eck-X.Y.Z").
list_chart_versions() {
  case "$CHART_SOURCE_TYPE" in
    github-releases)
      [ -z "$CHART_SOURCE_REPO" ] && return 0
      [ -z "$CHART_NAME" ] && return 0
      local url="https://api.github.com/repos/$CHART_SOURCE_REPO/releases?per_page=100"
      curl -sSfL "$url" 2>/dev/null | CHART_NAME="$CHART_NAME" python3 -c "
import json, sys, re, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
prefix = os.environ.get('CHART_NAME', '') + '-'
tags = [r.get('tag_name', '') for r in d
        if not r.get('prerelease') and not r.get('draft')]
vers = []
for t in tags:
    if t.startswith(prefix):
        v = t[len(prefix):]
        if re.fullmatch(r'\d+\.\d+\.\d+', v):
            vers.append(v)
vers.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
for v in vers:
    print(v)
" 2>/dev/null
      ;;
    *)
      ;;
  esac
}

fetch_latest_chart_version() {
  list_chart_versions | head -1
}

# Read release name from helmfile.yaml for use with `helm template`.
read_helmfile_release_name() {
  [ -f "$CHART_DIR/helmfile.yaml" ] || { echo ""; return; }
  awk '/^[[:space:]]*-[[:space:]]*name:/ {
    sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
    gsub(/["\x27]/, "")
    print
    exit
  }' "$CHART_DIR/helmfile.yaml"
}

# Guard: --check-chart / --upgrade-chart require CHART_SOURCE_TYPE configured.
require_chart_source_configured() {
  if [ -z "$CHART_SOURCE_TYPE" ]; then
    echo "ERROR: chart pin tracking is not configured for this component."
    echo "       Set CHART_SOURCE_TYPE / CHART_SOURCE_REPO / CHART_NAME in the"
    echo "       CONFIG block of $(basename "$0") to enable --check-chart /"
    echo "       --upgrade-chart."
    exit 1
  fi
  if [ -z "$CHART_SOURCE_REPO" ] || [ -z "$CHART_NAME" ]; then
    echo "ERROR: CHART_SOURCE_REPO and CHART_NAME must both be set when"
    echo "       CHART_SOURCE_TYPE='$CHART_SOURCE_TYPE'."
    exit 1
  fi
}

# --check-chart: report current chart pin vs. latest publisher release.
# Read-only; no files touched.
do_check_chart() {
  require_chart_source_configured

  echo "================================================"
  echo " Chart pin check — $CHART_NAME"
  echo "================================================"
  echo ""

  local current latest
  current=$(read_helmfile_chart_pin)
  if [ -z "$current" ]; then
    echo "  ERROR: could not read chart pin from helmfile.yaml."
    exit 1
  fi
  echo "  Current pin (helmfile.yaml): $current"

  echo "  Querying $CHART_SOURCE_TYPE for $CHART_SOURCE_REPO (prefix '$CHART_NAME-*')..."
  latest=$(fetch_latest_chart_version)
  if [ -z "$latest" ]; then
    echo ""
    echo "  ERROR: no matching release found in $CHART_SOURCE_REPO."
    echo "  Verify CHART_NAME='$CHART_NAME' matches the release tag prefix."
    exit 1
  fi
  echo "  Latest upstream:             $latest"
  echo ""

  if [ "$current" = "$latest" ]; then
    echo "  Status: OK — chart pin is up to date."
  else
    local cmp
    cmp=$(semver_compare "$current" "$latest")
    if [ "$cmp" = "1" ]; then
      echo "  Status: AHEAD — local pin ($current) is newer than the latest"
      echo "          published release ($latest). Probably a manual override."
    else
      echo "  Status: UPDATE AVAILABLE — $current -> $latest"
      echo "  Release notes: https://github.com/$CHART_SOURCE_REPO/releases/tag/$CHART_NAME-$latest"
      echo ""
      echo "  To preview:  $(basename "$0") --upgrade-chart --dry-run"
      echo "  To apply:    $(basename "$0") --upgrade-chart"
    fi
  fi
  echo ""
}

# --upgrade-chart: bump helmfile.yaml.version. Downloads current + target
# charts, renders both with the active values file, and shows a unified diff
# so the operator can spot values-schema breakages before applying.
do_upgrade_chart() {
  require_chart_source_configured

  local current target
  current=$(read_helmfile_chart_pin)
  if [ -z "$current" ]; then
    echo "ERROR: could not read chart pin from helmfile.yaml."
    exit 1
  fi

  echo "================================================"
  echo " Chart pin upgrade — $CHART_NAME"
  if $DRY_RUN; then
    echo " Mode: DRY-RUN (no files will be changed)"
  fi
  echo "================================================"
  echo ""

  echo "[Step 1/5] Resolving target chart version..."
  if [ -n "$TARGET_CHART_VERSION" ]; then
    target="$TARGET_CHART_VERSION"
    echo "  Using explicit target: $target"
  else
    target=$(fetch_latest_chart_version)
    if [ -z "$target" ]; then
      echo "  ERROR: no matching release found in $CHART_SOURCE_REPO (prefix '$CHART_NAME-*')."
      exit 1
    fi
    echo "  Current pin:     $current"
    echo "  Latest upstream: $target"
  fi

  if [ "$current" = "$target" ]; then
    echo ""
    echo "  Already up to date. Nothing to do."
    exit 0
  fi

  # Step 2: fetch both chart versions to a scratch dir.
  echo ""
  echo "[Step 2/5] Pulling charts to a scratch directory..."
  if ! command -v helm >/dev/null 2>&1; then
    echo "  ERROR: helm not found on PATH. Install helm to use --upgrade-chart."
    exit 1
  fi
  local chart_url
  chart_url=$(read_helmfile_chart_url)
  if [ -z "$chart_url" ]; then
    echo "  ERROR: could not read chart URL from helmfile.yaml."
    exit 1
  fi
  echo "  Chart: $chart_url"

  local scratch
  scratch=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" EXIT

  local cur_dir="$scratch/current" tgt_dir="$scratch/target"
  mkdir -p "$cur_dir" "$tgt_dir"

  if ! helm pull "$chart_url" --version "$current" -d "$cur_dir" --untar >/dev/null 2>&1; then
    echo "  ERROR: helm pull failed for $chart_url@$current."
    echo "         Check that the version is published and accessible."
    exit 1
  fi
  if ! helm pull "$chart_url" --version "$target" -d "$tgt_dir" --untar >/dev/null 2>&1; then
    echo "  ERROR: helm pull failed for $chart_url@$target."
    echo "         Check that the version is published and accessible."
    exit 1
  fi
  echo "  Pulled $current and $target."

  # Step 3: render both with the active values file and diff.
  echo ""
  echo "[Step 3/5] Rendering both charts with $VALUES_FILE and diffing..."
  local release_name
  release_name=$(read_helmfile_release_name)
  [ -z "$release_name" ] && release_name="$COMPONENT_LABEL"

  local cur_chart tgt_chart
  cur_chart=$(find "$cur_dir" -maxdepth 2 -name Chart.yaml -print -quit 2>/dev/null | xargs -I{} dirname {})
  tgt_chart=$(find "$tgt_dir" -maxdepth 2 -name Chart.yaml -print -quit 2>/dev/null | xargs -I{} dirname {})
  if [ -z "$cur_chart" ] || [ -z "$tgt_chart" ]; then
    echo "  ERROR: could not locate unpacked Chart.yaml. helm pull layout unexpected."
    exit 1
  fi

  local cur_render="$scratch/current-render.yaml" tgt_render="$scratch/target-render.yaml"
  local render_err="$scratch/render-err"
  if ! helm template "$release_name" "$cur_chart" -f "$CHART_DIR/$VALUES_FILE" \
      > "$cur_render" 2>"$render_err"; then
    echo "  ERROR: helm template failed on current chart ($current)."
    echo "  Details:"
    sed 's/^/    /' "$render_err"
    exit 1
  fi
  if ! helm template "$release_name" "$tgt_chart" -f "$CHART_DIR/$VALUES_FILE" \
      > "$tgt_render" 2>"$render_err"; then
    echo ""
    echo "  ERROR: helm template failed on target chart ($target). Possible values"
    echo "         schema breakage or a mandatory new field. Details:"
    sed 's/^/    /' "$render_err"
    echo ""
    echo "  Review the chart's release notes and values changes:"
    echo "    https://github.com/$CHART_SOURCE_REPO/releases/tag/$CHART_NAME-$target"
    exit 1
  fi

  local diff_file="$scratch/render.diff"
  diff -u "$cur_render" "$tgt_render" > "$diff_file" || true
  if [ ! -s "$diff_file" ]; then
    echo "  Rendered manifests are identical (label-only or pure refactor chart bump)."
  else
    local diff_lines
    diff_lines=$(wc -l < "$diff_file" | tr -d ' ')
    echo "  Rendered manifest diff ($diff_lines lines):"
    echo "  ---------------------------------------------"
    sed 's/^/  | /' "$diff_file"
    echo "  ---------------------------------------------"
  fi

  # Step 4: dry-run exit or backup + apply.
  echo ""
  echo "[Step 4/5] Applying chart pin update..."

  if $DRY_RUN; then
    echo "  [DRY-RUN] Would bump helmfile.yaml.version: $current -> $target"
    echo "  [DRY-RUN] Would back up helmfile.yaml to backup/${TIMESTAMP}-chart/"
    echo ""
    echo "  To apply: $(basename "$0") --upgrade-chart"
    [ -n "$TARGET_CHART_VERSION" ] && echo "  To apply: $(basename "$0") --upgrade-chart --chart-version $TARGET_CHART_VERSION"
    exit 0
  fi

  echo ""
  read -rp "  Apply chart pin update $current -> $target? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 1
  fi

  local bdir="$BACKUP_DIR/${TIMESTAMP}-chart"
  mkdir -p "$bdir"
  cp "$CHART_DIR/helmfile.yaml" "$bdir/helmfile.yaml"
  echo "  Backed up helmfile.yaml to: backup/${TIMESTAMP}-chart/"

  update_helmfile_chart_pin "$target"
  echo "  Updated helmfile.yaml (chart version: $current -> $target)"

  auto_prune_backups

  # Step 5: next-steps footer.
  echo ""
  echo "[Step 5/5] Chart pin bump complete."
  echo ""
  echo "================================================"
  echo " Chart pin bump complete! ($current -> $target)"
  echo ""
  echo " Release notes: https://github.com/$CHART_SOURCE_REPO/releases/tag/$CHART_NAME-$target"
  echo ""
  echo " Next steps:"
  echo "   1. Run: helmfile diff"
  echo "   2. Run: helmfile apply"
  echo "   3. Watch CR: kubectl -n <ns> get $COMPONENT_LABEL -w"
  echo ""
  echo " To rollback the chart pin:"
  echo "   $(basename "$0") --rollback   # pick the *-chart timestamp"
  echo "================================================"
  exit 0
}

# -----------------------------------------------
# Argument parsing
# -----------------------------------------------

DRY_RUN=false
TARGET_VERSION=""
TARGET_CHART_VERSION=""
CHART_ACTION=""   # "" | check | upgrade

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage ;;
    --list-backups)     list_backups; exit 0 ;;
    --rollback)         do_rollback; exit 0 ;;
    --cleanup-backups)  cleanup_backups; exit 0 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --check-chart)      CHART_ACTION="check"; shift ;;
    --upgrade-chart)    CHART_ACTION="upgrade"; shift ;;
    --chart-version)
      TARGET_CHART_VERSION="${2:-}"
      if [ -z "$TARGET_CHART_VERSION" ]; then
        echo "ERROR: --chart-version requires a version number"
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

# Dispatch chart-pin subcommands before the Stack-version flow.
case "$CHART_ACTION" in
  check)   do_check_chart; exit 0 ;;
  upgrade) do_upgrade_chart ;;
esac

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
