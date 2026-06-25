#!/bin/bash
# CLI tool for manual testing of USM features.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly LOG_PREFIX="[USM] CLI:"
readonly DRM_PATH="/sys/class/drm"
readonly SVC_NAME="usm.service"
readonly SLEEP_SEC=2

# Helper for formatted output
log() {
  printf "%s %s\n" "$LOG_PREFIX" "$1"
}

# Helper: Send desktop notification
notify_user() {
  local msg="$1"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "USM" "$msg" || true
  fi
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
  printf "  monitor      Monitor DRM events and validate EDID\n"
  printf "  screen-ext   Switch output to external display only\n"
  printf "  screen-int   Switch output to internal display only\n"
  printf "  screen-dual  Switch output to both displays\n"
  printf "  start        Start the USM background service\n"
  printf "  stop         Stop the USM background service\n"
  printf "  restart      Restart the USM background service\n"
  printf "  notify-test  Test desktop notification\n"
}

# Core Logic: Hardware bandwidth workaround with verification
execute_hardware_workaround() {
  local target="$1"
  local ext_res=""

  # 1.1 Fetch current/preferred external resolution directly from DRM
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

  # --- STEP 1: Low-res sync ---
  log "Step 1: Forcing low-res sync (1024x768 & 720x1280@270)..."
  local cmd1="wlr-randr "
  cmd1+="--output $USM_INT_OUT --on --mode 720x1280 --transform 270 --pos 0,0 "
  cmd1+="--output $USM_EXT_OUT --on --mode 1024x768 --pos 1280,0"

  if ! eval "$cmd1"; then
    log "Error: Step 1 execution failed."
    notify_user "Sync error: Execution failed (Step 1)."
    exit 1
  fi
  sleep "$SLEEP_SEC"
  if ! check_display_state "$USM_INT_OUT" "yes" || \
     ! check_display_state "$USM_EXT_OUT" "yes"; then
    log "Error: Step 1 verification failed. Displays are not both ON."
    notify_user "Sync error: Verification failed (Step 1)."
    exit 1
  fi

  # --- STEP 2: Restore external resolution ---
  log "Step 2: Restoring external display resolution..."
  local cmd2="wlr-randr --output $USM_EXT_OUT --pos 1280,0"
  [[ -n "$ext_res" ]] && cmd2+=" --mode $ext_res"

  if ! eval "$cmd2"; then
    log "Error: Step 2 execution failed."
    notify_user "Sync error: Execution failed (Step 2)."
    exit 1
  fi
  sleep "$SLEEP_SEC"
  if ! check_display_state "$USM_EXT_OUT" "yes"; then
    log "Error: Step 2 verification failed."
    notify_user "Sync error: Verification failed (Step 2)."
    exit 1
  fi

  # --- STEP 3: Finalize state based on target ---
  log "Step 3: Finalizing display state ($target)..."
  if [[ "$target" == "ext" ]]; then
    if ! wlr-randr --output "$USM_INT_OUT" --off; then
      log "Error: Step 3 execution failed."
      exit 1
    fi
    sleep "$SLEEP_SEC"
    if ! check_display_state "$USM_INT_OUT" "no" || \
       ! check_display_state "$USM_EXT_OUT" "yes"; then
      log "Error: Step 3 verification failed."
      exit 1
    fi
    notify_user "External display enabled."

  elif [[ "$target" == "int" ]]; then
    if ! wlr-randr --output "$USM_EXT_OUT" --off; then
      log "Error: Step 3 execution failed."
      exit 1
    fi
    sleep "$SLEEP_SEC"
    if ! check_display_state "$USM_EXT_OUT" "no" || \
       ! check_display_state "$USM_INT_OUT" "yes"; then
      log "Error: Step 3 verification failed."
      exit 1
    fi
    notify_user "Internal display enabled."

  elif [[ "$target" == "dual" ]]; then
    local cmd3="wlr-randr"
    [[ -n "${USM_EXT_SCALE:-}" ]] && \
      cmd3+=" --output $USM_EXT_OUT --scale $USM_EXT_SCALE"
    [[ -n "${USM_EXT_POS:-}" ]] && \
      cmd3+=" --output $USM_EXT_OUT --pos $USM_EXT_POS"

    if [[ "$cmd3" != "wlr-randr" ]]; then
      if ! eval "$cmd3"; then
        log "Error: Step 3 execution failed."
        exit 1
      fi
      sleep "$SLEEP_SEC"
    fi

    if ! check_display_state "$USM_INT_OUT" "yes" || \
       ! check_display_state "$USM_EXT_OUT" "yes"; then
      log "Error: Step 3 verification failed."
      exit 1
    fi
    notify_user "Dual display enabled."
  fi

  log "Hardware workaround sequence completed successfully."
}

# --- Command Functions ---

cmd_read_conf() {
  log "Reading configuration from $CONF_FILE:"
  cat "$CONF_FILE"
}

cmd_monitor() {
  log "Monitoring DRM events. Press Ctrl+C to stop."
  udevadm monitor --subsystem=drm | while read -r line; do
    if echo "$line" | grep -q "UDEV.*change"; then
      local stat_dir
      stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" \
        | head -n 1)
      if [[ -n "$stat_dir" ]]; then
        local status
        local edid_size
        status=$(cat "$stat_dir/status" 2>/dev/null || echo "unknown")
        edid_size=$(wc -c < "$stat_dir/edid" 2>/dev/null || echo "0")
        log "Event: status=$status, edid_size=$edid_size bytes"
      else
        log "Event detected but external port directory not found."
      fi
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
  execute_hardware_workaround "int"
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
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
