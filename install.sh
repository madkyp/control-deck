#!/usr/bin/env bash
# Installer for Install Deck (app_install) — Arch / CachyOS
# Copies the deck into place and (optionally) installs missing dependencies.
#
#   ./install.sh            copia + comprueba e instala dependencias
#   ./install.sh --no-deps  solo copia los archivos
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WITH_DEPS=1
[[ "${1:-}" == "--no-deps" ]] && WITH_DEPS=0

# Paquetes (nombres en repos oficiales / AUR). El font se trata aparte.
REQUIRED=(quickshell jq libarchive polkit)
OPTIONAL=(flatpak libnotify curl zenity hyprpolkitagent)

is_installed() { pacman -Qq "$1" &>/dev/null; }
in_repo()      { pacman -Si "$1" &>/dev/null; }

install_deps() {
    command -v pacman >/dev/null || { echo "⚠  No es Arch/pacman: instala las dependencias a mano (ver README)."; return; }

    local repo=() aur=() p
    for p in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
        is_installed "$p" && continue
        if in_repo "$p"; then repo+=("$p"); else aur+=("$p"); fi
    done

    # Nerd Font: solo sugerir si NO hay ninguna instalada
    if ! fc-list 2>/dev/null | grep -qi "nerd"; then
        if in_repo ttf-jetbrains-mono-nerd; then repo+=(ttf-jetbrains-mono-nerd); fi
    fi

    if [[ ${#repo[@]} -eq 0 && ${#aur[@]} -eq 0 ]]; then
        echo "✔ Todas las dependencias ya están instaladas."
        return
    fi

    echo "Dependencias que faltan:"
    [[ ${#repo[@]} -gt 0 ]] && echo "  · repos: ${repo[*]}"
    [[ ${#aur[@]}  -gt 0 ]] && echo "  · AUR:   ${aur[*]}"
    read -rp "¿Instalarlas ahora? [Y/n] " ans
    [[ "${ans,,}" == "n" ]] && { echo "→ Omitido. Instálalas a mano si algo no funciona."; return; }

    if [[ ${#repo[@]} -gt 0 ]]; then
        sudo pacman -S --needed "${repo[@]}"
    fi
    if [[ ${#aur[@]} -gt 0 ]]; then
        local helper; helper="$(command -v paru || command -v yay || true)"
        if [[ -n "$helper" ]]; then
            "$helper" -S --needed "${aur[@]}"
        else
            echo "⚠  Estos paquetes están en el AUR y no tienes helper (paru/yay):"
            echo "     ${aur[*]}"
            echo "   Instálalos con tu método habitual del AUR."
        fi
    fi
}

# ---- dependencias -----------------------------------------------------------
if [[ $WITH_DEPS -eq 1 ]]; then
    echo "== Dependencias =="
    install_deps
    echo
fi

# ---- archivos ---------------------------------------------------------------
echo "== Instalando Install Deck =="
echo "→ backend  ~/.local/bin/install-any"
install -Dm755 "$SRC/bin/install-any" "$HOME/.local/bin/install-any"

echo "→ GUI      ~/.config/quickshell/install-any/shell.qml"
install -Dm644 "$SRC/quickshell/shell.qml" "$HOME/.config/quickshell/install-any/shell.qml"

echo "→ lanzador ~/.local/share/applications/install-any.desktop"
install -Dm644 "$SRC/install-any.desktop" "$HOME/.local/share/applications/install-any.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
echo "✔ Instalado."
echo "  Lánzalo con:  qs -c install-any   (o desde tu menú como \"Install Any\")"
echo
case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) echo "⚠  ~/.local/bin no está en tu PATH. Añádelo para usar 'install-any' en terminal." ;;
esac
