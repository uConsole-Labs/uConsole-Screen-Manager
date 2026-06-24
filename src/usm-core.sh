#!/bin/bash
# Core daemon. Listens to udevadm and delegates actions to usm-cli.sh.

set -euo pipefail

# --- Constants ---
readonly CONF_FILE="$HOME/.config/usm/usm.conf"
readonly CLI_CMD="$HOME/.local/bin/usm-cli.sh"
readonly DRM_PATH="/sys/class/drm"
readonly STATE_CONN="connected"
readonly STATE_DISC="disconnected"

# Format and print state strings to stderr for journalctl
usm_print_state() {
  echo "[USM] Core: $1" >&2
}

# Load configuration
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
else
  usm_print_state "Error: Config not found at $CONF_FILE"
  exit 1
fi

LAST_STATE="unknown"

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

# Delegate display logic to CLI tool
apply_display() {
  local target_state="$1"

  if [[ "$target_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  usm_print_state "State changed to: $target_state"

  if [[ "$target_state" == "$STATE_CONN" ]]; then

    # Call CLI for display switching (abort if handshake fails)
    if [[ "${USM_MODE:-single}" == "single" ]]; then
      "$CLI_CMD" screen-ext || return 1
    else
      "$CLI_CMD" screen-dual || return 1
    fi

    run_hook "hook-plug.sh"

  elif [[ "$target_state" == "$STATE_DISC" ]]; then

    "$CLI_CMD" screen-int

    run_hook "hook-unplug.sh"

  fi

  LAST_STATE="$target_state"
}

# Verify physical HDMI connection and EDID
check_hdmi_state() {
  local stat_dir
  stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" \
    | head -n 1)

  if [[ -z "$stat_dir" ]]; then
    echo "$STATE_DISC"
    return
  fi

  local status
  local edid_size
  status=$(cat "$stat_dir/status" 2>/dev/null || echo "$STATE_DISC")
  edid_size=$(wc -c < "$stat_dir/edid" 2>/dev/null || echo "0")

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
