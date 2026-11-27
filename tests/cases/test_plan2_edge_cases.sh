#!/bin/bash
# Phase 2.5 edge-case sandbox tests (T9-T19 from ISSUE_01_04.md §D.5).

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

_setup_dual_active() {
  sandbox_init "hw_hp_e27u_g4.env"
  sandbox_set_conf "USM_MODE" "dual"
  sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "yes"
  sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "yes"
  printf "0\n" > "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power"
}

# T9: dual mode idle-off sleeps both; HDMI Enabled:no -> idle-on recovers both.
_setup_dual_active
bash "$USM_CLI" idle-off >/dev/null
assert_eq "dual" "$(cat "$USM_RUN_DIR_OVERRIDE/idle_off.lock")" \
  "T9: dual idle-off recorded dual lock"
assert_file_contains "$USM_MOCK_LOG" "wlopm --off HDMI-A-1" \
  "T9: dual idle-off turned off HDMI via wlopm"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_POWER="off"' \
  "T9: dual idle-off kept HDMI DPMS off after DSI-2 --off"
assert_eq "4" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "T9: dual idle-off powered off DSI backlight"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "T9: dual idle-on re-enabled HDMI from Enabled:no"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T9: dual idle-on re-enabled DSI-2"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "T9: dual idle-on recovery remained silent"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T9: dual idle-on cleared idle_off.lock"
sandbox_cleanup

# T10: dual mode Power Key off pauses swayidle; 2nd Power Key restores both.
_setup_dual_active
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
bash "$USM_CLI" screen-switch >/dev/null
assert_eq "dual" "$(cat "$USM_RUN_DIR_OVERRIDE/idle_off.lock")" \
  "T10: dual Power Key created dual idle_off.lock"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T10: dual Power Key created manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T10: dual Power Key paused swayidle"
bash "$USM_CLI" screen-switch >/dev/null
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T10: 2nd Power Key cleared idle_off.lock"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T10: 2nd Power Key cleared manual_off.lock"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "T10: 2nd Power Key restored HDMI"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T10: 2nd Power Key restored DSI-2"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T10: 2nd Power Key restored swayidle"
sandbox_cleanup

# T11: dual mode idle-off -> physical HDMI unplug -> idle-on recovers DSI-2.
_setup_dual_active
bash "$USM_CLI" idle-off >/dev/null
sandbox_set_drm "HDMI-A-1" "disconnected" 0
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "false"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T11: dual idle-on recovered DSI-2 after HDMI unplug"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/state_dirty" \
  "T11: dual idle-on marked state_dirty"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T11: dual idle-on cleared idle_off.lock"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "T11: dual idle-on recovery remained silent"
sandbox_cleanup

# T12: USM_HDMI_IDLE_MODE="disable" never starts swayidle on rollback/wake.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "disable"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
sandbox_set_mock_var "wlopm.env" "WLOPM_FAIL_OFF" "true"
printf "SWAYIDLE_RUNNING=0\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
rc=0
bash "$USM_CLI" screen-switch >/dev/null || rc=$?
assert_eq "1" "$rc" "T12: failed ext Power Key returns 1"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T12: rollback did not start swayidle when HDMI disables it"
sandbox_set_mock_var "wlopm.env" "WLOPM_FAIL_OFF" "false"
bash "$USM_CLI" screen-switch >/dev/null
bash "$USM_CLI" screen-switch >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T12: wake did not start swayidle when HDMI disables it"
sandbox_cleanup

# T13: Default conf (screensaver=0, HDMI_IDLE_MODE=no-screen-off) keeps
#      swayidle stopped on external Power Key wake.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
printf "SWAYIDLE_RUNNING=0\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
bash "$USM_CLI" screen-switch >/dev/null
bash "$USM_CLI" screen-switch >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "T13: default conf keeps swayidle stopped on HDMI wake"
sandbox_cleanup

