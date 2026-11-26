#!/bin/bash
# Test hardware power sequencing (ON before wlr-randr, OFF after, HPD safe).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

# 1. Switching ext -> int: DSI hw ON must precede wlr-randr; HDMI HPD intact.
sandbox_init "hw_hp_e27u_g4.env"
bash "$USM_CLI" screen-int >/dev/null
assert_order "$USM_MOCK_LOG" \
  "sudo tee .*/bl_power" \
  "wlr-randr --output DSI-2 --on" \
  "DSI hardware ON precedes wlr-randr --on"
assert_eq "0" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "DSI bl_power set to 0 (ON)"
assert_eq "connected" \
  "$(cat "$USM_SYSFS_ROOT/class/drm/card2-HDMI-A-1/status")" \
  "HDMI DRM status not forced off (HPD preserved)"
sandbox_cleanup

# 2. Switching int -> ext: wlr-randr --off must precede DSI hw OFF.
sandbox_init "hw_generic_1080p.env"
bash "$USM_CLI" screen-ext >/dev/null
assert_order "$USM_MOCK_LOG" \
  "wlr-randr --output DSI-2 --off" \
  "sudo tee .*/bl_power" \
  "wlr-randr --off precedes DSI hardware OFF"
assert_eq "4" "$(cat "$USM_SYSFS_ROOT/class/backlight/backlight@0/bl_power")" \
  "DSI bl_power set to 4 (OFF)"
assert_eq "off" "$(cat "$USM_SYSFS_ROOT/class/drm/card1-DSI-2/status")" \
  "DSI DRM status forced off after Wayland release"
sandbox_cleanup

assert_summary "test_hw_sequencing"
