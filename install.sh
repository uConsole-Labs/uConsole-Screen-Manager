#!/bin/bash
# USM Installer.

set -euo pipefail

# --- Constants ---
readonly USM_DIR="$HOME/.config/usm"
readonly SYS_DIR="$HOME/.config/systemd/user"
readonly BIN_DIR="$HOME/.local/bin"
readonly BASHRC="$HOME/.bashrc"
readonly FILE_CLI="usm-cli.sh"
readonly FILE_CONF="usm.conf"
readonly FILE_VER="VERSION"
readonly FILE_SVC="usm.service"
readonly FILE_UNINST="usm-uninstall"
readonly LOG_PREFIX="[USM] Installer:"
readonly ALIAS_CMD="alias usm='$BIN_DIR/$FILE_CLI'"
readonly MAKO_DIR="$HOME/.config/mako"
readonly MAKO_CONF="$MAKO_DIR/config"
readonly LABWC_DIR="$HOME/.config/labwc"
readonly LABWC_AUTO="$LABWC_DIR/autostart"
readonly SWAYIDLE_MARK_START="# === USM Swayidle Config Start ==="
readonly SWAYIDLE_MARK_END="# === USM Swayidle Config End ==="
USM_SWAYIDLE_MANAGED="false"

# ==============================================================================
# log
#
# Writes a formatted log message to stdout.
#
# Globals:
#   LOG_PREFIX
# Arguments:
#   $1 - message: The message text to log.
# Outputs:
#   Writes the message to stdout.
# Returns:
#   0 on success.
# ==============================================================================
log() {
  printf "%s %s\n" "$LOG_PREFIX" "$1"
}

# ==============================================================================
# install_mako
#
# Checks for and installs mako-notifier if requested by the user.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes prompts to stdout.
# Returns:
#   0 on success.
# ==============================================================================
install_mako() {
  if ! command -v mako >/dev/null 2>&1; then
    log "mako-notifier not found."
    read -r -p "Install mako-notifier? (requires sudo) [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      sudo apt update
      sudo apt install -y mako-notifier
    else
      log "Warning: Notifications will not work without mako."
    fi
  fi
}

# ==============================================================================
# configure_swayidle_autostart
#
# Manages the USM swayidle block in labwc autostart without altering custom
# non-wlopm swayidle configurations.
#
# Returns:
#   0 on success.
# ==============================================================================
configure_swayidle_autostart() {
  if ! command -v swayidle >/dev/null 2>&1; then
    log "swayidle not found. Skipping swayidle configuration."
    return 0
  fi

  if [[ -f "$LABWC_AUTO" ]] && \
     grep -qxF "$SWAYIDLE_MARK_START" "$LABWC_AUTO"; then
    if ! grep -qxF "$SWAYIDLE_MARK_END" "$LABWC_AUTO"; then
      log "Warning: Malformed USM swayidle block (missing End). Skipping."
      return 0
    fi
    log "USM swayidle config block already present in $LABWC_AUTO. Skipping."
    USM_SWAYIDLE_MANAGED="true"
    return 0
  fi

  local active_swayidle=""
  if [[ -f "$LABWC_AUTO" ]]; then
    active_swayidle=$(sed -n \
      '/^[[:space:]]*swayidle/{:a;/\\[[:space:]]*$/{N;s/\\\n/ /;ba};p;q}' \
      "$LABWC_AUTO")
  fi

  if [[ -z "$active_swayidle" ]]; then
    log "No active swayidle found in $LABWC_AUTO."
    log "Adding USM managed swayidle block..."
    cat << EOF >> "$LABWC_AUTO"
$SWAYIDLE_MARK_START
# Managed by uConsole Screen Manager (USM). Do not modify this block manually.
# Changes inside this block will be removed or overwritten by USM.
$BIN_DIR/$FILE_CLI swayidle-enable
$SWAYIDLE_MARK_END
EOF
    USM_SWAYIDLE_MANAGED="true"
  elif [[ "$active_swayidle" == *"wlopm"* ]]; then
    log "Detected wlopm in active swayidle config ($LABWC_AUTO)."
    log "Wrapping old wlopm as backup and switching to USM managed block..."
    local tmp_auto
    tmp_auto=$(mktemp)
    awk -v s="$SWAYIDLE_MARK_START" -v e="$SWAYIDLE_MARK_END" \
        -v cmd="$BIN_DIR/$FILE_CLI swayidle-enable" '
      BEGIN { in_block = 0; done = 0 }
      !done && !in_block && /^[[:space:]]*swayidle/ {
        in_block = 1
        print s
        print "# Managed by uConsole Screen Manager (USM). Do not modify."
        print "# Changes inside this block will be removed/overwritten by USM."
      }
      in_block {
        print "# [USM backup] " $0
        if ($0 !~ /\\[[:space:]]*$/) {
          print cmd
          print e
          in_block = 0
          done = 1
        }
        next
      }
      { print }
    ' "$LABWC_AUTO" > "$tmp_auto"
    mv "$tmp_auto" "$LABWC_AUTO"
    USM_SWAYIDLE_MANAGED="true"
  else
    log "Custom swayidle detected (no wlopm). Leaving $LABWC_AUTO untouched."
  fi
}

