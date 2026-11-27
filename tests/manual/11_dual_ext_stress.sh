#!/bin/bash
# Manual Test 11: 2x screen-dual <-> screen-ext stress + .xsession-errors check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/manual/lib_watchdog.sh
source "$SCRIPT_DIR/lib_watchdog.sh"

manual_init_log "11_dual_ext_stress"
manual_require_sudo

XERR="$HOME/.xsession-errors"
XERR_START=0
if [[ -f "$XERR" ]]; then
  XERR_START=$(wc -l < "$XERR")
fi

printf "=== Manual Test 11: 2x Dual <-> External Stress Test ===\n"
printf "What this test checks:\n"
printf "  1. Start the 120s safety timer.\n"
printf "  2. Run 2 full rounds of screen-dual -> screen-ext.\n"
printf "  3. Confirm zero libliftoff EINVAL / Swapchain / EPERM errors in\n"
printf "     ~/.xsession-errors.\n\n"
manual_wait_enter "Step 1: Confirm HDMI is connected and ON"

manual_start_watchdog
for round in 1 2; do
  printf "\n--- Round %d: screen-dual ---\n" "$round"
  "$USM_CLI" screen-dual
  manual_show_displays
  sleep 2

  printf "\n--- Round %d: screen-ext ---\n" "$round"
  "$USM_CLI" screen-ext
  manual_show_displays
  sleep 2
done

manual_wait_pin_cancel "Confirm external HDMI is ON at native resolution."

printf "\n--- Checking ~/.xsession-errors for DRM / Swapchain Errors ---\n"
if [[ -f "$XERR" ]]; then
  drm_hits=$(
    tail -n +"$((XERR_START + 1))" "$XERR" \
      | grep -E "drmCrtcGetSequence|Swapchain|liftoff_output_apply" || true
  )
  if [[ -z "$drm_hits" ]]; then
    printf "[PASS] Zero libliftoff / Swapchain errors found.\n"
  else
    printf "[FAIL] Found DRM / Swapchain errors:\n%s\n" "$drm_hits"
    exit 1
  fi
fi
printf "\n[DONE] Manual Test 11 finished.\n"
