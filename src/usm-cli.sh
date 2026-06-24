#!/bin/bash
# CLI tool for manual testing of USM features.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly LOG_PREFIX="[USM] CLI:"
readonly DRM_PATH="/sys/class/drm"
readonly SVC_NAME="usm.service"

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

# Helper: Wait for external display handshake (Max 10 seconds)
wait_for_handshake() {
  local stat_dir
  stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" \
    | head -n 1)

  for ((i = 0; i < 20; i++)); do
    sleep 0.5

    # 1. Check if Wayland has registered the output as enabled
    if wlr-randr | grep -A 5 "^$USM_EXT_OUT" | grep -q "Enabled: yes"; then

      # 2. Check if the Linux DRM subsystem has powered it on (DPMS)
      if [[ -n "$stat_dir" && -f "$stat_dir/dpms" ]]; then
        if [[ "$(cat "$stat_dir/dpms" 2>/dev/null)" != "On" ]]; then
          continue # Wait until kernel actually powers it on
        fi
      fi

      # 3. Hardware stabilization buffer to prevent Labwc panic
      sleep 2
      return 0
    fi
  done

  return 1
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
  log "Forcing external display output..."
  wlr-randr --output "$USM_EXT_OUT" --on

  if wait_for_handshake; then
    wlr-randr --output "$USM_INT_OUT" --off
    log "External display enabled. Internal display disabled."
    notify_user "External display enabled."
  else
    log "Error: External display handshake failed (timeout)."
    notify_user "External display handshake failed."
    exit 1
  fi
}

cmd_screen_dual() {
  log "Forcing dual display output..."
  wlr-randr --output "$USM_INT_OUT" --on
  wlr-randr --output "$USM_EXT_OUT" --on

  if wait_for_handshake; then
    log "Dual display enabled."
    notify_user "Dual display enabled."
  else
    log "Error: External display handshake failed (timeout)."
    notify_user "External display handshake failed."
    exit 1
  fi
}

cmd_screen_int() {
  log "Forcing internal display output..."
  wlr-randr --output "$USM_INT_OUT" --on
  sleep 0.5
  wlr-randr --output "$USM_EXT_OUT" --off || true
  log "Internal display enabled. External display disabled."
  notify_user "Internal display enabled."
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
