#!/bin/bash
# Core logic for USM. Strictly event-driven via udevadm.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly DRM_PATH="/sys/class/drm"
readonly CMD_TASKBAR="wf-panel-pi"
readonly HOOK_PLUG="hook-plug.sh"
readonly HOOK_UNPLUG="hook-unplug.sh"
readonly STATE_CONN="connected"
readonly STATE_DISC="disconnected"

# Format and print state strings to stderr for journalctl
usm_print_state() {
  echo "[USM]: $1" >&2
}

# Load configuration
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
else
  usm_print_state "Error: Config not found at $CONF_FILE"
  exit 1
fi

LAST_STATE="unknown"

# Restart native taskbar to enforce primary screen alignment
restart_bar() {
  if pgrep -x "$CMD_TASKBAR" >/dev/null; then
    killall "$CMD_TASKBAR" && "$CMD_TASKBAR" >/dev/null 2>&1 &
  fi
}

# Execute custom hooks if enabled, exist, and are executable
run_hook() {
  if [[ "${USM_ENABLE_HOOKS:-false}" != "true" ]]; then
    return 0
  fi

  local hook_file="$HOME/.config/usm/$1"
  if [[ -x "$hook_file" ]]; then
    "$hook_file" &
  fi
}

# Apply Wayland outputs using wlr-randr
apply_display() {
  local target_state="$1"

  if [[ "$target_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  # Log the formatted state
  usm_print_state "$target_state"

  if [[ "$target_state" == "$STATE_CONN" ]]; then
    local ext_cmd="wlr-randr --output $USM_EXT_OUT --on"
    [[ -n "$USM_EXT_RES" ]] && ext_cmd+=" --mode $USM_EXT_RES"
    [[ -n "$USM_EXT_SCALE" ]] && ext_cmd+=" --scale $USM_EXT_SCALE"
    [[ -n "$USM_EXT_POS" ]] && ext_cmd+=" --pos $USM_EXT_POS"

    eval "$ext_cmd"
    sleep 1 # Wait 1 second for compositor to register the output

    # Fail-Safe: Verify external output before turning off internal
    if wlr-randr | grep -q "$USM_EXT_OUT"; then
      if [[ "$USM_MODE" == "single" ]]; then
        wlr-randr --output "$USM_INT_OUT" --off
      else
        wlr-randr --output "$USM_INT_OUT" --on
      fi
      restart_bar
      run_hook "$HOOK_PLUG"
    else
      # Handshake failed, keep internal display active
      wlr-randr --output "$USM_INT_OUT" --on
      return 1
    fi
  elif [[ "$target_state" == "$STATE_DISC" ]]; then
    # Disconnected state: restore internal display
    wlr-randr --output "$USM_INT_OUT" --on
    sleep 0.5
    wlr-randr --output "$USM_EXT_OUT" --off || true
    restart_bar
    run_hook "$HOOK_UNPLUG"
  fi

  LAST_STATE="$target_state"
}

# Verify physical HDMI connection and EDID
check_hdmi_state() {
  local stat_dir
  stat_dir=$(find "$DRM_PATH" -name "card*-$USM_EXT_OUT" -type d | head -n 1)

  if [[ -z "$stat_dir" ]]; then
    echo "$STATE_DISC"
    return
  fi

  local status
  local edid_size
  status=$(cat "$stat_dir/status" 2>/dev/null || echo "$STATE_DISC")
  edid_size=$(wc -c < "$stat_dir/edid" 2>/dev/null || echo "0")

  # Validate both status and physical EDID presence
  if [[ "$status" == "$STATE_CONN" ]] && (( edid_size > 0 )); then
    echo "$STATE_CONN"
  else
    echo "$STATE_DISC"
  fi
}

# Initialize correct state on script startup
apply_display "$(check_hdmi_state)"

# Block and listen for kernel DRM events (0% CPU polling)
udevadm monitor --subsystem=drm | while read -r line; do
  if echo "$line" | grep -q "UDEV.*change"; then
    sleep 1 # Debounce delay
    apply_display "$(check_hdmi_state)"
  fi
done
