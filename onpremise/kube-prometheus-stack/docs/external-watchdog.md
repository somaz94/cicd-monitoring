# External Prometheus Watchdog (bastion host cron)

Prometheus cannot alert on its own death. That is exactly why the 2026-06-12 outage (the `monitoring.coreos.com` CRDs deleted out-of-band → the Prometheus pod gone) went unnoticed for so long — **nothing outside Prometheus was watching Prometheus.**

This watchdog closes that blind spot. It runs as a cron **outside** the cluster's in-cluster failure domain — on the bastion

<br/>

## How it works

```
bastion cron (5m)
   └─> kubectl get --raw /api/v1/namespaces/monitoring/services/
                          kube-prometheus-stack-prometheus:9090/proxy/-/healthy
        ├─ 200 OK  → quiet (if previous state was DOWN, one ✅ recovery message)
        └─ failure → 🔴 Slack alert (then hourly reminder, ✅ on recovery)
```

- Probing via the **kube-apiserver proxy** means it only needs the API server reachable, not in-cluster pod networking. It precisely catches the state where the API is up but Prometheus is down (the 6/12 scenario).
- **Why a host cron**: an in-cluster CronJob shares Prometheus' failure domain — if the monitoring stack / its node is wedged, the CronJob may not run either. So it lives on the bastion (outside the cluster but able to reach the API).

<br/>

## Limitations (honest)

- It catches app-level failures (pod gone, CRD deleted, OOM, crashloop, bad helm apply) as long as the API server is up.
- It does NOT catch a total host/network/power loss of the bastion itself — the cron dies with it. Catching a full outage needs an off-site external (SaaS) monitor. Acceptable trade-off for a dev cluster.

<br/>

## Active deployment

**This watchdog is installed on `server4` and runs every 5 minutes** (since 2026-06-12). server4 is an always-on LAN server (not a cluster node); it was installed under the user's home with no sudo.

| Item | Value |
|---|---|
| Host | `server4` (192.168.1.15) — non-cluster, always-on |
| Install path | `/home/example/.prometheus-watchdog/` |
| Files | `watchdog-check.sh` · `kubectl` (v1.34.3) · `kubeconfig` (SA token, 600) · `watchdog.env` (Slack webhook, 600) |
| Credential | Minimal ServiceAccount `prometheus-watchdog` (`monitoring` ns, `services/proxy` get only — not admin). Manifest: [scripts/watchdog-rbac.yaml](../scripts/watchdog-rbac.yaml) |
| API endpoint | `https://192.168.1.17:6443` |
| cron | `*/5 * * * *` (cron service active) |
| Status check | `ssh server4 'cat /var/tmp/prometheus-watchdog.state'` (UP/DOWN) |

> Editing `scripts/watchdog-check.sh` in the repo does NOT auto-update server4. After editing, redeploy:
> ```bash
> scp observability/monitoring/kube-prometheus-stack/scripts/watchdog-check.sh \
>     server4:~/.prometheus-watchdog/watchdog-check.sh
> ```

The "Install" steps below are for bringing up a **new host** (server4 is already running the configuration above).

<br/>

## Install

### 1. Place the script

If a repo checkout exists on the bastion, use it directly; otherwise copy just the script.

```bash
# Using a repo checkout (recommended)
WATCHDOG=/path/to/kuberntes-infra/observability/monitoring/kube-prometheus-stack/scripts/watchdog-check.sh

# Or copy standalone
sudo install -m 0755 watchdog-check.sh /usr/local/bin/prometheus-watchdog.sh
WATCHDOG=/usr/local/bin/prometheus-watchdog.sh
```

### 2. Create the env file (Slack webhook lives here only)

The Slack webhook URL is NOT committed to the repo — keep it in a **bastion-local file** (one place per host).

```bash
sudo mkdir -p /etc/example
sudo tee /etc/example/prometheus-watchdog.env >/dev/null <<'EOF'
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
# optional overrides:
# CLUSTER_NAME="example-cluster"
# REMINDER_INTERVAL="3600"
EOF
sudo chmod 0600 /etc/example/prometheus-watchdog.env
```

Reuse the `#infra-alerts` channel webhook (can be the same one Alertmanager uses).

Putting the kubectl/kubeconfig paths in the env file too keeps the cron line short (the configuration server4 uses):
```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
export KUBECTL="$HOME/.prometheus-watchdog/kubectl"
export KUBECONFIG="$HOME/.prometheus-watchdog/kubeconfig"
export CLUSTER_NAME="example-cluster"
```