# ==============================================================================
# configure_mako_and_labwc
#
# Configures mako and labwc autostart.
#
# Globals:
#   LABWC_DIR
#   LABWC_AUTO
#   MAKO_CONF
#   MAKO_DIR
#   FILE_SVC
# Arguments:
#   None
# Outputs:
#   Creates configuration files and directories.
# Returns:
#   0 on success.
# ==============================================================================
configure_mako_and_labwc() {
  mkdir -p "$LABWC_DIR"

  if command -v mako >/dev/null 2>&1; then
    if [[ ! -f "$MAKO_CONF" ]]; then
      log "Creating mako configuration..."
      mkdir -p "$MAKO_DIR"
      cat << 'EOF' > "$MAKO_CONF"
layer=overlay
anchor=top-right
font=sans-serif 11
background-color=#2b2b2bE6
text-color=#ffffff
width=280
margin=10
padding=12
border-size=1
border-color=#4a4a4a
border-radius=6
default-timeout=4000
EOF
    fi

    if [[ ! -f "$LABWC_AUTO" ]] || ! grep -q "mako" "$LABWC_AUTO"; then
      log "Adding mako to labwc autostart..."
      echo "mako >/dev/null 2>&1 &" >> "$LABWC_AUTO"
    fi
  fi

  if [[ ! -f "$LABWC_AUTO" ]] || \
     ! grep -q "restart $FILE_SVC" "$LABWC_AUTO"; then
    log "Configuring Labwc autostart for USM service..."

    if ! grep -q "import-environment WAYLAND_DISPLAY" "$LABWC_AUTO" \
         2>/dev/null; then
      echo "systemctl --user import-environment WAYLAND_DISPLAY" \
        >> "$LABWC_AUTO"
    fi

    echo "systemctl --user restart $FILE_SVC" >> "$LABWC_AUTO"
  fi

  configure_swayidle_autostart
}

