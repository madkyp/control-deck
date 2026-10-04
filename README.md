<p align="center"><img src="icons/control-deck.svg" width="112" alt="Control Deck icon"></p>

# 力 Control Deck

[![tests](https://github.com/madkyp/control-deck/actions/workflows/tests.yml/badge.svg)](https://github.com/madkyp/control-deck/actions/workflows/tests.yml)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Arch / CachyOS](https://img.shields.io/badge/Arch%20%2F%20CachyOS-Hyprland-1793d1)
![QuickShell 0.3+](https://img.shields.io/badge/QuickShell-0.3%2B-b9a3e3)
![Wayland](https://img.shields.io/badge/Wayland-1c1b2e)
[![Umbral compatible](https://img.shields.io/badge/Umbral-compatible-8b5cf6)](https://github.com/madkyp/umbral-project)

**A one-click app installer and manager for Arch / CachyOS**, with a [QuickShell](https://quickshell.outfoxxed.me/) UI (Wayland / Hyprland) and a *CONTROL DECK* look.

Drop a package and it installs itself; manage, edit and uninstall the apps in your menu; search and install by name from the repos, the AUR, Flatpak or GitHub releases; keep everything updated and your system clean — all from one window.

🎮 Its GAMING tab works with your Steam games and with **[Umbral](https://github.com/madkyp/umbral-project)**, a launcher for Battle.net and games from no store. See [Umbral compatibility](#-umbral-compatibility).

> Inspired by the [r/unixporn post](https://www.reddit.com/r/unixporn/comments/1ugobnt/oc_install_any_app_with_just_one_click/) *"install any app with just one click"*.

> 🤖 **This project was built with the help of AI.** See the [disclaimer](#-disclaimer) below.

---

## ✨ Features

The window has six tabs, in English or Spanish (**ESP / ENG** next to the title):

### 📥 INSTALL — from a file or a URL
- **Drag and drop** one or more packages (multi-file queue) and hit **INSTALL ALL**.
- Or type a **path**, a direct **download URL** or a **GitHub repo** (`github.com/user/repo` or `user/repo`, which opens its releases in STORE).

| Format | What happens |
|---|---|
| `.AppImage` | Stored as `~/Applications/<app>.AppImage` with a launcher that uses the **real name, icon, categories, WM class and MIME types** shipped inside it. Installing a newer version **replaces** the old one and **keeps your edits** |
| `.pkg.tar.zst` `.xz` `.gz` `.pkg.tar` | `pacman -U` (via `pkexec`) |
| `.flatpak` | `flatpak install --user` |
| `.tar` `.tar.gz` `.tgz` `.tar.xz` `.tar.zst` `.tar.bz2` | Extracted to `~/Applications/<app>`; the main executable and its icon are detected and **a launcher is created** |
| `.deb` | With [`debtap`](https://aur.archlinux.org/packages/debtap) installed, converted to an Arch package and installed with pacman |

> `.rpm` is detected but only produces a warning (not native to Arch).

### 🗂️ MANAGE — installed apps
- **Every app in your menu** with icon, filter, source and **disk usage** (program + user data) — sort by **A–Z** or **SIZE**.
- **Edit** name and icon (the icon is copied to a managed folder) and, under **MORE ▾**:
  - the **Exec** line (arguments, `env VAR=1 …`) with a **WAYLAND** button that adds the Ozone flags for Electron/Chromium apps,
  - **categories**, **hide from the menu** (without uninstalling; hidden apps stay listed here so you can bring them back) and **terminal**.
- **Quick actions**: ▶ launch, 📂 open the app's folder, 📋 copy its command.
- **Why won't it start?** LAUNCH runs the app with its output captured; if it dies on start-up the deck explains why and offers a one-click fix:

  | Problem | Fix offered |
  |---|---|
  | Missing FUSE 2 (old AppImage runtimes) — detected **before** launching | **INSTALL fuse2** or **RUN WITHOUT FUSE** (extract-and-run) |
  | Missing shared library | Finds the package that ships it → **INSTALL** |
  | Chromium/Electron sandbox failure | **ADD --no-sandbox** |
  | Missing Qt Wayland plugin | **INSTALL qt6-wayland** / qt5 |
  | Missing Python module | **INSTALL python-…** |
  | Broken launcher, wrong architecture, permissions, old glibc | Explained (and fixed when possible) |

- **AUTOSTART** *(opt-in, per app)*: start the app when you log in (XDG autostart entry). Nothing is enabled unless you switch it on.
- **Flatpak permissions** (a tiny Flatseal): network, Wayland, X11, audio, Bluetooth, devices, home folder, whole filesystem, Downloads — toggled as user overrides, with **RESET**.
- **Safe uninstall** depending on the source:
  - **Flatpak** → `flatpak uninstall` (in the right installation: user or system)
  - **AppImage / tar** → deletes the file or folder + icon + launcher
  - **pacman package** → `pacman -Rns` (with a **preview** of what would be removed)
  - **Wine / DOSBox** → removes the menu shortcut
  - **Steam / Lutris / Heroic shortcuts** → only the shortcut, **never** the client
- **+ DELETE DATA**: also deletes the app's config, data and cache (`~/.config/<app>`, `~/.local/share/<app>`, `~/.cache/<app>`, `~/.var/app/<id>`), **showing the exact folders first**. Never offered for games, Wine or shared folders.

### 🛒 STORE — install by name
- Searches the **official repos (pacman)**, the **AUR** and **Flatpak** at once.
- **Filter by source** (ALL · REPO · AUR · FLATPAK, with counts).
- **Trust tags** tell good results from suspicious ones; hover a tag to see what it means:
  - repos: **OFFICIAL** (Arch / CachyOS), **PREBUILT AUR** (chaotic-aur) or **THIRD-PARTY REPO**;
  - AUR: votes (▲276), **POPULAR**, **FEW VOTES**, **ORPHAN**, **OUT OF DATE**, and **NEW · FEW VOTES** in red (the usual shape of malicious AUR packages);
  - Flatpak: **VERIFIED** developer and installs last month, from Flathub's API.

  The most trustworthy result named like your search is marked **★ RECOMMENDED** and listed first: an official package beats a Flatpak, which beats the AUR.
- Type `github.com/user/repo` to see the installable files of its **latest release** (filtered for your architecture). Things installed from GitHub stay linked to their repo so they can be updated.
- **AUR packages are reviewed before they are built**: maintainer, votes, age and the full PKGBUILD (+ `.install`), with a **risk level** and findings such as `curl | sh`, base64-decoded payloads, `sudo` in the build, reverse-shell patterns, downloads from raw IPs / paste sites / plain HTTP, skipped checksums, `.install` scripts that download things, orphaned or brand-new packages. High-risk packages need a second confirmation.
- One click to install: repos → `pkexec pacman -S` · Flatpak → `flatpak install --user` · AUR → review, then a terminal with `paru`/`yay` · GitHub → download + install.

### ⬆️ UPDATES
- Everything pending in one view: **repos** (`checkupdates`), **AUR** (`paru`/`yay -Qua`), **Flatpak** and **AppImages/tarballs** (GitHub releases or `appimageupdatetool`).
- **UPDATE ALL** or one at a time. Repo packages update together (`pacman -Syu`): Arch doesn't support partial upgrades.
- **AUTO-CHECK** *(opt-in)*: a systemd user timer checks every 6 hours **even with the deck closed** and sends a notification (once per set of updates); clicking it opens the deck on this tab.
- **Arch news first**: news published on archlinux.org since your last full upgrade is shown above the list (some need manual steps before upgrading). While there is unread news, a system upgrade needs a second click.
- **GE-Proton**: when you already use GE-Proton, new releases show up here too (checksum-verified, unpacked next to the old ones; CLEAN lists the old builds nothing uses).
- **Control Deck updates itself**: when GitHub has a newer version of the deck it shows up here (and as *● NEW VERSION* in the header, next to the installed version). Updating runs `git pull` + `install.sh` in your clone — or downloads the latest code if you didn't install from a clone — and the window reloads by itself.

### 🧹 SYSTEM — clean-up, backup and history
- **CLEAN**: orphan packages, pacman cache (`paccache`), unused Flatpak runtimes, AUR cache, deck downloads, **broken launchers** (moved to a trash folder, not deleted) and, for gaming, stale/orphan **shader caches**, **orphan prefixes** (backed up first) and **unused Proton versions** (none of Steam, Umbral, a prefix or a running game uses them) — with the space each one takes. The gaming rows ask for a second click.
- **BACKUP**: exports your packages (repos and AUR), Flatpaks, GitHub AppImages and the launchers you edited (with their icons) to a `.json`; **RESTORE** reinstalls whatever is missing on another machine or after a reinstall. Game profiles, looks and FX settings travel too (**GAMING ONLY** brings back just those), and LIBRARY → **CHECK FOR THIS PC** flags what doesn't fit the new machine (e.g. NVIDIA variables on an AMD PC) with a one-click **FIX ALL**.
- **HISTORY**: a log of everything you installed, edited, updated, cleaned or removed.
- **SNAPSHOTS** (snapper): list your snapshots, **create** one before trying something risky, see **which packages changed** since any snapshot (added / removed / upgraded) and how to roll back (with a shortcut to *Btrfs Assistant* when installed).
  - **Delete** the snapshots you tick (a *pre* and its *post* are always ticked together) or hit **CLEANUP NOW** to apply snapper's own limits right away (what `snapper-cleanup.timer` does every hour). The tab shows those limits (e.g. keep 50, 15 important). Btrfs snapshots cost almost nothing when taken and grow as files change afterwards; deleting them frees that space.
  - If your snapper config only lets root list snapshots, load them with your password or — opt-in — allow your user to list them (`ALLOW_USERS`).
  - With **snap-pac** installed every pacman operation already gets pre/post snapshots, so the deck doesn't add more. Without snap-pac, the deck takes a snapshot itself before any pacman change it makes (same password prompt).

### 🎮 GAMING — per-game profiles and compatibility
- **LIBRARY**: your installed Steam games — plus the games of [Umbral](https://github.com/madkyp/umbral-project) (Battle.net and games from no store) — with size, **ProtonDB** rating for Steam games (public summary, cached 24 h), the Proton version each one uses, and **▶ PLAY** to start any of them from its own launcher.
- **Per-game profile**: gamemode, MangoHud, IO priority, nice, environment variables, a prefix (e.g. `gamescope -f --`) and extra arguments. **USE IN STEAM** turns the game's current launch options into its profile and makes Steam launch it through `control-deck run %command%` (**RESTORE STEAM** undoes it). Nothing it changes outlives the game: the CPU governor is handled by gamemode's daemon, which restores it even if the game crashes.
- **PLAYERS USE**: launch options suggested from ProtonDB's open data (ODbL) — for each game, the share of players **with hardware like this PC** (same GPU vendor, ±1 generation) who report it works and use each option. Options used by ≥ 20 % of them are marked **★ RECOMMENDED FOR THIS PC**; the hardware is detected every time, so the same install recommends different things on an NVIDIA laptop and an AMD desktop. Values like `-threads` or `-w`/`-h` are adapted to this CPU and screen, and vendor-only variables (`RADV_*`, NVAPI…) only show on that vendor. The data covers ~6 900 games, so games you install later get suggestions too, and new games are flagged in the library. Click a suggestion to add it, then SAVE; nothing is applied on its own.
- **Proton version per game**, from the ones you have installed (Steam must be closed; a backup of its config is kept).
- **UPSCALE** (per game): **FSR 4**, **DLSS** or **XeSS** upgrades through GE-Proton / Proton-CachyOS — Proton downloads the newest DLLs itself, nothing to install by hand. Each option is offered only when the game ships the right DLL, the GPU supports it (FSR 4: Radeon RX 9000; DLSS: RTX) and the game's Proton can do it; otherwise it says why. **FSR 4 via OptiScaler** brings FSR 4 to games that only offer DLSS/XeSS/FSR 2 (RX 9000; never offered with anti-cheat), again set up by Proton.
- **When a game ends**: games launched through the deck are watched until they close — a crash raises a notification with the error code and where the log is, and a **session summary** (time played, max temperatures, load, power) is sent and kept in STATUS → LAST SESSIONS.
- **SHADERS**: every game's shader cache split into Steam's pipeline recordings and the GPU driver's compiled cache (NVIDIA or Mesa for AMD/Intel), with **stale** caches (not used since the last driver update) and **orphans** (uninstalled games) detected and cleanable. UPDATES warns before an update that changes the GPU driver.
- **BENCH**: A/B benchmark of two launch variants (env, args, gamemode, Proton) with MangoHud frame logs: average FPS, 1 % / 0.1 % lows, p99 frametime and both frametime curves side by side.
- **PREFIXES**: every Wine/Proton prefix (Steam, Heroic, Faugus, Bottles, standalone) with size, last use, version and orphans (games no longer installed); backup, instant clone (Btrfs reflink), restore, and delete with an automatic backup first.
- **TEMPS** (per game, in LIBRARY): a one-line `CPU 54° · GPU 51°` readout at the top right while the game runs — the deck's own overlay (a Quickshell layer above fullscreen games, click-through, amber from 75 °C, red from 85 °C), not MangoHud. It closes with the game.
- **FX** (visual shaders), per game: **ReShade** itself (downloaded from reshade.me, installed as links next to the game's .exe — API and 32/64-bit detected from the executable — loaded through Proton with DLL overrides, removed cleanly with OFF) or **vkBasalt** (a Vulkan layer). Quick looks (CAS sharpening, SMAA/FXAA, clarity) and **per-game presets from SweetFX Settings DB**, with the shaders they need fetched from the official packages. Presets downloaded by hand (e.g. from Nexus Mods: zip, 7z, rar or .ini) are **imported** in one click, with the shaders they bring. Free community packs that ReShade's own list lacks (e.g. NiceGuy-Shaders) are fetched too, and the black-and-white **TEST** look shows at once that the effects are drawn. **★ marks the right tool for each game** (ReShade or vkBasalt) and says why — e.g. a Vulkan game needs vkBasalt, a 2D RPG Maker game can't be hooked by either. When a game is set up, a single **READY** line shows the look and its keys; otherwise only the next step is shown. ReShade screenshots go to `~/Pictures/ReShade/<game>`. AMD and NVIDIA alike. Online games get a warning, anti-cheat ones a red one and a confirmation click. The menu key is configurable. **MY LIBRARY** scans every game — best preset on SweetFX DB by downloads, ReShade compatibility and depth settings from PCGamingWiki, anti-cheat risk — and **SET UP ALL** installs ReShade with them on every single-player game in one go (anti-cheat games are never touched).
- **HEALTH**: what games need from the system — multilib, GPU driver (NVIDIA versions in sync after updates, `nvidia_drm modeset`; Mesa/RADV on AMD, AMDVLK warning), Vulkan devices, 32-bit libraries, `vm.max_map_count`, ntsync. Read-only: each problem shows the exact fix command with a COPY button.
- **STATUS** (live, refreshed every 3 s while open): the game running now (uptime, Proton build, ReShade/vkBasalt in use, GameMode), **GPU** (driver, load, VRAM, power vs limit, temperature, clocks and what is holding it back — NVIDIA via nvidia-smi, AMD via amdgpu sysfs), **CPU · memory** (model, MHz, temperature, governor, RAM, swap/zram, kernel, `vm.max_map_count` and the **CPU scheduler**: switch to sched-ext **LAVD Gaming** now, only **WHILE PLAYING**, or **AT BOOT**), **LAST SESSIONS** (summary of each game session with a temperature graph), **WHILE PLAYING** (opt-in: hold notifications — dunst pause or swaync Do Not Disturb — and turn Hyprland's animations, blur and shadows off from the first game that starts until the last one closes; only what the deck changed is put back), **display** (resolution, Hz, VRR) and **gaming tools** (GameMode with a one-click **JOIN GROUP**, MangoHud, gamescope, Steam, ntsync, Proton builds, shaders), with a shortcut to HEALTH.
- **Mods**: with **[Crisol](https://github.com/madkyp/crisol-app)** (the author's mod manager) installed, a game's LIBRARY panel shows its mods (how many are on, the profile, pending changes, updates, a missing mod loader) with **PLAY WITH MODS** and **OPEN IN CRISOL**.
- **Umbral games** ([Umbral](https://github.com/madkyp/umbral-project) ≥ 0.10.0) get TEMPS, FX, the scheduler and the session summary too: Umbral asks the deck for them each time it starts a game. With Umbral ≥ 0.11 the deck knows exactly which of its games are running (no guessing by .exe name) and can close them (**■ STOP** in STATUS). With Umbral ≥ 0.12 their GameMode, MangoHud, Wayland, FPS limit and variables are edited from LIBRARY too, and CHECK FOR THIS PC fixes them.
- Design notes, permissions and what's verified: [`docs/gaming.md`](docs/gaming.md).

> 🔔 Desktop notifications (`notify-send`) when each operation finishes.

---

## 🌑 Umbral compatibility

Control Deck is compatible with **[Umbral](https://github.com/madkyp/umbral-project)** (`github.com/madkyp/umbral-project`), a GTK launcher for Battle.net (World of Warcraft…) and for Windows games from no store, running with Proton. Install both and they work together: Umbral's games show up in GAMING next to Steam's.

| Umbral | What Control Deck does with its games |
|---|---|
| any | LIBRARY lists them (size, playtime, prefix and Proton) and ▶ PLAY starts them through Umbral; PREFIXES shows their prefixes with the game using each one, and flags the ones no game uses |
| ≥ 0.10 | Umbral asks the deck for **FX** (ReShade / vkBasalt) and **TEMPS** when it starts a game; the CPU scheduler *while playing*, *while playing* quiet notifications / lighter Hyprland and the **session summary** follow the game |
| ≥ 0.11 | Exact **running games** from Umbral's `running.json` (pids with their start time, no guessing by `.exe` name) and **■ STOP** in STATUS |
| ≥ 0.12 | A game's **options edited from LIBRARY** (GameMode, MangoHud, Wayland, FPS limit, variables) through `umbral --get / --set`, and **CHECK FOR THIS PC** fixing them after moving to another PC |

Nothing is needed on Control Deck's side: it finds `umbral` in your `PATH` and reads `~/.config/umbral/config.json`. With an older Umbral, the features it doesn't support yet stay read-only. How the two talk to each other is described in Umbral's README ("Integration") and in [`docs/gaming.md`](docs/gaming.md).

---

## 📸 Screenshots

| INSTALL | MANAGE | STORE |
|---|---|---|
| ![INSTALL — drop zone and supported formats](screenshots/install.png) | ![MANAGE — apps with source and disk usage](screenshots/manage.png) | ![STORE — search across repos, AUR and Flatpak](screenshots/store.png) |

| UPDATES | SYSTEM · CLEAN |
|---|---|
| ![UPDATES — pending updates and the opt-in auto-check](screenshots/updates.png) | ![SYSTEM — clean-up with the space each item takes](screenshots/clean.png) |

| SYSTEM · BACKUP | SYSTEM · HISTORY | SYSTEM · SNAPSHOTS |
|---|---|---|
| ![SYSTEM — backup export and restore](screenshots/backup.png) | ![SYSTEM — operation history](screenshots/history.png) | ![SYSTEM — snapper snapshots: create, diff, delete, cleanup](screenshots/snapshots.png) |

| GAMING · LIBRARY | GAMING · STATUS | GAMING · HEALTH |
|---|---|---|
| ![GAMING — library, per-game profile, mods (Crisol), UPSCALE and suggestions for this PC](screenshots/gaming-library.png) | ![GAMING — live status: GPU, CPU and scheduler, last sessions, tools](screenshots/gaming-status.png) | ![GAMING — health checks of what games need](screenshots/gaming-health.png) |

| GAMING · FX (this game) | GAMING · FX (my library) | Spanish interface (ESP) |
|---|---|---|
| ![FX — ReShade ready on a game, the recommended route and quick looks](screenshots/gaming-fx.png) | ![FX — every game: best preset, recommended tool, anti-cheat risk](screenshots/gaming-fx-library.png) | ![The FX tab with the interface in Spanish](screenshots/spanish.png) |

---

## 🧩 Requirements

**Required:**
- [`quickshell`](https://quickshell.outfoxxed.me/) `>= 0.3`
- `bash`, `coreutils`, `jq`, `libarchive` (`bsdtar`), `pacman`
- `polkit` + a graphical agent (e.g. `hyprpolkitagent`) — for pacman's `pkexec`
- A **Nerd Font** (the UI uses *JetBrainsMono Nerd Font* for its icons)

**Optional (depending on what you use):**
- `flatpak` with the `flathub` remote — install/search/update Flatpaks
- `libnotify` (`notify-send`) — notifications
- `curl` — AUR, GitHub and URL downloads
- `pacman-contrib` — `checkupdates` and `paccache` (UPDATES and CLEAN)
- `paru` or `yay` + a terminal (`kitty`, `alacritty`…) — AUR
- `zenity` — file pickers (icons, backup restore)
- `wl-clipboard` — copy an app's command
- `python` — FX: reads a game's .exe to tell which graphics API ReShade must hook (without it only 32/64-bit is detected and you pick the API)
- `appimageupdatetool` (AUR) — update AppImages that don't come from GitHub
- `debtap` (AUR) — install `.deb` files (then run `sudo debtap -u` once)
- `snapper` (+ `snap-pac`, `grub-btrfs`, `btrfs-assistant`) — SNAPSHOTS tab and snapshots before pacman changes
- `git` — the deck updating itself from your clone
- `gamemode` (+ `lib32-gamemode`), `mangohud` (+ `lib32-mangohud`), `gamescope` — GAMING profiles
- [Umbral](https://github.com/madkyp/umbral-project) — Battle.net and non-Steam Windows games in GAMING (see [Umbral compatibility](#-umbral-compatibility))

---

## 🚀 Installation

```bash
git clone https://github.com/madkyp/control-deck.git
cd control-deck
./install.sh
```

`install.sh`:
1. **Checks for and installs missing dependencies** (repo packages with `pacman`, AUR ones with `paru`/`yay`). It won't force the Nerd Font if you already have one.
2. Removes the previous version (**Install Deck / `install-any`**) if present. Your apps and launchers keep working: old AppImage launchers are recognised and migrated to the new format the next time you reinstall or update them.
3. Copies the files:
   - `bin/control-deck` → `~/.local/bin/control-deck` (bash backend)
   - `quickshell/shell.qml` → `~/.config/quickshell/control-deck/shell.qml` (GUI)
   - `control-deck.desktop` → `~/.local/share/applications/` (launcher)
   - `icons/control-deck.svg` → `~/.local/share/icons/hicolor/scalable/apps/` (icon)

> Only copy the files, don't touch dependencies → `./install.sh --no-deps`

Make sure `~/.local/bin` is in your `PATH`.

### Update
The easy way: when a new version is out, it appears in the **UPDATES** tab (and as *● NEW VERSION* in the header) — hit **UPDATE**.

By hand:
```bash
cd ~/control-deck
git pull
./install.sh --no-deps
```

A running deck reloads its window by itself when the new UI is installed. Your history, logs, edited launchers and the background update check (if you turned it on) are kept. If a new version needs extra dependencies, run `./install.sh` without `--no-deps`.

### Uninstall
```bash
./uninstall.sh
```

---

## 🖱️ Usage

- From your app launcher: **"Control Deck"**.
- From a terminal: `qs -c control-deck`
- Open straight on a tab: `CONTROL_DECK_VIEW=updates qs -c control-deck` (`manage`, `store`, `updates`, `system`).
- Language: the **ESP / ENG** switch next to the title changes the whole interface between English and Spanish. The first time it follows your system language; the choice is saved (`control-deck uilang es|en`). Logs and notifications stay in English.
- Full CLI: `control-deck help` (e.g. `control-deck install <file>`, `control-deck updates`, `control-deck aurreview <pkg>`, `control-deck export`).

### Hyprland keybind (optional)
Add to your `~/.config/hypr/keybindings.conf` (or `hyprland.conf`):

```ini
bind = SUPER SHIFT, I, exec, pkill -xf "qs -c control-deck" || qs -c control-deck
```

Toggles the deck with **SUPER + SHIFT + I**. If Hyprland tiles it, add a **floating** window rule for the title `Control Deck` (660×760 works well) using your Hyprland version's syntax.

---

## ❓ Installing an app from a GitHub repo

Type the repo (`github.com/user/repo` or `user/repo`) in **STORE** or in the **INSTALL** bar: the deck lists the installable files of its latest release and installs them with one click, linked for **UPDATES**.

| What the project publishes | How to install it |
|---|---|
| Releases with `.AppImage` / `.flatpak` / `.tar.*` / `.pkg.tar.*` / `.deb` | **STORE** → `user/repo` → **INSTALL** |
| It's in the **AUR** | **STORE** → search → **REVIEW** → **BUILD & INSTALL** |
| Only **source code** with a `PKGBUILD` | `git clone` + `makepkg -si` (by hand) |
| Only source with an `install.sh` / Makefile | Follow the project's own README |

> The GitHub API allows 60 unauthenticated requests per hour. If you run out, export `GITHUB_TOKEN` before opening the deck.

---

## 🏗️ How it works

**Script backend + thin GUI**:

- **`bin/control-deck`** — a bash script with all the logic, fully usable without the GUI (`control-deck help`).
- **`quickshell/shell.qml`** — the UI, which only shows state and calls the backend through `Process`.
- **`quickshell/es.js`** — the Spanish text: English string → Spanish, plus a few patterns for backend sentences that carry values. A missing entry just shows the English text, and `tests/run.sh` flags entries no longer used anywhere.

Launchers created by the deck carry their own keys (`X-ControlDeck-Type`, `X-ControlDeck-File`, `X-ControlDeck-Github`, `X-ControlDeck-Version`…) so it knows where they came from, how to update them and how to remove them cleanly. History, launch logs and the launcher trash live in `~/.local/share/control-deck/`.

### Tests

```bash
tests/run.sh
```

The suite runs the backend in a throw-away `$HOME` with stubbed system tools (`pacman`, `pkexec`, `flatpak`, `systemctl`, `curl`…): no root, no network, nothing on your system is touched. GitHub Actions runs it — plus `shellcheck` — on every push, in an Arch Linux container.

---

## ⚠️ Safety notes

- Game shortcuts (`steam://`, `lutris:`, `heroic://`) are treated as user launchers: **uninstalling only removes the menu shortcut**, never the client or the game data (not even with *DELETE DATA*).
- Before a `pacman -Rns` the deck shows **which packages would be removed**; with *DELETE DATA*, **which folders** will be deleted.
- AUR packages are **reviewed before building**, and high-risk ones need a second confirmation. The review is a set of heuristics, not a guarantee: only build packages you trust.
- System entries with no owning package are never uninstalled.
- Broken launchers are **moved** to `~/.local/share/control-deck/trash/`, not deleted.
- Autostart and the background update check are **opt-in**: nothing runs at login unless you turn it on.
- Arch news published since your last upgrade is shown before a system upgrade, and needs an extra click to go ahead.

---

## 🤖 Disclaimer

This project was created **with the help of AI** (Anthropic's Claude, through Claude Code). The code was written together with the AI, then reviewed, tested (see [Tests](#tests)) and used on a real Arch / CachyOS + Hyprland system, but:

- It is provided **as is**, without warranty of any kind (see the [license](LICENSE)).
- It runs privileged operations through `pkexec` (installing, removing and upgrading packages) and can delete files when you ask it to uninstall apps or purge their data. **Read what it is about to do** — the deck always shows it before acting — and keep backups / snapshots of your system.
- The AUR security review is a set of heuristics that helps you spot suspicious PKGBUILDs; it is **not** a guarantee that a package is safe.

Found a bug or something that looks wrong? Please open an issue.

---

## 📄 License

MIT — see [LICENSE](LICENSE).
