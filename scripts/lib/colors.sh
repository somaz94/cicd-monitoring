# shellcheck shell=bash
# =============================================================================
# scripts/lib/colors.sh — Shared ANSI color variables
# =============================================================================
# ANSI color variables consumed by every bash script under scripts/.
# When stdout is not a TTY or NO_COLOR is set, every variable is left as
# an empty string so the call sites stay neutral.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/<relative-path>/lib/colors.sh"
#
# Idempotent guard — safe to source multiple times from the same script.
# =============================================================================

[[ -n "${__SCRIPTS_LIB_COLORS_LOADED:-}" ]] && return 0
__SCRIPTS_LIB_COLORS_LOADED=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED=
  GREEN=
  YELLOW=
  BLUE=
  CYAN=
  BOLD=
  DIM=
  NC=
fi
