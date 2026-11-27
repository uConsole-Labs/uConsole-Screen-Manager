#!/bin/bash
# Shared safety helpers for USM manual on-device tests:
#   - Timestamped log saved in the same tests/manual/ folder
#   - 120s safety reboot watchdog with random 4-digit PIN cancel
#   - Temp /tmp USM_CONF_FILE helper (never modifies ~/.config/usm/usm.conf)

set -euo pipefail

MANUAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
USM_CLI="$HOME/.local/bin/usm-cli.sh"
CONF_FILE="$HOME/.config/usm/usm.conf"
TEMP_CONF=""
RESTORE_SWAYIDLE=false
WATCHDOG_PID=""
MANUAL_LOG_FILE=""

manual_init_log() {
  local test_name="$1"
  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  MANUAL_LOG_FILE="${MANUAL_DIR}/${test_name}_${ts}.log"
  : > "$MANUAL_LOG_FILE"
  exec > >(tee -a "$MANUAL_LOG_FILE") 2>&1
  printf "[INFO] Log file: %s\n\n" "$MANUAL_LOG_FILE"
}

manual_require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    printf "[ERROR] Passwordless sudo is required for the reboot timer.\n"
    exit 1
  fi
}

manual_make_temp_conf() {
  TEMP_CONF="/tmp/usm_manual_conf.$$"
  cp "$CONF_FILE" "$TEMP_CONF"
}

manual_stop_watchdog() {
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
    printf "[OK] Safety reboot timer cancelled. System will NOT reboot.\n"
  fi
}

manual_cleanup() {
  manual_stop_watchdog
  if [[ -n "${TEMP_CONF:-}" && -f "$TEMP_CONF" ]]; then
    rm -f "$TEMP_CONF"
  fi
  if [[ "${RESTORE_SWAYIDLE:-false}" == "true" ]]; then
    RESTORE_SWAYIDLE=false
    "$USM_CLI" swayidle-disable >/dev/null 2>&1 || true
    "$USM_CLI" swayidle-enable >/dev/null 2>&1 || true
    printf "[OK] Restored default swayidle from %s.\n" "$CONF_FILE"
  fi
  if [[ -n "${MANUAL_LOG_FILE:-}" ]]; then
    printf "[INFO] Log saved to: %s\n" "$MANUAL_LOG_FILE"
  fi
}

trap manual_cleanup EXIT INT TERM

manual_wait_enter() {
  local prompt="$1"
  read -r -p ">>> ${prompt} (Press Enter to continue)... " _
}

manual_start_watchdog() {
  (
    sleep 120
    sudo -n reboot
  ) &
  WATCHDOG_PID=$!
  printf "[ARMED] 120s safety reboot timer started.\n"
}

manual_wait_pin_cancel() {
  local instructions="$1"
  local pin input=""
  pin=$(shuf -i 1000-9999 -n 1)
  printf "\n========================================\n"
  printf "[SAFETY TIMER] System will auto-reboot in 120 seconds!\n"
  printf "%s\n" "$instructions"
  printf "When the screen is back, type this 4-digit PIN to cancel: %s\n" \
    "$pin"
  printf "========================================\n"
  while true; do
    read -r -p "Enter 4-digit PIN (${pin}): " input
    if [[ "$input" == "$pin" ]]; then
      manual_stop_watchdog
      return 0
    fi
    printf "[ERROR] Wrong PIN. Please try again.\n"
  done
}

manual_show_displays() {
  wlr-randr | grep -E "^[^ ]|Enabled:|current" || true
}

manual_countdown() {
  local secs="$1"
  local msg="$2"
  printf "\n[WAIT] %s (%ds)\n" "$msg" "$secs"
  local i
  for (( i = secs; i > 0; i-- )); do
    if [[ -w /dev/tty ]]; then
      printf "\r  Countdown: %2ds remaining... " "$i" > /dev/tty
    fi
    sleep 1
  done
  if [[ -w /dev/tty ]]; then
    printf "\r  Countdown:  0s remaining. Done!   \n" > /dev/tty
  fi
  printf "[WAIT] Countdown finished.\n"
}
