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

# 4. Boot with HDMI already active (silent boot: no wlr-randr switch/notify).
sandbox_init "hw_hp_e27u_g4.env"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
log_file=$(find "$USM_LOG_DIR" -name "usm_log_*.log" | head -n 1)
assert_file_contains "$log_file" "Screen mode matches 'ext' at start" \
  "Boot with HDMI hit idempotent silent-boot fast-bypass"
assert_file_not_contains "$USM_MOCK_LOG" "wlr-randr --output" \
  "Silent boot did not invoke wlr-randr output mutation"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "Silent boot emitted zero notifications"
assert_file_contains "$USM_MOCK_STATE_DIR/audio.env" "HDMI_AUDIO_PROFILE=off" \
  "Boot async audio init kept HDMI audio off"
sandbox_cleanup

# 5. Boot with both DSI-2 and HDMI-A-1 active in single mode turns off DSI-2.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "yes"
printf "0\n" > "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "Boot single mode kept HDMI-A-1 enabled"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="no"' \
  "Boot single mode disabled DSI-2"
assert_eq "4" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "Boot single mode powered off DSI backlight"
sandbox_cleanup

# 6. Boot early before compositor ready: wait_for_compositor blocks then runs.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_mock_var "wlr.env" "WLR_CONNECT_FAIL" "true"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
sleep 0.4
sandbox_set_mock_var "wlr.env" "WLR_CONNECT_FAIL" "false"
wait "$mon_pid" || true
log_file=$(find "$USM_LOG_DIR" -name "usm_log_*.log" | head -n 1)
assert_file_contains "$log_file" "Wayland compositor is ready." \
  "Boot waited until Wayland compositor became ready"
assert_file_contains "$log_file" "Screen mode matches 'ext' at start" \
  "Boot completed startup reconciliation after compositor ready"
sandbox_cleanup

# 7. Monitor startup syncs USM-managed swayidle when DISABLE_SCREEN_OFF=false.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_DISABLE_SWAYIDLE" "false"
sandbox_set_conf "USM_HDMI_DISABLE_SCREEN_OFF" "false"
sandbox_set_conf "USM_IDLE_SCREEN_OFF_TIMEOUT" "30"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_contains "$USM_MOCK_LOG" "pkill -x swayidle" \
  "Monitor startup stopped stale USM swayidle"
assert_file_contains "$USM_MOCK_LOG" "systemd-run.*timeout 30" \
  "Monitor startup restarted USM swayidle with new 30s timeout"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "Monitor startup left USM swayidle running"
sandbox_cleanup

# 8. Monitor startup never touches custom non-USM swayidle autostart config.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_DISABLE_SWAYIDLE" "false"
sandbox_set_conf "USM_HDMI_DISABLE_SCREEN_OFF" "false"
printf "swayidle -w timeout 999 'custom' &\n" \
  > "$HOME/.config/labwc/autostart"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_not_contains "$USM_MOCK_LOG" "pkill -x swayidle" \
  "Monitor startup did not kill custom swayidle"
assert_file_not_contains "$USM_MOCK_LOG" "systemd-run.*swayidle" \
  "Monitor startup did not restart custom swayidle"
sandbox_cleanup

assert_summary "test_lock_and_state"
