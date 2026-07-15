# shellcheck shell=bash
# =============================================================================
# scripts/lib/prompts.sh — Shared prompt + validation utilities
# =============================================================================
# Helpers consumed by every bash script under scripts/.
# - confirm_yes_no:     y/N confirmation prompt (default No)
# - confirm_typed_word: confirmation prompt that requires an exact word
# - require_commands:   batch presence-check for required commands
# - format_human_size:  bytes → human-readable size string
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/<relative-path>/lib/prompts.sh"
#
# When sourced alongside colors.sh, the color variables (YELLOW/RED/NC ...)
# are used. The fallback below keeps the helpers safe when colors.sh is
# not loaded (variables default to empty strings).
#
# Idempotent guard — safe to source multiple times from the same script.
# Default prompt strings stay in Korean because every current call site
# explicitly supplies its own message (the defaults are last-resort
# fallbacks and the existing Korean variant scripts depend on them).
# =============================================================================

[[ -n "${__SCRIPTS_LIB_PROMPTS_LOADED:-}" ]] && return 0
__SCRIPTS_LIB_PROMPTS_LOADED=1

# colors.sh fallback — empty strings when not loaded
: "${YELLOW:=}" "${RED:=}" "${GREEN:=}" "${NC:=}"

# y/N confirmation prompt. Default answer is No.
# Args:    $1 = message to display (e.g., "정말 삭제하시겠습니까?")
# Returns: 0 = yes, 1 = no/cancel
confirm_yes_no() {
  local message="${1:-계속하시겠습니까?}"
  local reply
  printf '%s%s (y/N): %s' "${YELLOW}" "${message}" "${NC}"
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# Confirmation prompt that requires the user to type an exact word.
# Used for destructive operations (e.g., index deletion).
# Args:    $1 = message, $2 = expected word (case-sensitive)
# Returns: 0 = match, 1 = mismatch
confirm_typed_word() {
  local message="${1:-계속하려면 정확히 입력하세요}"
  local expected="${2:-CONFIRM}"
  local reply
  printf '%s%s (%s 입력): %s' "${YELLOW}" "${message}" "${expected}" "${NC}"
  read -r reply
  [[ "${reply}" == "${expected}" ]]
}

# 필수 명령어 일괄 존재 확인.
# 인자: 명령어 이름들을 가변 인자로
# 동작: 누락된 명령이 있으면 stderr 로 안내 후 exit 1
require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done

  if (( ${#missing[@]} > 0 )); then
    printf '%s✗ 다음 필수 명령어가 누락되었습니다:%s\n' "${RED}" "${NC}" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi
}

# 바이트를 사람이 읽기 쉬운 단위로 변환 (B / KiB / MiB / GiB).
# 인자: $1 = 바이트 (정수)
# 출력: stdout 으로 변환된 문자열
format_human_size() {
  local bytes="${1:-0}"
  if (( bytes >= 1073741824 )); then
    printf '%.1f GiB\n' "$(echo "scale=2; ${bytes} / 1073741824" | bc)"
  elif (( bytes >= 1048576 )); then
    printf '%.1f MiB\n' "$(echo "scale=2; ${bytes} / 1048576" | bc)"
  elif (( bytes >= 1024 )); then
    printf '%.1f KiB\n' "$(echo "scale=2; ${bytes} / 1024" | bc)"
  else
    printf '%d B\n' "${bytes}"
  fi
}
