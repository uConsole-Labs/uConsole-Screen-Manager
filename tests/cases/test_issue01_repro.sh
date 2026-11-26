#!/bin/bash
# Test ISSUE_01 reproduction & USM_HDMI_DISABLE_SCREEN_OFF protection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

# 1. idle-off is silent and writes ext lock; HPD drop -> Enabled:no is
#    recovered by Plan 2 idle-on (re-enables HDMI-A-1 silently).
sandbox_init "hw_hp_e27u_g4.env"
bash "$USM_CLI" idle-off >/dev/null
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "idle-off created lock"
assert_eq "ext" "$(cat "$USM_RUN_DIR_OVERRIDE/idle_off.lock")" \
  "idle-off recorded ext state"
assert_file_contains "$USM_MOCK_LOG" "wlopm --off HDMI-A-1" \
  "idle-off invoked targeted wlopm --off"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "idle-off remained completely silent"

# Simulate HP E27u G4 HPD drop & bounce -> HDMI-A-1 rebuilt as Enabled: no.
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
bash "$USM_CLI" idle-on >/dev/null
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "idle-on removed lock"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "idle-on re-enabled Enabled:no HDMI (ISSUE_01 fixed by Plan 2)"
sandbox_cleanup

# 2. USM_HDMI_DISABLE_SCREEN_OFF="true" omits Stage 2 idle-off from swayidle.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_DISABLE_SCREEN_OFF" "true"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
sandbox_set_conf "USM_IDLE_SCREEN_OFF_TIMEOUT" "1200"

bash "$USM_CLI" swayidle-enable >/dev/null
assert_file_contains "$USM_MOCK_LOG" "systemd-run.*cmatrix" \
  "Stage 1 screensaver preserved while HDMI connected"
assert_file_not_contains "$USM_MOCK_LOG" "systemd-run.*idle-off" \
  "Stage 2 idle-off omitted while HDMI connected"
sandbox_cleanup

assert_summary "test_issue01_repro"
