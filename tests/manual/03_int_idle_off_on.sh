#!/bin/bash
# Manual Test 03: Internal DSI-2 idle-off -> wait 5s -> idle-on recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "03_int_idle_off_on"
manual_require_sudo

printf "=== Manual Test 03: Internal Screen Idle Off & On ===\n"
printf "What this test checks:\n"
printf "  1. Unplug HDMI so only the internal DSI-2 screen is active.\n"
printf "  2. Start the 120s safety timer, run idle-off, wait 5s, idle-on.\n"
printf "  3. Confirm DSI-2 wakes up cleanly with zero notifications.\n"
printf "  4. Type the 4-digit PIN to cancel the safety reboot.\n\n"
manual_wait_enter "Step 1: Confirm HDMI cable is unplugged"

printf "\n--- Current Displays ---\n"
manual_show_displays
manual_wait_enter "Step 2: Confirm only DSI-2 is ON, then run idle-off/on"

manual_start_watchdog
printf "\n[RUNNING] Turning internal screen OFF for 5 seconds...\n"
"$USM_CLI" idle-off
sleep 5
printf "[RUNNING] Waking internal screen...\n"
"$USM_CLI" idle-on

manual_wait_pin_cancel "Confirm the internal DSI-2 screen is back ON."

printf "\n--- Recent USM Logs ---\n"
log_file="$HOME/.local/state/usm/logs/usm_log_$(date +%y%m%d).log"
if [[ -f "$log_file" ]]; then
  tail -n 15 "$log_file"
fi
printf "\n[DONE] Manual Test 03 finished.\n"
