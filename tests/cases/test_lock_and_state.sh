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

_wait_monitor_ready() {
  local i=0
  while (( i < 40 )); do
    if compgen -G "$USM_RUN_DIR_OVERRIDE/monitor_*.fifo" >/dev/null; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# 2. _restart_swayidle_on_hdmi_change clears int lock on live HDMI hotplug.
sandbox_init "hw_dsi_only.env"
sandbox_set_conf "USM_HDMI_DISABLE_SCREEN_OFF" "true"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:0.8
UDEV  [1.0] change   /devices/drm/card2 (drm)
EOF
printf "SLEEP:1.0\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
bash "$USM_CLI" idle-off >/dev/null
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "int lock active before live HDMI hotplug"
sandbox_set_drm "HDMI-A-1" "connected" 256
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "true"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_MODES" "2560x1440"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_PREFERRED" "2560x1440"
wait "$mon_pid" || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "int lock cleared on live HDMI hotplug"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "HDMI enabled after live hotplug from int idle-off"
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
assert_file_not_contains "$log_file" "Screen mode matches" \
  "Failed startup switch did not hit startup skip branch"
sandbox_cleanup

assert_summary "test_lock_and_state"
