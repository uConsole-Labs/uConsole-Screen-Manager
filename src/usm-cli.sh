#!/bin/bash
# CLI tool and core logic for USM features.

set -euo pipefail

# --- 1. General Config ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly DRM_PATH="/sys/class/drm"
readonly LOG_PREFIX="[USM] CLI:"
readonly SVC_NAME="usm.service"
readonly VALID_SYSTEM_STATES=("running" "degraded")
readonly VER_FILE="$HOME/.config/usm/VERSION"

# --- 2. Timeouts & Delays ---
readonly ASYNC_WAIT_MAX_SEC=10
readonly DEBOUNCE_SEC=5
readonly DSI_POLL_INTERVAL_SEC="0.5"
readonly DSI_POLL_MAX_ATTEMPTS=6
readonly DSI_POLL_TIMEOUT_SEC=3
readonly NOTIFY_TIMEOUT_MS=10000
readonly RETRY_DELAY_SEC=2
readonly SYSTEMD_RUN_TIMEOUT_SEC="2"

# --- 3. Hooks ---
readonly HOOK_HDMI_PLUG="usm_hook_hdmi_plug.sh"
readonly HOOK_HDMI_UNPLUG="usm_hook_hdmi_unplug.sh"
readonly HOOK_USM_START="usm_hook_usm_start.sh"
readonly HOOK_USM_STOP="usm_hook_usm_stop.sh"

# --- 4. Screen & Display ---
readonly BRIGHTNESS_MAX="9"
readonly BRIGHTNESS_OFF="0"
# shellcheck disable=SC2034
readonly CONF_MODE_DUAL="dual"
readonly CONF_MODE_SINGLE="single"
readonly FLAG_NO="no"
readonly FLAG_SILENT="--silent"
readonly FLAG_YES="yes"
readonly PANEL_DRIVER_PATH="/sys/bus/mipi-dsi/drivers/panel-cwu50"
readonly MODE_DUAL="dual"
readonly MODE_EXT="ext"
readonly MODE_INT="int"
readonly MODE_NONE="none"
readonly SCREEN_ENABLED_NO="SCREEN_ENABLED_NO"
readonly SCREEN_ENABLED_SKIP="SCREEN_ENABLED_SKIP"
readonly SCREEN_ENABLED_YES="SCREEN_ENABLED_YES"
readonly SCREEN_OUT_EXT="HDMI-A-1"
readonly SCREEN_OUT_INT="DSI-2"
readonly SCREEN_POS_EXT="1280,0"
readonly SCREEN_POS_INT="0,0"
readonly SCREEN_RES_1024_768="1024x768"
readonly SCREEN_RES_2560_1440="2560x1440"
readonly SCREEN_RES_720_1280="720x1280"
readonly SCREEN_TRANS_NORMAL="normal"
readonly SCREEN_TRANS_RIGHT="270"
readonly STATE_HDMI_CONN="connected"
readonly STATE_HDMI_DISC="disconnected"
readonly SYSFS_BACKLIGHT_POWER_OFF="4"
readonly SYSFS_BACKLIGHT_POWER_ON="0"
readonly SYSFS_FRAMEBUFFER_BLANK="1"
readonly SYSFS_FRAMEBUFFER_UNBLANK="0"

# --- 5. Audio ---
readonly AUDIO_DEVICE_HDMI="vc4-hdmi"
readonly AUDIO_STATE_OFF="off"
readonly AUDIO_STATE_ON="on"
readonly PROFILE_IDX_OFF=0
readonly PROFILE_IDX_ON=1

# --- 6. Mutable Globals & Init ---
LAST_STATE="unknown"
USM_VERSION="unknown"
START_TIME_YYMMDD=$(date +%y%m%d)

if [[ -f "$VER_FILE" ]]; then
  USM_VERSION=$(cat "$VER_FILE")
fi

printf "uConsole Screen Manager (USM) Version: %s\n" "$USM_VERSION"


################################################################################
# 1. Basic Utilities
################################################################################


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
#   $1 - message: The message text to log.
# Outputs:
#   Writes the message to stdout and LOG_FILE.
# Returns:
#   0 on success.
# ==============================================================================
log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $LOG_PREFIX $1"
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
#   $1 - message: The message text to display.
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
  printf "  screen-on    Turn on screens based on detected hardware and mode\n"
  printf "  screen-off   Turn off all screens\n"
  printf "  screen-switch Toggle screen state (on to off, off to on)\n"
  printf "  screen-reset [%s] Reset DSI panel state via safe hotplug\n" \
         "$FLAG_SILENT"
  printf "  swayidle-enable  Enables swayidle by reading autostart config.\n"
  printf "  swayidle-disable Disables swayidle by terminating its process.\n"
  printf "  status       Print current service and display status\n"
  printf "  start        Start the USM background service\n"
  printf "  stop         Stop the USM background service\n"
  printf "  restart      Restart the USM background service\n"
  printf "  log-enable   Enable file logging\n"
  printf "  log-disable  Disable file logging\n"
  printf "  hdmi-audio-on    Enable HDMI audio devices (Digital Stereo)\n"
  printf "  hdmi-audio-off   Disable HDMI audio devices to prevent crashes\n"
  printf "  hdmi-audio-state Print current state of HDMI audio devices\n"
  printf "  notify-test  Test desktop notification\n"
  printf "  hw_status    Print all hardware parameters\n"
  printf "  version      Print version information\n"
}


################################################################################
# 2. Config & Init
################################################################################

# ==============================================================================
# set_sysfs_val
#
# Writes a value to a sysfs path using sudo tee.
#
# Arguments:
#   $1 - The sysfs path
#   $2 - The value to write
# Returns:
#   0 on success.
# ==============================================================================
set_sysfs_val() {
  local path="$1"
  local val="$2"
  if [[ -n "$path" && -n "$val" ]]; then
    echo "$val" | sudo tee "$path" >/dev/null 2>/dev/null || true
  fi
}

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

# ==============================================================================
# reload_config
#
# Reloads the configuration file and updates the log file variable.
# Called upon receiving a SIGHUP signal.
#
# Globals:
#   CONF_FILE
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================

# ==============================================================================
# usm_validate_config
#
# Validates and sanitizes the configured USM_MODE. Falls back to single mode
# if the configuration is invalid or missing.
#
# Globals:
#   CONF_MODE_SINGLE
#   CONF_MODE_DUAL
#   USM_MODE
# Arguments:
#   None
# Outputs:
#   Writes a warning to stderr if an invalid mode is detected.
# Returns:
#   Always 0.
# ==============================================================================
usm_validate_config() {
  case "${USM_MODE:-}" in
    "$CONF_MODE_DUAL")
      USM_MODE="$CONF_MODE_DUAL"
      ;;
    "$CONF_MODE_SINGLE")
      USM_MODE="$CONF_MODE_SINGLE"
      ;;
    *)
      printf "Warning: Invalid USM_MODE '%s'. " "${USM_MODE:-}" >&2
      printf "Falling back to '%s'.\n" "$CONF_MODE_SINGLE" >&2
      USM_MODE="$CONF_MODE_SINGLE"
      ;;
  esac
}

