#!/bin/bash
# TDD suite for Appendix F: DRM poison guard, kanshi isolation,
# validate_config() fail-closed/warn-only matrix, SIGHUP safety, legacy compat.

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

# 1. DRM poison guardrail: 2x screen-dual <-> screen-ext cycles succeed even
#    when legacy USM_ENABLE_HW_POWER_CONTROL="true" lingers in usm.conf.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_ENABLE_HW_POWER_CONTROL" "true"
printf "5\n" > "$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
bash "$USM_CLI" screen-dual >/dev/null 2>&1
bash "$USM_CLI" screen-ext >/dev/null 2>&1
bash "$USM_CLI" screen-dual >/dev/null 2>&1
bash "$USM_CLI" screen-ext >/dev/null 2>&1
assert_file_not_exists "$USM_MOCK_STATE_DIR/dsi_drm_poisoned" \
  "C1: 2x dual<->ext cycles never poisoned DSI DRM/fb0"
assert_eq "4" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "C1: bl_power ended at 4 (OFF) via driver"
bl_bright="$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
assert_eq "5" "$(cat "$bl_bright")" \
  "C1: user brightness remained untouched (5)"
sandbox_cleanup

# 2. kanshi isolation: cmd_monitor stops kanshi before display reconciliation,
#    handles absent kanshi cleanly, and cmd_status reports kanshi state.
sandbox_init "hw_hp_e27u_g4.env"
printf "KANSHI_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/kanshi.env"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "yes"
printf "SLEEP:0.3\n" > "$USM_MOCK_STATE_DIR/udev.events"
: > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 || true
assert_file_contains "$USM_MOCK_STATE_DIR/kanshi.env" "KANSHI_RUNNING=0" \
  "C2: cmd_monitor stopped running kanshi"
assert_order "$USM_MOCK_LOG" "pkill .*kanshi" "wlr-randr --output" \
  "C2: kanshi stopped before first wlr-randr mutation"

# cmd_status reports kanshi warning when running, stopped when absent.
printf "KANSHI_RUNNING=1\n" > "$USM_MOCK_STATE_DIR/kanshi.env"
st_out=$(bash "$USM_CLI" status 2>&1)
assert_contains "$st_out" "Kanshi: running \(WARNING" \
  "C2: cmd_status warns when kanshi is running"
printf "KANSHI_RUNNING=0\n" > "$USM_MOCK_STATE_DIR/kanshi.env"
st_out=$(bash "$USM_CLI" status 2>&1)
assert_contains "$st_out" "Kanshi: stopped" \
  "C2: cmd_status reports kanshi stopped"
sandbox_cleanup

# 3. validate_config Fail-closed matrix (blocks display/swayidle/monitor cmds,
#    exempts diagnostic/stop cmds without polluting stdout).
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_MODE" "bogus"
rc=0
err=$(bash "$USM_CLI" screen-ext 2>&1 >/dev/null) || rc=$?
assert_eq "1" "$rc" "C3: invalid USM_MODE blocks screen-ext"
assert_contains "$err" "USM_MODE" "C3: error names invalid USM_MODE"

# Diagnostic commands remain usable even with broken config.
rc=0
ver_out=$(bash "$USM_CLI" version 2>"$SANDBOX_DIR/ver.err") || rc=$?
assert_eq "0" "$rc" "C3: version succeeds despite invalid USM_MODE"
assert_contains "$ver_out" "0.0.0-test" \
  "C3: version stdout clean (not polluted by warnings)"
assert_file_contains "$SANDBOX_DIR/ver.err" "USM_MODE" \
  "C3: version emitted config warning to stderr"

# Invalid USM_HDMI_IDLE_MODE & octal timeout ("08") fail-closed.
sandbox_set_conf "USM_MODE" "single"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "invalid"
rc=0
bash "$USM_CLI" swayidle-enable >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "C3: invalid USM_HDMI_IDLE_MODE blocks swayidle-enable"

sandbox_set_conf "USM_HDMI_IDLE_MODE" "no-screen-off"
sandbox_set_conf "USM_IDLE_SCREEN_OFF_TIMEOUT" "08"
rc=0
err=$(bash "$USM_CLI" swayidle-enable 2>&1 >/dev/null) || rc=$?
assert_eq "1" "$rc" "C3: leading-zero timeout '08' blocked (octal guard)"
assert_contains "$err" "USM_IDLE_SCREEN_OFF_TIMEOUT" \
  "C3: error names invalid timeout key"

sandbox_set_conf "USM_IDLE_SCREEN_OFF_TIMEOUT" "600"
sandbox_set_conf "USM_HDMI_AUDIO_DEFAULT_STATE" "loud"
rc=0
bash "$USM_CLI" hdmi-audio-off >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "C3: invalid audio state blocks hdmi-audio-off"

sandbox_set_conf "USM_HDMI_AUDIO_DEFAULT_STATE" "off"
sandbox_set_conf "USM_LOG_ENABLE" "yes"
rc=0
bash "$USM_CLI" screen-ext >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "C3: invalid boolean blocks screen-ext"
sandbox_cleanup

