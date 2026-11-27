#!/bin/bash
# Manual Test 06: External Power Key off/on pauses and restores swayidle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "06_ext_power_key_swayidle"
manual_require_sudo

printf "=== Manual Test 06: External Power Key & Swayidle Pause ===\n"
printf "What this test checks:\n"
printf "  1. Confirm external HDMI screen is ON.\n"
printf "  2. Start the 120s safety timer and a 3s background check.\n"
printf "  3. Press Power Key right away to turn HDMI OFF, wait ~5s,\n"
printf "     then press Power Key again to wake HDMI.\n"
printf "  4. Confirm swayidle was PAUSED while off and RESTORED after wake.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is ON"

probe_file="/tmp/usm_manual_06_probe.$$"
manual_start_watchdog
(
  sleep 3
  if pgrep -a swayidle > "$probe_file" 2>&1; then
    true
  else
    printf "PAUSED\n" > "$probe_file"
  fi
) &
probe_pid=$!

manual_countdown 5 \
  "Press Power Key NOW (HDMI OFF) and keep it OFF during countdown"
wait "$probe_pid" || true

manual_wait_pin_cancel \
  "Press Power Key again to wake HDMI, then type PIN to cancel reboot."

printf "\n--- Swayidle State While Screen Was Off (expect PAUSED) ---\n"
cat "$probe_file" 2>/dev/null || printf "(probe file missing)\n"
rm -f "$probe_file"

printf "\n--- Swayidle State After Wake ---\n"
pgrep -a swayidle || printf "(swayidle is not running)\n"
printf "\n[DONE] Manual Test 06 finished.\n"