# T14: idle-on preserves idle_off.lock and returns 1 when wlr-randr fails.
sandbox_init "hw_hp_e27u_g4.env"
bash "$USM_CLI" idle-off >/dev/null
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
sandbox_set_mock_var "wlr.env" "WLR_FAIL_APPLY" "true"
rc=0
bash "$USM_CLI" idle-on >/dev/null || rc=$?
assert_eq "1" "$rc" "T14: idle-on returns 1 on WLR_FAIL_APPLY"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T14: idle_off.lock preserved on WLR_FAIL_APPLY"
sandbox_set_mock_var "wlr.env" "WLR_FAIL_APPLY" "false"
sandbox_set_mock_var "wlr.env" "WLR_CANCEL_APPLY" "true"
rc=0
bash "$USM_CLI" idle-on >/dev/null || rc=$?
assert_eq "1" "$rc" "T14: idle-on returns 1 on WLR_CANCEL_APPLY"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T14: idle_off.lock preserved on WLR_CANCEL_APPLY"
sandbox_cleanup

# T15: Missing wlopm binary skips ext idle-off safely & rolls back Power Key.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" "cmatrix &"
printf "SWAYIDLE_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
rm -f "$SANDBOX_DIR/bin/wlopm"
no_wlopm_bin="$SANDBOX_DIR/no_wlopm_bin"
mkdir -p "$no_wlopm_bin"
for cmd in awk basename bash cat cut date dirname find flock grep head id \
           mkdir mkfifo mktemp mv nohup readlink rm sed seq sh sleep sort \
           stdbuf stat tee timeout touch tr wc; do
  cmd_path="$(command -v "$cmd" || true)"
  [[ -n "$cmd_path" ]] && ln -sf "$cmd_path" "$no_wlopm_bin/$cmd"
done
rc=0
PATH="$SANDBOX_DIR/bin:$no_wlopm_bin" bash "$USM_CLI" screen-switch \
  >/dev/null || rc=$?
assert_eq "1" "$rc" "T15: ext Power Key returns 1 when wlopm missing"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/manual_off.lock" \
  "T15: manual_off.lock rolled back when wlopm missing"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T15: idle_off.lock absent when wlopm missing"
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=1" \
  "T15: swayidle restored when wlopm missing"
sandbox_cleanup

# T16: idle-on -> cmd_screen_ext --silent fallback to cmd_screen_int is silent.
sandbox_init "hw_hp_e27u_g4.env"
printf "ext\n" > "$USM_RUN_DIR_OVERRIDE/idle_off.lock"
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "false"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "no"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T16: cmd_screen_ext --silent fallback enabled DSI-2"
assert_file_not_contains "$USM_MOCK_LOG" "notify-send" \
  "T16: fallback forwarded --silent with zero notifications"
sandbox_cleanup

# T17: wlopm wildcard '*' guardrail triggers on '*' and never called by USM.
sandbox_init "hw_hp_e27u_g4.env"
rc=0
wlopm --off '*' >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "T17: mock wlopm rejects wildcard '*'"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-off >/dev/null
bash "$USM_CLI" idle-on >/dev/null
bash "$USM_CLI" screen-switch >/dev/null
bash "$USM_CLI" screen-switch >/dev/null
assert_file_not_contains "$USM_MOCK_LOG" "wlopm .* \*" \
  "T17: USM never passes wildcard '*' to wlopm"
sandbox_cleanup

# T18: state_dirty full round-trip: unplug during idle -> idle-on sets
#      state_dirty -> live HDMI replug switches back despite old LAST_STATE.
sandbox_init "hw_hp_e27u_g4.env"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:3.5
UDEV  [2.0] change   /devices/drm/card2 (drm)
EOF
printf "SLEEP:3.8\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
bash "$USM_CLI" idle-off >/dev/null
sandbox_set_drm "HDMI-A-1" "disconnected" 0
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "false"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "no"
bash "$USM_CLI" idle-on >/dev/null
assert_file_exists "$USM_RUN_DIR_OVERRIDE/state_dirty" \
  "T18: idle-on marked state_dirty after unplug"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T18: DSI-2 active before replug"
