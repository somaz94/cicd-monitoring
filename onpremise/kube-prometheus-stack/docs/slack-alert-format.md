# Slack Alert Format

Guide for alert message format sent from Alertmanager to Slack.

<br/>

## Alert Examples

The title line carries a `[<cluster>]` prefix, and the body prints only the labels the alert actually carries. `example-cluster` in the examples below is the value of `prometheusSpec.externalLabels.cluster` in `values/dev.yaml`. The blank lines are part of the template, not decoration: they separate three blocks — WHERE (labels), WHAT (summary, description, runbook), and the Prometheus link.

### Firing (Warning) — Pod Alert

```
🟡 [example-cluster] [WARNING] PodNotReady

Namespace: default
Pod: my-app-7d9f8c5b4-xk2mn
Container: my-app
Instance: 10.244.0.15:8080
Severity: warning

Summary: Pod is stuck in not-ready state
Description: Pod has been in not-ready state for 10 minutes

Source: Prometheus
```
Color: Yellow (warning)

### Firing (Critical) — Pod Alert

```
🔴 [example-cluster] [CRITICAL] DiskSpaceCritical

Namespace: monitoring
Pod: prometheus-kube-prometheus-stack-prometheus-0
Container: prometheus
Instance: 10.244.1.20:9090
Severity: critical

Summary: Disk usage is critical
Description: Disk usage is above 95% on /data (current: 97%)

Source: Prometheus
```
Color: Red (danger)

### Firing (Warning) — Node Alert (no namespace)

```
🟡 [example-cluster] [WARNING] NodeNetworkErrors

Instance: 192.0.2.10:9100
Severity: warning

Summary: Network interface is reporting errors
Description: Interface enp4s0 has 10.7 errors/sec (RX+TX combined over 5m)

Source: Prometheus
```
Color: Yellow (warning)
> Node alerts don't have a Kubernetes namespace, so the `Namespace:` field is hidden. The `Instance:` field identifies the server instead.

### Firing (Info) — Upstream Rule Carrying a Runbook

```
🔵 [example-cluster] [INFO] KubeletTooManyPods

Namespace: kube-system
Severity: info

Summary: Kubelet is running at capacity.
Description: Kubelet 'k8s-worker-01' is running at 95% of its Pod capacity.
Runbook: runbook

Source: Prometheus
```
Color: Blue (`#439FE0`)
> `Runbook:` is a link to the upstream runbook page. Only the chart's own `defaultRules` set a `runbook_url` annotation — the custom rules in `values/dev-alerts-*.yaml` do not — so the field shows up on exactly the alerts an on-call engineer is least likely to already know by heart. Info alerts reach Slack only while a warning or critical is firing beside them; see [Null Receiver](#null-receiver-suppressed-alerts).

### Firing (Warning) — Alert Carrying a `group` Label

```
🟡 [example-cluster] [WARNING] BlackboxProbeFailed

Instance: https://example.example.com
Group: blackbox
Severity: warning

Summary: Synthetic probe is failing
Description: The synthetic probe for example-hub-portal (https://example.example.com) has failed for 5+ minutes.

Source: Prometheus
```
Color: Yellow (warning)
> Custom rules in `values/dev-alerts-*.yaml` attach a `group` label (`metallb`, `blackbox`, `argocd`, `gitlab-runner`, `harbor`, …), so the message shows which alert bundle it came from. The `Env:` field behaves the same way — it appears only when the alert carries an `env` label, which on-prem targets get from `additionalScrapeConfigs`. No AWS cluster attaches that label, so `Env:` never appears there.

### Firing (Warning) — Several Alerts in One Notification

```
🟡 [example-cluster] [WARNING] DiskSpaceRunningLow

Instance: 192.0.2.11:9100
Severity: warning

Summary: Disk space running low
Description: Filesystem /data is 86% full (threshold 85%)

Source: Prometheus
──────────────────────────────
Instance: 192.0.2.12:9100
Severity: warning

Summary: Disk space running low
Description: Filesystem /var is 88% full (threshold 85%)

Source: Prometheus

Showing 10 of 59 alerts in this group.
```
Color: Yellow (warning)
> Alertmanager groups by `alertname` + `namespace`, and node alerts carry no namespace label, so one disk event collapses every node into a single notification. A rule divides the alerts so one alert's `Instance:` is not misread as another's, and **at most 10 are rendered**: Alertmanager sends `text` at any length, and Slack cuts a long attachment mid-alert with nothing to say it did. The closing line (italic in Slack) appears only when the group holds more than 10.

### Resolved

