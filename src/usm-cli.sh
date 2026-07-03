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
readonly STATE_HDMI_CONN="connected"
readonly STATE_HDMI_DISC="disconnected"
readonly HOOK_HDMI_PLUG="usm_hook_hdmi_plug.sh"
readonly HOOK_HDMI_UNPLUG="usm_hook_hdmi_unplug.sh"
readonly HOOK_USM_START="usm_hook_usm_start.sh"
readonly HOOK_USM_STOP="usm_hook_usm_stop.sh"

# --- Modes (Enum) ---
readonly MODE_INT="int"
readonly MODE_EXT="ext"
readonly MODE_DUAL="dual"
readonly DEBOUNCE_SEC=5

# --- Audio Constants ---
readonly AUDIO_STATE_ON="on"
readonly AUDIO_STATE_OFF="off"
readonly AUDIO_DEVICE_HDMI="vc4-hdmi"
readonly PROFILE_IDX_OFF=0
readonly PROFILE_IDX_ON=1
readonly ASYNC_WAIT_MAX_SEC=10

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
# Writes a timestamped log message to stdout. If LOG_FILE is set, also
# appends the message to that file.
#
# Globals:
#   LOG_PREFIX
#   LOG_FILE
# Arguments:
#   $1 - The message text to log.
# Outputs:
#   Writes the message to stdout and LOG_FILE.
# Returns:
#   0 on success.
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
# Sends a desktop notification using notify-send if it is available.
# Errors are silently ignored so the caller is not interrupted.
#
# Globals:
#   NOTIFY_TIMEOUT_MS
# Arguments:
#   $1 - The message text to display.
# Outputs:
#   Executes notify-send command.
# Returns:
#   0 on success.
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
# Checks whether the external HDMI display is physically connected by
# reading the DRM sysfs status file and verifying EDID data is present.
#
# Globals:
#   DRM_PATH
#   SCREEN_OUT_EXT
#   STATE_HDMI_CONN
#   STATE_HDMI_DISC
# Arguments:
#   None
# Outputs:
#   Writes "connected" or "disconnected" to stdout.
# Returns:
#   0 on success.
# ==============================================================================
check_hdmi_state() {
  local stat_dir
  stat_dir=$(
    find "$DRM_PATH" -maxdepth 1 \
      -name "card*-$SCREEN_OUT_EXT" \
      | head -n 1
  )

  if [[ -z "$stat_dir" ]]; then
    printf "%s\n" "$STATE_HDMI_DISC"
    return
  fi

  local status
  local edid_size
  status=$(cat "$stat_dir/status" 2>/dev/null || echo "disconnected")
  edid_size=$(wc -c < "$stat_dir/edid" 2>/dev/null || echo "0")

  if [[ "$status" == "$STATE_HDMI_CONN" ]] && (( edid_size > 0 )); then
    printf "%s\n" "$STATE_HDMI_CONN"
  else
    printf "%s\n" "$STATE_HDMI_DISC"
  fi
}

# ==============================================================================
# is_ext_connected
#
# Returns true (exit 0) if the external HDMI display is connected,
# false (exit 1) otherwise.
#
# Globals:
#   STATE_HDMI_CONN
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 if connected, 1 otherwise.
# ==============================================================================
is_ext_connected() {
  [[ "$(check_hdmi_state)" == "$STATE_HDMI_CONN" ]]
}

