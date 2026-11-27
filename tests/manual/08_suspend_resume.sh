#!/bin/bash
# Manual Test 08: Power Key off -> systemctl suspend -> resume (auto-SKIP if
# kernel does not support S3 suspend, e.g. Raspberry Pi 5 / CM5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "08_suspend_resume"

printf "=== Manual Test 08: Power Key Off -> Suspend -> Resume ===\n"
if [[ ! -r /sys/power/state ]] || ! grep -qw "mem" /sys/power/state; then
  printf "[SKIP] Kernel does not support S3 suspend (mem) on this device.\n"
  printf "       Suspend/resume lock recovery is covered by sandbox test T8.\n"
  exit 0
fi

manual_require_sudo
printf "What this test checks:\n"
printf "  1. Start 120s safety timer and 5s countdown to suspend.\n"
printf "  2. Press Power Key right away to turn the screen OFF.\n"
printf "  3. After 5s, system suspends. Press a key to wake.\n"
printf "  4. Confirm screen wakes and swayidle is restored.\n\n"
manual_wait_enter "Step 1: Ready to start 5s countdown"

manual_start_watchdog
printf "\n[COUNTDOWN 5s] Press Power Key NOW! Suspending in 5 seconds...\n"
sleep 5
systemctl suspend

manual_wait_pin_cancel \
  "System resumed. Confirm screen is ON, then type PIN to cancel reboot."

printf "\n--- Swayidle After Resume ---\n"
pgrep -a swayidle || printf "(swayidle is not running)\n"
printf "\n[DONE] Manual Test 08 finished.\n"
