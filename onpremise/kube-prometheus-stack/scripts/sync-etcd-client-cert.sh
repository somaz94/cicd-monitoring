#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# etcd Client Cert Sync Script
# Pulls the kubespray-managed etcd CA + admin client cert/key from a
# control-plane node via SSH and creates/updates a Kubernetes Secret
# that the kube-prometheus-stack ServiceMonitor mounts into the
# Prometheus pod for the mTLS scrape of etcd metrics (port 2379).
#
# Idempotent — uses `kubectl apply` with a dry-run rendered manifest,
# so repeat runs converge to the desired state without hot-conflict.
#
# Re-run when:
#   - the etcd cert is rotated by kubespray (default validity 365d)
#   - the cluster is rebuilt or the control-plane node IP changes
#   - the client cert files on the control plane are regenerated
# ============================================================

SCRIPT_NAME="etcd Client Cert Sync"
DEFAULT_NODE="192.168.1.17"
DEFAULT_SSH_USER="example"
DEFAULT_NS="monitoring"
DEFAULT_SECRET="etcd-client-cert"
DEFAULT_CERT_DIR="/etc/ssl/etcd/ssl"
# kubespray names the admin cert per-node (admin-<node>.pem).
DEFAULT_CA_FILE="ca.pem"
DEFAULT_CLIENT_CERT_FILE="admin-k8s-control-01.pem"
DEFAULT_CLIENT_KEY_FILE="admin-k8s-control-01-key.pem"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

$SCRIPT_NAME — pull etcd client cert from control plane, create/update Secret.

Connection:
  -H, --node <IP|HOST>     Control-plane node to SSH into (default: $DEFAULT_NODE)
  -u, --user <USER>        SSH user (default: $DEFAULT_SSH_USER)
      --cert-dir <PATH>    Remote dir holding etcd certs (default: $DEFAULT_CERT_DIR)
      --ca <FILE>          CA cert filename (default: $DEFAULT_CA_FILE)
      --client-cert <FILE> Client cert filename (default: $DEFAULT_CLIENT_CERT_FILE)
      --client-key <FILE>  Client key filename (default: $DEFAULT_CLIENT_KEY_FILE)

Target Secret:
  -n, --namespace <NS>     Target namespace (default: $DEFAULT_NS)
  -s, --secret <NAME>      Target secret name (default: $DEFAULT_SECRET)

Behavior:
      --dry-run            Render the Secret YAML to stdout, send no kubectl apply.
  -h, --help               Show this help.

Examples:
  # Default (kubespray dev cluster, control-01)
  $(basename "$0")

  # Different node / user
  $(basename "$0") -H 192.168.1.18 -u ubuntu

  # Render only — preview the Secret without applying
  $(basename "$0") --dry-run
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

NODE="$DEFAULT_NODE"
SSH_USER="$DEFAULT_SSH_USER"
NS="$DEFAULT_NS"
SECRET="$DEFAULT_SECRET"
CERT_DIR="$DEFAULT_CERT_DIR"
CA_FILE="$DEFAULT_CA_FILE"
CLIENT_CERT_FILE="$DEFAULT_CLIENT_CERT_FILE"
CLIENT_KEY_FILE="$DEFAULT_CLIENT_KEY_FILE"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--node)        NODE="$2"; shift 2 ;;
    -u|--user)        SSH_USER="$2"; shift 2 ;;
    --cert-dir)       CERT_DIR="$2"; shift 2 ;;
    --ca)             CA_FILE="$2"; shift 2 ;;
    --client-cert)    CLIENT_CERT_FILE="$2"; shift 2 ;;
    --client-key)     CLIENT_KEY_FILE="$2"; shift 2 ;;
    -n|--namespace)   NS="$2"; shift 2 ;;
    -s|--secret)      SECRET="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Required tools (ssh always; kubectl only when applying).
need_bins=(ssh)
[[ $DRY_RUN -eq 0 ]] && need_bins+=(kubectl)
for bin in "${need_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

# Stage cert content into a temp dir (cleaned up on exit).
tmpdir="$(mktemp -d -t etcd-cert.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

echo "=== $SCRIPT_NAME ==="
echo "Node     : $SSH_USER@$NODE"
echo "Cert dir : $CERT_DIR"
echo "Secret   : $NS/$SECRET"
[[ $DRY_RUN -eq 1 ]] && echo "Mode     : dry-run (no apply)"
echo ""

fetch_one() {
  local remote="$1"
  local local_path="$2"
  local label="$3"
  echo "  fetching $label ($remote)"
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$NODE" \
        "sudo cat $remote" > "$local_path" 2>/tmp/etcd-cert-fetch.err; then
    die "ssh fetch failed for $remote: $(cat /tmp/etcd-cert-fetch.err 2>/dev/null || true)"
  fi
  [[ -s "$local_path" ]] || die "fetched $label is empty (sudoers / file missing?)"
}

fetch_one "$CERT_DIR/$CA_FILE"          "$tmpdir/ca.crt"     "CA"
fetch_one "$CERT_DIR/$CLIENT_CERT_FILE" "$tmpdir/client.crt" "client cert"
fetch_one "$CERT_DIR/$CLIENT_KEY_FILE"  "$tmpdir/client.key" "client key"

# Render the Secret from kubectl in client-side dry-run, then apply (server-side reconcile).
echo ""
echo "  rendering secret manifest..."
manifest="$(kubectl create secret generic "$SECRET" \
  --namespace "$NS" \
  --from-file=ca.crt="$tmpdir/ca.crt" \
  --from-file=client.crt="$tmpdir/client.crt" \
  --from-file=client.key="$tmpdir/client.key" \
  --dry-run=client -o yaml)"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "$manifest"
  exit 0
fi

echo "  applying to cluster..."
echo "$manifest" | kubectl apply -f -
echo ""
echo "✓ secret $NS/$SECRET synchronized."
