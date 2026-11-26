#!/bin/bash
# Test Plan 1.1 & 1.2: NOOP-1 removal, clean --off args, USM_EXT_RES & 1080p.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

trap sandbox_cleanup EXIT

# 1. NOOP-1 is pre-disabled before real output switch; --off has no --mode.
sandbox_init "hw_hp_e27u_g4.env"
sandbox_set_mock_var "wlr.env" "WLR_HAS_NOOP" "true"
sandbox_set_mock_var "wlr.env" "WLR_HDMI_ENABLED" "yes"
sandbox_set_mock_var "wlr.env" "WLR_DSI_ENABLED" "no"

bash "$USM_CLI" screen-int >/dev/null
assert_file_contains "$USM_MOCK_LOG" "wlr-randr --output NOOP-1 --off" \
  "NOOP-1 pre-cleanup disables placeholder output"
assert_order "$USM_MOCK_LOG" \
  "wlr-randr --output NOOP-1 --off" \
  "wlr-randr --output DSI-2 --on" \
  "NOOP-1 pre-cleanup runs before enabling DSI-2"
assert_file_contains "$USM_MOCK_LOG" "--output HDMI-A-1 --off$" \
  "HDMI --off must not carry --mode/--transform/--pos"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HAS_NOOP="false"' \
  "NOOP-1 disabled after pre-cleanup"
sandbox_cleanup

# 2. Generic 1080p monitor (no 2560x1440) succeeds with USM_EXT_RES="".
sandbox_init "hw_generic_1080p.env"
sandbox_set_conf "USM_EXT_RES" ""
bash "$USM_CLI" screen-ext >/dev/null
assert_file_contains "$USM_MOCK_LOG" \
  "--output DSI-2 --off --output HDMI-A-1 --on --transform normal" \
  "DSI --off clean and HDMI --on omits --mode when USM_EXT_RES empty"
assert_file_contains "$USM_MOCK_STATE_DIR/wlr.env" 'WLR_HDMI_ENABLED="yes"' \
  "1080p HDMI enabled without hardcoded 2560x1440"
sandbox_cleanup

# 3. Explicit USM_EXT_RES="1920x1080@60" is honored in ext and dual modes.
sandbox_init "hw_generic_1080p.env"
sandbox_set_conf "USM_EXT_RES" "1920x1080@60"
bash "$USM_CLI" screen-ext >/dev/null
assert_file_contains "$USM_MOCK_LOG" \
  "--output HDMI-A-1 --on --mode 1920x1080@60" \
  "cmd_screen_ext honors USM_EXT_RES"
: > "$USM_MOCK_LOG"
bash "$USM_CLI" screen-dual >/dev/null
assert_file_contains "$USM_MOCK_LOG" \
  "--output DSI-2 --on .*--output HDMI-A-1 --on --mode 1920x1080@60" \
  "cmd_screen_dual honors USM_EXT_RES"
sandbox_cleanup

assert_summary "test_wlr_randr_args"
