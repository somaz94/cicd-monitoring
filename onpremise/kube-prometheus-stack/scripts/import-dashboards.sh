#!/bin/bash
set -euo pipefail

# ============================================================
# Grafana Dashboard Import Script
# POSTs JSON files under <chart>/dashboards/ to the Grafana
# HTTP API. Idempotent — repeat runs overwrite dashboards with
# the same uid (`overwrite: true`).
#
# Files under sub-directories (e.g. dashboards/_deprecated/)
# are intentionally skipped; move retired dashboards there.
# ============================================================
SCRIPT_NAME="Grafana Dashboard Import"
DEFAULT_URL="http://grafana.example.com"
DEFAULT_USER="admin"
DEFAULT_SECRET_NS="monitoring"
DEFAULT_SECRET_NAME="kube-prometheus-stack-grafana"
DEFAULT_SECRET_KEY="admin-password"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARDS_DIR="${DASHBOARDS_DIR:-$CHART_DIR/dashboards}"

# Replace $HOME with ~ for display purposes only
_tilde() {
  local p="$1"
  [[ "$p" == "$HOME"* ]] && printf '~%s' "${p#$HOME}" || printf '%s' "$p"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

$SCRIPT_NAME — POST custom dashboards to Grafana via HTTP API.

Selection (choose one; --all is the default when no -f is given):
  -f, --file <PATH>        Import this JSON file. Repeat -f for multiple files.
      --all                Import every *.json directly under the dashboards directory.
      --except <PAT[,PAT]> With --all, skip files whose basename contains any comma-separated substring.

Connection:
  -u, --url <URL>             Grafana base URL
  -U, --user <USER>           Grafana user
  -p, --password <PASS>       Grafana password (or GRAFANA_PASSWORD env)
      --from-secret           Fetch password via kubectl from the configured secret
      --secret-namespace <NS> Kubernetes namespace for --from-secret
      --secret-name <NAME>    Secret name for --from-secret
      --secret-key <KEY>      Data key inside the secret

Behavior:
  -n, --dry-run               List the files that would be imported; send no requests.
  -v, --verbose               Print the full Grafana response body for each import.
  -h, --help                  Show this help.

Environment:
  GRAFANA_PASSWORD            Password, used when -p / --password is not given.
  GRAFANA_SECRET_NS           Default for --secret-namespace.
  GRAFANA_SECRET_NAME         Default for --secret-name.
  GRAFANA_SECRET_KEY          Default for --secret-key.
  DASHBOARDS_DIR              Override dashboards directory.

Defaults:
  SCRIPT_DIR                  $(_tilde "$SCRIPT_DIR")
  CHART_DIR                   $(_tilde "$CHART_DIR")
  DASHBOARDS_DIR              $(_tilde "$DASHBOARDS_DIR")
  URL                         $DEFAULT_URL
  USER                        $DEFAULT_USER
  SECRET_NAMESPACE            $DEFAULT_SECRET_NS
  SECRET_NAME                 $DEFAULT_SECRET_NAME
  SECRET_KEY                  $DEFAULT_SECRET_KEY

Examples:
  # Bulk import, password from kube secret
  $(basename "$0") --all --from-secret

  # Bulk, skip two files
  $(basename "$0") --all --except ingress-nginx,metallb -p 'xxx'

  # Explicit files, multiple -f
  $(basename "$0") -f dashboards/mysql-dashboard.json -f dashboards/redis-dashboard.json -p 'xxx'

  # Preview only
  $(basename "$0") --all --dry-run
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

URL="$DEFAULT_URL"
GRAFANA_USER="$DEFAULT_USER"
PASSWORD="${GRAFANA_PASSWORD:-}"
SECRET_NS="${GRAFANA_SECRET_NS:-$DEFAULT_SECRET_NS}"
SECRET_NAME="${GRAFANA_SECRET_NAME:-$DEFAULT_SECRET_NAME}"
SECRET_KEY="${GRAFANA_SECRET_KEY:-$DEFAULT_SECRET_KEY}"
DRY_RUN=0
VERBOSE=0
MODE=""          # "file" | "all" — decided from flags
FROM_SECRET=0
EXCEPT=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)           URL="$2"; shift 2 ;;
    -U|--user)          GRAFANA_USER="$2"; shift 2 ;;
    -p|--password)      PASSWORD="$2"; shift 2 ;;
    --from-secret)      FROM_SECRET=1; shift ;;
    --secret-namespace) SECRET_NS="$2"; shift 2 ;;
    --secret-name)      SECRET_NAME="$2"; shift 2 ;;
    --secret-key)       SECRET_KEY="$2"; shift 2 ;;
    -f|--file)          FILES+=("$2"); MODE="${MODE:-file}"; shift 2 ;;
    --all)              MODE="all"; shift ;;
    --except)           EXCEPT="$2"; shift 2 ;;
    -n|--dry-run)       DRY_RUN=1; shift ;;
    -v|--verbose)       VERBOSE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Default mode when nothing was specified
[[ -z "$MODE" ]] && MODE="all"

# --except is only meaningful with --all
if [[ "$MODE" == "file" && -n "$EXCEPT" ]]; then
  die "--except is only valid with --all"
fi