# Replug HDMI before queued udev event fires.
sandbox_set_drm "HDMI-A-1" "connected" 256
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "true"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_MODES" "2560x1440"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_PREFERRED" "2560x1440"
wait "$mon_pid" || true
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/state_dirty" \
  "T18: live monitor cleared state_dirty on replug"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "T18: live monitor switched back to HDMI despite old LAST_STATE"
sandbox_cleanup

# T19: flock serializes concurrent display mutations on usm_display.lock.
sandbox_init "hw_hp_e27u_g4.env"
lock_file="$USM_RUN_DIR_OVERRIDE/usm_display.lock"
order_log="$SANDBOX_DIR/flock_order.log"
(
  exec 9>"$lock_file"
  flock 9
  sleep 0.4
  printf "holder_released\n" >> "$order_log"
) &
holder_pid=$!
sleep 0.05
(
  bash "$USM_CLI" screen-switch >/dev/null
  printf "switch_done\n" >> "$order_log"
) &
switch_pid=$!
wait "$holder_pid" "$switch_pid"
assert_order "$order_log" "holder_released" "switch_done" \
  "T19: screen-switch waited for usm_display.lock release"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_POWER="off"' \
  "T19: serialized screen-switch completed cleanly"
sandbox_cleanup

# T20: Internal DSI-2 idle-on succeeds on 1st try without DRM poisoning.
sandbox_init "hw_dsi_only.env"
bash "$USM_CLI" idle-off >/dev/null
assert_eq "int" "$(cat "$USM_RUN_DIR_OVERRIDE/idle_off.lock")" \
  "T20: internal idle-off wrote int lock"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" idle-on >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T20: idle-on enabled DSI-2 cleanly"
assert_file_not_exists "$USM_MOCK_STATE_DIR/dsi_drm_poisoned" \
  "T20: idle-on never poisoned DSI DRM"
assert_file_not_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T20: idle-on cleared idle_off.lock"
dsi_tries=$(grep -c "wlr-randr --output DSI-2 --on" "$USM_MOCK_LOG" || true)
assert_eq "1" "$dsi_tries" \
  "T20: DSI-2 enable succeeded on 1st attempt (zero failed commits)"
sandbox_cleanup

# T21: exec_wlr_randr retries up to 3 times on persistent failure & keeps lock.
sandbox_init "hw_dsi_only.env"
bash "$USM_CLI" idle-off >/dev/null
sandbox_set_mock_var "wlr.env" "WLR_FAIL_APPLY" "true"
: > "$USM_MOCK_LOG"
rc=0
bash "$USM_CLI" idle-on >/dev/null || rc=$?
assert_eq "1" "$rc" "T21: idle-on returns 1 after 3 failed attempts"
assert_file_exists "$USM_RUN_DIR_OVERRIDE/idle_off.lock" \
  "T21: idle_off.lock preserved after 3 failed attempts"
dsi_tries=$(grep -c "wlr-randr --output DSI-2 --on" "$USM_MOCK_LOG" || true)
assert_eq "3" "$dsi_tries" \
  "T21: exec_wlr_randr attempted exactly 3 times"
sandbox_cleanup

# T22: cmd_screen_dual from bl_power=4 succeeds on 1st try for both stages.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_EXT_RES" ""
: > "$USM_MOCK_LOG"
bash "$USM_CLI" screen-dual >/dev/null
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="yes"' \
  "T22: dual mode enabled DSI-2 from bl_power=4"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" \
  'WLR_HDMI_CURRENT_MODE="2560x1440"' \
  "T22: dual mode ended at preferred 2560x1440"
dual_calls=$(grep -c "wlr-randr --output DSI-2 --on" "$USM_MOCK_LOG" || true)
assert_eq "2" "$dual_calls" \
  "T22: Stage 1 + Stage 2 each succeeded on 1st attempt (2 total calls)"
sandbox_cleanup

assert_summary "test_plan2_edge_cases"
