#!/bin/bash
# CLI tool and core logic for USM features.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly VER_FILE="$HOME/.config/usm/VERSION"
readonly LOG_PREFIX="[USM] CLI:"
readonly DRM_PATH="/sys/class/drm"
readonly SVC_NAME="usm.service"
readonly SLEEP_SEC=2
readonly NOTIFY_TIMEOUT_MS=10000
readonly STATE_CONN="connected"
readonly STATE_DISC="disconnected"

# --- Modes (Enum) ---
readonly MODE_INT="int"
readonly MODE_EXT="ext"
readonly MODE_DUAL="dual"
readonly DEBOUNCE_SEC=5

# --- Screens (Enum) ---

# Internal and External Screens interface names
readonly SCREEN_OUT_INT="DSI-2"
readonly SCREEN_OUT_EXT="HDMI-A-1"
readonly SCREEN_ENABLED_YES="SCREEN_ENABLED_YES"
readonly SCREEN_ENABLED_NO="SCREEN_ENABLED_NO"
readonly SCREEN_MODE_720_1280="720x1280"
readonly SCREEN_MODE_1024_768="1024x768"
readonly SCREEN_MODE_2560_1440="2560x1440"
readonly SCREEN_TRANS_NORMAL="normal"
readonly SCREEN_TRANS_RIGHT="270"
readonly SCREEN_POS_INT="0,0"
readonly SCREEN_POS_EXT="1280,0"

# --- Global State ---
LAST_STATE="unknown"
USM_VERSION="unknown"
START_TIME_YYMMDD=$(date +%y%m%d)

if [[ -f "$VER_FILE" ]]; then
  USM_VERSION=$(cat "$VER_FILE")
fi

printf "uConsole Screen Manager (USM) Version: %s\n" "$USM_VERSION"

# --- Helpers ---

# ==============================================================================
# log
#
# Purpose:
#   Writes a timestamped log message to stdout. If LOG_FILE is set, also
#   appends the message to that file.
#
# Arguments:
#   msg  The message text to log.
# ==============================================================================
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $LOG_PREFIX $1"
  printf "%s\n" "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf "%s\n" "$msg" >> "$LOG_FILE"
  fi
}

# ==============================================================================
# notify_user
#
# Purpose:
#   Sends a desktop notification using notify-send if it is available.
#   Errors are silently ignored so the caller is not interrupted.
#
# Arguments:
#   msg  The message text to display.
# ==============================================================================
notify_user() {
  local msg="$1"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -t "$NOTIFY_TIMEOUT_MS" "USM" "$msg" || true
  fi
}

# ==============================================================================
# check_hdmi_state
#
# Purpose:
#   Checks whether the external HDMI display is physically connected by
#   reading the DRM sysfs status file and verifying EDID data is present.
#
# Returns (stdout):
#   "connected"    if the HDMI cable is plugged in and EDID data exists.
#   "disconnected" otherwise.
# ==============================================================================
check_hdmi_state() {
  local stat_dir
  stat_dir=$(
    find "$DRM_PATH" -maxdepth 1 \
      -name "card*-$SCREEN_OUT_EXT" \
      | head -n 1
  )

  if [[ -z "$stat_dir" ]]; then
    printf "%s\n" "$STATE_DISC"
    return
  fi

  local status
  local edid_size
  status=$(cat "$stat_dir/status" 2>/dev/null || echo "disconnected")
  edid_size=$(wc -c < "$stat_dir/edid" 2>/dev/null || echo "0")

  if [[ "$status" == "$STATE_CONN" ]] && (( edid_size > 0 )); then
    printf "%s\n" "$STATE_CONN"
  else
    printf "%s\n" "$STATE_DISC"
  fi
}

# ==============================================================================
# is_ext_connected
#
# Purpose:
#   Returns true (exit 0) if the external HDMI display is connected,
#   false (exit 1) otherwise.
# ==============================================================================
is_ext_connected() {
  [[ "$(check_hdmi_state)" == "$STATE_CONN" ]]
}

# ==============================================================================
# check_display_state
#
# Purpose:
#   Checks whether a given display output matches the expected enabled
#   state by querying wlr-randr.
#
# Arguments:
#   output    The output name (e.g. DSI-2, HDMI-A-1).
#   expected  "yes" to expect enabled, "no" to expect disabled.
#
# Returns:
#   0 if the output state matches expected, 1 otherwise.
# ==============================================================================
check_display_state() {
  local output="$1"
  local expected="$2"
  if wlr-randr | grep -A 5 "^$output" | grep -q "Enabled: yes"; then
    [[ "$expected" == "yes" ]]
  else
    [[ "$expected" == "no" ]]
  fi
}

