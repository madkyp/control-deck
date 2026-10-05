#!/usr/bin/env bash
# Installer for System Deck — Arch / CachyOS
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
OPTIONAL=(flatpak libnotify curl zenity hyprpolkitagent pacman-contrib wl-clipboard python)

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
echo "== Installing System Deck =="
echo "→ backend   ~/.local/bin/system-deck"
install -Dm755 "$SRC/bin/system-deck" "$HOME/.local/bin/system-deck"

echo "→ icon      ~/.local/share/icons/hicolor/scalable/apps/system-deck.svg"
install -Dm644 "$SRC/icons/system-deck.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/system-deck.svg"
gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

echo "→ launcher  ~/.local/share/applications/system-deck.desktop"
install -Dm644 "$SRC/system-deck.desktop" "$HOME/.local/share/applications/system-deck.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# version info, used by the deck to spot a newer version of itself on GitHub
commit="${SYSTEM_DECK_COMMIT:-$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)}"
gh_repo="${SYSTEM_DECK_REPO:-$(git -C "$SRC" remote get-url origin 2>/dev/null \
        | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//' || true)}"
branch="$(git -C "$SRC" branch --show-current 2>/dev/null || true)"
src="$SRC"; git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || src=""
mkdir -p "$HOME/.local/share/system-deck"
printf 'SRC=%s\nREPO=%s\nBRANCH=%s\nCOMMIT=%s\nDATE=%s\n' \
    "$src" "${gh_repo:-madkyp/system-deck}" "${branch:-main}" "$commit" "$(date -Is)" \
    > "$HOME/.local/share/system-deck/install.env"
echo "→ version   ${commit:0:7}"

# the GUI goes last: a running deck reloads as soon as shell.qml changes
echo "→ GUI       ~/.config/quickshell/system-deck/shell.qml"
install -Dm644 "$SRC/quickshell/es.js" "$HOME/.config/quickshell/system-deck/es.js"
install -Dm644 "$SRC/quickshell/shell.qml" "$HOME/.config/quickshell/system-deck/shell.qml"

# Control Deck became System Deck (apps) + Gaming Deck (games): move the app data
# over and remove the old deck. The old command stays while a Steam game still
# launches through it (Gaming Deck's migrate switches those, with Steam closed).
if [[ -d "$HOME/.local/share/control-deck" || -x "$HOME/.local/bin/control-deck" || -d "$HOME/.config/quickshell/control-deck" ]]; then
    echo
    echo "== Migrating from Control Deck =="
    "$HOME/.local/bin/system-deck" migrate || true
    rm -rf "$HOME/.config/quickshell/control-deck" "$HOME/.config/quickshell/control-deck-overlay"
    rm -f "$HOME/.local/share/applications/control-deck.desktop" "$HOME/.local/share/icons/hicolor/scalable/apps/control-deck.svg"
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    if grep -qs 'control-deck run' "$HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf "$HOME"/.steam/steam/userdata/*/config/localconfig.vdf; then
        echo "⚠  Some Steam games still launch through control-deck: install Gaming Deck (or run 'gaming-deck migrate'"
        echo "   with Steam closed) — the old command stays until then."
    elif [[ -e "$HOME/.local/bin/control-deck" ]]; then
        rm -f "$HOME/.local/bin/control-deck"; echo "→ removed the old control-deck command"
    fi
    # what's left of the old data folder once both decks have taken theirs
    old="$HOME/.local/share/control-deck"
    if [[ -d "$old" && ! -e "$old/gaming" && ! -e "$old/reshade" ]]; then
        rm -f "$old/install.env" "$old/ui.json" "$old/history.tsv"; rm -rf "$old/logs"; rmdir "$old" 2>/dev/null || true
    fi
fi

echo
echo "✔ Installed."
echo "  Run it with:  qs -c system-deck   (or \"System Deck\" from your app menu)"
echo
echo "  Optional extras from the AUR:"
echo "    · appimageupdatetool — update AppImages that don't come from GitHub"
echo "    · debtap             — install .deb packages (then: sudo debtap -u)"
echo
case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) echo "⚠  ~/.local/bin is not in your PATH. Add it to use 'system-deck' from a terminal." ;;
esac
