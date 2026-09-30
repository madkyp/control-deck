#!/usr/bin/env bash
# Installer for Control Deck — Arch / CachyOS
# Copies the deck into place and (optionally) installs missing dependencies.
#
#   ./install.sh            copy + check and install dependencies
#   ./install.sh --no-deps  only copy the files
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WITH_DEPS=1
[[ "${1:-}" == "--no-deps" ]] && WITH_DEPS=0

# Package names (official repos / AUR). The font is handled separately.
REQUIRED=(quickshell jq libarchive polkit)
OPTIONAL=(flatpak libnotify curl zenity hyprpolkitagent pacman-contrib wl-clipboard)

is_installed() { pacman -Qq "$1" &>/dev/null; }
in_repo()      { pacman -Si "$1" &>/dev/null; }

install_deps() {
    command -v pacman >/dev/null || { echo "⚠  Not Arch/pacman: install the dependencies by hand (see README)."; return; }

    local repo=() aur=() p
    for p in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
        is_installed "$p" && continue
        if in_repo "$p"; then repo+=("$p"); else aur+=("$p"); fi
    done

    # Nerd Font: only suggested when none is installed
    if ! fc-list 2>/dev/null | grep -qi "nerd"; then
        if in_repo ttf-jetbrains-mono-nerd; then repo+=(ttf-jetbrains-mono-nerd); fi
    fi

    if [[ ${#repo[@]} -eq 0 && ${#aur[@]} -eq 0 ]]; then
        echo "✔ All dependencies are already installed."
        return
    fi

    echo "Missing dependencies:"
    [[ ${#repo[@]} -gt 0 ]] && echo "  · repos: ${repo[*]}"
    [[ ${#aur[@]}  -gt 0 ]] && echo "  · AUR:   ${aur[*]}"
    read -rp "Install them now? [Y/n] " ans
    [[ "${ans,,}" == "n" ]] && { echo "→ Skipped. Install them by hand if something doesn't work."; return; }

    if [[ ${#repo[@]} -gt 0 ]]; then
        sudo pacman -S --needed "${repo[@]}"
    fi
    if [[ ${#aur[@]} -gt 0 ]]; then
        local helper; helper="$(command -v paru || command -v yay || true)"
        if [[ -n "$helper" ]]; then
            "$helper" -S --needed "${aur[@]}"
        else
            echo "⚠  These packages are in the AUR and you have no helper (paru/yay):"
            echo "     ${aur[*]}"
            echo "   Install them the way you usually install AUR packages."
        fi
    fi
}

# ---- dependencies -----------------------------------------------------------
if [[ $WITH_DEPS -eq 1 ]]; then
    echo "== Dependencies =="
    install_deps
    echo
fi

# ---- migration from "Install Deck" (install-any) ----------------------------
if [[ -e "$HOME/.local/bin/install-any" || -d "$HOME/.config/quickshell/install-any" ]]; then
    echo "== Migrating from install-any =="
    rm -f "$HOME/.local/bin/install-any"
    rm -rf "$HOME/.config/quickshell/install-any"
    rm -f "$HOME/.local/share/applications/install-any.desktop"
    echo "→ removed the old version (your apps and launchers are kept)"
    echo
fi

# ---- files ------------------------------------------------------------------
echo "== Installing Control Deck =="
echo "→ backend   ~/.local/bin/control-deck"
install -Dm755 "$SRC/bin/control-deck" "$HOME/.local/bin/control-deck"

echo "→ icon      ~/.local/share/icons/hicolor/scalable/apps/control-deck.svg"
install -Dm644 "$SRC/icons/control-deck.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/control-deck.svg"
gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

echo "→ launcher  ~/.local/share/applications/control-deck.desktop"
install -Dm644 "$SRC/control-deck.desktop" "$HOME/.local/share/applications/control-deck.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# version info, used by the deck to spot a newer version of itself on GitHub
commit="${CONTROL_DECK_COMMIT:-$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)}"
gh_repo="${CONTROL_DECK_REPO:-$(git -C "$SRC" remote get-url origin 2>/dev/null \
        | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//' || true)}"
branch="$(git -C "$SRC" branch --show-current 2>/dev/null || true)"
src="$SRC"; git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || src=""
mkdir -p "$HOME/.local/share/control-deck"
printf 'SRC=%s\nREPO=%s\nBRANCH=%s\nCOMMIT=%s\nDATE=%s\n' \
    "$src" "${gh_repo:-madkyp/control-deck}" "${branch:-main}" "$commit" "$(date -Is)" \
    > "$HOME/.local/share/control-deck/install.env"
echo "→ version   ${commit:0:7}"

# the GUI goes last: a running deck reloads as soon as shell.qml changes
echo "→ GUI       ~/.config/quickshell/control-deck/shell.qml"
install -Dm644 "$SRC/quickshell/overlay.qml" "$HOME/.config/quickshell/control-deck-overlay/shell.qml"
install -Dm644 "$SRC/quickshell/shell.qml" "$HOME/.config/quickshell/control-deck/shell.qml"

echo
echo "✔ Installed."
echo "  Run it with:  qs -c control-deck   (or \"Control Deck\" from your app menu)"
echo
echo "  Optional extras from the AUR:"
echo "    · appimageupdatetool — update AppImages that don't come from GitHub"
echo "    · debtap             — install .deb packages (then: sudo debtap -u)"
echo
case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) echo "⚠  ~/.local/bin is not in your PATH. Add it to use 'control-deck' from a terminal." ;;
esac