reload_config() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    usm_validate_config
    set_log_file_var
    log "Configuration reloaded via SIGHUP."
  else
    log "Warning: SIGHUP received, but $CONF_FILE is missing. Ignored."
  fi
}

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
#   $1 - key: The configuration key name.
#   $2 - val: The value to set.
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
# setup_runtime_dir
#
# Determines and creates a writable runtime directory for USM.
# Applies fallbacks if the primary XDG_RUNTIME_DIR is unavailable.
#
# Globals:
#   USM_RUN_DIR (writes)
# Arguments:
#   None
# Outputs:
#   Writes logs to stdout if fallbacks are used.
# Returns:
#   0 on success.
# ==============================================================================
setup_runtime_dir() {
  local dirs=(
    "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/usm"
    "/tmp/usm_$(id -u)"
    "$HOME/.local/state/usm/run"
  )

  local d
  for d in "${dirs[@]}"; do
    local err_msg
    if err_msg=$(mkdir -p "$d" 2>&1); then
      if [[ -w "$d" ]]; then
        USM_RUN_DIR="$d"
        return 0
      else
        log "Warning: Directory $d created but is not writable."
      fi
    else
      log "Warning: Failed to create $d. Error: $err_msg"
    fi
  done

  USM_RUN_DIR="/tmp"
  log "Error: All runtime directories failed. Using fallback: $USM_RUN_DIR"
  return 0
}


################################################################################
# 3. Hardware & State
################################################################################

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
#   $1 - output: The output name (e.g. DSI-2, HDMI-A-1).
#   $2 - expected: "$FLAG_YES" to expect enabled,
#        "$FLAG_NO" to expect disabled.
# Outputs:
#   None
# Returns:
#   0 if the output state matches expected, 1 otherwise.
# ==============================================================================
check_display_state() {
  local output="$1"
  local expected="$2"
  if wlr-randr | grep -A 5 "^$output" | grep -q "Enabled: yes"; then
    [[ "$expected" == "$FLAG_YES" ]]
  else
    [[ "$expected" == "$FLAG_NO" ]]
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
#   $1 - target: Target mode: int, ext, or dual.
# Outputs:
#   None
# Returns:
#   0 if the current state matches the target mode, 1 otherwise.
# ==============================================================================
is_state_matching() {
  local target="$1"
  case "$target" in
    "$MODE_EXT")
      check_display_state "$SCREEN_OUT_INT" "$FLAG_NO" \
        && check_display_state "$SCREEN_OUT_EXT" "$FLAG_YES"
      ;;
    "$MODE_INT")
      check_display_state "$SCREEN_OUT_INT" "$FLAG_YES" \
        && check_display_state "$SCREEN_OUT_EXT" "$FLAG_NO"
      ;;
    "$MODE_DUAL")
      check_display_state "$SCREEN_OUT_INT" "$FLAG_YES" \
        && check_display_state "$SCREEN_OUT_EXT" "$FLAG_YES"
      ;;
    *)
      return 1
      ;;
  esac
}

# ==============================================================================
# usm_is_screen_detected
#
# Checks if a specific screen output is currently detected by the Wayland
# compositor using wlr-randr.
#
# Globals:
#   None
# Arguments:
#   $1 - target_screen: The name of the screen output (e.g. HDMI-A-1).
# Outputs:
#   None
# Returns:
#   0 if the screen is detected, 1 otherwise.
# ==============================================================================
usm_is_screen_detected() {
  local target_screen="$1"
  local ret=0

  wlr-randr 2>/dev/null \
    | awk '/^[a-zA-Z0-9_-]+/ {print $1}' \
    | grep -qx "$target_screen" || ret=$?

  return "$ret"
}

# ==============================================================================
# usm_is_screen_on
#
# Checks whether a specified Wayland output is currently enabled via wlr-randr.
#
# Globals:
#   None
# Arguments:
#   $1 - target_screen: The name of the screen output (e.g. HDMI-A-1).
# Outputs:
#   None
# Returns:
#   0 if the screen is enabled, 1 otherwise.
# ==============================================================================
usm_is_screen_on() {
  local target_screen="$1"
  local is_target_screen_enabled
  local wlr_out
  wlr_out=$(wlr-randr 2>/dev/null || true)
  is_target_screen_enabled=$(
    printf '%s\n' "$wlr_out" | awk -v sc="$target_screen" '
      $1 == sc { found = 1 }
      found && $1 == "Enabled:" { print $2; exit }
    ' || true
  )
  if [[ "$is_target_screen_enabled" == "$FLAG_YES" ]]; then
    return 0
  else
    return 1
  fi
}

# ==============================================================================
# usm_get_current_usm_mode
#
# Determines the current display mode by checking hardware connectivity via
# wlr-randr and combining it with the configured USM_MODE target.
#
# Globals:
#   SCREEN_OUT_EXT
#   SCREEN_OUT_INT
#   USM_MODE
#   MODE_EXT
#   MODE_DUAL
#   MODE_INT
# Arguments:
#   None
# Outputs:
#   Writes the resulting mode string to stdout ("ext", "dual", "int", "none").
# Returns:
#   0 on success.
# ==============================================================================
usm_get_current_usm_mode() {
  local has_ext=1
  local has_int=1

  while read -r line; do
    if [[ "$line" =~ ^([a-zA-Z0-9_-]+) ]]; then
      local out="${BASH_REMATCH[1]}"
      if [[ "$out" == "$SCREEN_OUT_EXT" ]]; then
        has_ext=0
      elif [[ "$out" == "$SCREEN_OUT_INT" ]]; then
        has_int=0
      fi
    fi
  done < <(wlr-randr 2>/dev/null || true)

  if [[ $has_ext -eq 0 ]]; then
    if [[ "${USM_MODE:-$CONF_MODE_SINGLE}" == "$CONF_MODE_SINGLE" ]]; then
      printf "%s\n" "$MODE_EXT"
    else
      printf "%s\n" "$MODE_DUAL"
    fi
  elif [[ $has_int -eq 0 ]]; then
    printf "%s\n" "$MODE_INT"
  else
    printf "%s\n" "$MODE_NONE"
  fi
}

# ==============================================================================
# usm_hw_screen_on
#
# Hardware level function to prepare the screen prior to Wayland engagement.
# Strictly controls sysfs and DRM states to ensure display hardware is lit
# before the compositor starts rendering.
#
# Globals:
#   USM_ENABLE_HW_POWER_CONTROL
#   BRIGHTNESS_MAX
#   SCREEN_OUT_INT
#   SCREEN_OUT_EXT
# Arguments:
#   $1 - target: "DSI" or "HDMI"
# Outputs:
#   Writes to hardware sysfs and logs execution.
# Returns:
#   0 on success.
# ==============================================================================
usm_hw_screen_on() {
  local target="$1"
  if [[ "${USM_ENABLE_HW_POWER_CONTROL:-false}" != "true" ]]; then
    return 0
  fi

  if [[ "$target" == "DSI" ]]; then
    local bl_path fb_path bl_val
    bl_path=$(_get_backlight_path)
    fb_path=$(_get_fb_path)
    if [[ -n "$bl_path" ]] && [[ -f "$bl_path/bl_power" ]]; then
      bl_val=$(cat "$bl_path/bl_power" 2>/dev/null || echo "")
      if [[ "$bl_val" == "$SYSFS_BACKLIGHT_POWER_OFF" ]]; then
        log "Hardware ON Sequence for DSI"
        if [[ -n "$fb_path" ]]; then
          log "HW write: $SYSFS_FRAMEBUFFER_UNBLANK (UNBLANK) -> $fb_path/blank"
          set_sysfs_val "$fb_path/blank" "$SYSFS_FRAMEBUFFER_UNBLANK"
        else
          log "Skip DSI ON: fb0/blank path missing."
        fi
        log "HW write: $SYSFS_BACKLIGHT_POWER_ON (ON) -> $bl_path/bl_power"
        set_sysfs_val "$bl_path/bl_power" "$SYSFS_BACKLIGHT_POWER_ON"

        local dsi_stat
        dsi_stat=$(
          find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_INT}" \
            2>/dev/null | head -n 1
        )
        if [[ -n "$dsi_stat" ]]; then
          log "HW write: detect (FORCE DETECT) -> $dsi_stat/status"
          set_sysfs_val "$dsi_stat/status" "detect"
        else
          log "Skip DSI ON: DRM status node missing."
        fi

        usm_set_int_screen_brightness "$BRIGHTNESS_MAX"
      else
        local msg="Skip DSI ON: bl_power='$bl_val'."
        log "$msg Expected: $SYSFS_BACKLIGHT_POWER_OFF (OFF)."
      fi
    else
      log "Skip DSI ON: bl_power path missing."
    fi
  elif [[ "$target" == "HDMI" ]]; then
    log "Hardware ON Sequence for HDMI"
    local hdmi_stat
    hdmi_stat=$(
      find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_EXT}" \
        2>/dev/null | head -n 1
    )
    if [[ -n "$hdmi_stat" ]]; then
      log "HW write: detect (FORCE DETECT) -> $hdmi_stat/status"
      set_sysfs_val "$hdmi_stat/status" "detect"
    else
      log "Skip HDMI ON: DRM status node missing."
    fi
  fi
}

