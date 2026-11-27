#!/bin/bash
# Manual Test 09: External app wakes HDMI -> 1 Power Key press turns it off.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "09_external_app_wake_guard"
manual_require_sudo

printf "=== Manual Test 09: External App Wake Guard ===\n"
printf "What this test checks:\n"
printf "  1. Confirm external HDMI screen is ON.\n"
printf "  2. Start 120s safety timer and a 5s background 'wlopm --on'.\n"
printf "  3. Press Power Key right away to turn HDMI OFF.\n"
printf "  4. Wait 5s for the background command to wake HDMI.\n"
printf "  5. Press Power Key ONCE -> HDMI should turn OFF immediately\n"
printf "     (no need to press twice). Press Power Key again to wake.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is ON"

manual_start_watchdog
(
  sleep 5
  wlopm --on HDMI-A-1 || true
) &
wake_pid=$!

manual_countdown 6 \
  "Press Power Key NOW (HDMI OFF)! Waiting for background wlopm --on"
wait "$wake_pid" || true

manual_wait_pin_cancel \
  "HDMI should be back ON. Press Power Key 1x (OFF) -> 1x (ON), then PIN."

printf "\n--- Final Displays ---\n"
manual_show_displays
printf "\n[DONE] Manual Test 09 finished.\n"
