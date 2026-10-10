#!/usr/bin/env bash
# Removes everything install.sh added and turns normal sleep back on.
set -euo pipefail

LABEL="local.auto-nosleep"
DOMAIN="gui/$(id -u)"
APP_DIR="$HOME/Library/Application Support/AutoNoSleep"

[[ $EUID -ne 0 ]] || {
    echo "error: run ./uninstall.sh without sudo" >&2
    exit 1
}

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL"
fi
echo "Restoring normal sleep and removing the sudo rule (may ask for your Mac password)..."
sudo pmset disablesleep 0
sudo rm -f /etc/sudoers.d/auto-nosleep
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/Library/Logs/auto-nosleep.log"
rm -f "$APP_DIR/auto-nosleep"
if [[ -d "$APP_DIR" ]]; then
    rmdir "$APP_DIR" 2>/dev/null || echo "Leaving non-empty directory: $APP_DIR"
fi
echo "auto-nosleep is uninstalled; your Mac sleeps normally again."