# ==============================================================================
# usm_hw_screen_off
#
# Hardware level function to cut off power to the screen after Wayland releases
# it. Properly unbinds DRM states to avoid race conditions.
#
# Globals:
#   USM_ENABLE_HW_POWER_CONTROL
#   USM_HDMI_DRM_FORCE_OFF
#   SCREEN_OUT_INT
#   SCREEN_OUT_EXT
# Arguments:
#   $1 - target: "DSI" or "HDMI"
# Outputs:
#   Writes to hardware sysfs and logs execution.
# Returns:
#   0 on success.
# ==============================================================================
usm_hw_screen_off() {
  local target="$1"
  if [[ "${USM_ENABLE_HW_POWER_CONTROL:-false}" != "true" ]]; then
    return 0
  fi

  if [[ "$target" == "DSI" ]]; then
    local bl_path fb_path bl_val
    bl_path=$(_get_backlight_path)
    fb_path=$(_get_fb_path)
    if [[ -n "$bl_path" ]] && [[ -f "$bl_path/bl_power" ]]; then
      bl_val=$(cat "$bl_path/bl_power" 2>/dev/null || echo "")
      if [[ "$bl_val" == "$SYSFS_BACKLIGHT_POWER_ON" ]]; then
        log "Hardware OFF Sequence for DSI"
        local dsi_stat
        dsi_stat=$(
          find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_INT}" \
            2>/dev/null | head -n 1
        )
        if [[ -n "$dsi_stat" ]]; then
          log "HW write: off (FORCE OFF) -> $dsi_stat/status"
          set_sysfs_val "$dsi_stat/status" "off"
        else
          log "Skip DSI OFF: DRM status node missing."
        fi

        if [[ -n "$fb_path" ]]; then
          log "HW write: $SYSFS_FRAMEBUFFER_BLANK (BLANK) -> $fb_path/blank"
          set_sysfs_val "$fb_path/blank" "$SYSFS_FRAMEBUFFER_BLANK"
        else
          log "Skip DSI OFF: fb0/blank path missing."
        fi
        log "HW write: $SYSFS_BACKLIGHT_POWER_OFF (OFF) -> $bl_path/bl_power"
        set_sysfs_val "$bl_path/bl_power" "$SYSFS_BACKLIGHT_POWER_OFF"

        usm_set_int_screen_brightness "$BRIGHTNESS_OFF"
      else
        local msg="Skip DSI OFF: bl_power='$bl_val'."
        log "$msg Expected: $SYSFS_BACKLIGHT_POWER_ON (ON)."
      fi
    else
      log "Skip DSI OFF: bl_power path missing."
    fi
  elif [[ "$target" == "HDMI" ]]; then
    if [[ "${USM_HDMI_DRM_FORCE_OFF:-false}" == "true" ]]; then
      log "Hardware OFF Sequence for HDMI (DRM status=off, HPD disabled)"
      local hdmi_stat
      hdmi_stat=$(
        find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_EXT}" \
          2>/dev/null | head -n 1
      )
      if [[ -n "$hdmi_stat" ]]; then
        log "HW write: off (FORCE OFF) -> $hdmi_stat/status"
        set_sysfs_val "$hdmi_stat/status" "off"
      else
        log "Skip HDMI OFF: DRM status node missing."
      fi
    else
      # Bypass DRM 'off' for HDMI to preserve Hot Plug Detect (HPD).
      log "Hardware OFF for HDMI bypassed to preserve udev HPD events."
    fi
  fi
}

# ==============================================================================
# _get_backlight_path
#
# Helper function to find the sysfs path for the internal screen backlight.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes the backlight path to stdout.
# Returns:
#   Always 0.
# ==============================================================================
_get_backlight_path() {
  find /sys/class/backlight \
    -maxdepth 1 -mindepth 1 2>/dev/null \
    | head -n 1 || true
}

# ==============================================================================
# _get_fb_path
#
# Helper function to find the sysfs path for the internal screen framebuffer.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes the framebuffer path to stdout.
# Returns:
#   Always 0.
# ==============================================================================
_get_fb_path() {
  find /sys/class/graphics -name "fb0" \
    2>/dev/null | head -n 1 || true
}

# ==============================================================================
# usm_set_int_screen_brightness
#
# Forces the internal screen brightness to a specific numeric value.
#
# Globals:
#   None
# Arguments:
#   $1 - target_brightness: Numeric brightness value (e.g. BRIGHTNESS_MAX).
# Outputs:
#   None
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
usm_set_int_screen_brightness() {
  local target_brightness="$1"
  local bl_path
  bl_path=$(_get_backlight_path)
  if [[ -n "$bl_path" ]]; then
    log "Hardware write: $target_brightness -> $bl_path/brightness"
    set_sysfs_val "$bl_path/brightness" "$target_brightness" \
      2>/dev/null || true
  fi
}





################################################################################
# 4. Wayland & Swayidle
################################################################################