# ==============================================================================
# check_display_state
#
# Checks whether a given display output matches the expected enabled
# state by querying wlr-randr.
#
# Globals:
#   None
# Arguments:
#   $1 - The output name (e.g. DSI-2, HDMI-A-1).
#   $2 - "yes" to expect enabled, "no" to expect disabled.
# Outputs:
#   None
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
# Checks whether the current display configuration matches a target mode
# by verifying the enabled/disabled state of each output.
#
# Globals:
#   MODE_EXT
#   MODE_INT
#   MODE_DUAL
#   SCREEN_OUT_INT
#   SCREEN_OUT_EXT
# Arguments:
#   $1 - Target mode: int, ext, or dual.
# Outputs:
#   None
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
# Reads the USM_LOG_ENABLE setting and sets the LOG_FILE global variable.
# If logging is enabled, creates the log directory if it does not exist.
# If logging is disabled, sets LOG_FILE to an empty string.
#
# Globals:
#   USM_LOG_ENABLE
#   LOG_DIR
#   LOG_FILE
#   START_TIME_YYMMDD
# Arguments:
#   None
# Outputs:
#   Creates the log directory.
# Returns:
#   0 on success.
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
# Updates or appends a key=value pair in the USM configuration file.
# If the key already exists its value is replaced; otherwise a new
# line is appended.
#
# Globals:
#   CONF_FILE
# Arguments:
#   $1 - The configuration key name.
#   $2 - The value to set.
# Outputs:
#   Modifies the configuration file.
# Returns:
#   0 on success.
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
# reload_svc_if_active
#
# Checks if the USM service is active and reloads it if so.
#
# Globals:
#   SVC_NAME
# Arguments:
#   None
# Outputs:
#   Executes systemctl reload if service is active.
# Returns:
#   0 on success.
# ==============================================================================
reload_svc_if_active() {
  local ret=0
  systemctl --user is-active --quiet "$SVC_NAME" || ret=$?

  if [[ $ret -eq 0 ]]; then
    systemctl --user reload "$SVC_NAME"
  fi
}

# ==============================================================================
# cmd_log_enable
#
# Sets USM_LOG_ENABLE=true in the configuration file and reloads the
# USM service if it is currently running.
#
# Globals:
#   CONF_FILE
# Arguments:
#   None
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success.
# ==============================================================================
cmd_log_enable() {
  update_conf "USM_LOG_ENABLE" "true"
  printf "Logging enabled in %s.\n" "$CONF_FILE"
  reload_svc_if_active
}

# ==============================================================================
# cmd_log_disable
#
# Sets USM_LOG_ENABLE=false in the configuration file and reloads the
# USM service if it is currently running.
#
# Globals:
#   CONF_FILE
# Arguments:
#   None
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success.
# ==============================================================================
cmd_log_disable() {
  update_conf "USM_LOG_ENABLE" "false"
  printf "Logging disabled in %s.\n" "$CONF_FILE"
  reload_svc_if_active
}

# ==============================================================================
# show_usage
#
# Prints the list of available USM commands to stdout.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes usage instructions to stdout.
# Returns:
#   0 on success.
# ==============================================================================
show_usage() {
  printf "Usage: usm [command]\n"
  printf "Commands:\n"
  printf "  read-conf    Print the current usm.conf\n"
  printf "  monitor      Start the DRM event monitor daemon\n"
  printf "  screen-int   Switch output to internal display only\n"
  printf "  screen-ext   Switch output to external display only\n"
  printf "  screen-dual  Switch output to both displays\n"
  printf "  swayidle_enable  Enables swayidle by reading autostart config.\n"
  printf "  swayidle_disable Disables swayidle by terminating its process.\n"
  printf "  status       Print current service and display status\n"
  printf "  start        Start the USM background service\n"
  printf "  stop         Stop the USM background service\n"
  printf "  restart      Restart the USM background service\n"
  printf "  log_enable   Enable file logging\n"
  printf "  log_disable  Disable file logging\n"
  printf "  hdmi-audio-on    Enable HDMI audio devices (Digital Stereo)\n"
  printf "  hdmi-audio-off   Disable HDMI audio devices to prevent crashes\n"
  printf "  hdmi-audio-state Print current state of HDMI audio devices\n"
  printf "  notify-test  Test desktop notification\n"
  printf "  version      Print version information\n"
}

# ==============================================================================
# run_hook
#
# Executes a hook script in the background if hooks are enabled and the
# script file exists and is executable.
#
# Globals:
#   USM_HOOKS_ENABLE
# Arguments:
#   $1 - The filename of the hook script (e.g. hook-plug.sh).
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
run_hook() {
  if [[ "${USM_HOOKS_ENABLE:-false}" != "true" ]]; then
    return 0
  fi
  local hook_file="$HOME/.config/usm/hooks/$1"
  if [[ -x "$hook_file" ]]; then
    "$hook_file" &
  fi
}

