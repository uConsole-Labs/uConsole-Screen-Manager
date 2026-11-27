#!/bin/bash
# Manual Test 07: Internal Power Key off -> plug HDMI directly -> restore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "07_int_off_plug_hdmi"
manual_require_sudo

printf "=== Manual Test 07: Internal Off -> Plug HDMI Directly ===\n"
printf "What this test checks:\n"
printf "  1. Unplug HDMI so only internal DSI-2 is ON.\n"
printf "  2. Start the 120s safety timer.\n"
printf "  3. Press Power Key once (internal DSI-2 turns OFF).\n"
printf "  4. Do NOT press Power Key again; plug in the HDMI cable.\n"
printf "  5. Confirm HDMI turns ON automatically and swayidle is restored.\n\n"
manual_wait_enter "Step 1: Confirm HDMI cable is unplugged"

printf "\n--- Current Displays ---\n"
manual_show_displays
manual_wait_enter "Step 2: Confirm only DSI-2 is ON, then start safety timer"

manual_start_watchdog
manual_wait_pin_cancel \
  "Press Power Key (DSI-2 OFF), then plug HDMI cable directly."

printf "\n--- Final Displays & Swayidle ---\n"
manual_show_displays
pgrep -a swayidle || printf "(swayidle is not running)\n"
printf "\n[DONE] Manual Test 07 finished.\n"
