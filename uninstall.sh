#!/bin/bash
# Full AliSwitcher removal. Run with sudo (or via the app menu).
set -euo pipefail

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo 501)

kill_all() {
    pkill -9 -x AliSwitcher 2>/dev/null || true
    sleep 1
}

echo "▸ Stopping the app..."
kill_all

echo "▸ Resetting permissions (TCC: Accessibility / Input Monitoring)..."
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    sudo -u "$CONSOLE_USER" tccutil reset Accessibility local.alishch.aliswitcher 2>/dev/null || true
    sudo -u "$CONSOLE_USER" tccutil reset ListenEvent local.alishch.aliswitcher 2>/dev/null || true
fi

echo "▸ Disabling Launch at Login (LaunchAgent)..."
launchctl bootout "gui/$CONSOLE_UID/local.alishch.aliswitcher" 2>/dev/null || true
rm -f /Library/LaunchAgents/local.alishch.aliswitcher.plist

echo "▸ Removing the app from /Applications..."
rm -rf /Applications/AliSwitcher.app

echo "▸ Searching for and removing other app copies..."
ps -xo command 2>/dev/null | grep '/AliSwitcher.app/Contents/MacOS/AliSwitcher' | grep -v grep | awk '{print $1}' | sed 's#/Contents/MacOS/AliSwitcher$##' | sort -u | while read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && rm -rf "$p" && echo "  removed: $p"
done
# In case the process is still alive after file removal — kill again
kill_all

echo "▸ Forgetting the installation record..."
pkgutil --forget local.alishch.aliswitcher 2>/dev/null || true

echo "▸ Cleaning temp files and logs..."
rm -f /tmp/AliSwitcher.log /tmp/local.alishch.aliswitcher.lock
rm -f "$HOME/Library/Logs/DiagnosticReports/AliSwitcher-"*.ips 2>/dev/null || true

echo ""
echo "✓ AliSwitcher fully removed."
