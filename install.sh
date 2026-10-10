#!/usr/bin/env bash
# Installs (or updates) auto-nosleep for the current user. Safe to re-run.
set -euo pipefail

LABEL="local.auto-nosleep"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Library/Application Support/AutoNoSleep"
BIN="$APP_DIR/auto-nosleep"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/auto-nosleep.log"
SUDOERS="/etc/sudoers.d/auto-nosleep"
USER_NAME="$(id -un)"
DOMAIN="gui/$(id -u)"
LOGIN_ITEMS_URL="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() {
    printf '\n\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

check_requirements() {
    [[ "$(uname -s)" == Darwin ]] || die "auto-nosleep only works on macOS."
    [[ $EUID -ne 0 ]] || die "Run ./install.sh as your normal user, without sudo."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    ((major >= 12)) || die "macOS 12 (Monterey) or newer is required."
    [[ -f "$SRC_DIR/auto-nosleep.swift" ]] || die "auto-nosleep.swift must be next to install.sh."
    if ! xcode-select -p >/dev/null 2>&1; then
        xcode-select --install 2>/dev/null || true
        die "Apple's Command Line Tools are needed to build auto-nosleep. An installer window
       should have opened; once it finishes, run ./install.sh again."
    fi
}

build() {
    step "Building auto-nosleep"
    mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    swiftc -O "$SRC_DIR/auto-nosleep.swift" -o "$BIN"
}

install_sudo_rule() {
    step "Allowing auto-nosleep to change the sleep setting (asks for your Mac password)"
    echo "Lets '$USER_NAME' run only 'pmset disablesleep 0|1' and 'pmset sleepnow' as root."
    local tmp
    tmp="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: %s, %s, %s\n' "$USER_NAME" \
        "/usr/bin/pmset disablesleep 0" "/usr/bin/pmset disablesleep 1" "/usr/bin/pmset sleepnow" \
        >"$tmp"
    sudo visudo -cf "$tmp" >/dev/null
    sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"
    rm -f "$tmp"
    sudo -k
    sudo -n /usr/bin/pmset disablesleep 0 || die "The sudo rule in $SUDOERS isn't working."
}

install_agent() {
    step "Starting auto-nosleep (and at every login from now on)"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$DOMAIN/$LABEL"
    fi
    launchctl enable "$DOMAIN/$LABEL"
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "$DOMAIN/$LABEL"
}

verify() {
    sleep 3
    if ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
        open "$LOGIN_ITEMS_URL" || true
        die "auto-nosleep is installed but macOS didn't let it start. In System Settings, turn on
       'auto-nosleep' under 'Allow in the Background', then run ./install.sh again."
    fi
    step "Done: auto-nosleep is running"
    pmset -g | grep SleepDisabled || true
    echo "SleepDisabled is 1 while an external display is connected, 0 otherwise."
    echo "Log: $LOG"
}

check_requirements
build
install_sudo_rule
install_agent
verify