```
✅ [example-cluster] [RESOLVED] PodNotReady

Namespace: default
Pod: my-app-7d9f8c5b4-xk2mn
Container: my-app
Instance: 10.244.0.15:8080
Severity: warning

Summary: Pod is stuck in not-ready state
Description: Pod has been in not-ready state for 10 minutes

Source: Prometheus
```
Color: Green (good)

<br/>

## Format Configuration

The format SSOT is the `slack-infra-alerts` receiver under `alertmanager.config.receivers` in `values/dev-alertmanager.yaml` (three Go templates: `color` / `title` / `text`). Copying it here would drift every time the live template changes, so read the actual wording from that key.

<br/>

## Field Descriptions

| Field | Description |
|------|------|
| `color` | When firing, danger (red) / warning (yellow) / `#439FE0` (blue, info) by severity; when resolved, good (green) |
| `title` | Emoji + `[cluster]` + severity + alertname (`cluster` comes from `prometheusSpec.externalLabels` in `values/dev.yaml`) |
| `Namespace` / `Pod` / `Container` | Shown for K8s workload alerts, each only when the alert carries that label (all three hidden for node alerts) |
| `Instance` | Target server/Pod endpoint (identifies the server for node alerts that have no namespace) |
| `Env` / `Group` | Shown only for alerts carrying an `env` / `group` label — identifies which custom-rule bundle it came from. `env` is attached by the on-prem `additionalScrapeConfigs` and exists on no AWS cluster |
| `Summary` | The alert's one-line headline. Every rule in this repo sets it; without this field it was being dropped entirely |
| `Runbook` | Link from the `runbook_url` annotation — set by the chart's `defaultRules`, not by the custom rules here |
| `text` group cap | At most 10 alerts render per Slack message, followed by a count of the total. Alertmanager truncates `title` at 1024 runes but sends `text` at any length |
| `send_resolved` | Sends a RESOLVED message when the alert clears |

> Every body field is wrapped in `{{- if .Labels.<x> }}`, so the line itself is omitted for alerts that lack the label.

<br/>

## Slack Emoji Codes

| Emoji | Code | Usage |
|--------|------|------|
| 🔴 | `:red_circle:` | Critical |
| 🟡 | `:large_yellow_circle:` | Warning |
| 🔵 | `:large_blue_circle:` | Info |
| ✅ | `:white_check_mark:` | Resolved |

<br/>

## Null Receiver (Suppressed Alerts)

| Alert | Reason |
|-------|--------|
| `Watchdog` | Pipeline health check (always firing) |
| `InfoInhibitor` | Suppresses info-level alerts |

<br/>

## Test

### 1. Pod Alert Test (with namespace)

**Fire:**
```bash
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "test-pod-alert",
      "severity": "critical",
      "namespace": "slack-bots",
      "pod": "test-pod-abc123",
      "instance": "10.244.0.15:8080"
    },
    "annotations": {
      "description": "Testing pod alert — namespace and instance should both appear"
    }
  }]'
```

**Resolve:**
```bash
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "test-pod-alert",
      "severity": "critical",
      "namespace": "slack-bots",
      "pod": "test-pod-abc123",
      "instance": "10.244.0.15:8080"
    },
    "annotations": {
      "description": "Testing pod alert — namespace and instance should both appear"
    },
    "endsAt": "2024-01-01T00:00:00Z"
  }]'
```

### 2. Node Alert Test (no namespace)

**Fire:**
```bash
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "NodeNetworkErrors",
      "severity": "warning",
      "instance": "192.0.2.10:9100",
      "device": "enp4s0"
    },
    "annotations": {
      "description": "Interface enp4s0 has 15.5 errors/sec (RX+TX combined over 5m)"
    }
  }]'
```

**Resolve:**
```bash
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "NodeNetworkErrors",
      "severity": "warning",
      "instance": "192.0.2.10:9100",
      "device": "enp4s0"
    },
    "annotations": {
      "description": "Interface enp4s0 has 15.5 errors/sec (RX+TX combined over 5m)"
    },
    "endsAt": "2024-01-01T00:00:00Z"
  }]'
```

### Verification Checklist

| Test | Expected Result |
|------|----------------|
| All | Title carries the `[<cluster>]` prefix (the `prometheusSpec.externalLabels.cluster` value in `values/dev.yaml`) |
| Pod alert | All of `Namespace: slack-bots`, `Pod: test-pod-abc123`, `Instance: 10.244.0.15:8080` shown (plus `Container:` if a `container` label was included) |
| Node alert | No `Namespace:` / `Pod:` / `Container:` fields, only `Instance: 192.0.2.10:9100` shown |
| `env` / `group` | `Env:` / `Group:` lines appear only when those labels were included |
| Resolve | ✅ RESOLVED message with green color |
