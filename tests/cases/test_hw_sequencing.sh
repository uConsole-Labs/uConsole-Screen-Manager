#!/bin/bash
# Test Wayland-only DSI power control (zero out-of-band DRM/fb0 writes,
# kernel panel-cwu50 bl_power sync, brightness preservation, HDMI HPD safe).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

# 1. Switching ext -> int: zero out-of-band sysfs writes; driver turns bl_power
#    to 0, preserves brightness, and keeps HDMI HPD intact.
sandbox_init "hw_hp_e27u_g4.env"
printf "5\n" > "$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
bash "$USM_CLI" screen-int >/dev/null
assert_file_not_exists "$USM_MOCK_STATE_DIR/dsi_drm_poisoned" \
  "screen-int never poisoned DSI DRM/fb0"
assert_file_not_contains "$USM_MOCK_LOG" "sudo tee .*/(status|blank|bl_power)" \
  "screen-int performed zero out-of-band sysfs writes"
assert_eq "0" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "Driver set DSI bl_power to 0 (ON) on wlr-randr --on"
bl_bright="$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
assert_eq "5" "$(cat "$bl_bright")" \
  "User brightness preserved across DSI wake"
assert_eq "connected" \
  "$(cat "$USM_SYSFS_ROOT/class/drm/card2-HDMI-A-1/status")" \
  "HDMI DRM status not forced off (HPD preserved)"
sandbox_cleanup

# 2. Switching int -> ext: zero out-of-band sysfs writes; driver sets
#    bl_power=4 (UPM powersave) and keeps DSI DRM connector connected.
sandbox_init "hw_generic_1080p.env"
printf "5\n" > "$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
bash "$USM_CLI" screen-ext >/dev/null
assert_file_not_exists "$USM_MOCK_STATE_DIR/dsi_drm_poisoned" \
  "screen-ext never poisoned DSI DRM/fb0"
assert_file_not_contains "$USM_MOCK_LOG" "sudo tee .*/(status|blank|bl_power)" \
  "screen-ext performed zero out-of-band sysfs writes"
assert_eq "4" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "Driver set DSI bl_power to 4 (OFF) on wlr-randr --off"
bl_bright="$USM_SYSFS_ROOT/class/backlight/backlight@0/brightness"
assert_eq "5" "$(cat "$bl_bright")" \
  "User brightness preserved across DSI off"
assert_eq "connected" \
  "$(cat "$USM_SYSFS_ROOT/class/drm/card1-DSI-2/status")" \
  "DSI DRM status not forced off (no libliftoff deadlock)"
sandbox_cleanup

assert_summary "test_hw_sequencing"
