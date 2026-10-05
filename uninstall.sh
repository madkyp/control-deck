#!/usr/bin/env bash
# Uninstaller for System Deck — removes only the deck itself
set -euo pipefail

# the background update check (if it was turned on) goes first
if [[ -x "$HOME/.local/bin/system-deck" ]]; then
    "$HOME/.local/bin/system-deck" timer off >/dev/null 2>&1 || true
fi

rm -f "$HOME/.local/bin/system-deck"
rm -f "$HOME/.config/quickshell/system-deck/shell.qml"
rm -f "$HOME/.config/quickshell/system-deck/es.js"
rmdir "$HOME/.config/quickshell/system-deck" 2>/dev/null || true
rm -f "$HOME/.local/share/applications/system-deck.desktop"
rm -f "$HOME/.local/share/icons/hicolor/scalable/apps/system-deck.svg"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo "✔ System Deck uninstalled (the apps you installed with it stay on your system)."
echo "  History, logs and the launcher trash live in ~/.local/share/system-deck (delete it if you like)."
