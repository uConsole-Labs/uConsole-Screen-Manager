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
readonly STATE_CONN="connected"
readonly STATE_DISC="disconnected"

# --- Global State & Dynamic Version Loading ---
LAST_STATE="unknown"
USM_VERSION="unknown"

if [[ -f "$VER_FILE" ]]; then
  USM_VERSION=$(cat "$VER_FILE")
fi

# Print version banner on the VERY FIRST line for any command
printf "uConsole Screen Manager (USM) Version: %s\n" "$USM_VERSION"

# Helper for formatted output
log() {
  printf "[%s] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_PREFIX" "$1"
}

# Helper: Send desktop notification
notify_user() {
  local msg="$1"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "USM" "$msg" || true
  fi
}

# Helper: Check HDMI state via DRM
check_hdmi_state() {
  local stat_dir
  stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" \
    | head -n 1)

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

# Helper: Check if external monitor is physically connected
is_ext_connected() {
  [[ "$(check_hdmi_state)" == "$STATE_CONN" ]]
}

# Helper: Verify if output is in the expected state ("yes" or "no")
check_display_state() {
  local output="$1"
  local expected="$2"

  if wlr-randr | grep -A 5 "^$output" | grep -q "Enabled: yes"; then
    [[ "$expected" == "yes" ]]
  else
    [[ "$expected" == "no" ]]
  fi
}

# Helper: Check if current hardware state already matches the target
is_state_matching() {
  local target="$1"
  case "$target" in
    ext)
      check_display_state "$USM_INT_OUT" "no" && \
      check_display_state "$USM_EXT_OUT" "yes"
      ;;
    int)
      check_display_state "$USM_INT_OUT" "yes" && \
      check_display_state "$USM_EXT_OUT" "no"
      ;;
    dual)
      check_display_state "$USM_INT_OUT" "yes" && \
      check_display_state "$USM_EXT_OUT" "yes"
      ;;
    *)
      return 1
      ;;
  esac
}

# Load configuration
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
else
  log "Error: Configuration file not found at $CONF_FILE"
  notify_user "Error: Configuration file not found."
  exit 1
fi

show_usage() {
  printf "Usage: usm [command]\n"
  printf "Commands:\n"
  printf "  read-conf    Print the current usm.conf\n"
  printf "  monitor      Start the DRM event monitor daemon\n"
  printf "  screen-ext   Switch output to external display only\n"
  printf "  screen-int   Switch output to internal display only\n"
  printf "  screen-dual  Switch output to both displays\n"
  printf "  start        Start the USM background service\n"
  printf "  stop         Stop the USM background service\n"
  printf "  restart      Restart the USM background service\n"
  printf "  notify-test  Test desktop notification\n"
  printf "  version      Print version information\n"
}

# --- Daemon Logic ---

run_hook() {
  if [[ "${USM_ENABLE_HOOKS:-false}" != "true" ]]; then
    return 0
  fi
  local hook_file="$HOME/.config/usm/$1"
  if [[ -x "$hook_file" ]]; then
    "$hook_file" &
  fi
}