# 4. SIGHUP reload_config safety: invalid config keeps live daemon alive and
#    preserves prior valid USM_MODE="single" for subsequent udev events.
sandbox_init "hw_dsi_only.env"
cat > "$USM_MOCK_STATE_DIR/udev.events" <<'EOF'
SLEEP:1.0
UDEV  [1.0] change   /devices/drm/card2 (drm)
EOF
printf "SLEEP:1.3\n" > "$USM_MOCK_STATE_DIR/dbus.events"
bash "$USM_CLI" monitor >/dev/null 2>&1 &
mon_pid=$!
_wait_monitor_ready
# Corrupt usm.conf and send SIGHUP.
printf 'USM_MODE="broken_value"\n' > "$USM_CONF_FILE"
kill -HUP "$mon_pid"
sleep 0.2
assert_eq "0" "$(kill -0 "$mon_pid" 2>/dev/null; printf "%s" "$?")" \
  "C4: daemon survived SIGHUP with invalid usm.conf"
# Trigger HDMI plug -> daemon must still apply prior valid single mode.
sandbox_set_drm "HDMI-A-1" "connected" 256
sandbox_set_mock_var "wlr.env" "WLR_HAS_HDMI" "true"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_MODES" "2560x1440"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_PREFERRED" "2560x1440"
wait "$mon_pid" || true
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "C4: daemon kept handling udev events after rejected SIGHUP"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_DSI_ENABLED="no"' \
  "C4: daemon preserved prior valid USM_MODE=single"
sandbox_cleanup

# 5. Warn-only matrix: warns to stderr without blocking execution.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_conf "USM_IDLE_SCREENSAVER_TIMEOUT" "600"
sandbox_set_conf "USM_IDLE_SCREENSAVER_CMD" ""
sandbox_set_conf "USM_IDLE_SCREEN_OFF_TIMEOUT" "300"
sandbox_set_conf "USM_HDMI_AUDIO_DEFAULT_STATE" "on"
sandbox_set_conf "USM_HDMI_IDLE_MODE" "enable"
rc=0
warn_err=$(bash "$USM_CLI" screen-ext 2>&1 >/dev/null) || rc=$?
assert_eq "0" "$rc" "C5: warn-only combinations do not block screen-ext"
assert_contains "$warn_err" "USM_IDLE_SCREENSAVER_CMD" \
  "C5: warns on screensaver timeout with empty cmd"
assert_contains "$warn_err" "USM_IDLE_SCREEN_OFF_TIMEOUT" \
  "C5: warns on screensaver timeout >= screen-off timeout"
assert_contains "$warn_err" "USM_HDMI_AUDIO_DEFAULT_STATE" \
  "C5: warns on HDMI audio default on"
assert_contains "$warn_err" "USM_HDMI_IDLE_MODE" \
  "C5: warns on HDMI idle mode enable"
sandbox_cleanup

# 6. Legacy compat: old keys map cleanly, new key wins, non-empty legacy
#    SCREEN_OFF_CMD="wlopm --off *" is ignored & warned, empty does not spam.
sandbox_init "hw_hp_e27u_g4.env"
cat > "$USM_CONF_FILE" <<'EOF'
USM_MODE="single"
USM_HDMI_DISABLE_SWAYIDLE="true"
USM_HDMI_DISABLE_SCREEN_OFF="false"
USM_IDLE_SCREENSAVER_TIMEOUT="600"
USM_IDLE_SCREENSAVER_CMD="cmatrix &"
USM_IDLE_SCREEN_OFF_TIMEOUT="900"
USM_IDLE_SCREEN_OFF_CMD="wlopm --off *"
USM_ENABLE_HW_POWER_CONTROL="true"
EOF
: > "$USM_MOCK_LOG"
err=$(bash "$USM_CLI" swayidle-enable 2>&1 >/dev/null)
assert_file_contains "$USM_MOCK_STATE_DIR/swayidle.env" "SWAYIDLE_RUNNING=0" \
  "C6: legacy DISABLE_SWAYIDLE=true beats DISABLE_SCREEN_OFF=false"
assert_file_not_contains "$USM_MOCK_LOG" "wlopm --off \*" \
  "C6: legacy USM_IDLE_SCREEN_OFF_CMD with wlopm * ignored"
assert_contains "$err" "deprecated" \
  "C6: deprecated legacy keys emitted stderr warning"

# Empty legacy USM_IDLE_SCREEN_OFF_CMD="" produces zero deprecation spam.
cat > "$USM_CONF_FILE" <<'EOF'
USM_MODE="single"
USM_HDMI_IDLE_MODE="no-screen-off"
USM_IDLE_SCREEN_OFF_TIMEOUT="600"
USM_IDLE_SCREEN_OFF_CMD=""
USM_IDLE_SCREEN_ON_CMD=""
EOF
err=$(bash "$USM_CLI" screen-ext 2>&1 >/dev/null)
assert_eq "" "$err" "C6: empty legacy CMD vars emit zero deprecation spam"
sandbox_cleanup

assert_summary "test_config_and_guards"
