#!/bin/bash
# Manual Test 04 (Optional): External HDMI 30s swayidle auto screen-off & wake.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "04_ext_idle_auto_off"
manual_require_sudo

printf "=== Manual Test 04 (Optional): External 15s Auto Screen Off ===\n"
printf "Note: Some monitors wake themselves during DPMS unless\n"
printf "      Auto-Switch Input is turned OFF in the monitor OSD.\n\n"
printf "What this test checks (never modifies ~/.config/usm/usm.conf):\n"
printf "  1. Create a temporary /tmp config with HDMI idle=enable, 15s.\n"
printf "  2. Start the 120s safety timer and run temporary swayidle.\n"
printf "  3. Do NOT touch keyboard/mouse during the 15s countdown.\n"
printf "  4. After screen turns OFF, wake it and type the 4-digit PIN.\n\n"
manual_wait_enter "Step 1: Ready to start (HDMI connected)"

manual_make_temp_conf
if grep -q '^USM_HDMI_IDLE_MODE=' "$TEMP_CONF"; then
  sed -i 's/^USM_HDMI_IDLE_MODE=.*/USM_HDMI_IDLE_MODE="enable"/' \
    "$TEMP_CONF"
else
  printf 'USM_HDMI_IDLE_MODE="enable"\n' >> "$TEMP_CONF"
fi
sed -i 's/^USM_IDLE_SCREENSAVER_TIMEOUT=.*/USM_IDLE_SCREENSAVER_TIMEOUT="0"/' \
  "$TEMP_CONF"
sed -i 's/^USM_IDLE_SCREEN_OFF_TIMEOUT=.*/USM_IDLE_SCREEN_OFF_TIMEOUT="15"/' \
  "$TEMP_CONF"

# shellcheck disable=SC2034
RESTORE_SWAYIDLE=true
manual_start_watchdog
"$USM_CLI" swayidle-disable
USM_CONF_FILE="$TEMP_CONF" "$USM_CLI" swayidle-enable
sleep 1
printf "\n--- Temporary swayidle ---\n"
pgrep -a swayidle || printf "(swayidle is not running)\n"

manual_countdown 18 \
  "DO NOT touch keyboard or mouse! Waiting for 15s auto screen-off"

manual_wait_pin_cancel \
  "Move mouse or press a key to wake screen, then type PIN to cancel."

printf "\n[DONE] Manual Test 04 finished.\n"
