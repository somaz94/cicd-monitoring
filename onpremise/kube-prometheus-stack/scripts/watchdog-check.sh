#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# External Prometheus Watchdog (bastion host cron)
#
# A dead-man's-switch for Prometheus that runs OUTSIDE the cluster's
# in-cluster failure domain — on the bastion / kubespray control host that
# already has kubectl + a kubeconfig. It probes Prometheus health through the
# kube-apiserver proxy (so it only needs the API server reachable, not
# in-cluster pod networking) and posts to Slack when the probe fails.
#
# WHY a host cron and not an in-cluster CronJob: a CronJob shares Prometheus'
# failure domain — if the monitoring stack (or its node) is wedged, the
# CronJob may not run either. The 2026-06-12 outage (monitoring.coreos.com
# CRDs deleted out-of-band → Prometheus pod gone) went unnoticed precisely
# because nothing outside Prometheus was watching it. The API server was
# healthy throughout, so this proxy probe would have caught it within 5m.
#
# Scope / limitation: this catches app-level failures (pod gone, CRD deleted,
# OOM, crashloop, bad helm apply) while the API server is up. It does NOT
# catch a total host/network/power loss of the bastion itself — that requires
# a truly external (off-site) monitor. Acceptable trade-off for a dev cluster.
#
# Install: see docs/external-watchdog.md. Summary:
#   1. Copy this script to the bastion (or run from a repo checkout there).
#   2. Create the env file (default /etc/example/prometheus-watchdog.env) with:
#        SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
#   3. crontab -e:  */5 * * * * /path/to/watchdog-check.sh
#
# The Slack webhook is read from the bastion-local env file (NOT hardcoded
# here) so the URL lives in exactly one place per host and never in the repo.
# ============================================================

# --- Config (env overrides; sourced from the env file first) ----------------
WATCHDOG_ENV_FILE="${WATCHDOG_ENV_FILE:-/etc/example/prometheus-watchdog.env}"
if [ -f "${WATCHDOG_ENV_FILE}" ]; then
  # shellcheck source=/dev/null
  . "${WATCHDOG_ENV_FILE}"
fi

CLUSTER_NAME="${CLUSTER_NAME:-example-cluster}"
NAMESPACE="${NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-kube-prometheus-stack-prometheus}"
PROM_PORT="${PROM_PORT:-9090}"
HEALTH_PATH="${HEALTH_PATH:-/-/healthy}"
STATE_FILE="${STATE_FILE:-/var/tmp/prometheus-watchdog.state}"
REMINDER_INTERVAL="${REMINDER_INTERVAL:-3600}"   # seconds between "still DOWN" reminders
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10s}"
KUBECTL="${KUBECTL:-kubectl}"

# SLACK_WEBHOOK_URL must be provided (env or env file). Fail loudly otherwise —
# cron mails the output to the host owner, surfacing the misconfiguration.
: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL not set — export it or put it in ${WATCHDOG_ENV_FILE}}"

# --- Helpers ----------------------------------------------------------------

# Post a plain-text message to Slack. Best-effort: a failed POST must not crash
# the cron (egress could be down), so it only warns on stderr.
notify() {
  message="$1"
  # message is controlled (no double-quotes), safe to embed in the JSON literal.
  if ! curl -sf -m 10 -X POST \
      -H 'Content-type: application/json' \
      --data "{\"text\":\"${message}\"}" \
      "${SLACK_WEBHOOK_URL}" >/dev/null 2>&1; then
    printf 'watchdog: slack notify failed\n' >&2
  fi
}

# Probe Prometheus /-/healthy through the kube-apiserver service proxy.
# Returns 0 when healthy, non-zero on any failure (Prometheus down, no
# endpoints, or API unreachable — all of which warrant an alert).
prometheus_healthy() {
  "${KUBECTL}" get --raw \
    "/api/v1/namespaces/${NAMESPACE}/services/${PROM_SVC}:${PROM_PORT}/proxy${HEALTH_PATH}" \
    --request-timeout="${REQUEST_TIMEOUT}" >/dev/null 2>&1
}

# --- State machine (throttled alerting) -------------------------------------
# STATE_FILE holds one line: "<UP|DOWN> <first_fail_epoch> <last_notify_epoch>".
now="$(date +%s)"
prev_status="UP"
first_fail="0"
last_notify="0"
if [ -r "${STATE_FILE}" ]; then
  read -r prev_status first_fail last_notify < "${STATE_FILE}" || true
  prev_status="${prev_status:-UP}"
  first_fail="${first_fail:-0}"
  last_notify="${last_notify:-0}"
fi

if prometheus_healthy; then
  if [ "${prev_status}" = "DOWN" ]; then
    down_min=$(( (now - first_fail) / 60 ))
    notify "✅ [${CLUSTER_NAME}] Prometheus recovered — ${PROM_SVC}:${PROM_PORT}${HEALTH_PATH} OK (was down ~${down_min}m, bastion watchdog)"
  fi
  printf 'UP 0 0\n' > "${STATE_FILE}"
else
  if [ "${prev_status}" != "DOWN" ]; then
    notify "🔴 [${CLUSTER_NAME}] Prometheus health check FAILED — ${PROM_SVC}:${PROM_PORT}${HEALTH_PATH} unreachable (bastion watchdog)"
    printf 'DOWN %s %s\n' "${now}" "${now}" > "${STATE_FILE}"
  elif [ "$(( now - last_notify ))" -ge "${REMINDER_INTERVAL}" ]; then
    down_min=$(( (now - first_fail) / 60 ))
    notify "🔴 [${CLUSTER_NAME}] Prometheus still DOWN ~${down_min}m — ${PROM_SVC} (bastion watchdog)"
    printf 'DOWN %s %s\n' "${first_fail}" "${now}" > "${STATE_FILE}"
  fi
fi
