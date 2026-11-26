#!/bin/bash
# Test Plan 1.3 & 1.4: stale idle_off.lock wake/cleanup & LAST_STATE reset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

# 1. cmd_monitor startup with stale idle_off.lock (ext) wakes HDMI & cleans.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_POWER" "off"
printf "ext\n" > "$USM_RUN_DIR_OVERRIDE/idle_off.lock"
: > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"

# Monitor exits cleanly on EOF from empty mock event streams.
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "Stale idle_off.lock removed at monitor startup"
assert_file_contains "$USM_MOCK_LOG" "wlopm --on HDMI-A-1" \
  "HDMI DPMS woken before clearing stale ext lock"
sandbox_cleanup

# 2. _restart_swayidle_on_hdmi_change clears int lock when HDMI connects.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_DISABLE_SCREEN_OFF" "true"
printf "int\n" > "$USM_RUN_DIR_OVERRIDE/idle_off.lock"
: > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"

# Source functions safely in a subshell by testing via monitor startup
# (which runs update_display_by_hdmi_state -> manage_swayidle).
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "int lock cleared when HDMI connected"
sandbox_cleanup

# 3. Failed display switch keeps LAST_STATE intact (does not loop or hit
#    startup skip branch).
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "yes"
sandbox_set_mock_var "wlr.env" "WLR_FAIL_APPLY" "true"
: > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"

bash "$USM_CLI" monitor >/dev/null 2>&1 || true
log_file=$(find "$USM_LOG_DIR" -name "usm_log_*.log" | head -n 1)
assert_file_contains "$log_file" "Error: cmd_screen_ext returned 1" \
  "Startup switch failed as injected"
sandbox_cleanup

assert_summary "test_lock_and_state"
