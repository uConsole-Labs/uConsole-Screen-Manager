#!/bin/bash
# USM Installer.

set -euo pipefail

# --- Constants ---
readonly USM_DIR="$HOME/.config/usm"
readonly SYS_DIR="$HOME/.config/systemd/user"
readonly BIN_DIR="$HOME/.local/bin"
readonly BASHRC="$HOME/.bashrc"
readonly FILE_CORE="usm-core.sh"
readonly FILE_CLI="usm-cli.sh"
readonly FILE_CONF="usm.conf"
readonly FILE_SVC="usm.service"
readonly FILE_UNINST="usm-uninstall"
readonly LOG_PREFIX="[USM] Installer:"
readonly ALIAS_CMD="alias usm='$BIN_DIR/$FILE_CLI'"

# Helper for formatted output
log() {
  printf "%s %s\n" "$LOG_PREFIX" "$1"
}

log "Installing USM..."

mkdir -p "$USM_DIR" "$SYS_DIR" "$BIN_DIR"
cp "src/$FILE_CORE" "$USM_DIR/$FILE_CORE"
chmod +x "$USM_DIR/$FILE_CORE"

# Copy CLI tool to binary directory
cp "src/$FILE_CLI" "$BIN_DIR/$FILE_CLI"
chmod +x "$BIN_DIR/$FILE_CLI"

if [[ ! -f "$USM_DIR/$FILE_CONF" ]]; then
  cp "conf/$FILE_CONF" "$USM_DIR/$FILE_CONF"
fi

cp "systemd/$FILE_SVC" "$SYS_DIR/$FILE_SVC"

# Inject or update the bash alias
if grep -q "alias usm=" "$BASHRC"; then
  sed -i "s|alias usm=.*|$ALIAS_CMD|" "$BASHRC"
else
  printf "%s\n" "$ALIAS_CMD" >> "$BASHRC"
fi

# Generate uninstaller script dynamically with confirmation prompt
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
rm -f "$HOME/.config/systemd/user/$FILE_SVC"
systemctl --user daemon-reload
rm -rf "$HOME/.config/usm"
sed -i '/alias usm=/d' "\$HOME/.bashrc"
rm -f "$HOME/.local/bin/$FILE_CLI"
rm -f "$HOME/.local/bin/$FILE_UNINST"
printf "%s USM successfully removed.\n" "\$LOG_PREFIX"
EOF

chmod +x "$BIN_DIR/$FILE_UNINST"

# Enable and start the background service
systemctl --user daemon-reload
systemctl --user enable --now "$FILE_SVC"

log "Installation complete! Please reload bashrc or restart terminal."
