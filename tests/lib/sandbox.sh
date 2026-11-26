#!/bin/bash
# Sandbox lifecycle and hardware state helpers for USM tests.

set -euo pipefail

# shellcheck disable=SC2034
USM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034
USM_CLI="$USM_REPO_ROOT/src/usm-cli.sh"

sandbox_init() {
  local fixture="${1:-hw_hp_e27u_g4.env}"
  SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usm_sandbox.XXXXXX")"

  export HOME="$SANDBOX_DIR/home"
  export XDG_RUNTIME_DIR="$SANDBOX_DIR/xdg_runtime"
  export WAYLAND_DISPLAY="wayland-0"
  export USM_CONF_FILE="$HOME/.config/usm/usm.conf"
  export USM_RUN_DIR_OVERRIDE="$SANDBOX_DIR/run"
  export USM_LOG_DIR="$SANDBOX_DIR/logs"
  export USM_SYSFS_ROOT="$SANDBOX_DIR/sys"
  export USM_MOCK_STATE_DIR="$SANDBOX_DIR/mock_state"
  export USM_MOCK_LOG="$SANDBOX_DIR/mock_calls.log"
  export PATH="$SANDBOX_DIR/bin:$PATH"

  mkdir -p \
    "$SANDBOX_DIR/bin" \
    "$HOME/.config/usm" \
    "$HOME/.config/labwc" \
    "$XDG_RUNTIME_DIR" \
    "$USM_RUN_DIR_OVERRIDE" \
    "$USM_LOG_DIR" \
    "$USM_MOCK_STATE_DIR" \
    "$USM_SYSFS_ROOT/class/drm/card1-DSI-2" \
    "$USM_SYSFS_ROOT/class/drm/card2-HDMI-A-1" \
    "$USM_SYSFS_ROOT/class/backlight/backlight@0" \
    "$USM_SYSFS_ROOT/class/graphics/fb0" \
    "$USM_SYSFS_ROOT/bus/mipi-dsi/drivers/panel-cwu50"

  cp "$USM_REPO_ROOT"/tests/mocks/* "$SANDBOX_DIR/bin/"
  chmod +x "$SANDBOX_DIR/bin/"*

  touch "$XDG_RUNTIME_DIR/wayland-0.lock"
  : > "$USM_MOCK_LOG"
  printf "0.0.0-test\n" > "$HOME/.config/usm/VERSION"

  cat > "$HOME/.config/labwc/autostart" <<'EOF'
# === USM Swayidle Config Start ===
swayidle -w timeout 600 'usm-cli.sh idle-off' resume 'usm-cli.sh idle-on' &
# === USM Swayidle Config End ===
EOF

  cp "$USM_REPO_ROOT/conf/usm.conf" "$USM_CONF_FILE"
  cp "$USM_REPO_ROOT/tests/fixtures/$fixture" "$USM_MOCK_STATE_DIR/wlr.env"
  cp "$USM_REPO_ROOT/tests/fixtures/$fixture" "$USM_MOCK_STATE_DIR/wlopm.env"

  # Initialize sysfs from fixture defaults.
  # shellcheck disable=SC1090,SC1091
  source "$USM_MOCK_STATE_DIR/wlr.env"
  sandbox_set_drm "DSI-2" "${FIXTURE_DSI_DRM_STATUS:-connected}" 0
  sandbox_set_drm "HDMI-A-1" \
    "${FIXTURE_HDMI_DRM_STATUS:-connected}" \
    "${FIXTURE_HDMI_EDID_BYTES:-256}"
  printf "%s\n" "${FIXTURE_BL_POWER:-0}" \
    > "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power"
  printf "%s\n" "${FIXTURE_BL_BRIGHTNESS:-9}" \
    > "$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
  printf "0\n" > "$USM_SYSFS_ROOT/class/graphics/fb0/blank"
  printf "0\n" > "$USM_SYSFS_ROOT/class/graphics/fb0/state"
  printf "vc4drmfb\n" > "$USM_SYSFS_ROOT/class/graphics/fb0/name"

  printf "SWAYIDLE_RUNNING=0\n" > "$USM_MOCK_STATE_DIR/swayidle.env"
  printf "HDMI_AUDIO_PROFILE=off\n" > "$USM_MOCK_STATE_DIR/audio.env"
}

sandbox_set_drm() {
  local out="$1"
  local status="$2"
  local edid_bytes="${3:-0}"
  local dir="$USM_SYSFS_ROOT/class/drm/card2-HDMI-A-1"
  if [[ "$out" == "DSI-2" ]]; then
    dir="$USM_SYSFS_ROOT/class/drm/card1-DSI-2"
  fi
  printf "%s\n" "$status" > "$dir/status"
  if (( edid_bytes > 0 )); then
    head -c "$edid_bytes" /dev/zero | tr '\0' 'E' > "$dir/edid"
  else
    : > "$dir/edid"
  fi
}

sandbox_set_mock_var() {
  local file="$1"
  local key="$2"
  local val="$3"
  local path="$USM_MOCK_STATE_DIR/$file"
  touch "$path"
  if grep -q "^${key}=" "$path"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$path"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$path"
  fi
}

sandbox_set_conf() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$USM_CONF_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$USM_CONF_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$USM_CONF_FILE"
  fi
}

sandbox_cleanup() {
  if [[ -n "${SANDBOX_DIR:-}" && -d "$SANDBOX_DIR" ]]; then
    rm -rf "$SANDBOX_DIR"
  fi
}