### 3. kubeconfig — minimal SA (recommended)

To avoid putting cluster-admin credentials on the watchdog host, build the kubeconfig from a ServiceAccount token that only has `get` on `services/proxy` (this is what server4 uses).

```bash
# (1) apply the minimal RBAC (once, with an admin kubeconfig)
kubectl apply -f scripts/watchdog-rbac.yaml

# (2) build a standalone kubeconfig from the SA token + CA
NS=monitoring; API=https://192.168.1.17:6443
kubectl -n $NS get secret prometheus-watchdog-token -o jsonpath='{.data.token}'    | base64 -d > token
kubectl -n $NS get secret prometheus-watchdog-token -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl --kubeconfig=kubeconfig config set-cluster example-cluster --server="$API" --certificate-authority=ca.crt --embed-certs=true
kubectl --kubeconfig=kubeconfig config set-credentials prometheus-watchdog --token="$(cat token)"
kubectl --kubeconfig=kubeconfig config set-context default --cluster=example-cluster --user=prometheus-watchdog --namespace=$NS
kubectl --kubeconfig=kubeconfig config use-context default

# (3) copy kubeconfig to the watchdog host (600); the env file's KUBECONFIG points at it
```

> If the host has no kubectl, fetch it without sudo (match the cluster version):
> ```bash
> curl -L -o kubectl https://dl.k8s.io/release/v1.34.3/bin/linux/amd64/kubectl && chmod +x kubectl
> ```

### 4. Register the crontab

```bash
crontab -e
```
```cron
# when KUBECTL/KUBECONFIG live in the env file (server4 configuration)
*/5 * * * * WATCHDOG_ENV_FILE=$HOME/.prometheus-watchdog/watchdog.env $HOME/.prometheus-watchdog/watchdog-check.sh
```

> cron may not expand `$HOME` — use **absolute paths** (e.g. `/home/example/.prometheus-watchdog/...`).

<br/>

## Configuration (env vars / env file)

| Variable | Default | Description |
|---|---|---|
| `SLACK_WEBHOOK_URL` | (required) | Slack incoming webhook URL |
| `WATCHDOG_ENV_FILE` | `/etc/example/prometheus-watchdog.env` | File that is sourced for the variables above |
| `CLUSTER_NAME` | `example-cluster` | Cluster name shown in alert messages |
| `NAMESPACE` | `monitoring` | Prometheus Service namespace |
| `PROM_SVC` | `kube-prometheus-stack-prometheus` | Prometheus Service name |
| `PROM_PORT` | `9090` | Prometheus Service port |
| `HEALTH_PATH` | `/-/healthy` | Health endpoint path |
| `STATE_FILE` | `/var/tmp/prometheus-watchdog.state` | Throttling state file |
| `REMINDER_INTERVAL` | `3600` | Seconds between "still DOWN" reminders |
| `REQUEST_TIMEOUT` | `10s` | kubectl request timeout |
| `KUBECTL` | `kubectl` | kubectl binary path override |

<br/>

## Alerting behavior (anti-spam)

A state file throttles notifications:

- **Healthy** → silent. One `✅ recovered` if the previous state was DOWN.
- **First DOWN detection** → one `🔴 ... FAILED`.
- **Sustained DOWN** → a `🔴 ... still DOWN ~Nm` reminder every `REMINDER_INTERVAL` (default 1h).
- **Recovery** → one `✅ ... recovered (was down ~Nm)`.

<br/>

## Testing

```bash
# 1) one manual run (quiet if healthy)
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ" /path/to/watchdog-check.sh

# 2) force the failure path — probe a non-existent service → 🔴 alert
PROM_SVC="does-not-exist" SLACK_WEBHOOK_URL="..." /path/to/watchdog-check.sh

# 3) verify recovery — re-run with the real service right after → ✅
SLACK_WEBHOOK_URL="..." /path/to/watchdog-check.sh
```

Remove the state file to reset: `rm -f /var/tmp/prometheus-watchdog.state`

<br/>

## Relationship to Alertmanager

kube-prometheus-stack's default `Watchdog` alert (always firing) is dropped to the `null` receiver in `dev-alertmanager.yaml` because there is **no external dead-man's-switch receiver** (the push model would require signing up for an external SaaS

> To also watch Alertmanager itself, register a second cron with `PROM_SVC=kube-prometheus-stack-alertmanager PROM_PORT=9093`.
