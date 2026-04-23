#!/usr/bin/env bash
# =============================================================================
# notify-rule-change.sh
#
# ArgoCD notification rule change helper
# Background: cicd/argo-cd/docs/notification-rule-change-playbook.md
#
# Usage
#   ./scripts/notify-rule-change.sh check    — dry-run: detect impacted triggers
#   ./scripts/notify-rule-change.sh pre      — before apply: impact analysis + Slack pre-notice
#   ./scripts/notify-rule-change.sh post     — after apply: sent count + goroutine check + completion notice
#   ./scripts/notify-rule-change.sh status   — controller state (goroutine
#
# Requirements
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VALUES_FILE="${SCRIPT_DIR}/../values/mgmt-notifications.yaml"
NS_ARGOCD=argocd
CONTROLLER_POD=argocd-application-controller-0
NOTIFICATIONS_DEPLOY=argocd-notifications-controller
SLACK_CHANNEL="#argocd-alarm"
# Goroutine count is informational; baseline depends on app count & sharding (1400+ seen as normal on 10-app cluster)
GOROUTINE_INFO_THRESHOLD=3000
# Real stuck detection: zero reconcile activity over this window
RECONCILE_WINDOW=10m

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' required but not found in PATH" >&2; exit 1; }
  done
}

# Extract changed trigger block names from git diff (detects oncePer/when/send changes)
# Check staged + unstaged + last commit (works both before and after apply)
detect_impacted_triggers() {
  local diff_output=""
  # 1) working tree vs HEAD
  diff_output=$(git -C "$SCRIPT_DIR/.." diff -- "values/mgmt-notifications.yaml" 2>/dev/null || true)
  # 2) if empty, fall back to HEAD~1..HEAD (changes already committed)
  if [ -z "$diff_output" ]; then
    diff_output=$(git -C "$SCRIPT_DIR/.." diff HEAD~1 HEAD -- "values/mgmt-notifications.yaml" 2>/dev/null || true)
  fi
  [ -z "$diff_output" ] && return 0
  # Pick trigger.<name> appearing near oncePer/when/send lines
  echo "$diff_output" | awk '
    /^[-+].*trigger\.[a-z-]+:/ {
      if (match($0, /trigger\.[a-z-]+/)) {
        trig = substr($0, RSTART, RLENGTH)
        last_trig = trig
      }
    }
    /^[-+].*(oncePer|when|send):/ {
      if (last_trig != "") changed[last_trig] = 1
    }
    END { for (t in changed) print t }
  ' | sort -u
}

count_applications() {
  kubectl get applications -n "$NS_ARGOCD" -o name 2>/dev/null | wc -l | tr -d ' '
}

get_slack_token() {
  kubectl get secret argocd-notifications-secret -n "$NS_ARGOCD" \
    -o jsonpath='{.data.slack-token}' 2>/dev/null | base64 -d 2>/dev/null || true
}

slack_post() {
  local text=$1
  local token
  token=$(get_slack_token)
  if [ -z "$token" ]; then
    echo "WARN: Slack bot token 조회 실패 — Slack 발송 생략 (stdout 에만 출력)" >&2
    echo "---"
    echo "$text"
    echo "---"
    return 0
  fi
  local response
  response=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$(jq -n --arg ch "$SLACK_CHANNEL" --arg t "$text" '{channel:$ch, text:$t}')" 2>&1 || true)
  local ok
  ok=$(echo "$response" | jq -r '.ok // "error"' 2>/dev/null)
  if [ "$ok" = "true" ]; then
    echo "Slack 발송 성공 → $SLACK_CHANNEL"
  else
    echo "WARN: Slack 발송 실패: $(echo "$response" | jq -r '.error // .' 2>/dev/null)" >&2
  fi
}

get_goroutines() {
  kubectl logs -n "$NS_ARGOCD" "$CONTROLLER_POD" --tail=200 2>/dev/null \
    | grep -oE 'Goroutines=[0-9]+' | tail -1 | cut -d= -f2
}

recent_reconcile_log_lines() {
  # --since=11m: stats log is emitted every 10 min, so at least 1 line must exist when healthy
  kubectl logs -n "$NS_ARGOCD" "$CONTROLLER_POD" --since=11m 2>/dev/null | wc -l | tr -d ' '
}

# -----------------------------------------------------------------------------
# commands
# -----------------------------------------------------------------------------

cmd_check() {
  require kubectl git
  echo "== git diff 기반 영향 분석 (values/mgmt-notifications.yaml) =="
  local impacted
  impacted=$(detect_impacted_triggers || true)
  if [ -z "$impacted" ]; then
    echo "영향받는 trigger 없음 (oncePer/when/send 관련 변경 미감지)"
    return 0
  fi
  echo "영향받는 trigger:"
  echo "$impacted" | sed 's/^/  - /'
  local app_count trigger_count
  app_count=$(count_applications)
  trigger_count=$(echo "$impacted" | wc -l | tr -d ' ')
  echo ""
  echo "예상 재발송량 (상한): $((app_count * trigger_count)) 건 = ${app_count} apps × ${trigger_count} triggers"
  echo "(실제 발송은 각 trigger 의 when 조건이 현재 맞는 앱에 한정됨)"
}

