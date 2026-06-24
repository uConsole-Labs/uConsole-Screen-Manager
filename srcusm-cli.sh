#!/bin/bash
# CLI tool for manual testing of USM features.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly LOG_PREFIX="[USM] CLI:"
readonly DRM_PATH="/sys/class/drm"
readonly CMD_TASKBAR="wf-panel-pi"

# Helper for formatted output
log() {
  printf "%s %s\n" "$LOG_PREFIX" "$1"
}

# Load configuration
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
else
  log "Error: Configuration file not found at $CONF_FILE"
  exit 1
fi

show_usage() {
  printf "Usage: usm [command]\n"
  printf "Commands:\n"
  printf "  read-conf       Print the current usm.conf\n"
  printf "  monitor         Monitor DRM events and validate EDID\n"
  printf "  screen-external Switch output to the external display\n"
  printf "  screen-internal Switch output to the internal display\n"
  printf "  bar-external    Reload taskbar for external display\n"
  printf "  bar-internal    Reload taskbar for internal display\n"
}

if (( $# == 0 )); then
  show_usage
  exit 1
fi

case "$1" in
  read-conf)
    log "Reading configuration from $CONF_FILE:"
    cat "$CONF_FILE"
    ;;
  monitor)
    log "Monitoring DRM events. Press Ctrl+C to stop."
    udevadm monitor --subsystem=drm | while read -r line; do
      if echo "$line" | grep -q "UDEV.*change"; then
        local stat_dir
        stat_dir=$(find "$DRM_PATH" -name "card*-$USM_EXT_OUT" \
          -type d | head -n 1)
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
    ;;
  screen-external)
    log "Forcing external display output..."
    wlr-randr --output "$USM_EXT_OUT" --on
    sleep 1
    if wlr-randr | grep -q "$USM_EXT_OUT"; then
      if [[ "${USM_MODE:-single}" == "single" ]]; then
        wlr-randr --output "$USM_INT_OUT" --off
      fi
      log "External display enabled."
    else
      log "Error: External display handshake failed."
      exit 1
    fi
    ;;
  screen-internal)
    log "Forcing internal display output..."
    wlr-randr --output "$USM_INT_OUT" --on
    sleep 0.5
    wlr-randr --output "$USM_EXT_OUT" --off || true
    log "Internal display enabled. External display disabled."
    ;;
  bar-external)
    log "Reloading taskbar (target: external)..."
    if pgrep -x "$CMD_TASKBAR" >/dev/null; then
      killall "$CMD_TASKBAR" && "$CMD_TASKBAR" >/dev/null 2>&1 &
    fi
    log "Taskbar reload completed."
    ;;
  bar-internal)
    log "Reloading taskbar (target: internal)..."
    if pgrep -x "$CMD_TASKBAR" >/dev/null; then
      killall "$CMD_TASKBAR" && "$CMD_TASKBAR" >/dev/null 2>&1 &
    fi
    log "Taskbar reload completed."
    ;;
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
