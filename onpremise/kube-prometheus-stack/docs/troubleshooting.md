# Troubleshooting Guide

Known issues and solutions for kube-prometheus-stack operations.

<br/>

## kube-apiserver gRPC etcd Connection Warning (K8s 1.34.x)

### Symptoms

kube-apiserver logs show the following Warning every 30 seconds:

```
grpc: addrConn.createTransport failed to connect to {Addr: "192.168.1.17:2379", ...}.
Err: connection error: desc = "transport: Error while dialing: dial tcp 192.168.1.17:2379: operation was canceled"
```

`KubeAPIErrorBudgetBurn` alert may fire.

<br/>

### Cause

**Known bug in Kubernetes 1.34.x** ([kubernetes/kubernetes#134080](https://github.com/kubernetes/kubernetes/issues/134080))

- K8s 1.34 upgraded etcd client v3.5 -> v3.6 and gRPC v1.68 -> v1.72
- Every `/metrics` scrape creates a new etcd client and immediately closes it
- The new gRPC `pickfirstleaf` balancer emits Warnings during connection teardown
- Prometheus scrapes every 30 seconds, producing Warnings at the same interval

**No impact on cluster operations** — these are Warning-level logs and existing connections work normally.

<br/>

### Verification

```bash
# Verify cluster is healthy
kubectl get nodes
kubectl get pods -A | head -10

# etcd health check
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://192.168.1.17:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/node-k8s-control-01.pem \
  --key=/etc/ssl/etcd/ssl/node-k8s-control-01-key.pem

# Check API server -> etcd connections (should show many ESTABLISHED)
ss -tnp | grep 2379 | wc -l
```

<br/>

### Solutions

#### Option 1: Wait for patch release (recommended)

Fix PR ([kubernetes/kubernetes#138075](https://github.com/kubernetes/kubernetes/pull/138075)) is in progress to reuse etcd clients. Since cluster operations are unaffected, ignore the Warnings and wait for the patch.

#### Option 2: Silence KubeAPIErrorBudgetBurn alert

If the Warning triggers alerts, add null routing in `values/mgmt-alertmanager.yaml`:

```yaml
route:
  routes:
    - receiver: 'null'
      matchers:
        - alertname = "KubeAPIErrorBudgetBurn"
```

#### Option 3: Disable kubeApiServer scraping

Stopping `/metrics` scraping eliminates the Warnings, but API server metrics will no longer be collected:

```yaml
kubeApiServer:
  enabled: false
```

<br/>

## etcd Performance Degradation (Virtual Disk Environment)

### Symptoms

etcd logs show intermittent Warnings:

```
"apply request took too long" took: 152ms, expected-duration: 100ms
```

`etcdctl check perf` reports `Slowest request took too long` FAIL.

<br/>

### Cause

Virtual disk (vda) I/O latency causes etcd responses to exceed the 100ms threshold. Hypervisor I/O scheduling can introduce intermittent latency spikes.

<br/>

### Solutions

```bash
# 1. etcd defrag (cleans DB fragmentation, no service impact)
sudo ETCDCTL_API=3 etcdctl defrag \
  --endpoints=https://192.168.1.17:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/node-k8s-control-01.pem \
  --key=/etc/ssl/etcd/ssl/node-k8s-control-01-key.pem

# 2. Raise etcd I/O priority (resets on restart)
sudo ionice -c 1 -n 0 -p $(pgrep etcd)

# 3. Persist via systemd override
sudo systemctl edit etcd
# Add:
# [Service]
# IOSchedulingClass=realtime
# IOSchedulingPriority=0
sudo systemctl daemon-reload
sudo systemctl restart etcd
```

For a permanent fix, move the etcd data directory to an SSD-backed storage.

<br/>

## Periodic etcd Defrag

etcd does not reclaim disk space immediately when keys are deleted or updated, causing fragmentation over time.

### Check Status

```bash
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://192.168.1.17:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/node-k8s-control-01.pem \
  --key=/etc/ssl/etcd/ssl/node-k8s-control-01-key.pem \
  --write-out=table
```

If there is a large gap between `DB SIZE` and `IN USE`, defrag is needed. Running defrag weekly via cron is recommended.

<br/>

## helmfile CRD Error on First Install

### Symptoms

```
helmfile apply fails with ServiceMonitor, PrometheusRule CRD errors
```

### Cause

`helmfile apply` runs a diff first, which fails when CRDs don't exist yet.

### Solution

```bash
# First install (CRDs not yet present)
helmfile sync

# Subsequent updates
helmfile apply
```

<br/>

## Alertmanager Watchdog/InfoInhibitor Slack Noise

### Symptoms

Slack `#infra-alerts` channel receives repeated `Watchdog` and `InfoInhibitor` alerts.

### Cause

- `Watchdog`: Health check alert for Alertmanager (always firing)
- `InfoInhibitor`: System alert for suppressing info-level alerts

### Solution

Route to null receiver in `values/mgmt-alertmanager.yaml` (included in default config):

```yaml
route:
  routes:
    - receiver: 'null'
      matchers:
        - alertname = "Watchdog"
    - receiver: 'null'
      matchers:
        - alertname = "InfoInhibitor"
receivers:
  - name: 'null'
```