# Can't combine -f with --all explicitly
if [[ "$MODE" == "all" && ${#FILES[@]} -gt 0 ]]; then
  die "-f/--file and --all are mutually exclusive"
fi

# Required tools
need_bins=(python3)
if [[ $DRY_RUN -eq 0 ]]; then
  need_bins+=(curl)
  [[ $FROM_SECRET -eq 1 ]] && need_bins+=(kubectl base64)
fi
for bin in "${need_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

# Fetch password from secret if asked (skip during dry-run — no POST will be sent)
if [[ $FROM_SECRET -eq 1 && $DRY_RUN -eq 0 ]]; then
  if ! PASSWORD="$(kubectl get secret -n "$SECRET_NS" "$SECRET_NAME" \
                    -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 --decode)"; then
    die "failed to read $SECRET_NS/$SECRET_NAME:$SECRET_KEY (check kubectl context / RBAC)"
  fi
  [[ -z "$PASSWORD" ]] && die "secret $SECRET_NS/$SECRET_NAME returned empty $SECRET_KEY"
fi

# Resolve file list
if [[ "$MODE" == "all" ]]; then
  [[ -d "$DASHBOARDS_DIR" ]] || die "dashboards directory not found: $DASHBOARDS_DIR"
  shopt -s nullglob
  FILES=("$DASHBOARDS_DIR"/*.json)
  shopt -u nullglob

  if [[ -n "$EXCEPT" ]]; then
    IFS=',' read -r -a except_pats <<< "$EXCEPT"
    kept=()
    skipped=()
    for f in "${FILES[@]}"; do
      name="$(basename "$f")"
      drop=0
      for pat in "${except_pats[@]}"; do
        pat_trim="${pat## }"; pat_trim="${pat_trim%% }"
        [[ -z "$pat_trim" ]] && continue
        if [[ "$name" == *"$pat_trim"* ]]; then drop=1; break; fi
      done
      if [[ $drop -eq 1 ]]; then skipped+=("$name"); else kept+=("$f"); fi
    done
    FILES=("${kept[@]}")
    if [[ ${#skipped[@]} -gt 0 ]]; then
      echo "Excluded ${#skipped[@]} file(s) via --except:"
      printf '  - %s\n' "${skipped[@]}"
      echo ""
    fi
  fi
fi

[[ ${#FILES[@]} -gt 0 ]] || die "no dashboard JSON files to import"

# Password required for real runs
if [[ $DRY_RUN -eq 0 && -z "$PASSWORD" ]]; then
  die "password required: use -p/--password, GRAFANA_PASSWORD env, or --from-secret"
fi

import_one() {
  local file="$1"
  local name
  name="$(basename "$file")"

  [[ -f "$file" ]] || { echo "  ✗ $name -> file not found: $file" >&2; return 1; }

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would import: $name -> $URL/api/dashboards/db"
    return 0
  fi

  echo "Importing: $name"

  local payload
  if ! payload="$(python3 -c \
        "import sys,json; d=json.load(open(sys.argv[1])); print(json.dumps({'dashboard':d,'overwrite':True,'folderId':0}))" \
        "$file" 2>/tmp/import-dashboards.err)"; then
    echo "  ✗ $name -> invalid JSON: $(cat /tmp/import-dashboards.err)" >&2
    return 1
  fi

  local resp http_code body
  resp="$(curl -sS -w $'\n%{http_code}' -X POST "$URL/api/dashboards/db" \
            -H "Content-Type: application/json" \
            -u "$GRAFANA_USER:$PASSWORD" \
            --data-binary "$payload")" || { echo "  ✗ $name -> curl failed" >&2; return 1; }

  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" =~ ^2 ]]; then
    # Grafana POST /api/dashboards/db returns version=1 for newly created dashboards
    # and an incremented version for each overwrite, so we can tell the two cases apart.
    local status
    status="$(printf '%s' "$body" | \
              python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('version', 0)
action = 'created' if v == 1 else ('updated (v=' + str(v) + ')' if v > 1 else d.get('status','ok'))
print(action + ' uid=' + str(d.get('uid','')) + ' slug=' + str(d.get('slug','')))
" 2>/dev/null || echo "HTTP $http_code")"
    echo "  ✓ $name -> $status"
    [[ $VERBOSE -eq 1 ]] && echo "    $body"
    return 0
  fi

  echo "  ✗ $name -> HTTP $http_code" >&2
  echo "    body: $body" >&2
  return 1
}

echo "=== $SCRIPT_NAME ==="
echo "Target  : $URL"
echo "User    : $GRAFANA_USER"
echo "Mode    : $MODE$([[ $DRY_RUN -eq 1 ]] && echo ' (dry-run)')"
echo "Source  : $(_tilde "$DASHBOARDS_DIR")"
echo "Files   : ${#FILES[@]}"
[[ $FROM_SECRET -eq 1 ]] && echo "Password: fetched from $SECRET_NS/$SECRET_NAME (key: $SECRET_KEY)"
echo ""

ok_files=()
failed_files=()
for f in "${FILES[@]}"; do
  if import_one "$f"; then
    ok_files+=("$(basename "$f")")
  else
    failed_files+=("$(basename "$f")")
  fi
done

echo ""
echo "Summary: ${#ok_files[@]} imported, ${#failed_files[@]} failed (of ${#FILES[@]})"
if [[ ${#failed_files[@]} -gt 0 ]]; then
  echo "Failed:"
  printf '  - %s\n' "${failed_files[@]}"
  exit 1
fi
