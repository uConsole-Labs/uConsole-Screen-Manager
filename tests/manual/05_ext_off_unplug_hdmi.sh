#!/bin/bash
# Manual Test 05: External Power Key off -> unplug HDMI -> wake DSI-2 -> replug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "05_ext_off_unplug_hdmi"
manual_require_sudo

printf "=== Manual Test 05: Unplug HDMI While Screen Is Off ===\n"
printf "What this test checks:\n"
printf "  1. Confirm external HDMI screen is ON.\n"
printf "  2. Start the 120s safety timer.\n"
printf "  3. Press Power Key once (HDMI turns OFF).\n"
printf "  4. Unplug the HDMI cable.\n"
printf "  5. Press Power Key once (internal DSI-2 turns ON, no blackout).\n"
printf "  6. Plug HDMI back in (switches back to external HDMI).\n"
printf "  7. Type the 4-digit PIN to cancel the safety reboot.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is ON"

printf "\n--- Current Displays ---\n"
manual_show_displays
manual_wait_enter "Step 2: Start 120s safety timer and begin steps 3-6"

manual_start_watchdog
manual_wait_pin_cancel \
  "Power Key OFF -> Unplug HDMI -> Power Key wake DSI-2 -> Replug HDMI."

printf "\n--- Final Displays ---\n"
manual_show_displays
printf "\n[DONE] Manual Test 05 finished.\n"
