#!/bin/bash
# Manual Test 01: Check USM service, kanshi isolation, swayidle, and displays.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "01_service_and_swayidle_check"

printf "=== Manual Test 01: Service & Swayidle Preflight Check ===\n"
printf "What this test checks (read-only, no reboot timer needed):\n"
printf "  1. usm.service is active (running).\n"
printf "  2. Background kanshi is stopped.\n"
printf "  3. swayidle arguments match your usm.conf settings.\n"
printf "  4. Current wlr-randr outputs look normal.\n\n"

printf "--- 1. USM Status ---\n"
"$USM_CLI" status || true

printf "\n--- 2. Running swayidle Process ---\n"
pgrep -a swayidle || printf "(swayidle is not running)\n"

printf "\n--- 3. Active Displays ---\n"
manual_show_displays

printf "\n[DONE] Manual Test 01 finished.\n"