# ==============================================================================
# wait_for_compositor
#
# Blocks until the Wayland compositor is ready by polling wlr-randr
# once per second. Used at startup before applying any display config.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes waiting status logs.
# Returns:
#   0 on success.
# ==============================================================================
wait_for_compositor() {
  log "Waiting for Wayland compositor..."
  while ! wlr-randr >/dev/null 2>&1; do
    sleep 1
  done
  log "Wayland compositor is ready."
}

# ==============================================================================
# exec_wlr_randr
#
# Execute wlr-randr with per-screen parameters.
#
# Globals:
#   SCREEN_OUT_INT
#   SCREEN_OUT_EXT
#   SCREEN_ENABLED_YES
#   SCREEN_MODE_720_1280
#   SCREEN_TRANS_RIGHT
#   SCREEN_POS_INT
#   SCREEN_POS_EXT
#   SCREEN_TRANS_NORMAL
# Arguments:
#   $1 - int_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   $2 - ext_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   $3 - ext_mode: SCREEN_MODE_1024_768, SCREEN_MODE_2560_1440, etc.
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
exec_wlr_randr() {
  local int_enabled="$1"
  local ext_enabled="$2"
  local ext_mode="$3"

  # Step a: Init empty command array.
  local full_cmd=(wlr-randr)

  # Query all connected outputs once.
  local active_outputs=()
  mapfile -t active_outputs < <(
    wlr-randr \
      | grep -E "^[a-zA-Z0-9_-]+" \
      | awk '{print $1}'
  )

  # Check which screens are active
  local has_int=1
  local has_ext=1
  local o
  for o in "${active_outputs[@]}"; do
    if [[ "$o" == "$SCREEN_OUT_INT" ]]; then
      has_int=0
    elif [[ "$o" == "$SCREEN_OUT_EXT" ]]; then
      has_ext=0
    fi
  done

  log "Detected outputs: ${active_outputs[*]}"

  # Step b: Build internal screen command.
  if [[ $has_int -eq 0 ]]; then
    local int_state="--off"
    if [[ "$int_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      int_state="--on"
    fi

    full_cmd+=(
      "--output" "$SCREEN_OUT_INT"
      "$int_state"
      "--mode" "$SCREEN_MODE_720_1280"
      "--transform" "$SCREEN_TRANS_RIGHT"
      "--pos" "$SCREEN_POS_INT"
    )
    log "Internal screen ($SCREEN_OUT_INT) config added."
  else
    log "Internal screen ($SCREEN_OUT_INT) not detected. Skipped."
  fi

  # Step c: Build external screen command.
  if [[ $has_ext -eq 0 ]]; then
    local ext_state="--off"
    if [[ "$ext_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      ext_state="--on"
    fi

    full_cmd+=(
      "--output" "$SCREEN_OUT_EXT"
      "$ext_state"
      "--mode" "$ext_mode"
      "--transform" "$SCREEN_TRANS_NORMAL"
      "--pos" "$SCREEN_POS_EXT"
    )
    log "External screen ($SCREEN_OUT_EXT) config added."
  else
    log "External screen ($SCREEN_OUT_EXT) not detected. Skipped."
  fi

  log "Final command: ${full_cmd[*]}"

  # Step e: Execute and report result.
  local rc=0
  "${full_cmd[@]}" || rc=$?

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
# Changes the screen display mode and runs hook scripts based on the HDMI
# cable status. Stop at start if the screen is already set right.
#
# Globals:
#   LAST_STATE
#   MODE_INT
#   MODE_EXT
#   MODE_DUAL
#   STATE_HDMI_CONN
#   STATE_HDMI_DISC
#   USM_MODE
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success or if no changes are needed. Always returns 0 to prevent
#   set -e from terminating the monitor daemon.
# ==============================================================================
# ==============================================================================
# stop_swayidle
#
# Terminates the swayidle process if it is currently running.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
stop_swayidle() {
  if ! pgrep -x "swayidle" >/dev/null 2>&1; then
    log "swayidle not running"
    return 0
  fi
  pkill -x "swayidle" || true
  log "swayidle killed"
}

# ==============================================================================
# start_swayidle
#
# Starts the swayidle process by extracting its command from the autostart
# configuration file, provided it is not already running.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
start_swayidle() {
  if pgrep -x "swayidle" >/dev/null 2>&1; then
    log "swayidle already running"
    return 0
  fi

  local autostart_file="$HOME/.config/labwc/autostart"
  if [[ ! -f "$autostart_file" ]]; then
    log "Autostart file $autostart_file not found"
    return 0
  fi

  local swayidle_cmd
  swayidle_cmd=$(
    sed -n '/^[ \t]*swayidle/{:a; /\\$/{N; s/\\\n/ /; ba}; p; q}' \
      "$autostart_file"
  )
  if [[ -z "$swayidle_cmd" ]]; then
    log "No swayidle command found in $autostart_file"
    return 0
  fi

  log "Executing via subshell: $swayidle_cmd"
  bash -c "$swayidle_cmd" &
}

# ==============================================================================
# manage_swayidle
#
# Manages the swayidle process based on HDMI state. Kills swayidle when HDMI
# is connected, and starts it when disconnected.
#
# Globals:
#   USM_HDMI_DISABLE_SWAYIDLE
#   STATE_HDMI_CONN
#   STATE_HDMI_DISC
# Arguments:
#   $1 - The current HDMI state.
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
manage_swayidle() {
  local hdmi_state="$1"

  if [[ "${USM_HDMI_DISABLE_SWAYIDLE:-true}" != "true" ]]; then
    return 0
  fi

  if [[ "$hdmi_state" == "$STATE_HDMI_CONN" ]]; then
    log "HDMI connected: stopping swayidle"
    stop_swayidle
    return 0
  fi

  if [[ "$hdmi_state" == "$STATE_HDMI_DISC" ]]; then
    log "HDMI disconnected: starting swayidle"
    start_swayidle
    return 0
  fi
}

update_display_by_hdmi_state() {
  local current_hdmi_state
  current_hdmi_state=$(check_hdmi_state)

  # 1. Stop if the state has not changed
  if [[ "$current_hdmi_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  manage_swayidle "$current_hdmi_state"

  # 2. Find the needed screen mode
  local target_screen_mode="$MODE_INT"
  if [[ "$current_hdmi_state" == "$STATE_HDMI_CONN" ]]; then
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
  local target_cmd=""
  local hook_name=""

  if [[ "$current_hdmi_state" == "$STATE_HDMI_CONN" ]]; then
    if [[ "${USM_MODE:-single}" == "single" ]]; then
      target_cmd="cmd_screen_ext"
    else
      target_cmd="cmd_screen_dual"
    fi
    hook_name="$HOOK_HDMI_PLUG"
  elif [[ "$current_hdmi_state" == "$STATE_HDMI_DISC" ]]; then
    target_cmd="cmd_screen_int"
    hook_name="$HOOK_HDMI_UNPLUG"
  fi

  if [[ -n "$target_cmd" ]]; then
    local ret=0
    "$target_cmd" || ret=$?
    if [[ $ret -ne 0 ]]; then
      log "Error: $target_cmd returned $ret"
      return 0
    fi
    log "$target_cmd returned 0"
    run_hook "$hook_name"
  fi

  LAST_STATE="$current_hdmi_state"
  return 0
}


# ==============================================================================
# cmd_screen_int
#
# Sets the display to internal screen only. Uses a fallback sequence if
# the first try fails.
#
# Globals:
#   SCREEN_ENABLED_YES
#   SCREEN_ENABLED_NO
#   SCREEN_MODE_2560_1440
#   SCREEN_MODE_1024_768
#   SLEEP_SEC
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_int() {
  log "Starting cmd_screen_int."
  local ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_2560_1440" || ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "Internal Screen Enabled"
    log "Successfully set to internal screen."
    return 0
  fi

  sleep "$SLEEP_SEC"
  log "First try failed. Starting fallback sequence."

  ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_1024_768" || ret=$?
  log "Fallback: Disabled both screens (ret: $ret)."

  sleep "$SLEEP_SEC"
  log "Fallback: Waiting completed."

  ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_MODE_2560_1440" || ret=$?
  log "Second exec_wlr_randr returned: $ret"
  return "$ret"
}

# ==============================================================================
# cmd_screen_ext
#
# Sets the display to external screen only. Falls back to internal screen
# only if the first try fails.
#
# Globals:
#   SCREEN_ENABLED_YES
#   SCREEN_ENABLED_NO
#   SCREEN_MODE_2560_1440
#   SLEEP_SEC
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_ext() {
  log "Starting cmd_screen_ext."
  local ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_2560_1440" || ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "External Screen Enabled"
    log "Successfully set to external screen."
    return 0
  fi

  log "First try failed. Waiting before fallback."
  sleep "$SLEEP_SEC"

  log "Starting fallback to internal screen."
  ret=0
  cmd_screen_int || ret=$?
  log "Fallback cmd_screen_int returned: $ret"
  return "$ret"
}

# ==============================================================================
# cmd_screen_dual
#
# Sets the display to dual screen mode using a safe mode sequence. Falls
# back to internal screen only if it fails.
#
# Globals:
#   SCREEN_ENABLED_YES
#   SCREEN_MODE_1024_768
#   SCREEN_MODE_2560_1440
#   SLEEP_SEC
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_dual() {
  log "Starting cmd_screen_dual."
  local ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_1024_768" || ret=$?
  log "Applied safe mode for dual screen (ret: $ret)."

  sleep "$SLEEP_SEC"
  log "Waiting completed. Applying target mode."

  ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_MODE_2560_1440" || ret=$?
  log "Second exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "Dual Screen Enabled"
    log "Successfully set to dual screen."
    return 0
  fi

  log "Dual screen setup failed. Waiting before fallback."
  sleep "$SLEEP_SEC"

  log "Starting fallback to internal screen."
  ret=0
  cmd_screen_int || ret=$?
  log "Fallback cmd_screen_int returned: $ret"
  return "$ret"
}

# ==============================================================================
# handle_event_suspend
#
# Handles the system suspend event from logind. Creates a lock file so
# that incoming udev events are ignored during the suspend/resume cycle.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes execution logs and creates a lock file in /tmp.
# Returns:
#   0 on success.
# ==============================================================================
handle_event_suspend() {
  log "System is suspending (PrepareForSleep: true)"
  touch /tmp/usm_suspending.lock
}

# ==============================================================================
# handle_event_resume
#
# Handles the system resume event from logind. Removes the suspend lock
# file and re-evaluates the display state after a short delay to allow
# hardware to stabilise.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes execution logs and removes the lock file.
# Returns:
#   0 on success.
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
# Handles a DRM udev change event. Ignores the event if a suspend/resume
# lock is active. Applies a debounce wait to filter rapid repeated events
# before re-evaluating the display state.
#
# Globals:
#   DEBOUNCE_SEC
#   LAST_STATE
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
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
# get_hdmi_audio_device_ids
#
# Helper function to find all HDMI audio output device IDs.
#
# Globals:
#   AUDIO_DEVICE_HDMI
# Arguments:
#   None
# Outputs:
#   Writes the PipeWire device IDs (newline-separated) to stdout.
# Returns:
#   0 on success.
# ==============================================================================
get_hdmi_audio_device_ids() {
  pw-cli ls Device 2>/dev/null \
    | awk -v dev="$AUDIO_DEVICE_HDMI" \
        '$0 ~ dev {print id} {if($1=="id") id=$2}' \
    | tr -d ','
}

# ==============================================================================
# get_hdmi_audio_state
#
# Helper function to query the current active profile name for a device ID.
#
# Globals:
#   None
# Arguments:
#   $1 - The PipeWire device ID to query.
# Outputs:
#   Writes the active profile name string to stdout.
# Returns:
#   0 on success.
# ==============================================================================
get_hdmi_audio_state() {
  local id="$1"
  pw-cli e "$id" Profile 2>/dev/null \
    | awk -F '"' '/Profile:name/{getline; print $2}'
}

# ==============================================================================
# cmd_hdmi_audio_off
#
# Disables all HDMI audio output devices to prevent kernel crashes during
# hotplug events.
#
# Globals:
#   AUDIO_STATE_OFF
#   PROFILE_IDX_OFF
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
cmd_hdmi_audio_off() {
  log "Executing cmd_hdmi_audio_off..."

  local ids=()
  mapfile -t ids < <(get_hdmi_audio_device_ids)

  local id
  for id in "${ids[@]}"; do
    [[ -z "$id" ]] && continue
    local state
    state=$(get_hdmi_audio_state "$id")
    if [[ "$state" == "$AUDIO_STATE_OFF" ]]; then
      log "HDMI Audio (ID: $id) is already Off. Skipped."
      continue
    fi

    wpctl set-profile "$id" "$PROFILE_IDX_OFF" 2>/dev/null || true
    log "HDMI Audio (ID: $id) is now set to Off."
  done

  log "cmd_hdmi_audio_off completed."
}

# ==============================================================================
# cmd_hdmi_audio_on
#
# Enables all HDMI audio output devices and sets their profile to Digital
# Stereo.
#
# Globals:
#   AUDIO_STATE_OFF
#   PROFILE_IDX_ON
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
cmd_hdmi_audio_on() {
  log "Executing cmd_hdmi_audio_on..."

  local ids=()
  mapfile -t ids < <(get_hdmi_audio_device_ids)

  local id
  for id in "${ids[@]}"; do
    [[ -z "$id" ]] && continue
    local state
    state=$(get_hdmi_audio_state "$id")
    if [[ "$state" != "$AUDIO_STATE_OFF" && -n "$state" ]]; then
      log "HDMI Audio (ID: $id) is already On ($state). Skipped."
      continue
    fi

    wpctl set-profile "$id" "$PROFILE_IDX_ON" 2>/dev/null || true
    log "HDMI Audio (ID: $id) is now set to On (Digital Stereo)."
  done

  log "cmd_hdmi_audio_on completed."
}

# ==============================================================================
# cmd_hdmi_audio_state
#
# Checks and prints the current active profile name for each HDMI audio
# device using pw-cli.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Prints the audio state to stdout. If no devices are found, prints an
#   unknown state message.
# Returns:
#   0 on success.
# ==============================================================================
cmd_hdmi_audio_state() {
  local ids=()
  mapfile -t ids < <(get_hdmi_audio_device_ids)

  if [[ ${#ids[@]} -eq 0 || -z "${ids[0]}" ]]; then
    printf "HDMI Audio state: unknown (no device found or PipeWire not ready)\n"
    return 0
  fi

  local id
  for id in "${ids[@]}"; do
    [[ -z "$id" ]] && continue
    local state
    state=$(get_hdmi_audio_state "$id")
    printf "HDMI Audio (ID: %s) state: %s\n" "$id" "${state:-unknown}"
  done
}

# ==============================================================================
# init_hdmi_audio_default_async
#
# A background process that waits for PipeWire to detect HDMI audio devices,
# then applies the default audio state configured in the config file.
# It loops up to a maximum defined seconds to prevent blocking the monitor.
#
# Globals:
#   ASYNC_WAIT_MAX_SEC
#   AUDIO_DEVICE_HDMI
#   USM_HDMI_AUDIO_DEFAULT_STATE
#   AUDIO_STATE_OFF
#   AUDIO_STATE_ON
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
init_hdmi_audio_default_async() {
  local device_found=1
  local i

  for (( i=1; i<=ASYNC_WAIT_MAX_SEC; i++ )); do
    if pw-cli ls Device 2>/dev/null | grep -q "$AUDIO_DEVICE_HDMI"; then
      device_found=0
      break
    fi
    sleep 1
  done

  if [[ $device_found -ne 0 ]]; then
    log "Async Audio Init: Timeout waiting for PipeWire devices."
    return 0
  fi

  local default_state="${USM_HDMI_AUDIO_DEFAULT_STATE:-}"
  log "Async Audio Init: Checking DEFAULT_STATE: $default_state"

  if [[ "$default_state" == "$AUDIO_STATE_OFF" || \
        "$default_state" == "$AUDIO_STATE_ON" ]]; then
    log "Async Audio Init: Recording current HDMI audio state:"

    cmd_hdmi_audio_state | while read -r line; do
      log "  $line"
    done

    if [[ "$default_state" == "$AUDIO_STATE_OFF" ]]; then
      log "Async Audio Init: Applying hdmi-audio-off."
      cmd_hdmi_audio_off
    else
      log "Async Audio Init: Applying hdmi-audio-on."
      cmd_hdmi_audio_on
    fi
  else
    log "Async Audio Init: Default state not set to on/off. Ignored."
  fi
}

# ==============================================================================
# cmd_monitor
#
# Starts the USM background monitor daemon. Listens simultaneously to
# two event sources via process substitution: dbus-monitor and udevadm.
#
# Globals:
#   CONF_FILE
# Arguments:
#   None
# Outputs:
#   Writes execution logs and listens to system events.
# Returns:
#   Does not return under normal execution.
# ==============================================================================
# ==============================================================================
# cleanup_on_exit
#
# Cleans up resources when the monitor daemon is terminating. Removes the
# suspending lock file, kills all child processes, and restores swayidle.
#
# Globals:
#   USM_HDMI_DISABLE_SWAYIDLE
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
cleanup_on_exit() {
  log "Monitor daemon terminating. Running cleanup..."
  run_hook "$HOOK_USM_STOP"
  rm -f /tmp/usm_suspending.lock
  pkill -P $$ 2>/dev/null || true
  if [[ "${USM_HDMI_DISABLE_SWAYIDLE:-true}" == "true" ]]; then
    log "Service exiting: restoring swayidle"
    start_swayidle
  fi
}

cmd_monitor() {
  trap 'source "$CONF_FILE"; set_log_file_var' SIGHUP
  trap 'cleanup_on_exit' EXIT INT TERM

  log "Starting monitor daemon..."
  run_hook "$HOOK_USM_START"
  wait_for_compositor
  update_display_by_hdmi_state

  init_hdmi_audio_default_async &

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
# Prints the current USM service status, active display resolutions,
# and recent service log entries.
#
# Globals:
#   SVC_NAME
# Arguments:
#   None
# Outputs:
#   Writes status information to stdout.
# Returns:
#   0 on success.
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
# Prints the contents of the current USM configuration file to stdout.
#
# Globals:
#   CONF_FILE
# Arguments:
#   None
# Outputs:
#   Writes file contents to stdout.
# Returns:
#   0 on success.
# ==============================================================================
cmd_read_conf() {
  cat "$CONF_FILE"
}

# ==============================================================================
# cmd_service
#
# Runs a systemctl action (start, stop, restart) on the USM service.
#
# Globals:
#   SVC_NAME
# Arguments:
#   $1 - The systemctl action to run (e.g. start, stop, restart).
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
cmd_service() {
  local action="$1"
  systemctl --user "$action" "$SVC_NAME"
  log "Service $action completed."
}

# ==============================================================================
# cmd_notify_test
#
# Sends a test desktop notification to verify that the notification
# system is working correctly.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Executes notify_user command.
# Returns:
#   0 on success.
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
  swayidle_enable) start_swayidle ;;
  swayidle_disable) stop_swayidle ;;
  status)      cmd_status ;;
  start)       cmd_service "start" ;;
  stop)        cmd_service "stop" ;;
  restart)     cmd_service "restart" ;;
  log_enable)  cmd_log_enable ;;
  log_disable) cmd_log_disable ;;
  hdmi-audio-on)    cmd_hdmi_audio_on ;;
  hdmi-audio-off)   cmd_hdmi_audio_off ;;
  hdmi-audio-state) cmd_hdmi_audio_state ;;
  notify-test) cmd_notify_test ;;
  version)     printf "USM Version: %s\n" "$USM_VERSION" ;;
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