# ==============================================================================
# is_state_matching
#
# Purpose:
#   Checks whether the current display configuration matches a target mode
#   by verifying the enabled/disabled state of each output.
#
# Arguments:
#   target  One of: int, ext, dual.
#
# Returns:
#   0 if the current state matches the target mode, 1 otherwise.
# ==============================================================================
is_state_matching() {
  local target="$1"
  case "$target" in
    "$MODE_EXT")
      check_display_state "$SCREEN_OUT_INT" "no" \
        && check_display_state "$SCREEN_OUT_EXT" "yes"
      ;;
    "$MODE_INT")
      check_display_state "$SCREEN_OUT_INT" "yes" \
        && check_display_state "$SCREEN_OUT_EXT" "no"
      ;;
    "$MODE_DUAL")
      check_display_state "$SCREEN_OUT_INT" "yes" \
        && check_display_state "$SCREEN_OUT_EXT" "yes"
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Load config ---
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
else
  log "Error: Configuration file not found at $CONF_FILE"
  notify_user "Error: Configuration file not found."
  exit 1
fi

# ==============================================================================
# set_log_file_var
#
# Purpose:
#   Reads the USM_LOG_ENABLE setting and sets the LOG_FILE global variable.
#   If logging is enabled, creates the log directory if it does not exist.
#   If logging is disabled, sets LOG_FILE to an empty string.
# ==============================================================================
set_log_file_var() {
  USM_LOG_ENABLE="${USM_LOG_ENABLE:-true}"
  if [[ "$USM_LOG_ENABLE" == "true" ]]; then
    LOG_DIR="$HOME/.local/state/usm/logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/usm_log_${START_TIME_YYMMDD}.log"
  else
    LOG_FILE=""
  fi
}

set_log_file_var

# ==============================================================================
# update_conf
#
# Purpose:
#   Updates or appends a key=value pair in the USM configuration file.
#   If the key already exists its value is replaced; otherwise a new
#   line is appended.
#
# Arguments:
#   key  The configuration key name.
#   val  The value to set.
# ==============================================================================
update_conf() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$CONF_FILE"; then
    sed -i "s/^${key}=.*/${key}=\"${val}\"/" "$CONF_FILE"
  else
    echo "${key}=\"${val}\"" >> "$CONF_FILE"
  fi
}

# ==============================================================================
# cmd_log_enable
#
# Purpose:
#   Sets USM_LOG_ENABLE=true in the configuration file and reloads the
#   USM service if it is currently running.
# ==============================================================================
cmd_log_enable() {
  update_conf "USM_LOG_ENABLE" "true"
  printf "Logging enabled in %s.\n" "$CONF_FILE"
  if systemctl --user is-active --quiet "$SVC_NAME"; then
    systemctl --user reload "$SVC_NAME"
  fi
}

# ==============================================================================
# cmd_log_disable
#
# Purpose:
#   Sets USM_LOG_ENABLE=false in the configuration file and reloads the
#   USM service if it is currently running.
# ==============================================================================
cmd_log_disable() {
  update_conf "USM_LOG_ENABLE" "false"
  printf "Logging disabled in %s.\n" "$CONF_FILE"
  if systemctl --user is-active --quiet "$SVC_NAME"; then
    systemctl --user reload "$SVC_NAME"
  fi
}

# ==============================================================================
# show_usage
#
# Purpose:
#   Prints the list of available USM commands to stdout.
# ==============================================================================
show_usage() {
  printf "Usage: usm [command]\n"
  printf "Commands:\n"
  printf "  read-conf    Print the current usm.conf\n"
  printf "  monitor      Start the DRM event monitor daemon\n"
  printf "  screen-int   Switch output to internal display only\n"
  printf "  screen-ext   Switch output to external display only\n"
  printf "  screen-dual  Switch output to both displays\n"
  printf "  status       Print current service and display status\n"
  printf "  start        Start the USM background service\n"
  printf "  stop         Stop the USM background service\n"
  printf "  restart      Restart the USM background service\n"
  printf "  log_enable   Enable file logging\n"
  printf "  log_disable  Disable file logging\n"
  printf "  notify-test  Test desktop notification\n"
  printf "  version      Print version information\n"
}

