#!/bin/bash
# Manual Test 02: Two full HDMI hotplug cycles (unplug -> DSI-2 -> replug).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "02_hdmi_hotplug_cycles"
manual_require_sudo

printf "=== Manual Test 02: 2x HDMI Hotplug Cycles ===\n"
printf "What this test checks:\n"
printf "  1. Make sure the external HDMI screen is ON.\n"
printf "  2. Start the 120s safety reboot timer.\n"
printf "  3. Repeat TWICE:\n"
printf "     - Unplug HDMI -> wait for internal DSI-2 to turn ON.\n"
printf "     - Plug HDMI back in -> wait (~5s) for HDMI to turn ON.\n"
printf "  4. Type the 4-digit PIN to cancel the safety reboot.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is connected and ON"

printf "\n--- Current Displays ---\n"
manual_show_displays
manual_wait_enter "Step 2: Start 120s safety timer and begin 2x hotplug"

manual_start_watchdog
manual_wait_pin_cancel \
  "Do 2 full cycles: Unplug HDMI (DSI-2 ON) -> Replug HDMI (HDMI ON)."

printf "\n--- Final Displays ---\n"
manual_show_displays
printf "\n[DONE] Manual Test 02 finished.\n"
