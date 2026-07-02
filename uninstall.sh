#!/usr/bin/env bash
# Uninstaller for Install Deck (app_install) — removes only the deck itself
set -euo pipefail

rm -f "$HOME/.local/bin/install-any"
rm -f "$HOME/.config/quickshell/install-any/shell.qml"
rmdir "$HOME/.config/quickshell/install-any" 2>/dev/null || true
rm -f "$HOME/.local/share/applications/install-any.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo "✔ Install Deck desinstalado (las apps que instalaste con él siguen en tu sistema)."