# ==============================================================================
# _build_wlr_internal_cmd
#
# Helper function to build the wlr-randr internal screen parameters.
#
# Globals:
#   SCREEN_ENABLED_SKIP, SCREEN_OUT_INT, SCREEN_ENABLED_YES,
#   SCREEN_RES_720_1280, SCREEN_TRANS_RIGHT, SCREEN_POS_INT
# Arguments:
#   $1 - int_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO or SKIP
#   $2 - has_int: 0 if detected, 1 if not
#   $3 - int_ref_cmd: nameref to the array holding the command
# Outputs:
#   Writes logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
_build_wlr_internal_cmd() {
  local int_enabled="$1"
  local has_int="$2"
  local -n int_ref_cmd="$3"

  if [[ "$int_enabled" == "$SCREEN_ENABLED_SKIP" ]]; then
    log "Internal screen ($SCREEN_OUT_INT) config explicitly skipped."
  elif [[ "$has_int" -eq 0 ]]; then
    local int_state="--off"
    if [[ "$int_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      int_state="--on"
    fi

    int_ref_cmd+=(
      "--output" "$SCREEN_OUT_INT"
      "$int_state"
      "--mode" "$SCREEN_RES_720_1280"
      "--transform" "$SCREEN_TRANS_RIGHT"
      "--pos" "$SCREEN_POS_INT"
    )
    log "Internal screen ($SCREEN_OUT_INT) config added."
  else
    log "Internal screen ($SCREEN_OUT_INT) not detected. Skipped."
  fi
  return 0
}

# ==============================================================================
# _build_wlr_external_cmd
#
# Helper function to build the wlr-randr external screen parameters.
#
# Globals:
#   SCREEN_ENABLED_SKIP, SCREEN_OUT_EXT, SCREEN_ENABLED_YES,
#   SCREEN_TRANS_NORMAL, SCREEN_POS_EXT
# Arguments:
#   $1 - ext_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO or SKIP
#   $2 - has_ext: 0 if detected, 1 if not
#   $3 - ext_mode: The resolution/mode to apply
#   $4 - ext_ref_cmd: nameref to the array holding the command
# Outputs:
#   Writes logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
_build_wlr_external_cmd() {
  local ext_enabled="$1"
  local has_ext="$2"
  local ext_mode="$3"
  local -n ext_ref_cmd="$4"

  if [[ "$ext_enabled" == "$SCREEN_ENABLED_SKIP" ]]; then
    log "External screen ($SCREEN_OUT_EXT) config explicitly skipped."
  elif [[ "$has_ext" -eq 0 ]]; then
    local ext_state="--off"
    if [[ "$ext_enabled" == "$SCREEN_ENABLED_YES" ]]; then
      ext_state="--on"
    fi

    ext_ref_cmd+=(
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
  return 0
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
#   SCREEN_RES_720_1280
#   SCREEN_TRANS_RIGHT
#   SCREEN_POS_INT
#   SCREEN_POS_EXT
#   SCREEN_TRANS_NORMAL
# Arguments:
#   $1 - int_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   $2 - ext_enabled: SCREEN_ENABLED_YES or SCREEN_ENABLED_NO
#   $3 - ext_mode: SCREEN_RES_1024_768, SCREEN_RES_2560_1440, etc.
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
exec_wlr_randr() {
  local int_enabled="$1"
  local ext_enabled="$2"
  local ext_mode="$3"

  auto_update_wayland_display

  local full_cmd=(wlr-randr)
  local wlr_output
  local rc_wlr=0
  wlr_output=$(wlr-randr 2>&1) || rc_wlr=$?

  if [[ $rc_wlr -ne 0 ]]; then
    local err_msg="Error: wlr-randr failed to connect to display "
    err_msg+="(exit code: $rc_wlr, output: $wlr_output)"
    log "$err_msg"
    return 1
  fi

  local active_outputs=()
  mapfile -t active_outputs < <(
    printf "%s\n" "$wlr_output" \
      | grep -E "^[a-zA-Z0-9_-]+" \
      | awk '{print $1}'
  )

  local has_int=1
  local has_ext=1
  local noop_output=""
  local o
  for o in "${active_outputs[@]}"; do
    if [[ "$o" == "$SCREEN_OUT_INT" ]]; then
      has_int=0
    elif [[ "$o" == "$SCREEN_OUT_EXT" ]]; then
      has_ext=0
    elif [[ "$o" =~ ^NOOP ]]; then
      noop_output="$o"
    fi
  done

  log "Detected outputs: ${active_outputs[*]}"

  _build_wlr_internal_cmd "$int_enabled" "$has_int" full_cmd
  _build_wlr_external_cmd "$ext_enabled" "$has_ext" "$ext_mode" full_cmd

  # Prevent blackout: do not disable internal screen if requested external
  # screen is missing.
  if [[ "$ext_enabled" == "$SCREEN_ENABLED_YES" && \
        "$has_ext" -ne 0 && \
        "$int_enabled" == "$SCREEN_ENABLED_NO" ]]; then
    local err_msg="Error: External screen ($SCREEN_OUT_EXT) requested ON but "
    err_msg+="not detected. Aborting to prevent blackout."
    log "$err_msg"
    return 1
  fi

  if (( ${#full_cmd[@]} == 1 )); then
    log "Error: No target outputs configured. Aborting."
    return 1
  fi

  # Pre-cleanup: Gracefully disable placeholder output (NOOP) if present
  # to prevent coordinate overlap conflicts.
  if [[ -n "$noop_output" ]]; then
    log "Pre-cleanup: Disabling placeholder output $noop_output..."
    wlr-randr --output "$noop_output" --off >/dev/null 2>&1 || true
  fi

  log "Final command: ${full_cmd[*]}"

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
# _test_wayland_socket
#
# Tests if a given Wayland socket is active by running wlr-randr against it.
#
# Globals:
#   None
# Arguments:
#   $1 - socket_name (e.g., wayland-0)
# Outputs:
#   Writes a probing log to standard output.
# Returns:
#   0 if the socket is alive, 1 otherwise.
# ==============================================================================
_test_wayland_socket() {
  local socket="$1"
  log "Probing socket: $socket..."
  WAYLAND_DISPLAY="$socket" wlr-randr >/dev/null 2>&1
}

# ==============================================================================
# _apply_wayland_socket
#
# Updates the system environment and notifies the user of the socket change.
#
# Globals:
#   WAYLAND_DISPLAY (Write)
# Arguments:
#   $1 - socket_name (e.g., wayland-0)
# Outputs:
#   Writes an application log to standard output.
#   Sends a desktop notification.
# Returns:
#   0 on normal completion.
# ==============================================================================
_apply_wayland_socket() {
  local socket="$1"
  log "Applying active socket: $socket..."
  export WAYLAND_DISPLAY="$socket"
  systemctl --user import-environment WAYLAND_DISPLAY 2>/dev/null || true
  notify-send "USM" "WAYLAND_DISPLAY auto-updated to $socket" \
    2>/dev/null || true
}

# ==============================================================================
# auto_update_wayland_display
#
# Automatically detects and updates WAYLAND_DISPLAY if the environment is out of
# sync. This function checks $XDG_RUNTIME_DIR for Wayland socket lock files.
#
# Principle:
# - Single lock: Fast path, blindly trusts and applies the socket.
# - Multiple locks: Probes current cache first; if dead, actively probes others
#   descendingly to prevent race conditions and connect to the living socket.
#
# Globals:
#   XDG_RUNTIME_DIR (Read)
#   WAYLAND_DISPLAY (Read/Write)
# Arguments:
#   None
# Outputs:
#   Writes status or warning logs to standard output.
# Returns:
#   0 on normal completion.
# ==============================================================================
auto_update_wayland_display() {
  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local lock_files=("$runtime_dir"/wayland-*.lock)
  local count="${#lock_files[@]}"

  # Guard 1: Zero locks
  if [[ "$count" -eq 0 || ! -e "${lock_files[0]}" ]]; then
    return 0
  fi

  # Guard 2: Single lock optimization
  if [[ "$count" -eq 1 ]]; then
    local socket_name
    socket_name=$(basename "${lock_files[0]%.lock}")
    if [[ "$WAYLAND_DISPLAY" != "$socket_name" ]]; then
      log "Single lock found. Trusting $socket_name."
      _apply_wayland_socket "$socket_name"
    fi
    return 0
  fi

  # Guard 3: Fast path cache validation
  log "Validating current cache: ${WAYLAND_DISPLAY:-<unset>}"
  if [[ -n "$WAYLAND_DISPLAY" ]] && \
     _test_wayland_socket "$WAYLAND_DISPLAY"; then
    log "Cache valid."
    return 0
  fi

  # Main logic: Active probing for multiple locks
  # Reverse sort the array to prioritize newer sockets (e.g., wayland-1)
  mapfile -t lock_files < <(printf "%s\n" "${lock_files[@]}" | sort -r)

  local socket_name
  for lock_file in "${lock_files[@]}"; do
    socket_name=$(basename "${lock_file%.lock}")
    if _test_wayland_socket "$socket_name"; then
      _apply_wayland_socket "$socket_name"
      return 0
    fi
  done

  # Fallback: All probed sockets are dead
  log "Error: All sockets dead."
}

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
# try_systemd_run
#
# Attempts to execute the given swayidle command via systemd-run.
# Uses timeout to prevent the command from hanging indefinitely during
# system shutdown when D-Bus might be unresponsive.
#
# Globals:
#   None
# Arguments:
#   $1 - swayidle_cmd: The command string to execute.
# Outputs:
#   None
# Returns:
#   0 if systemd-run exists and executes successfully, 1 otherwise.
# ==============================================================================
try_systemd_run() {
  local swayidle_cmd="$1"
  command -v systemd-run >/dev/null 2>&1 || return 1
  local systemd_args=(--user)
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    systemd_args+=(--setenv="WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
  fi
  timeout "$SYSTEMD_RUN_TIMEOUT_SEC" systemd-run \
    "${systemd_args[@]}" bash -c "$swayidle_cmd" 2>/dev/null
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
  swayidle_cmd=$(
    printf '%s' "$swayidle_cmd" | sed 's/[[:space:]]*&[[:space:]]*$//'
  )
  if [[ -z "$swayidle_cmd" ]]; then
    log "No swayidle command found in $autostart_file"
    return 0
  fi

  log "Executing via systemd-run: $swayidle_cmd"
  if ! try_systemd_run "$swayidle_cmd"; then
    log "Warning: Falling back to nohup to start swayidle"
    nohup bash -c "$swayidle_cmd" >/dev/null 2>&1 &
  fi
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
#   $1 - hdmi_state: The current HDMI state.
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


################################################################################
# 5. Audio Management
################################################################################


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
#   $1 - id: The PipeWire device ID to query.
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


################################################################################
# 6. Event Handlers
################################################################################


# ==============================================================================
# run_hook
#
# Executes a hook script in the background if hooks are enabled and the
# script file exists and is executable.
#
# Globals:
#   USM_HOOKS_ENABLE
# Arguments:
#   $1 - hook_name: The filename of the hook script.
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
    log "Executing hook: $1"
    "$hook_file"
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
update_display_by_hdmi_state() {
  local current_hdmi_state
  current_hdmi_state=$(check_hdmi_state)

  manage_swayidle "$current_hdmi_state"

  # Find the needed screen mode
  local target_screen_mode="$MODE_INT"
  if [[ "$current_hdmi_state" == "$STATE_HDMI_CONN" ]]; then
    if [[ "${USM_MODE:-$CONF_MODE_SINGLE}" == "$CONF_MODE_SINGLE" ]]; then
      target_screen_mode="$MODE_EXT"
    else
      target_screen_mode="$MODE_DUAL"
    fi
  fi

  # Stop if state has not changed and display matches target mode
  if [[ "$current_hdmi_state" == "$LAST_STATE" ]] \
    && is_state_matching "$target_screen_mode"; then
    return 0
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
    if [[ "${USM_MODE:-$CONF_MODE_SINGLE}" == "$CONF_MODE_SINGLE" ]]; then
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
  touch "$USM_RUN_DIR/usm_suspending.lock"
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
  rm -f "$USM_RUN_DIR/usm_suspending.lock"
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
#   DSI_POLL_INTERVAL_SEC
#   DSI_POLL_MAX_ATTEMPTS
#   DSI_POLL_TIMEOUT_SEC
#   LAST_STATE
#   SCREEN_OUT_INT
#   STATE_HDMI_DISC
#   USM_RUN_DIR
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success.
# ==============================================================================
handle_event_udev() {
  if [[ -f "$USM_RUN_DIR/usm_suspending.lock" ]]; then
    log "Ignoring event due to suspend/resume"
    return 0
  fi

  local current_state
  current_state=$(check_hdmi_state)

  if [[ "$current_state" == "$LAST_STATE" ]]; then
    log "DRM change event: state unchanged ($current_state). Ignored."
    return 0
  fi

  # Handle HDMI disconnect (unplug):
  # Poll Wayland for internal display (DSI) to appear, then switch immediately.
  if [[ "$current_state" == "$STATE_HDMI_DISC" ]]; then
    log "HDMI unplug detected. Polling Wayland for $SCREEN_OUT_INT..."
    local attempt=0
    local dsi_ready=false

    while (( attempt < DSI_POLL_MAX_ATTEMPTS )); do
      if wlr-randr 2>/dev/null | grep -q "^$SCREEN_OUT_INT"; then
        dsi_ready=true
        log "$SCREEN_OUT_INT detected on attempt $((attempt + 1))."
        break
      fi
      sleep "$DSI_POLL_INTERVAL_SEC"
      ((attempt++))
    done

    if [[ "$dsi_ready" != "true" ]]; then
      local warn_msg="Warning: $SCREEN_OUT_INT not found after "
      warn_msg+="${DSI_POLL_TIMEOUT_SEC}s timeout. Proceeding with switch..."
      log "$warn_msg"
    fi

    update_display_by_hdmi_state
    return 0
  fi

  # Handle HDMI connect (plug-in):
  # Debounce to allow EDID handshake and modes to stabilize.
  log "HDMI plug-in detected. Initiating ${DEBOUNCE_SEC}s debounce..."
  sleep "$DEBOUNCE_SEC"

  current_state=$(check_hdmi_state)
  log "Debounce wait finished. Re-verified state: $current_state"

  if [[ "$current_state" != "$LAST_STATE" ]]; then
    update_display_by_hdmi_state
  else
    log "State unchanged after debounce. Ignored."
  fi
}


################################################################################
# 7. CLI Commands
################################################################################


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
# cmd_screen_int
#
# Sets the display to internal screen only. Uses a fallback sequence if
# the first try fails.
#
# Globals:
#   SCREEN_ENABLED_YES
#   SCREEN_ENABLED_NO
#   SCREEN_RES_2560_1440
#   SCREEN_RES_1024_768
#   RETRY_DELAY_SEC
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
#
# Flow:
#   [usm_hw_screen_on] --> [wlr-randr: target mode] --> [usm_hw_screen_off]
#
# Hardware must be powered on before Wayland configures the DRM connector.
# ==============================================================================
cmd_screen_int() {
  log "Starting cmd_screen_int."
  local ret=0

  usm_hw_screen_on "DSI"

  if [[ "${USM_ENABLE_HW_POWER_CONTROL:-false}" == "true" ]] && \
     ! usm_is_screen_detected "$SCREEN_OUT_INT"; then
    log "Waiting for $SCREEN_OUT_INT to appear in wlr-randr..."
    local attempt=0
    while (( attempt < DSI_POLL_MAX_ATTEMPTS )); do
      if usm_is_screen_detected "$SCREEN_OUT_INT"; then
        log "$SCREEN_OUT_INT detected on attempt $((attempt + 1))."
        break
      fi
      sleep "$DSI_POLL_INTERVAL_SEC"
      attempt=$((attempt + 1))
    done
  fi

  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_RES_2560_1440" || ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    usm_hw_screen_off "HDMI"
    notify_user "Internal Screen Enabled"
    log "Successfully set to internal screen."
    return 0
  fi

  sleep "$RETRY_DELAY_SEC"
  log "First try failed. Starting fallback sequence."

  if usm_is_screen_on "$SCREEN_OUT_EXT"; then
    log "Fallback: Turning off external screen..."
    exec_wlr_randr \
      "$SCREEN_ENABLED_SKIP" \
      "$SCREEN_ENABLED_NO" \
      "$SCREEN_RES_1024_768" || true
  fi

  if usm_is_screen_on "$SCREEN_OUT_INT"; then
    log "Fallback: Turning off internal screen temporarily..."
    exec_wlr_randr \
      "$SCREEN_ENABLED_NO" \
      "$SCREEN_ENABLED_SKIP" \
      "$SCREEN_RES_1024_768" || true
  fi

  log "Fallback: Enabling internal screen..."
  ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_SKIP" \
    "$SCREEN_RES_1024_768" || ret=$?

  if [[ $ret -eq 0 ]]; then
    usm_hw_screen_off "HDMI"
  fi
  log "Fallback internal enable returned: $ret"
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
#   SCREEN_RES_2560_1440
#   RETRY_DELAY_SEC
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

  usm_hw_screen_on "HDMI"

  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_RES_2560_1440" || ret=$?
  log "First exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    usm_hw_screen_off "DSI"
    notify_user "External Screen Enabled"
    log "Successfully set to external screen."
    return 0
  fi

  log "First try failed. Waiting before fallback."
  sleep "$RETRY_DELAY_SEC"

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
#   SCREEN_RES_1024_768
#   SCREEN_RES_2560_1440
#   RETRY_DELAY_SEC
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
#
# Flow:
#   [usm_hw_screen_on] --> [wlr-randr: target mode]
#
# Hardware must be powered on before Wayland configures the DRM connector.
# ==============================================================================
cmd_screen_dual() {
  log "Starting cmd_screen_dual."
  local ret=0

  usm_hw_screen_on "DSI"
  usm_hw_screen_on "HDMI"

  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_RES_1024_768" || ret=$?
  log "Applied safe mode for dual screen (ret: $ret)."

  sleep "$RETRY_DELAY_SEC"
  log "Waiting completed. Applying target mode."

  ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_ENABLED_YES" \
    "$SCREEN_RES_2560_1440" || ret=$?
  log "Second exec_wlr_randr returned: $ret"

  if [[ $ret -eq 0 ]]; then
    notify_user "Dual Screen Enabled"
    log "Successfully set to dual screen."
    return 0
  fi

  log "Dual screen setup failed. Waiting before fallback."
  sleep "$RETRY_DELAY_SEC"

  log "Starting fallback to internal screen."
  ret=0
  cmd_screen_int || ret=$?
  log "Fallback cmd_screen_int returned: $ret"
  return "$ret"
}

# ==============================================================================
# cmd_screen_off
#
# Disables the internal screen, but only if the external screen is disconnected
# or disabled. Aborts if the external screen is active.
#
# Globals:
#   SCREEN_ENABLED_NO
#   SCREEN_ENABLED_SKIP
#   SCREEN_RES_1024_768
#   SCREEN_OUT_EXT
#   SCREEN_OUT_INT
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_off() {
  log "Starting cmd_screen_off."

  # Check if external screen is enabled; if so, disallow screen-off
  if usm_is_screen_on "$SCREEN_OUT_EXT"; then
    log "External screen is active. screen-off is not allowed."
    notify_user "Screen-off disabled in Dual/Ext mode."
    return 1
  fi

  # Check internal screen state
  local int_on=1
  usm_is_screen_on "$SCREEN_OUT_INT" && int_on=0

  if [[ $int_on -eq 1 ]]; then
    log "Internal screen is already off. Expected state matched. Skip."
    return 0
  fi

  # Turn off internal screen and explicitly skip external screen
  local ret=0
  exec_wlr_randr \
    "$SCREEN_ENABLED_NO" \
    "$SCREEN_ENABLED_SKIP" \
    "$SCREEN_RES_1024_768" || ret=$?

  if [[ $ret -eq 0 ]]; then
    # Completely cut off internal screen power and backlight
    usm_hw_screen_off "DSI"
    notify_user "Screen Turned Off"
    log "Successfully turned off internal screen."
  else
    log "Failed to turn off screen. (ret: $ret)"
  fi
  return "$ret"
}

# ==============================================================================
# cmd_screen_reset
#
# Safely resets the DSI panel state machine by coordinating Wayland
# and kernel driver hotplugging to avoid compositor crashes.
# Prints recent cwu50 driver errors before prompting for confirmation.
#
# Globals:
#   FLAG_SILENT
#   PANEL_DRIVER_PATH
#   SCREEN_OUT_INT
# Arguments:
#   $1 - mode: Set to $FLAG_SILENT to bypass the confirmation prompt.
# Outputs:
#   Writes unbind/bind commands to sysfs and logs progress to stdout.
# Returns:
#   0 on success, 1 on error if no DSI device is found or user aborts.
# ==============================================================================
cmd_screen_reset() {
  local mode="${1:-}"
  log "Starting cmd_screen_reset (Safe DSI Hotplug Sequence)."
  local dsi_dev
  local dsi_match=("$PANEL_DRIVER_PATH"/*.dsi.*)
    if [[ -e "${dsi_match[0]}" ]]; then
      dsi_dev=$(basename "${dsi_match[0]}")
    else
      dsi_dev=""
    fi

  if [[ -z "$dsi_dev" ]]; then
    log "Error: No DSI device found in $PANEL_DRIVER_PATH."
    return 1
  fi

  if [[ "$mode" != "$FLAG_SILENT" ]]; then
    printf "Recent cwu50 driver errors:\n"
    dmesg | grep "cwu50" | grep -i "failed to" | tail -n 10 || \
      printf "  (No 'failed to' errors found)\n"
    printf "\n"

    local confirm
    read -r -p "Reset the DSI panel state? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY])
        ;;
      *)
        log "cmd_screen_reset aborted by user."
        return 1
        ;;
    esac
  fi

  log "1. Soft Disconnect: Releasing Wayland output $SCREEN_OUT_INT..."
  wlr-randr --output "$SCREEN_OUT_INT" --off
  sleep 1

  log "2. Hard Disconnect: Unbinding driver for $dsi_dev..."
  echo "$dsi_dev" | sudo tee "$PANEL_DRIVER_PATH/unbind" > /dev/null
  sleep 1

  log "3. Hard Reconnect: Binding driver to force init sequence..."
  echo "$dsi_dev" | sudo tee "$PANEL_DRIVER_PATH/bind" > /dev/null
  sleep 1

  log "4. Soft Reconnect: Resuming Wayland output $SCREEN_OUT_INT..."
  wlr-randr --output "$SCREEN_OUT_INT" --on
  log "cmd_screen_reset completed."
  return 0
}

# ==============================================================================
# cmd_screen_on
#
# Enables screens based on detected hardware via wlr-randr and the configured
# USM_MODE. Falls back to internal screen if external is not found.
#
# Globals:
#   SCREEN_OUT_EXT
#   SCREEN_OUT_INT
#   USM_MODE
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_on() {
  log "Starting cmd_screen_on."

  auto_update_wayland_display
  if ! wlr-randr >/dev/null 2>&1; then
    log "Error: wlr-randr failed to connect to Wayland compositor."
    return 1
  fi

  local cur_mode
  cur_mode=$(usm_get_current_usm_mode)

  local int_on=1
  usm_is_screen_on "$SCREEN_OUT_INT" && int_on=0
  local ext_on=1
  usm_is_screen_on "$SCREEN_OUT_EXT" && ext_on=0

  if usm_is_screen_detected "$SCREEN_OUT_EXT"; then
    if [[ "${USM_MODE:-$CONF_MODE_SINGLE}" == "$CONF_MODE_SINGLE" ]]; then
      if [[ "$cur_mode" == "$MODE_EXT" && \
            $ext_on -eq 0 && $int_on -eq 1 ]]; then
        log "Screen state already matches expected (ext only). Skip."
        return 0
      fi
      log "External screen detected. Applying single mode (ext)."
      cmd_screen_ext
      return "$?"
    else
      if [[ "$cur_mode" == "$MODE_DUAL" && \
            $ext_on -eq 0 && $int_on -eq 0 ]]; then
        log "Screen state already matches expected (dual). Skip."
        return 0
      fi
      log "External screen detected. Applying dual mode."
      cmd_screen_dual
      return "$?"
    fi
  elif usm_is_screen_detected "$SCREEN_OUT_INT"; then
    if [[ "$cur_mode" == "$MODE_INT" && $int_on -eq 0 && $ext_on -eq 1 ]]; then
      log "Screen state already matches expected (int only). Skip."
      return 0
    fi
    log "Only internal screen detected. Applying internal mode."
    cmd_screen_int
    return "$?"
  else
    log "No active outputs in wlr-randr. Attempting internal screen recovery."
    cmd_screen_int
    return "$?"
  fi
}

# ==============================================================================
# cmd_screen_switch
#
# Toggles the screen state. If the external screen is on, the action is
# disabled. Otherwise, if the internal screen is on, it calls cmd_screen_off;
# if it is off, it calls cmd_screen_on.
#
# Globals:
#   SCREEN_OUT_EXT
#   SCREEN_OUT_INT
# Arguments:
#   None
# Outputs:
#   Writes execution logs to stdout/log file.
# Returns:
#   0 on success, 1 on failure.
# ==============================================================================
cmd_screen_switch() {
  log "Starting cmd_screen_switch."

  local ext_on=1
  usm_is_screen_on "$SCREEN_OUT_EXT" && ext_on=0

  if [[ $ext_on -eq 0 ]]; then
    log "External screen is active. screen-switch is disabled."
    notify_user "Screen-switch disabled in Dual/Ext mode."
    return 1
  fi

  local int_on=1
  usm_is_screen_on "$SCREEN_OUT_INT" && int_on=0

  if [[ $int_on -eq 0 ]]; then
    log "Internal screen is on (and external is off). Calling cmd_screen_off."
    cmd_screen_off
  else
    log "Internal screen is off (and external is off). Calling cmd_screen_on."
    cmd_screen_on
  fi
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

# ==============================================================================
# _print_hw_internal_screen
#
# Helper function to print internal hardware screen status.
#
# Globals:
#   SCREEN_OUT_INT, PANEL_DRIVER_PATH, SYSFS_BACKLIGHT_POWER_ON
#   SYSFS_BACKLIGHT_POWER_OFF, SYSFS_FRAMEBUFFER_UNBLANK,
#   SYSFS_FRAMEBUFFER_BLANK
# Arguments:
#   $1 - fb_int: internal framebuffer path
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success.
# ==============================================================================
_print_hw_internal_screen() {
  local dsi_stat bl_path bl_val fb_name fb_blank fb_mean \
        st_mean fb_state fb_int
  fb_int="$1"

  printf "\n[Internal Screen: %s]\n" "$SCREEN_OUT_INT"
  if [[ -d "$PANEL_DRIVER_PATH" ]]; then
    printf "  Panel Driver: Loaded (%s)\n" "$(basename "$PANEL_DRIVER_PATH")"
  else
    printf "  Panel Driver: Not Loaded\n"
  fi

  dsi_stat=$(find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_INT}" \
    2>/dev/null | head -n 1)
  if [[ -n "$dsi_stat" ]] && [[ -f "$dsi_stat/status" ]]; then
    printf "  DRM Status: %s\n" \
      "$(cat "$dsi_stat/status" 2>/dev/null || printf "%s\n" "error")"
  else
    printf "  DRM Status: Not Found\n"
  fi

  bl_path=$(_get_backlight_path)
  if [[ -n "$bl_path" ]]; then
    if [[ -f "$bl_path/bl_power" ]]; then
      bl_val=$(cat "$bl_path/bl_power" 2>/dev/null)
      bl_mean="Unknown"
      [[ "$bl_val" == "$SYSFS_BACKLIGHT_POWER_ON" ]] && bl_mean="ON"
      [[ "$bl_val" == "$SYSFS_BACKLIGHT_POWER_OFF" ]] && bl_mean="OFF"
      printf "  Backlight Power: %s (%s)\n" "$bl_val" "$bl_mean"
    fi
    if [[ -f "$bl_path/brightness" ]]; then
      printf "  Backlight Brightness: %s\n" \
        "$(cat "$bl_path/brightness" 2>/dev/null)"
    fi
  else
    printf "  Backlight: Not Found\n"
  fi

  if [[ -n "$fb_int" ]]; then
    fb_name=$(cat "$fb_int/name")
    fb_blank=$(cat "$fb_int/blank" 2>/dev/null)
    [[ -z "$fb_blank" ]] && fb_blank="N/A"
    fb_mean=""
    [[ "$fb_blank" == "$SYSFS_FRAMEBUFFER_UNBLANK" ]] && fb_mean=" (UNBLANK/ON)"
    [[ "$fb_blank" == "$SYSFS_FRAMEBUFFER_BLANK" ]] || \
      [[ "$fb_blank" == "4" ]] && fb_mean=" (BLANK/OFF)"
    printf "  Framebuffer Blank (%s): %s%s\n" "$fb_name" "$fb_blank" "$fb_mean"

    fb_state=$(cat "$fb_int/state" 2>/dev/null)
    [[ -z "$fb_state" ]] && fb_state="N/A"
    st_mean=""
    [[ "$fb_state" == "0" ]] && st_mean=" (Normal/Running)"
    [[ "$fb_state" == "1" ]] && st_mean=" (Suspended)"
    printf "  Framebuffer State (%s): %s%s\n" "$fb_name" "$fb_state" "$st_mean"
  fi
}

# ==============================================================================
# _print_hw_external_screen
#
# Helper function to print external hardware screen status.
#
# Globals:
#   SCREEN_OUT_EXT, SYSFS_FRAMEBUFFER_UNBLANK, SYSFS_FRAMEBUFFER_BLANK
# Arguments:
#   $1 - fb_ext: external framebuffer path
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success.
# ==============================================================================
_print_hw_external_screen() {
  local hdmi_stat fb_name fb_blank fb_mean st_mean fb_state fb_ext
  fb_ext="$1"

  printf "\n[External Screen: %s]\n" "$SCREEN_OUT_EXT"
  hdmi_stat=$(find /sys/class/drm -maxdepth 1 -name "card*-${SCREEN_OUT_EXT}" \
    2>/dev/null | head -n 1)
  if [[ -n "$hdmi_stat" ]]; then
    local card_name card_base driver_path
    card_name=$(basename "$hdmi_stat")
    card_base=${card_name%%-*}
    if [[ -e "/sys/class/drm/$card_base/device/driver" ]]; then
      driver_path=$(readlink -f "/sys/class/drm/$card_base/device/driver" \
        2>/dev/null)
      printf "  Display Driver: Loaded (%s)\n" "$(basename "$driver_path")"
    else
      printf "  Display Driver: Not Loaded\n"
    fi

    if [[ -f "$hdmi_stat/status" ]]; then
      printf "  DRM Status: %s\n" \
      "$(cat "$hdmi_stat/status" 2>/dev/null || printf "%s\n" "error")"
    else
      printf "  DRM Status: Not Found\n"
    fi
  else
    printf "  DRM Status: Not Found\n"
  fi

  if [[ -n "$fb_ext" ]]; then
    fb_name=$(cat "$fb_ext/name")
    fb_blank=$(cat "$fb_ext/blank" 2>/dev/null)
    [[ -z "$fb_blank" ]] && fb_blank="N/A"
    fb_mean=""
    [[ "$fb_blank" == "$SYSFS_FRAMEBUFFER_UNBLANK" ]] && fb_mean=" (UNBLANK/ON)"
    [[ "$fb_blank" == "$SYSFS_FRAMEBUFFER_BLANK" ]] || \
      [[ "$fb_blank" == "4" ]] && fb_mean=" (BLANK/OFF)"
    printf "  Framebuffer Blank (%s): %s%s\n" "$fb_name" "$fb_blank" "$fb_mean"

    fb_state=$(cat "$fb_ext/state" 2>/dev/null)
    [[ -z "$fb_state" ]] && fb_state="N/A"
    st_mean=""
    [[ "$fb_state" == "0" ]] && st_mean=" (Normal/Running)"
    [[ "$fb_state" == "1" ]] && st_mean=" (Suspended)"
    printf "  Framebuffer State (%s): %s%s\n" "$fb_name" "$fb_state" "$st_mean"
  fi
}

# ==============================================================================
# cmd_hw_status
#
# Prints real-time hardware status of panels, DRM, and backlight.
#
# Globals:
#   DRM_PATH, PANEL_DRIVER_PATH, SCREEN_*, SYSFS_*, AUDIO_DEVICE_HDMI
# Arguments:
#   None
# Outputs:
#   Writes hardware parameters to stdout.
# Returns:
#   0 on success.
# ==============================================================================
cmd_hw_status() {
  printf "%s\n" "--- Hardware Status ---"
  local fb_path fb_name
  local fb_int=""
  local fb_ext=""

  for fb_path in /sys/class/graphics/fb*; do
    [[ -e "$fb_path" ]] || continue
    fb_name=$(cat "$fb_path/name" 2>/dev/null || printf "%s\n" "Unknown")
    if [[ "$fb_name" == *"dsi"* ]]; then
      fb_int="$fb_path"
    elif [[ "$fb_name" == *"vc4"* ]]; then
      fb_ext="$fb_path"
    fi
  done

  _print_hw_internal_screen "$fb_int"
  _print_hw_external_screen "$fb_ext"

  cmd_hdmi_audio_state
  printf "\n-----------------------\n"
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
  local rc=0

  systemctl --user status "$SVC_NAME" \
    -n 10 -l --no-pager 2>/dev/null || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf "(Service not found or failed to load)\n"
  fi

  printf "\nCurrent Resolutions:\n"
  rc=0
  wlr-randr 2>/dev/null | awk '
    /^[^ ]/ { out=$1 }
    /current/ { print out ": " $1 " " $2 }
  ' || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf "(wlr-randr execution failed)\n"
  fi

  printf "\nRecent Service Logs:\n"
  rc=0
  journalctl --user-unit="$SVC_NAME" \
    -n 20 --no-pager || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf "No logs found.\n"
  fi
  printf "%s\n" "------------------"
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
cmd_monitor() {
  trap 'reload_config' SIGHUP
  trap 'cleanup_on_exit' EXIT INT TERM

  log "Starting monitor daemon..."
  run_hook "$HOOK_USM_START"
  wait_for_compositor
  update_display_by_hdmi_state

  init_hdmi_audio_default_async &

  setup_runtime_dir
  rm -f "$USM_RUN_DIR/usm_suspending.lock"

  FIFO_PATH="$USM_RUN_DIR/monitor_$$.fifo"
  rm -f "$FIFO_PATH" 2>/dev/null
  local fifo_err
  if ! fifo_err=$(mkfifo "$FIFO_PATH" 2>&1); then
    log "Error: Failed to create FIFO at $FIFO_PATH. Error: $fifo_err"
    if [[ "$USM_RUN_DIR" != "/tmp" ]]; then
      log "Warning: Attempting to create FIFO in /tmp as fallback."
      FIFO_PATH="/tmp/monitor_$$.fifo"
      rm -f "$FIFO_PATH" 2>/dev/null
      if ! fifo_err=$(mkfifo "$FIFO_PATH" 2>&1); then
        log "Error: Fallback FIFO failed. Error: $fifo_err"
        exit 1
      fi
    else
      exit 1
    fi
  fi

  local dbus_filter
  dbus_filter="type='signal',"
  dbus_filter+="interface='org.freedesktop.login1.Manager',"
  dbus_filter+="member='PrepareForSleep'"

  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL dbus-monitor --system "$dbus_filter" > "$FIFO_PATH" 2>/dev/null &
  else
    dbus-monitor --system "$dbus_filter" > "$FIFO_PATH" 2>/dev/null &
  fi
  DBUS_PID=$!

  udevadm monitor --subsystem=drm > "$FIFO_PATH" 2>/dev/null &
  UDEV_PID=$!

  while read -r line; do
    if [[ "$line" == *"boolean true"* ]]; then
      handle_event_suspend
    elif [[ "$line" == *"boolean false"* ]]; then
      handle_event_resume
    elif [[ "$line" =~ UDEV.*change ]]; then
      handle_event_udev
    fi
  done < "$FIFO_PATH"

  log "Error: Monitor loop unexpectedly closed (EOF). Exiting..."
  exit 1
}

# ==============================================================================
# cmd_service
#
# Runs a systemctl action (start, stop, restart) on the USM service.
#
# Globals:
#   SVC_NAME
# Arguments:
#   $1 - action: The systemctl action to run (e.g. start, stop, restart).
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


################################################################################
# 8. Main Entrypoint
################################################################################


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
  # Prevent duplicate execution during exit traps
  [[ -n "${_CLEANUP_DONE:-}" ]] && return
  _CLEANUP_DONE=1

  log "Monitor daemon terminating. Running cleanup..."
  run_hook "$HOOK_USM_STOP"
  [[ -z "${USM_RUN_DIR:-}" ]] || rm -f "$USM_RUN_DIR/usm_suspending.lock"

  [[ -z "${DBUS_PID:-}" ]] || kill "$DBUS_PID" 2>/dev/null || true
  [[ -z "${UDEV_PID:-}" ]] || kill "$UDEV_PID" 2>/dev/null || true
  [[ -z "${FIFO_PATH:-}" ]] || rm -f "$FIFO_PATH" 2>/dev/null || true

  if [[ "${USM_HDMI_DISABLE_SWAYIDLE:-true}" == "true" ]]; then
    local sys_state
    sys_state=$(systemctl is-system-running 2>/dev/null || true)
    local is_valid_state=false

    for state in "${VALID_SYSTEM_STATES[@]}"; do
      if [[ "$sys_state" == "$state" ]]; then
        is_valid_state=true
        break
      fi
    done

    if [[ "$is_valid_state" == "true" ]]; then
      log "Service exiting: restoring swayidle"
      start_swayidle
    else
      log "System state '$sys_state'. Skipping swayidle restore."
    fi
  fi
}

main() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    usm_validate_config
  else
    log "Error: Configuration file not found at $CONF_FILE"
    notify_user "Error: Configuration file not found."
    exit 1
  fi

  set_log_file_var

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
    screen-on)   cmd_screen_on ;;
    screen-off)  cmd_screen_off ;;
    screen-switch) cmd_screen_switch ;;
    screen-reset) cmd_screen_reset "${2:-}" ;;
    swayidle-enable) start_swayidle ;;
    swayidle-disable) stop_swayidle ;;
    status)      cmd_status ;;
    start)       cmd_service "start" ;;
    stop)        cmd_service "stop" ;;
    restart)     cmd_service "restart" ;;
    log-enable)  cmd_log_enable ;;
    log-disable) cmd_log_disable ;;
    hdmi-audio-on)    cmd_hdmi_audio_on ;;
    hdmi-audio-off)   cmd_hdmi_audio_off ;;
    hdmi-audio-state) cmd_hdmi_audio_state ;;
    notify-test) cmd_notify_test ;;
    hw_status)   cmd_hw_status ;;
    version)     printf "USM Version: %s\n" "$USM_VERSION" ;;
    *)
      log "Error: Unknown command '$1'"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
