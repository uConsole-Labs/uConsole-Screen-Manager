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

# --- Global State ---
LAST_STATE="unknown"
USM_VERSION="unknown"
START_TIME_YYMMDD=$(date +%y%m%d)

if [[ -f "$VER_FILE" ]]; then
  USM_VERSION=$(cat "$VER_FILE")
fi

printf "uConsole Screen Manager (USM) Version: %s\n" "$USM_VERSION"

# --- Helpers ---
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $LOG_PREFIX $1"
  printf "%s\n" "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf "%s\n" "$msg" >> "$LOG_FILE"
  fi
}

notify_user() {
  local msg="$1"
  if command -v notify-send >/dev/null 2>&1; then
    local cmd="notify-send -t $NOTIFY_TIMEOUT_MS \"USM\" \"$msg\""
    log "Executing: $cmd"
    eval "$cmd" || true
  fi
}

check_hdmi_state() {
  local stat_dir
  stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" | head -n 1)

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

is_ext_connected() {
  [[ "$(check_hdmi_state)" == "$STATE_CONN" ]]
}

check_display_state() {
  local output="$1"
  local expected="$2"
  if wlr-randr | grep -A 5 "^$output" | grep -q "Enabled: yes"; then
    [[ "$expected" == "yes" ]]
  else
    [[ "$expected" == "no" ]]
  fi
}

is_state_matching() {
  local target="$1"
  case "$target" in
    "$MODE_EXT")
      check_display_state "$USM_INT_OUT" "no" && check_display_state "$USM_EXT_OUT" "yes"
      ;;
    "$MODE_INT")
      check_display_state "$USM_INT_OUT" "yes" && check_display_state "$USM_EXT_OUT" "no"
      ;;
    "$MODE_DUAL")
      check_display_state "$USM_INT_OUT" "yes" && check_display_state "$USM_EXT_OUT" "yes"
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

update_conf() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$CONF_FILE"; then
    sed -i "s/^${key}=.*/${key}=\"${val}\"/" "$CONF_FILE"
  else
    echo "${key}=\"${val}\"" >> "$CONF_FILE"
  fi
}

cmd_log_enable() {
  update_conf "USM_LOG_ENABLE" "true"
  printf "Logging enabled in %s.\n" "$CONF_FILE"
  if systemctl --user is-active --quiet "$SVC_NAME"; then
    systemctl --user reload "$SVC_NAME"
  fi
}

cmd_log_disable() {
  update_conf "USM_LOG_ENABLE" "false"
  printf "Logging disabled in %s.\n" "$CONF_FILE"
  if systemctl --user is-active --quiet "$SVC_NAME"; then
    systemctl --user reload "$SVC_NAME"
  fi
}