# ==============================================================================
# run_hook
#
# Purpose:
#   Executes a hook script in the background if hooks are enabled and the
#   script file exists and is executable.
#
# Arguments:
#   hook_name  The filename of the hook script (e.g. hook-plug.sh).
# ==============================================================================
run_hook() {
  if [[ "${USM_ENABLE_HOOKS:-false}" != "true" ]]; then
    return 0
  fi
  local hook_file="$HOME/.config/usm/$1"
  if [[ -x "$hook_file" ]]; then
    "$hook_file" &
  fi
}

# ==============================================================================
# wait_for_compositor
#
# Purpose:
#   Blocks until the Wayland compositor is ready by polling wlr-randr
#   once per second. Used at startup before applying any display config.
# ==============================================================================
wait_for_compositor() {
  log "Waiting for Wayland compositor..."
  while ! wlr-randr >/dev/null 2>&1; do
    sleep 1
  done
  log "Wayland compositor is ready."
}

# Execute wlr-randr with per-screen parameters.
#
# Usage:
#   exec_wlr_randr <int_enabled> <ext_enabled> <ext_mode>
#
# Arguments:
#   int_enabled  SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   ext_enabled  SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   ext_mode     SCREEN_MODE_1024_768, SCREEN_MODE_2560_1440,
#                or any future mode constant
#
# Returns:
#   0 on success, 1 on failure.
exec_wlr_randr() {
  local int_enabled="$1"
  local ext_enabled="$2"
  local ext_mode="$3"

  # Step a: Init empty command fragments.
  local int_cmd=""
  local ext_cmd=""

  # Query all connected outputs once.
  local active_outputs
  active_outputs=$(
    wlr-randr \
      | grep -E "^[a-zA-Z0-9_-]+" \
      | awk '{print $1}'
  )
  log "Detected outputs: $active_outputs"

  # Step b: Build internal screen command.
  if echo "$active_outputs" \
    | grep -q "$SCREEN_OUT_INT"; then

    local int_state="--off"
    if [[ "$int_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      int_state="--on"
    fi

    int_cmd="--output $SCREEN_OUT_INT $int_state"
    int_cmd+=" --mode $SCREEN_MODE_720_1280"
    int_cmd+=" --transform $SCREEN_TRANS_RIGHT"
    int_cmd+=" --pos $SCREEN_POS_INT"
    log "Internal screen ($SCREEN_OUT_INT): $int_cmd"
  else
    log "Internal screen ($SCREEN_OUT_INT) not detected. Skipped."
  fi

  # Step c: Build external screen command.
  if echo "$active_outputs" \
    | grep -q "$SCREEN_OUT_EXT"; then

    local ext_state="--off"
    if [[ "$ext_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      ext_state="--on"
    fi

    ext_cmd="--output $SCREEN_OUT_EXT $ext_state"
    ext_cmd+=" --mode $ext_mode"
    ext_cmd+=" --transform $SCREEN_TRANS_NORMAL"
    ext_cmd+=" --pos $SCREEN_POS_EXT"
    log "External screen ($SCREEN_OUT_EXT): $ext_cmd"
  else
    log "External screen ($SCREEN_OUT_EXT) not detected. Skipped."
  fi

  # Step d: Assemble the full command.
  local full_cmd="wlr-randr ${int_cmd} ${ext_cmd}"
  log "Final command: $full_cmd"

  # Step e: Execute and report result.
  local rc=0
  eval "$full_cmd" || rc=$?

  if [[ $rc -eq 0 ]]; then
    log "exec_wlr_randr succeeded."
    return 0
  else
    log "exec_wlr_randr failed. (exit code: $rc)"
    return 1
  fi
}

# ==============================================================================
# update_display_by_hdmi_state
#
# Purpose:
#   Changes the screen display mode and runs hook scripts based on the HDMI
#   cable status.
#
# When it is called:
#   - At script start to set the first display state.
#   - When the background loop sees that the HDMI cable is plugged in or
#     pulled out.
#
# Returns:
#   0 on success or if no changes are needed. Always returns 0 to prevent
#   set -e from terminating the monitor daemon.
#
# Steps:
#   1. Check the current HDMI state. Stop if it is the same as the last
#      state.
#   2. Stop at start if the screen is already set right. This stops the
#      screen from blinking.
#   3. Run the right command to change the screen based on the HDMI status
#      and the user's USM_MODE setting.
#   4. Run the right hook script (hook-plug.sh or hook-unplug.sh) when the
#      screen change is done.
# ==============================================================================
update_display_by_hdmi_state() {
  local current_hdmi_state
  current_hdmi_state=$(check_hdmi_state)

  # 1. Stop if the state has not changed
  if [[ "$current_hdmi_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  # 2. Find the needed screen mode
  local target_screen_mode="$MODE_INT"
  if [[ "$current_hdmi_state" == "$STATE_CONN" ]]; then
    if [[ "${USM_MODE:-single}" == "single" ]]; then
      target_screen_mode="$MODE_EXT"
    else
      target_screen_mode="$MODE_DUAL"
    fi
  fi

  # Check screen mode at startup
  if [[ "$LAST_STATE" == "unknown" ]] \
    && is_state_matching "$target_screen_mode"; then
    log "Screen mode matches '$target_screen_mode' at start. Stop here."
    LAST_STATE="$current_hdmi_state"
    return 0
  fi

  log "State changed to: $current_hdmi_state"

  # 3. Run switch command and 4. Run hook scripts
  local ret=0
  if [[ "$current_hdmi_state" == "$STATE_CONN" ]]; then
    if [[ "${USM_MODE:-single}" == "single" ]]; then
      cmd_screen_ext
      ret=$?
      if [[ $ret -ne 0 ]]; then
        log "Error: cmd_screen_ext returned $ret"
        return 0
      fi
      log "cmd_screen_ext returned 0"
    else
      cmd_screen_dual
      ret=$?
      if [[ $ret -ne 0 ]]; then
        log "Error: cmd_screen_dual returned $ret"
        return 0
      fi
      log "cmd_screen_dual returned 0"
    fi
    run_hook "hook-plug.sh"

  elif [[ "$current_hdmi_state" == "$STATE_DISC" ]]; then
    cmd_screen_int
    ret=$?
    if [[ $ret -ne 0 ]]; then
      log "Error: cmd_screen_int returned $ret"
      return 0
    fi
    log "cmd_screen_int returned 0"
    run_hook "hook-unplug.sh"
  fi

  LAST_STATE="$current_hdmi_state"
  return 0
}

# ==============================================================================
# check_exact_state
#
# Purpose:
#   Verifies that a specific display output is enabled with the expected
#   resolution, position, and transform by querying wlr-randr output.
#
# Arguments:
#   out    The output name (e.g. DSI-2, HDMI-A-1).
#   res    Expected resolution string (e.g. 720x1280).
#   pos    Expected position string (e.g. 0,0).
#   trans  Expected transform value (e.g. 270, normal, or 0).
#
# Returns:
#   0 if all properties match, 1 otherwise.
# ==============================================================================
check_exact_state() {
  local out="$1"
  local res="$2"
  local pos="$3"
  local trans="$4"

  local output_str
  output_str=$(wlr-randr 2>/dev/null | awk -v out="$out" '
    $1 == out { found=1; next }
    /^[^ \t]/ { if (found) exit }
    found { print }
  ')

  if ! echo "$output_str" | grep -q "Enabled: yes"; then
    return 1
  fi
  if ! echo "$output_str" | grep -q "${res} px.*current"; then
    return 1
  fi
  if ! echo "$output_str" | grep -q "Position: $pos"; then
    return 1
  fi
  if [[ "$trans" == "0" || "$trans" == "normal" ]]; then
    if ! echo "$output_str" | grep -qE "Transform: (0|normal)"; then
      return 1
    fi
  else
    if ! echo "$output_str" | grep -q "Transform: $trans"; then
      return 1
    fi
  fi
  return 0
}

# ==============================================================================
# apply_display_config
#
# Purpose:
#   Applies a display configuration command. If the first attempt fails,
#   runs a reset (off) command and retries once.
#
# Arguments:
#   output_name  The display output name, used only for logging.
#   cmd_on       The wlr-randr command string to apply the desired state.
#   cmd_off      The wlr-randr command string to reset the output to off.
#
# Returns:
#   0 on success, non-zero if the retry also fails.
# ==============================================================================
apply_display_config() {
  local output_name="$1"
  local cmd_on="$2"
  local cmd_off="$3"

  log "Executing: $cmd_on"
  if eval "$cmd_on"; then
    return 0
  fi

  log "Warning: Config failed. Reset workaround on $output_name"
  sleep 1
  log "Executing reset: $cmd_off"
  eval "$cmd_off" || true
  sleep 1

  log "Retrying configuration: $cmd_on"
  eval "$cmd_on"
}


# ==============================================================================
# cmd_screen_int
#
# Purpose:
#   Sets the display to internal screen only. Uses a fallback sequence if
#   the first try fails.
#
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_int() {
  log "Starting cmd_screen_int."
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_2560_1440"
  local ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "Internal Screen Enabled"
    log "Successfully set to internal screen."
    return 0
  fi

  sleep "$SLEEP_SEC"
  log "First try failed. Starting fallback sequence."

  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_1024_768"
  log "Fallback: Disabled both screens."

  sleep "$SLEEP_SEC"
  log "Fallback: Waiting completed."

  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_2560_1440"
  ret=$?
  log "Fallback: Applied internal screen. ret=$ret"
  log "Second exec_wlr_randr returned: $ret"
  return "$ret"
}

# ==============================================================================
# cmd_screen_ext
#
# Purpose:
#   Sets the display to external screen only. Falls back to internal screen
#   only if the first try fails.
#
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_ext() {
  log "Starting cmd_screen_ext."
  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_2560_1440"
  local ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "External Screen Enabled"
    log "Successfully set to external screen."
    return 0
  fi

  log "First try failed. Waiting before fallback."
  sleep "$SLEEP_SEC"

  log "Starting fallback to internal screen."
  cmd_screen_int
  ret=$?
  log "Fallback cmd_screen_int returned: $ret"
  return "$ret"
}

# ==============================================================================
# cmd_screen_dual
#
# Purpose:
#   Sets the display to dual screen mode using a safe mode sequence. Falls
#   back to internal screen only if it fails.
#
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_dual() {
  log "Starting cmd_screen_dual."
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_1024_768"
  log "Applied safe mode for dual screen."

  sleep "$SLEEP_SEC"
  log "Waiting completed. Applying target mode."

  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_2560_1440"
  local ret=$?
  log "Second exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "Dual Screen Enabled"
    log "Successfully set to dual screen."
    return 0
  fi

  log "Dual screen setup failed. Waiting before fallback."
  sleep "$SLEEP_SEC"

  log "Starting fallback to internal screen."
  cmd_screen_int
  ret=$?
  log "Fallback cmd_screen_int returned: $ret"
  return "$ret"
}

# ==============================================================================
# handle_event_suspend
#
# Purpose:
#   Handles the system suspend event from logind. Creates a lock file so
#   that incoming udev events are ignored during the suspend/resume cycle.
# ==============================================================================
handle_event_suspend() {
  log "System is suspending (PrepareForSleep: true)"
  touch /tmp/usm_suspending.lock
}

# ==============================================================================
# handle_event_resume
#
# Purpose:
#   Handles the system resume event from logind. Removes the suspend lock
#   file and re-evaluates the display state after a short delay to allow
#   hardware to stabilise.
# ==============================================================================
handle_event_resume() {
  log "System has resumed (PrepareForSleep: false)"
  rm -f /tmp/usm_suspending.lock
  sleep 3
  log "Re-evaluating display state after resume"
  update_display_by_hdmi_state
}

# ==============================================================================
# handle_event_udev
#
# Purpose:
#   Handles a DRM udev change event. Ignores the event if a suspend/resume
#   lock is active. Applies a debounce wait to filter rapid repeated events
#   before re-evaluating the display state.
#
# Dependencies:
#   Reads and writes last_event_time, which must be declared as a local
#   variable in the enclosing scope (cmd_monitor).
# ==============================================================================
handle_event_udev() {
  if [[ -f /tmp/usm_suspending.lock ]]; then
    log "Ignoring event due to suspend/resume"
    return 0
  fi

  local current_time
  current_time=$(date +%s)
  local diff=$((current_time - last_event_time))

  if (( diff < DEBOUNCE_SEC )); then
    log "Event debounced (only ${diff}s since last event)."
    return 0
  fi

  log "Hardware change detected. Initiating ${DEBOUNCE_SEC}s debounce..."
  sleep "$DEBOUNCE_SEC"

  local current_state
  current_state=$(check_hdmi_state)
  log "Debounce wait finished. Re-verified state: $current_state"

  if [[ "$current_state" != "$LAST_STATE" ]]; then
    last_event_time=$(date +%s)
    update_display_by_hdmi_state
  else
    log "State unchanged after debounce. Ignored."
  fi
}

# ==============================================================================
# cmd_monitor
#
# Purpose:
#   Starts the USM background monitor daemon. Listens simultaneously to
#   two event sources via process substitution:
#     - dbus-monitor: catches logind PrepareForSleep signals for
#       suspend/resume handling.
#     - udevadm monitor: catches DRM hardware change events for
#       HDMI plug/unplug detection.
#   Both sources feed into a single while-read loop for unified handling.
#
#   SIGHUP reloads the config file and log settings.
#   EXIT/INT/TERM cleans up the suspend lock file and child processes.
# ==============================================================================
cmd_monitor() {
  trap 'source "$CONF_FILE"; set_log_file_var' SIGHUP
  trap 'rm -f /tmp/usm_suspending.lock; pkill -P $$ 2>/dev/null' \
    EXIT INT TERM

  log "Starting monitor daemon..."
  wait_for_compositor
  update_display_by_hdmi_state

  rm -f /tmp/usm_suspending.lock
  local last_event_time=0

  # Read events from dbus-monitor and udevadm in parallel.
  # stdbuf -oL ensures line-buffered output from dbus-monitor so each
  # signal line is delivered immediately to the while-read loop.
  local dbus_filter
  dbus_filter="type='signal',"
  dbus_filter+="interface='org.freedesktop.login1.Manager',"
  dbus_filter+="member='PrepareForSleep'"

  while read -r line; do
    if echo "$line" | grep -q "boolean true"; then
      handle_event_suspend
    elif echo "$line" | grep -q "boolean false"; then
      handle_event_resume
    elif echo "$line" | grep -q "UDEV.*change"; then
      handle_event_udev
    fi
  done < <(
    trap 'pkill -P $BASHPID 2>/dev/null' EXIT
    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL dbus-monitor --system "$dbus_filter" 2>/dev/null &
    else
      dbus-monitor --system "$dbus_filter" 2>/dev/null &
    fi
    udevadm monitor --subsystem=drm 2>/dev/null &
    wait
  )
}

# ==============================================================================
# cmd_status
#
# Purpose:
#   Prints the current USM service status, active display resolutions,
#   and recent service log entries.
# ==============================================================================
cmd_status() {
  printf "%s\n" "--- USM Status ---"
  local svc_status
  systemctl --user status "$SVC_NAME" \
    -n 10 -l --no-pager 2>/dev/null \
    || echo "(Service not found or failed to load)"

  printf "\nCurrent Resolutions:\n"
  wlr-randr 2>/dev/null | awk '
    /^[^ ]/ { out=$1 }
    /current/ { print out ": " $1 " " $2 }
  ' || echo "(wlr-randr execution failed)"

  printf "\nRecent Service Logs:\n"
  journalctl --user-unit="$SVC_NAME" \
    -n 20 --no-pager \
    || echo "No logs found."
  printf "%s\n" "------------------"
}

# ==============================================================================
# cmd_read_conf
#
# Purpose:
#   Prints the contents of the current USM configuration file to stdout.
# ==============================================================================
cmd_read_conf() {
  cat "$CONF_FILE"
}

# ==============================================================================
# cmd_service
#
# Purpose:
#   Runs a systemctl action (start, stop, restart) on the USM service.
#
# Arguments:
#   action  The systemctl action to run (e.g. start, stop, restart).
# ==============================================================================
cmd_service() {
  local action="$1"
  systemctl --user "$action" "$SVC_NAME"
  log "Service $action completed."
}

# ==============================================================================
# cmd_notify_test
#
# Purpose:
#   Sends a test desktop notification to verify that the notification
#   system is working correctly.
# ==============================================================================
cmd_notify_test() {
  notify_user "This is a test notification."
  log "Notification sent."
}

if (( $# == 0 )); then
  show_usage
  exit 1
fi

case "$1" in
  read-conf)   cmd_read_conf ;;
  monitor)     cmd_monitor ;;
  screen-ext)  cmd_screen_ext ;;
  screen-int)  cmd_screen_int ;;
  screen-dual) cmd_screen_dual ;;
  status)      cmd_status ;;
  start)       cmd_service "start" ;;
  stop)        cmd_service "stop" ;;
  restart)     cmd_service "restart" ;;
  log_enable)  cmd_log_enable ;;
  log_disable) cmd_log_disable ;;
  notify-test) cmd_notify_test ;;
  version)     printf "USM Version: %s\n" "$USM_VERSION" ;;
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