apply_display() {
  local target_state="$1"

  if [[ "$target_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  # Determine expected logical target
  local expected_hw="int"
  if [[ "$target_state" == "$STATE_CONN" ]]; then
    [[ "${USM_MODE:-single}" == "single" ]] && expected_hw="ext" || \
      expected_hw="dual"
  fi

  # Fast-bypass on startup if hardware is already correct
  if [[ "$LAST_STATE" == "unknown" ]] && is_state_matching "$expected_hw"; then
    log "Initial hardware state matches '$expected_hw'. Skipping actions."
    LAST_STATE="$target_state"
    return 0
  fi

  log "State changed to: $target_state"

  if [[ "$target_state" == "$STATE_CONN" ]]; then
    if [[ "${USM_MODE:-single}" == "single" ]]; then
      cmd_screen_ext || return 1
    else
      cmd_screen_dual || return 1
    fi
    run_hook "hook-plug.sh"

  elif [[ "$target_state" == "$STATE_DISC" ]]; then
    cmd_screen_int || return 1
    run_hook "hook-unplug.sh"
  fi

  LAST_STATE="$target_state"
}

wait_for_compositor() {
  log "Waiting for Wayland compositor..."
  while ! wlr-randr >/dev/null 2>&1; do
    sleep 1
  done
  log "Wayland compositor is ready."
}

# --- Core Logic: Hardware bandwidth workaround ---
execute_hardware_workaround() {
  local target="$1"
  local ext_res=""

  # Idempotent bypass
  if is_state_matching "$target"; then
    log "Display is already in '$target' state. Skipping workaround."
    return 0
  fi

  if ! is_ext_connected; then
    log "Error: External display is not physically connected."
    notify_user "Hardware Error: External display disconnected."
    return 1
  fi

  if [[ -n "${USM_EXT_RES:-}" ]]; then
    ext_res="$USM_EXT_RES"
  else
    local stat_dir
    stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" \
      | head -n 1)
    if [[ -n "$stat_dir" && -f "$stat_dir/modes" ]]; then
      ext_res=$(head -n 1 "$stat_dir/modes" 2>/dev/null || true)
    fi
  fi
  log "Target external resolution: ${ext_res:-auto}"

  # STEP 1: Low-res sync
  log "Step 1: Forcing low-res sync (1024x768 & 720x1280@270)..."
  local cmd1="wlr-randr "
  cmd1+="--output $USM_INT_OUT --on --mode 720x1280 --transform 270 --pos 0,0 "
  cmd1+="--output $USM_EXT_OUT --on --mode 1024x768 --pos 1280,0"

  if ! eval "$cmd1"; then
    log "Error: Step 1 execution failed."
    notify_user "Sync error: Execution failed (Step 1)."
    return 1
  fi
  sleep "$SLEEP_SEC"
  if ! check_display_state "$USM_INT_OUT" "yes" || \
     ! check_display_state "$USM_EXT_OUT" "yes"; then
    log "Error: Step 1 verification failed. Displays are not both ON."
    notify_user "Sync error: Verification failed (Step 1)."
    return 1
  fi

  # STEP 2: Restore external resolution
  log "Step 2: Restoring external display resolution..."
  local cmd2="wlr-randr --output $USM_EXT_OUT --pos 1280,0"
  [[ -n "$ext_res" ]] && cmd2+=" --mode $ext_res"

  if ! eval "$cmd2"; then
    log "Error: Step 2 execution failed."
    notify_user "Sync error: Execution failed (Step 2)."
    return 1
  fi
  sleep "$SLEEP_SEC"
  if ! check_display_state "$USM_EXT_OUT" "yes"; then
    log "Error: Step 2 verification failed."
    notify_user "Sync error: Verification failed (Step 2)."
    return 1
  fi

  # STEP 3: Finalize state
  log "Step 3: Finalizing display state ($target)..."
  if [[ "$target" == "ext" ]]; then
    if ! wlr-randr --output "$USM_INT_OUT" --off; then
      log "Error: Step 3 execution failed."
      return 1
    fi
    sleep "$SLEEP_SEC"
    if ! check_display_state "$USM_INT_OUT" "no" || \
       ! check_display_state "$USM_EXT_OUT" "yes"; then
      log "Error: Step 3 verification failed."
      return 1
    fi
    notify_user "External display enabled."

  elif [[ "$target" == "dual" ]]; then
    local cmd3="wlr-randr"
    [[ -n "${USM_EXT_SCALE:-}" ]] && \
      cmd3+=" --output $USM_EXT_OUT --scale $USM_EXT_SCALE"
    [[ -n "${USM_EXT_POS:-}" ]] && \
      cmd3+=" --output $USM_EXT_OUT --pos $USM_EXT_POS"

    if [[ "$cmd3" != "wlr-randr" ]]; then
      if ! eval "$cmd3"; then
        log "Error: Step 3 execution failed."
        return 1
      fi
      sleep "$SLEEP_SEC"
    fi

    if ! check_display_state "$USM_INT_OUT" "yes" || \
       ! check_display_state "$USM_EXT_OUT" "yes"; then
      log "Error: Step 3 verification failed."
      return 1
    fi
    notify_user "Dual display enabled."
  fi

  log "Hardware workaround sequence completed successfully."
}

# --- Command Functions ---

cmd_monitor() {
  log "Starting monitor daemon..."
  wait_for_compositor
  apply_display "$(check_hdmi_state)"

  udevadm monitor --subsystem=drm | while read -r line; do
    if echo "$line" | grep -q "UDEV.*change"; then
      sleep 1 # Debounce delay
      apply_display "$(check_hdmi_state)"
    fi
  done
}

cmd_screen_ext() {
  execute_hardware_workaround "ext"
}

cmd_screen_dual() {
  execute_hardware_workaround "dual"
}

cmd_screen_int() {
  log "Switching to internal display ONLY..."

  # Idempotent bypass
  if is_state_matching "int"; then
    log "Display is already in 'int' state. Skipping switch."
    return 0
  fi

  local cmd="wlr-randr --output $USM_INT_OUT --on --mode 720x1280 "
  cmd+="--transform 270 --pos 0,0"

  if is_ext_connected; then
    log "External display is connected. Adding explicit off command..."
    cmd+=" --output $USM_EXT_OUT --off"
  fi

  log "Executing: $cmd"
  if ! eval "$cmd"; then
    log "Error: Failed to enable internal display."
    notify_user "Error: Internal display config failed."
    return 1
  fi
  sleep "$SLEEP_SEC"

  if ! check_display_state "$USM_INT_OUT" "yes"; then
    log "Error: Internal display state verification failed."
    notify_user "Error: Internal display verification failed."
    return 1
  fi

  log "Internal display successfully enabled."
  notify_user "Internal display enabled."
}

cmd_read_conf() {
  log "Reading configuration from $CONF_FILE:"
  cat "$CONF_FILE"
}

cmd_service() {
  local action="$1"
  log "Executing systemctl --user $action $SVC_NAME..."
  systemctl --user "$action" "$SVC_NAME"
  log "Service $action completed."
  notify_user "Service $action completed."
}

cmd_notify_test() {
  log "Sending test notification..."
  notify_user "This is a test notification."
  log "Notification sent."
}

# --- Main Logic ---

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
  start)       cmd_service "start" ;;
  stop)        cmd_service "stop" ;;
  restart)     cmd_service "restart" ;;
  notify-test) cmd_notify_test ;;
  version)     log "Version command executed." ;;
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