show_usage() {
  printf "Usage: usm [command]\n"
  printf "Commands:\n"
  printf "  read-conf    Print the current usm.conf\n"
  printf "  monitor      Start the DRM event monitor daemon\n"
  printf "  screen-ext   Switch output to external display only\n"
  printf "  screen-int   Switch output to internal display only\n"
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

run_hook() {
  if [[ "${USM_ENABLE_HOOKS:-false}" != "true" ]]; then
    return 0
  fi
  local hook_file="$HOME/.config/usm/$1"
  if [[ -x "$hook_file" ]]; then
    "$hook_file" &
  fi
}

wait_for_compositor() {
  log "Waiting for Wayland compositor..."
  while ! wlr-randr >/dev/null 2>&1; do
    sleep 1
  done
  log "Wayland compositor is ready."
}

apply_display() {
  local target_state="$1"

  if [[ "$target_state" == "$LAST_STATE" ]]; then
    return 0
  fi

  local expected_hw="$MODE_INT"
  if [[ "$target_state" == "$STATE_CONN" ]]; then
    [[ "${USM_MODE:-single}" == "single" ]] && expected_hw="$MODE_EXT" || expected_hw="$MODE_DUAL"
  fi

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

get_ext_target_res() {
  if [[ -n "${USM_EXT_RES:-}" ]]; then
    echo "$USM_EXT_RES"
  else
    local stat_dir
    stat_dir=$(find "$DRM_PATH" -maxdepth 1 -name "card*-$USM_EXT_OUT" | head -n 1)
    if [[ -n "$stat_dir" && -f "$stat_dir/modes" ]]; then
      head -n 1 "$stat_dir/modes" 2>/dev/null || true
    fi
  fi
}

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

  if ! echo "$output_str" | grep -q "Enabled: yes"; then return 1; fi
  if ! echo "$output_str" | grep -q "${res} px.*current"; then return 1; fi
  if ! echo "$output_str" | grep -q "Position: $pos"; then return 1; fi
  if [[ "$trans" == "0" || "$trans" == "normal" ]]; then
    if ! echo "$output_str" | grep -qE "Transform: (0|normal)"; then return 1; fi
  else
    if ! echo "$output_str" | grep -q "Transform: $trans"; then return 1; fi
  fi
  return 0
}

rescue_internal_display() {
  log "Warning: Entering rescue mode. Forcing internal display ON..."
  local cmd="wlr-randr --output $USM_INT_OUT --on --mode 720x1280 "
  cmd+="--transform 270 --pos 0,0"
  log "Executing: $cmd"
  if ! eval "$cmd"; then
    log "Critical Error: Failed to rescue internal display."
    notify_user "Critical: Rescue failed."
    return 1
  fi
  log "Rescue successful. Internal display is ON."
  return 0
}

ensure_low_res_sync() {
  log "Step A: Verify external display (1024x768)..."
  if ! check_exact_state "$USM_EXT_OUT" "1024x768" "1280,0" "0"; then
    log "External display state mismatch. Applying config..."
    local cmd="wlr-randr --output $USM_EXT_OUT --on --mode 1024x768 "
    cmd+="--transform normal --pos 1280,0"
    log "Executing: $cmd"
    if ! eval "$cmd"; then
      log "Error: External display setup failed."
      notify_user "Error: External display setup failed."
      return 1
    fi
    sleep "$SLEEP_SEC"
  fi

  log "Step B: Verify internal display (720x1280)..."
  if ! check_exact_state "$USM_INT_OUT" "720x1280" "0,0" "270"; then
    log "Internal display state mismatch. Applying config..."
    local cmd="wlr-randr --output $USM_INT_OUT --on --mode 720x1280 "
    cmd+="--transform 270 --pos 0,0"
    log "Executing: $cmd"
    if ! eval "$cmd"; then
      log "Error: Internal display setup failed."
      notify_user "Error: Internal display setup failed."
      return 1
    fi
    sleep "$SLEEP_SEC"
  fi

  log "Step C: Verify dual display synchronization..."
  if ! check_exact_state "$USM_INT_OUT" "720x1280" "0,0" "270" || \
     ! check_exact_state "$USM_EXT_OUT" "1024x768" "1280,0" "0"; then
    log "Error: Synchronization verification failed."
    notify_user "Error: Sync state verification failed."
    return 1
  fi
  return 0
}

cmd_screen_ext() {
  log "Switching to external display ONLY..."
  if is_state_matching "$MODE_EXT"; then
    log "Display is already in '$MODE_EXT' state. Skipping switch."
    return 0
  fi
  if ! is_ext_connected; then
    log "Error: External display is not connected."
    return 1
  fi

  log "Step A: Disable internal display..."
  local cmd_off="wlr-randr --output $USM_INT_OUT --off"
  log "Executing: $cmd_off"
  eval "$cmd_off" || true
  sleep "$SLEEP_SEC"

  log "Step B: Turn ON external display..."
  local ext_res
  ext_res=$(get_ext_target_res)
  local cmd_on="wlr-randr --output $USM_EXT_OUT --on"
  [[ -n "$ext_res" ]] && cmd_on+=" --mode $ext_res"
  [[ -n "${USM_EXT_SCALE:-}" ]] && cmd_on+=" --scale $USM_EXT_SCALE"
  [[ -n "${USM_EXT_POS:-}" ]] && cmd_on+=" --pos $USM_EXT_POS"

  log "Executing: $cmd_on"
  if ! eval "$cmd_on"; then
    log "Error: External display setup failed. Rolling back..."
    rescue_internal_display
    return 1
  fi
  sleep "$SLEEP_SEC"

  notify_user "External Display Enabled"
  log "External display successfully enabled."
}

cmd_screen_int() {
  log "Switching to internal display ONLY..."
  if is_state_matching "$MODE_INT"; then
    log "Display is already in '$MODE_INT' state. Skipping switch."
    return 0
  fi

  log "Step A: Disable external display..."
  local cmd_off="wlr-randr --output $USM_EXT_OUT --off"
  log "Executing: $cmd_off"
  eval "$cmd_off" || true
  sleep "$SLEEP_SEC"

  log "Step B: Turn ON internal display..."
  local cmd_on="wlr-randr --output $USM_INT_OUT --on --mode 720x1280 "
  cmd_on+="--transform 270 --pos 0,0"
  log "Executing: $cmd_on"
  if ! eval "$cmd_on"; then
    log "Error: Internal display setup failed. Trying rescue..."
    rescue_internal_display || true
    if is_ext_connected; then
      log "Attempting to restore external display as fallback..."
      local cmd_ext="wlr-randr --output $USM_EXT_OUT --on"
      log "Executing: $cmd_ext"
      eval "$cmd_ext" || true
    fi
    return 1
  fi
  sleep "$SLEEP_SEC"

  notify_user "Internal Display Enabled"
  log "Internal display successfully enabled."
}

cmd_screen_dual() {
  log "Switching to dual display..."
  if is_state_matching "$MODE_DUAL"; then
    log "Display is already in '$MODE_DUAL' state. Skipping switch."
    return 0
  fi
  if ! is_ext_connected; then
    log "Error: External display is not connected."
    return 1
  fi

  if ! ensure_low_res_sync; then
    log "Dual sync failed. Rolling back..."
    rescue_internal_display
    return 1
  fi

  log "Step D: Configure external display to target resolution..."
  local ext_res
  ext_res=$(get_ext_target_res)
  local cmd="wlr-randr --output $USM_EXT_OUT"
  [[ -n "$ext_res" ]] && cmd+=" --mode $ext_res"
  [[ -n "${USM_EXT_SCALE:-}" ]] && cmd+=" --scale $USM_EXT_SCALE"
  [[ -n "${USM_EXT_POS:-}" ]] && cmd+=" --pos $USM_EXT_POS"

  log "Executing: $cmd"
  if ! eval "$cmd"; then
    log "Error: External high-res setup failed. Rolling back..."
    rescue_internal_display
    return 1
  fi
  sleep "$SLEEP_SEC"

  notify_user "Dual Display Enabled"
  log "Dual display successfully enabled."
}



handle_event_suspend() {
  log "System is suspending (PrepareForSleep: true)"
  touch /tmp/usm_suspending.lock
}

handle_event_resume() {
  log "System has resumed (PrepareForSleep: false)"
  rm -f /tmp/usm_suspending.lock
  sleep 3
  local current_state
  current_state=$(check_hdmi_state)
  log "Re-evaluating display state after resume: $current_state"
  apply_display "$current_state"
}

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

  log "Hardware change detected. Initiating ${DEBOUNCE_SEC}s debounce wait..."
  sleep "$DEBOUNCE_SEC"

  local current_state
  current_state=$(check_hdmi_state)
  log "Debounce wait finished. Re-verified state: $current_state"

  if [[ "$current_state" != "$LAST_STATE" ]]; then
    last_event_time=$(date +%s)
    apply_display "$current_state"
  else
    log "State unchanged after debounce. Ignored."
  fi
}

cmd_monitor() {
  trap 'source "$CONF_FILE"; set_log_file_var' SIGHUP
  trap 'rm -f /tmp/usm_suspending.lock; pkill -P $$ 2>/dev/null' EXIT INT TERM

  log "Starting monitor daemon..."
  wait_for_compositor
  apply_display "$(check_hdmi_state)"

  rm -f /tmp/usm_suspending.lock
  local last_event_time=0

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
      stdbuf -oL dbus-monitor --system "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null &
    else
      dbus-monitor --system "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null &
    fi
    udevadm monitor --subsystem=drm 2>/dev/null &
    wait
  )
}

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
  journalctl --user-unit="$SVC_NAME" -n 20 --no-pager || echo "No logs found."
  printf "%s\n" "------------------"
}

cmd_read_conf() {
  cat "$CONF_FILE"
}

cmd_service() {
  local action="$1"
  systemctl --user "$action" "$SVC_NAME"
  log "Service $action completed."
}

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
  version)     log "Version command executed." ;;
  *)
    log "Error: Unknown command '$1'"
    show_usage
    exit 1
    ;;
esac
