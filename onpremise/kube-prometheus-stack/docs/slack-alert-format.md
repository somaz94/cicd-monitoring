# Slack Alert Format

Guide for alert message format sent from Alertmanager to Slack.

<br/>

## Alert Examples

### Firing (Warning)

```
🟡 [WARNING] PodNotReady
Namespace: default
Severity: warning
Description: Pod has been in not-ready state for 10 minutes
Source: Prometheus
```
Color: Yellow (warning)

### Firing (Critical)

```
🔴 [CRITICAL] DiskSpaceCritical
Namespace: monitoring
Severity: critical
Description: Disk usage is above 95% on /data (current: 97%)
Source: Prometheus
```
Color: Red (danger)

### Resolved

```
✅ [RESOLVED] PodNotReady
Namespace: default
Severity: warning
Description: Pod has been in not-ready state for 10 minutes
Source: Prometheus
```
Color: Green (good)

<br/>

## Null Receiver (Suppressed Alerts)

| Alert | Reason |
|-------|--------|
| `Watchdog` | Pipeline health check (always firing) |
| `InfoInhibitor` | Suppresses info-level alerts |

<br/>

## Test

```bash
# Warning alert
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning","namespace":"default"},"annotations":{"description":"Testing Slack format"}}]'

# Expire
curl -X POST http://alertmanager.example.com/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"test-alert","severity":"warning","namespace":"default"},"annotations":{"description":"Testing Slack format"},"endsAt":"2024-01-01T00:00:00Z"}]'
```
