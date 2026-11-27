#!/bin/bash
# TDD suite for Plan 2 (external screen-off, Power Key, swayidle, ext wake).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

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

# T1: Ext idle-off -> HPD drop/bounce (Enabled: no) -> live daemon ignores,
#     idle-on silently re-enables HDMI-A-1.
sandbox_init "hw_hp_e27u_g4.env"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:0.8
UDEV  [1.0] change   /devices/drm/card2 (drm)
EOF
printf "SLEEP:1.0\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
bash "$USM_CLI" idle-off >/dev/null
: > "$USM_MOCK_LOG"
sandbox_set_drm "HDMI-A-1" "disconnected" 0
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
wait "$mon_pid" || true
assert_file_not_contains "$USM_MOCK_LOG" "wlr-randr --output DSI-2 --on" \
  "T1: daemon ignores HPD disconnect during ext idle-off"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T1: idle_off.lock preserved across HPD disconnect"
# HPD bounces back as Enabled: no -> idle-on must re-enable silently.
sandbox_set_drm "HDMI-A-1" "connected" 256
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "T1: idle-on re-enabled HDMI-A-1 from Enabled:no"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "T1: idle-on remained silent"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T1: idle_off.lock cleared after wake"
sandbox_cleanup

# T2: Ext idle-off -> real physical HDMI unplug (B2) -> idle-on wakes DSI-2
#     silently and marks state_dirty.
sandbox_init "hw_hp_e27u_g4.env"
bash "$USM_CLI" idle-off >/dev/null
sandbox_set_drm "HDMI-A-1" "disconnected" 0
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "false"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T2: idle-on recovered DSI-2 after real HDMI unplug"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/state_dirty" \
  "T2: state_dirty set for daemon resync"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "T2: idle-on B2 recovery remained silent"
sandbox_cleanup

# T3: Ext Power Key off pauses swayidle; 2nd Power Key wakes & restores.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
rc=0
bash "$USM_CLI" screen-switch >/dev/null || rc=$?
assert_eq "0" "$rc" "T3: ext Power Key off returns 0"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T3: ext Power Key created idle_off.lock"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T3: ext Power Key created manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T3: swayidle stopped during manual ext off"
assert_file_not_contains "$USM_MOCK_LOG" "Screen-switch disabled" \
  "T3: no disabled notification on ext Power Key"
bash "$USM_CLI" screen-switch >/dev/null
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T3: 2nd Power Key cleared idle_off.lock"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T3: 2nd Power Key cleared manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T3: swayidle restored on Power Key wake"
sandbox_cleanup

# T4: Int Power Key off pauses swayidle; live HDMI plug clears manual_off.
sandbox_init "hw_dsi_only.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "enable"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:0.8
UDEV  [1.0] change   /devices/drm/card2 (drm)
EOF
printf "SLEEP:1.0\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
bash "$USM_CLI" screen-switch >/dev/null
assert_file_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T4: int Power Key created manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T4: swayidle stopped during manual int off"
# Simulate live HDMI hotplug while monitor is running.
sandbox_set_drm "HDMI-A-1" "connected" 256
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "true"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_MODES" "2560x1440"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_PREFERRED" "2560x1440"
wait "$mon_pid" || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T4: manual_off.lock cleared after HDMI switch"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T4: swayidle restored after HDMI switch"
sandbox_cleanup

# T5: Ext Power Key off rolls back manual_off.lock & swayidle if wlopm fails.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
sandbox_set_mock_var "wlopm.env" "WLOPM_FAIL_OFF" "true"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
rc=0
bash "$USM_CLI" screen-switch >/dev/null || rc=$?
assert_eq "1" "$rc" "T5: ext Power Key returns 1 when wlopm fails"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T5: manual_off.lock rolled back"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T5: idle_off.lock rolled back"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T5: swayidle restored on rollback"
sandbox_cleanup

# T6: External app wakes HDMI (wlopm on) -> 1 Power Key press turns it off.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
printf "ext\n" > "$USM_RUN_DIR_OVERRIDE/idle_off.lock"
touch "$USM_RUN_DIR_OVERRIDE/manual_off.lock"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_POWER" "on"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" screen-switch >/dev/null || true
assert_file_contains "$USM_MOCK_LOG" "wlopm --off HDMI-A-1" \
  "T6: single Power Key press turned off externally-woken HDMI"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_POWER="off"' \
  "T6: HDMI DPMS is now off"
sandbox_cleanup

# T7: External app wakes DSI-2 during manual_off -> live udev clears lock.
sandbox_init "hw_dsi_only.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:0.8
UDEV  [1.0] change   /devices/drm/card1 (drm)
EOF
printf "SLEEP:1.0\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
touch "$USM_RUN_DIR_OVERRIDE/manual_off.lock"
printf "SWAYIDLE_RUNNING=0\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "yes"
wait "$mon_pid" || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T7: stale manual_off.lock cleared after external DSI wake"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T7: swayidle restored after external DSI wake"
sandbox_cleanup

# T8: Ext Power Key off -> live suspend/resume clears locks & restores.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "enable"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
cat > "$USM_MOCK_STATE_DIR/dbus.events" <<'EOF'
SLEEP:0.8
boolean true
SLEEP:0.2
boolean false
EOF
printf "SLEEP:1.2\n" > "$USM_MOCK_STATE_DIR/udev.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
bash "$USM_CLI" screen-switch >/dev/null
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T8: pre-suspend idle_off.lock active"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T8: pre-suspend manual_off.lock active"
wait "$mon_pid" || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T8: resume cleared idle_off.lock"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T8: resume cleared manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T8: resume restored swayidle"
sandbox_cleanup

assert_summary "test_plan2_ext_screen_off"
