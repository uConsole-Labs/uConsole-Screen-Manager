#!/bin/bash
# Manual Test 10: Dual mode switch + Power Key off/on + restore single mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "10_dual_mode_power_key"
manual_require_sudo

printf "=== Manual Test 10: Dual Mode & Screen-Switch ===\n"
printf "What this test checks (never modifies ~/.config/usm/usm.conf):\n"
printf "  1. Create a temporary /tmp config with USM_MODE=\"dual\".\n"
printf "  2. Start the 120s safety timer and switch to dual mode.\n"
printf "  3. Run screen-switch OFF (both OFF) -> wait 3s -> ON (both ON).\n"
printf "  4. Switch back to external-only and type PIN to cancel reboot.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is connected and ON"

manual_make_temp_conf
sed -i 's/^USM_MODE=.*/USM_MODE="dual"/' "$TEMP_CONF"

manual_start_watchdog
printf "\n--- Switching to dual mode ---\n"
USM_CONF_FILE="$TEMP_CONF" "$USM_CLI" screen-dual
manual_show_displays

printf "\n--- Turning both screens OFF via screen-switch (3s) ---\n"
USM_CONF_FILE="$TEMP_CONF" "$USM_CLI" screen-switch
sleep 3

printf "\n--- Waking both screens via screen-switch ---\n"
USM_CONF_FILE="$TEMP_CONF" "$USM_CLI" screen-switch
manual_show_displays
printf "wlopm:\n"
wlopm || true

printf "\n--- Switching back to external-only ---\n"
"$USM_CLI" screen-ext
manual_show_displays

manual_wait_pin_cancel \
  "Confirm external HDMI is ON at native resolution, then type PIN."
printf "\n[DONE] Manual Test 10 finished.\n"