cmd_pre() {
  require kubectl git jq curl
  cmd_check
  local impacted
  impacted=$(detect_impacted_triggers || true)
  if [ -z "$impacted" ]; then
    echo "(dedup 영향 없음, Slack 공지 생략)"
    return 0
  fi
  local app_count trigger_count text
  app_count=$(count_applications)
  trigger_count=$(echo "$impacted" | wc -l | tr -d ' ')
  text=":warning: *ArgoCD notification rule 변경 예정*
• 변경 대상: $(echo "$impacted" | paste -sd, - | sed 's/,/, /g')
• 예상 재발송량: 최대 $((app_count * trigger_count)) 건 (${app_count} apps × ${trigger_count} triggers)
• 이후 수 분간 배포/재시작 알람이 실제 이벤트 없이 발생할 수 있음. 무시해도 됨.
• See: cicd/argo-cd/docs/notification-rule-change-playbook.md"
  echo ""
  echo "== Slack 공지 발송 =="
  slack_post "$text"
}

cmd_post() {
  require kubectl git jq curl
  echo "== 변경 후 실제 발송량 집계 =="
  local sent already
  sent=$(kubectl logs -n "$NS_ARGOCD" "deployment/${NOTIFICATIONS_DEPLOY}" --since=15m 2>/dev/null \
    | grep -c "Sending notification" || true)
  already=$(kubectl logs -n "$NS_ARGOCD" "deployment/${NOTIFICATIONS_DEPLOY}" --since=15m 2>/dev/null \
    | grep -c "already sent" || true)
  echo "최근 15분: 실제 발송 ${sent} 건

  echo ""
  echo "== Controller goroutine check (informational)
  local g
  g=$(get_goroutines || true)
  if [ -z "$g" ]; then
    echo "goroutine count unavailable (stats log pending, printed every 10 min)
  elif [ "$g" -gt "$GOROUTINE_INFO_THRESHOLD" ]; then
    echo "Goroutines=$g — above baseline threshold ${GOROUTINE_INFO_THRESHOLD}. Unusual; capture pprof and investigate.
  else
    echo "Goroutines=$g (within baseline; count alone does not indicate stuck — see reconcile activity)
  fi

  echo ""
  echo "== Slack 완료 공지 =="
  local text="$(printf ':white_check_mark: *ArgoCD notification rule 변경 완료*\n• 실제 발송: %s 건 (dedup 억제: %s 건)\n• Controller goroutines: %s\n• 이후 알람은 정상 이벤트로 간주' "$sent" "$already" "${g:-unknown}")"
  slack_post "$text"
}

cmd_status() {
  require kubectl
  echo "== Controller 현재 상태 / Controller state =="
  local g
  g=$(get_goroutines || true)
  if [ -z "$g" ]; then
    echo "Goroutines: unknown (stats log not emitted yet, printed every 10 min
  else
    printf "Goroutines: %s (informational only; baseline depends on app count)
    [ "$g" -gt "$GOROUTINE_INFO_THRESHOLD" ] && printf "  [unusually high, investigate
    echo ""
  fi
  local lines
  lines=$(recent_reconcile_log_lines)
  printf "최근 11분 로그 라인 / log lines (last 11m): %s" "$lines"
  [ "$lines" -lt 1 ] && printf "  [no stats line — complete halt
  echo ""

  # Real stuck detection: reconcile activity over RECONCILE_WINDOW
  local reconciles
  reconciles=$(kubectl logs -n "$NS_ARGOCD" "$CONTROLLER_POD" --since="$RECONCILE_WINDOW" 2>/dev/null \
    | grep -cE "Reconciliation completed" || true)
  printf "최근 %s reconcile 완료 건수 / completed reconciles in last %s: %s" "$RECONCILE_WINDOW" "$RECONCILE_WINDOW" "$reconciles"
  if [ "$reconciles" -eq 0 ]; then
    printf "  ⚠️  STUCK — no reconcile activity, restart required
  fi
  echo ""

  echo ""
  echo "== 앱별 reconciledAt 오래된 순 (상위 5) =="
  kubectl get applications -n "$NS_ARGOCD" -o json 2>/dev/null \
    | jq -r '.items[] | [.status.reconciledAt, .metadata.name] | @tsv' \
    | sort | head -5 \
    | awk -v now="$(date -u +%s)" '
      {
        # ISO8601 to epoch, macOS-compatible date invocation
        cmd = "date -u -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"" $1 "\" +%s 2>/dev/null || date -u -d \"" $1 "\" +%s 2>/dev/null"
        cmd | getline epoch
        close(cmd)
        age = int((now - epoch) / 60)
        printf "  %-40s reconciledAt=%s (%d분 전)\n", $2, $1, age
      }'
}

# -----------------------------------------------------------------------------
# entrypoint
# -----------------------------------------------------------------------------

case "${1:-help}" in
  check)  cmd_check ;;
  pre)    cmd_pre ;;
  post)   cmd_post ;;
  status) cmd_status ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
