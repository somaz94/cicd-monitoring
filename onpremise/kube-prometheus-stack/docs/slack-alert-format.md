# Slack Alert Format

Guide for alert message format sent from Alertmanager to Slack.

<br/>

## Alert Examples

### Firing (Warning) — Pod Alert

```
🟡 [WARNING] PodNotReady
Namespace: default
Instance: 10.244.0.15:8080
Severity: warning
Description: Pod has been in not-ready state for 10 minutes
Source: Prometheus
```
Color: Yellow (warning)

### Firing (Critical) — Pod Alert

```
🔴 [CRITICAL] DiskSpaceCritical
Namespace: monitoring
Instance: 10.244.1.20:9090
Severity: critical
Description: Disk usage is above 95% on /data (current: 97%)
Source: Prometheus
```
Color: Red (danger)

### Firing (Warning) — Node Alert (no namespace)

```
🟡 [WARNING] NodeNetworkErrors
Instance: 10.10.10.10:9100
Severity: warning
Description: Interface enp4s0 has 10.7 errors/sec (RX+TX combined over 5m)
Source: Prometheus
```
Color: Yellow (warning)
> Node alerts don't have a Kubernetes namespace, so the `Namespace:` field is hidden. The `Instance:` field identifies the server instead.

### Resolved

```
✅ [RESOLVED] PodNotReady
Namespace: default
Instance: 10.244.0.15:8080
Severity: warning
Description: Pod has been in not-ready state for 10 minutes
Source: Prometheus
```
Color: Green (good)

<br/>

## Format Configuration

`values/mgmt.yaml` → `alertmanager.config.receivers.slack_configs`:

```yaml
slack_configs:
  - api_url: "https://hooks.slack.com/services/YOUR_WEBHOOK_URL"
    channel: "#alerts"
    send_resolved: true
    color: '{{ if eq .Status "firing" }}{{ if eq .CommonLabels.severity "critical" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}'
    title: '{{ if eq .Status "firing" }}{{ if eq .CommonLabels.severity "critical" }}:red_circle:{{ else }}:large_yellow_circle:{{ end }} [{{ .CommonLabels.severity | toUpper }}] {{ .CommonLabels.alertname }}{{ else }}:white_check_mark: [RESOLVED] {{ .CommonLabels.alertname }}{{ end }}'
    text: |-
      {{ range .Alerts -}}
      {{- if .Labels.namespace }}
      *Namespace:* `{{ .Labels.namespace }}`
      {{- end -}}
      {{- if .Labels.instance }}
      *Instance:* `{{ .Labels.instance }}`
      {{- end }}
      *Severity:* `{{ .Labels.severity }}`
      *Description:* {{ .Annotations.description }}
      {{- if .GeneratorURL }}
      *Source:* <{{ .GeneratorURL }}|Prometheus>
      {{- end }}
      {{ end }}
```

<br/>

## Field Descriptions

| Field | Description |
|-------|-------------|
| `color` | firing: danger (red) for critical / warning (yellow) for warning; resolved: good (green) |
| `title` | Emoji + severity + alertname |
| `Namespace` | Shown only for K8s workload alerts (hidden for node alerts) |
| `Instance` | Target server/Pod IP (identifies server for node alerts without namespace) |
| `send_resolved` | Sends RESOLVED message when alert clears |

<br/>

## Slack Emoji Codes

| Emoji | Code | Usage |
|-------|------|-------|
| 🔴 | `:red_circle:` | Critical |
| 🟡 | `:large_yellow_circle:` | Warning |
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
      "namespace": "default",
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
      "namespace": "default",
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
      "instance": "10.10.10.10:9100",
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
      "instance": "10.10.10.10:9100",
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
| Pod alert | Both `Namespace: default` and `Instance: 10.244.0.15:8080` shown |
| Node alert | No `Namespace:` field, only `Instance: 10.10.10.10:9100` shown |
| Resolve | ✅ RESOLVED message with green color |
