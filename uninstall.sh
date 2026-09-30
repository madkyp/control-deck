#!/usr/bin/env bash
# Uninstaller for Control Deck — removes only the deck itself
set -euo pipefail

# the background update check (if it was turned on) goes first
if [[ -x "$HOME/.local/bin/control-deck" ]]; then
    "$HOME/.local/bin/control-deck" timer off >/dev/null 2>&1 || true
fi

rm -f "$HOME/.local/bin/control-deck"
rm -f "$HOME/.config/quickshell/control-deck/shell.qml"
rm -f "$HOME/.config/quickshell/control-deck-overlay/shell.qml"
rmdir "$HOME/.config/quickshell/control-deck-overlay" 2>/dev/null || true
rmdir "$HOME/.config/quickshell/control-deck" 2>/dev/null || true
rm -f "$HOME/.local/share/applications/control-deck.desktop"
rm -f "$HOME/.local/share/icons/hicolor/scalable/apps/control-deck.svg"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo "✔ Control Deck uninstalled (the apps you installed with it stay on your system)."
echo "  History, logs and the launcher trash live in ~/.local/share/control-deck (delete it if you like)."