# ==============================================================================
# install_usm_files
#
# Installs USM scripts, configurations, and hooks.
#
# Globals:
#   USM_DIR
#   SYS_DIR
#   BIN_DIR
#   FILE_CLI
#   FILE_VER
#   FILE_CONF
#   FILE_SVC
# Arguments:
#   None
# Outputs:
#   Copies files to target directories.
# Returns:
#   0 on success.
# ==============================================================================
install_usm_files() {
  mkdir -p "$USM_DIR" "$SYS_DIR" "$BIN_DIR"

  # Copy CLI tool to binary directory
  cp "src/$FILE_CLI" "$BIN_DIR/$FILE_CLI"
  chmod +x "$BIN_DIR/$FILE_CLI"

  # Copy Version file to configuration directory
  cp "$FILE_VER" "$USM_DIR/$FILE_VER"

  if [[ ! -f "$USM_DIR/$FILE_CONF" ]]; then
    cp "conf/$FILE_CONF" "$USM_DIR/$FILE_CONF"
  fi

  cp "systemd/$FILE_SVC" "$SYS_DIR/$FILE_SVC"

  # Install hooks
  mkdir -p "$USM_DIR/hooks"
  for hook in src/hooks/*.sh; do
    hook_name=$(basename "$hook")
    dest="$USM_DIR/hooks/$hook_name"
    if [[ ! -f "$dest" ]]; then
      cp "$hook" "$dest"
      chmod +x "$dest"
    fi
  done
}

# ==============================================================================
# inject_bash_alias
#
# Adds the usm alias to the user's bashrc.
#
# Globals:
#   BASHRC
#   ALIAS_CMD
# Arguments:
#   None
# Outputs:
#   Modifies ~/.bashrc.
# Returns:
#   0 on success.
# ==============================================================================
inject_bash_alias() {
  if grep -q "alias usm=" "$BASHRC"; then
    sed -i "s|alias usm=.*|$ALIAS_CMD|" "$BASHRC"
  else
    printf "%s\n" "$ALIAS_CMD" >> "$BASHRC"
  fi
}

# ==============================================================================
# generate_uninstaller
#
# Generates the uninstaller script.
#
# Globals:
#   BIN_DIR
#   FILE_UNINST
#   FILE_SVC
#   FILE_CONF
#   FILE_VER
#   FILE_CLI
# Arguments:
#   None
# Outputs:
#   Creates the uninstaller script.
# Returns:
#   0 on success.
# ==============================================================================
generate_uninstaller() {
  cat << EOF > "$BIN_DIR/$FILE_UNINST"
#!/bin/bash
set -euo pipefail

readonly LOG_PREFIX="[USM] Uninstaller:"

read -r -p "Are you sure you want to uninstall USM? [y/N] " response
if [[ ! "\$response" =~ ^[Yy]\$ ]]; then
  printf "%s Uninstallation aborted.\n" "\$LOG_PREFIX"
  exit 0
fi

printf "%s Uninstalling USM...\n" "\$LOG_PREFIX"
systemctl --user disable --now $FILE_SVC || true
rm -f "\$HOME/.config/systemd/user/$FILE_SVC"
systemctl --user daemon-reload

read -r -p "Remove config/hooks in \$HOME/.config/usm? [y/N] " rm_conf
if [[ "\$rm_conf" =~ ^[Yy]\$ ]]; then
  rm -f "\$HOME/.config/usm/$FILE_CONF"
  rm -f "\$HOME/.config/usm/hooks/"*.sh
  rmdir "\$HOME/.config/usm/hooks" 2>/dev/null || true
  rmdir "\$HOME/.config/usm" 2>/dev/null || true
else
  rm -f "\$HOME/.config/usm/$FILE_VER"
  printf "%s User configurations and hooks retained.\n" "\$LOG_PREFIX"
fi

sed -i '/alias usm=/d' "\$HOME/.bashrc"
sed -i "/restart $FILE_SVC/d" "\$HOME/.config/labwc/autostart" || true
if [[ -f "\$HOME/.config/labwc/autostart" ]]; then
  if grep -qxF "$SWAYIDLE_MARK_START" "\$HOME/.config/labwc/autostart"; then
    if ! grep -qxF "$SWAYIDLE_MARK_END" "\$HOME/.config/labwc/autostart"; then
      printf "%s Warning: Malformed USM swayidle block (no End). Skipped.\n" \
        "\$LOG_PREFIX"
    else
      tmp_auto=\$(mktemp)
      has_backup="false"
      grep -q "^# \[USM backup\] " "\$HOME/.config/labwc/autostart" && \
        has_backup="true"
      awk -v s="$SWAYIDLE_MARK_START" -v e="$SWAYIDLE_MARK_END" '
        BEGIN { in_block = 0 }
        \$0 == s { in_block = 1; next }
        \$0 == e { in_block = 0; next }
        in_block {
          if (index(\$0, "# [USM backup] ") == 1) {
            print substr(\$0, 16)
          }
          next
        }
        { print }
      ' "\$HOME/.config/labwc/autostart" > "\$tmp_auto"
      mv "\$tmp_auto" "\$HOME/.config/labwc/autostart"
      pkill -x "swayidle" 2>/dev/null || true
      if [[ "\$has_backup" == "true" ]]; then
        printf "%s Removed USM swayidle block and restored original config.\n" \
          "\$LOG_PREFIX"
      else
        printf "%s Removed USM swayidle block from %s.\n" \
          "\$LOG_PREFIX" "\$HOME/.config/labwc/autostart"
      fi
    fi
  elif grep -q "^[[:space:]]*swayidle" "\$HOME/.config/labwc/autostart"; then
    printf "%s Custom swayidle config in %s retained.\n" \
      "\$LOG_PREFIX" "\$HOME/.config/labwc/autostart"
  fi
fi
rm -f "\$HOME/.local/bin/$FILE_CLI"
rm -f "\$HOME/.local/bin/$FILE_UNINST"

printf "%s USM successfully removed.\n" "\$LOG_PREFIX"
EOF

  chmod +x "$BIN_DIR/$FILE_UNINST"
}

# ==============================================================================
# main
#
# Main installation workflow.
#
# Globals:
#   FILE_SVC
# Arguments:
#   $@ - script arguments
# Outputs:
#   Writes logs and prompts.
# Returns:
#   0 on success.
# ==============================================================================
main() {
  log "Installing USM..."

  # Stop existing service before installation to prevent file lock
  log "Stopping existing service (if any)..."
  systemctl --user stop "$FILE_SVC" 2>/dev/null || true

  install_mako
  configure_mako_and_labwc
  install_usm_files
  inject_bash_alias
  generate_uninstaller

  # Enable the background service
  log "Enabling USM service..."
  systemctl --user daemon-reload
  systemctl --user enable "$FILE_SVC"

  # Start mako for the current session if not already running
  if command -v mako >/dev/null 2>&1 && ! pgrep -x "mako" >/dev/null; then
    log "Starting mako daemon..."
    mako >/dev/null 2>&1 &
  fi

  if [[ "$USM_SWAYIDLE_MANAGED" == "true" ]] && \
     grep -qxF "$SWAYIDLE_MARK_START" "$LABWC_AUTO" 2>/dev/null; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
      # Wake idle-slept screens first: a killed swayidle sends no resume.
      log "Waking idle-off screens (if any) before restarting swayidle..."
      "$BIN_DIR/$FILE_CLI" idle-on || true
      log "Restarting swayidle to apply USM configuration..."
      "$BIN_DIR/$FILE_CLI" swayidle-disable || true
      "$BIN_DIR/$FILE_CLI" swayidle-enable || true
    else
      log "No active Wayland display in current shell."
      log "New USM swayidle config will take effect on next login."
    fi
  else
    log "USM swayidle block not managed. Leaving running swayidle untouched."
  fi

  # Prompt to start the service immediately
  read -r -p "Do you want to start the USM service now? [y/N] " start_resp
  if [[ "$start_resp" =~ ^[Yy]$ ]]; then
    log "Starting USM service..."
    # Explicitly import environment for the current session
    systemctl --user import-environment WAYLAND_DISPLAY 2>/dev/null || true
    systemctl --user restart "$FILE_SVC"
  fi

  log "Installation complete! Please reload bashrc or restart terminal."
}

main "$@"
