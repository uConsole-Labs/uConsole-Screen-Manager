#!/bin/bash
# Core daemon entrypoint. Delegates entirely to usm-cli.sh monitor.

set -euo pipefail

readonly CLI_CMD="$HOME/.local/bin/usm-cli.sh"

if [[ ! -x "$CLI_CMD" ]]; then
  echo "[USM] Core: Error: $CLI_CMD not found or not executable." >&2
  exit 1
fi

# Forward execution to CLI tool's monitor mode
exec "$CLI_CMD" monitor
