#!/usr/bin/env bash
# Installer for Install Deck (app_install)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

echo "→ Instalando backend en ~/.local/bin/install-any"
install -Dm755 "$SRC/bin/install-any" "$HOME/.local/bin/install-any"

echo "→ Instalando GUI en ~/.config/quickshell/install-any/shell.qml"
install -Dm644 "$SRC/quickshell/shell.qml" "$HOME/.config/quickshell/install-any/shell.qml"

echo "→ Instalando lanzador en ~/.local/share/applications/install-any.desktop"
install -Dm644 "$SRC/install-any.desktop" "$HOME/.local/share/applications/install-any.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
echo "✔ Instalado."
echo "  Lánzalo con:  qs -c install-any"
echo "  O desde tu menú de aplicaciones como \"Install Any\"."
echo
case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) echo "⚠  ~/.local/bin no está en tu PATH. Añádelo para usar 'install-any' en terminal." ;;
esac
