# GAMING tab — design notes and module status

This document tracks the gaming extension of Control Deck: what was found on
the reference system, how the modules fit the existing architecture, and what
each implemented module does, needs and depends on.

## Reference system (phase 0)

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 2070 (TU106), proprietary driver 615.71.09, Vulkan ICD `nvidia_icd.json` |
| CPU | Intel i7-4790K, `intel_cpufreq` driver, governor `schedutil` (performance available) |
| Session | Hyprland 0.56 on Wayland |
| Filesystem | Btrfs (`@`, `@home`), snapper + snap-pac + grub-btrfs |
| Launchers | Steam (3 games, 1 library), Lutris and Heroic installed with no games, Faugus (Flatpak) |
| Present | gamemode (+lib32), MangoHud (+lib32), gamescope, umu-run, protontricks, winetricks, cpupower, lm_sensors, `multilib` enabled |
| Absent | vkBasalt, ReShade, LACT/CoreCtrl, Timeshift, Syncthing, rclone |
| Available | `lact` and `corectrl` in `extra`; `vkbasalt`/`lib32-vkbasalt`/`reshade-shaders-git` in chaotic-aur and the AUR |
| `vm.max_map_count` | 1048576 (Arch default since the 2024 `filesystem` package) |

Privileges found: gamemode ships a polkit rule letting members of the
`gamemode` group run its governor/GPU/CPU/procsys helpers without a password,
plus `limits.d` allowing that group `nice` down to −10. The user is not in the
group yet. Everything else in Control Deck already goes through `pkexec`.

## Architecture (phase 1)

- **Same pattern as the rest of the app**: all logic in `bin/control-deck`
  subcommands (JSON / `KEY=VALUE` out), the QML only renders and calls them.
- **Data**: `~/.local/share/control-deck/gaming/profiles.json`
  (`{"default": {...}, "steam:<appid>": {...}}`); ProtonDB cache in
  `~/.cache/control-deck/protondb/<appid>.json` (24 h).
- **Applying a profile**: Steam's launch options become
  `~/.local/bin/control-deck run %command%`. The wrapper sets env vars, `nice`
  / `ionice` on itself, and `exec`s `gamemoderun [mangohud] [prefix] <game> [args]`.
- **Reverting safely**: nothing the wrapper does outlives the game. env, nice
  and ionice die with the process; the CPU governor is changed by the gamemode
  *daemon*, which restores it when the registered process exits, including a
  crash or `SIGKILL` (it polls registered PIDs). No restore step lives inside
  Control Deck, so closing or crashing the deck can't leave the system tuned.
  Future modules that change state gamemode doesn't know about (GPU power
  limits) will use a watchdog of the same kind: a separate process tied to the
  game's PID, never a `finally` in the GUI.
- **Privileges**: one path per kind of change. Reversible per-game tweaks go
  through gamemode (polkit rule + `gamemode` group, joined once from the STATUS
  view). One-off admin actions keep using `pkexec`, like the rest of the app.
  There is no `sudo`, and no new privileged service.
- **Steam files**: `localconfig.vdf` / `config.vdf` are edited with a small
  KeyValues editor (case-insensitive keys, creates missing blocks, keeps the
  rest byte-for-byte). Writes refuse to run while Steam is open (it rewrites
  both files on exit) and leave a `*.control-deck.bak` copy.

## Implemented

### 2.1 Game profiler — `GAMING → LIBRARY / STATUS`
- Library of installed Steam games (tools, runtimes and redistributables
  filtered out) with size, Proton version, ProtonDB tier and whether the deck
  wraps them.
- Per-game profile: gamemode, MangoHud, IO priority (`ionice -c2 -n0`),
  nice (0 / −5 / −10), environment variables, a prefix (e.g. `gamescope -f --`)
  and extra arguments. The user `default` profile applies to unlisted games.
- **USE IN STEAM** adopts the game's current launch options into its profile
  (`VAR=x mangohud gamemoderun %command% -args` → env / toggles / args), saves
  the original, and points Steam at the wrapper. **RESTORE STEAM** puts the
  original back.
- STATUS: gamemode installed / active / group membership (with **JOIN GROUP**),
  CPU governor, `vm.max_map_count` check, MangoHud / gamescope, and games
  running now (processes whose environment has `SteamAppId`).
- Permissions: none to edit profiles; Steam must be closed to wrap/unwrap;
  `gamejoin` uses `pkexec usermod -aG gamemode` once (re-login needed).
- Tools: gamemode (recommended), mangohud (optional), gamescope (optional).
- CLI: `games`, `gstatus`, `gprofile get|set|reset`, `run`, `steamwrap`, `gamejoin`.

### Umbral games in the library
- [Umbral](https://github.com/madkyp/umbral-project) is the user's launcher for
  Battle.net and games from no store. Its library
  (`~/.config/umbral/config.json`: `prefixes[]`, `games[]`) is read — never
  written — and its non-hidden games join the Steam ones in LIBRARY as
  `umbral:<id>`: kind (Battle.net client / Battle.net game / own game), prefix
  and Proton runner, game folder size, playtime and last play. New Umbral games
  are flagged **NEW** like Steam ones.
- **▶ PLAY** starts any library game from its own launcher:
  `steam://rungameid/<appid>` or `umbral --launch <id>`.
- Umbral games have their own launch options in Umbral (Proton, gamemode,
  MangoHud, gamescope…), so the profile editor, ProtonDB and BENCH stay
  Steam-only. Their prefixes appear in PREFIXES as **UMBRAL** with Umbral's names.
- A running Umbral game is found by its `.exe` in a process's arguments (exact
  file name, read in bash so the search can't match itself).
- CLI: `games` (includes them), `gplay <key>`.

### 2.2 Shader-cache assistant — `GAMING → SHADERS`
- Per game, Steam's `steamapps/shadercache/<appid>/` (every library) split
  into **pipelines** (`fozpipelinesv6`, Fossilize recordings — driver-
  independent, what Steam pre-compiles from), **driver** (`nvidiav1` on NVIDIA,
  `mesa_shader_cache*` on AMD/Intel — the compiled cache, tied to the driver
  version), **dxvk** (`DXVK_state_cache`, empty with DXVK ≥ 2.0), **videos**
  (`transcoded_video.foz`, `fozmediav1`) and other. Global driver caches:
  `~/.cache/nvidia/GLCache` (+ legacy `~/.nv/GLCache`), `~/.cache/mesa_shader_cache`
  and `mesa_shader_cache_db`.
- **Driver updates**: the last install/upgrade of a driver package
  (`nvidia*-utils`, `nvidia-open-dkms`, `mesa`, `vulkan-radeon|intel|nouveau`,
  `amdvlk`, lib32 included) is read from `pacman.log`. A driver cache with no
  file written after it is **stale** (the game hasn't been played since, so
  it's all old-driver data). Before updating, the UPDATES tab warns when the
  pending update changes the GPU driver.
- Caches of games no longer installed are **orphans**.
- Cleaning (always a second click to confirm): a game's driver cache only,
  the whole game folder, all stale caches, all orphans, or a global driver
  cache. Folders are emptied, not removed, where Steam/the driver expect them.
  Refused while Steam is compiling shaders (`fossilize_replay`) or while the
  game (for global caches: any game) is running.
- Pre-warming: Steam already does it from the Fossilize recordings (Settings →
  Downloads → Shader Pre-Caching); the deck shows when it's running. The
  setting itself isn't stored in any Steam file the deck could verify, so it's
  not read or changed.
- **AMD/Intel**: Mesa paths follow Mesa's defaults and the folder names Steam
  uses; verified here only on NVIDIA.
- CLI: `shadercache`, `shaderclean steam:<appid> [driver|all] | orphans | stale | global:<id>`.

### 2.3 A/B benchmark — `GAMING → BENCH`
- Two variants of the selected game's launch: extra env vars, args (replace
  the profile's), gamemode on/off/profile and Proton version. Measure time
  (30–300 s) and a delay before measuring (skips loading screens).
- **RUN A/B** arms the wrapper for exactly one launch and starts the game from
  Steam (`steam://rungameid/<appid>`). The wrapper overlays the variant and
  turns on MangoHud frame logging (`output_folder`, `autostart_log`,
  `log_duration`, `log_interval=0`) into the variant's folder; the next normal
  launch is untouched. A variant that changes Proton needs Steam closed; the
  original Proton is remembered and **RESTORE PROTON** puts it back.
- MangoHud's per-frame CSV was verified on this system (0.8.4): 2 system-info
  lines, a column header, one row per frame (`frametime` in ms). Its own
  `*_summary.csv` reported "Average FPS 0.0" and is ignored; frames longer than
  5 s (pauses, and one bogus 16 330 800 ms frame seen in a real log) are
  dropped. Stats: average FPS, 1 % and 0.1 % lows (average of the slowest
  1 % / 0.1 % frames), p99 frametime, spikes (> 2.5× the average frametime),
  CPU/GPU load and max temperatures. Cross-check: the 1 % low of a real vkcube
  run (59.8) matched MangoHud's own (59.77).
- The UI compares A and B (% change, green = better) and draws both frametime
  curves (worst frame per bucket, so stutter stays visible).
- Needs: `mangohud` (+`lib32-mangohud`), the game launched through the deck.
- CLI: `bench get|set|run|restore|clear steam:<appid> …`.

### 2.6 Wine/Proton prefix manager — `GAMING → PREFIXES`
- A prefix is any folder with `system.reg` + `drive_c` (incomplete folders are
  ignored). Searched in every Steam library's `compatdata/<appid>/pfx`, Heroic
  (`…/Heroic/Prefixes/`), Faugus (its configured `default-prefix`), Bottles,
  `~/.wine`, `~/.local/share/wineprefixes` (winetricks) and `~/Games` (Lutris
  and umu defaults), 4 levels deep.
- Per prefix: launcher, game name (Steam), size, last use (`system.reg` mtime,
  written by Wine on shutdown), Proton/Wine version, arch, and whether it's in
  use (a process with `WINEPREFIX` or `STEAM_COMPAT_DATA_PATH` pointing at it).
- Steam prefixes of games no longer installed are **orphans**; a compatibility
  tool's own prefix (e.g. Proton Experimental, 1493710) and `compatdata/0`
  (Steam's shared one) are marked as such and can't be deleted from the deck.
- **Backup** → `~/control-deck-backups/prefixes/<launcher>-<name>-<date>.tar.zst`
  (gzip without zstd). **Clone** → `cp -a --reflink=auto` (instant and
  space-free on Btrfs until files diverge). **Delete** always backs up first;
  only prefixes the deck found can be touched, Steam ones only as
  `…/steamapps/compatdata/<appid>` (libraries may be on other drives), the rest
  only inside `$HOME`. **Restore** only from the deck's backup folder into a new
  folder. Everything is refused while the prefix is in use.
- Verified here: 7 prefixes (Steam, Steam shared, Proton tool, three
  umu/Umbral prefixes). Lutris/Heroic/Bottles have no prefixes on this system,
  so their detection is covered by path rules only.
- CLI: `prefixes`, `prefix backup|clone|delete <path>`, `prefix restore <backup> <dest>`, `prefix backups`.

### 2.5 Compatibility manager (Steam + ProtonDB)
- ProtonDB **summary** per game: tier, score, report count, trending tier,
  confidence. Only the public summary endpoint is used
  (`/api/v1/reports/summaries/<appid>.json`), one request per game, on demand,
  cached for 24 h, with the app's own User-Agent. It is not an official,
  documented API: if it disappears the deck shows "no data".
- **Launch-option suggestions from ProtonDB's open data.** ProtonDB publishes a
  monthly dump of every report (github.com/bdefore/protondb-data, **ODbL**), and
  ~15 % of reports include the player's launch options. `pdbindex update`
  streams the newest dump (≈70 MB download, never unpacked to disk, a few MB of
  RAM, ~1 min) into a local index of every report with launch options — about
  59 000 reports for ~6 900 games (≈5 MB) — so games installed later get
  suggestions with no extra download. `gsuggest <appid>` then counts, among the
  reports that say the game **works** (last 3 years, or all time when there are
  fewer than 8), how many use each option: env variables, wrappers
  (`gamemoderun`, `mangohud`, …) and arguments (`+cvar value` / `-flag value`
  kept together). Shares are given overall and for **your GPU vendor**;
  vendor-specific variables (`RADV_*`/Mesa → AMD, `__GL_*`/NVAPI → NVIDIA) are
  marked and hidden when they don't fit, personal paths (`~/lsfg`) are dropped.
- **Recommended for this PC.** Every report in the index carries the player's
  GPU generation (an ordinal per vendor: NVIDIA GTX 700 … RTX 50, with GTX 16
  counted as Turing like RTX 20; AMD RX 400/500, Vega, RX 5000/6000/7000/9000,
  Steam Deck = RDNA2). Shares are computed among players whose GPU is the
  **same vendor and ±1 generation** as this PC (falling back to same vendor,
  then everyone, when there are fewer than 5 such reports). An option is
  marked **★ RECOMMENDED FOR THIS PC** when ≥ 20 % of those players use it
  (and at least 5 reports). An **environment variable** additionally needs to be
  set by more of them than leave it unset: not setting it means keeping the
  default, which is a choice too (e.g. Deadlock on RTX 20-class GPUs: 32 % set
  `PROTON_ENABLE_WAYLAND=1`, 62 % keep the default, so it is not recommended).
  When the profile already gives that variable another value, the chip says
  so (`you: =0 · 62 % keep default`). The hardware is read every time (GPU name from
  `nvidia-smi`/`lspci`, CPU threads, focused monitor), so the same install on
  another PC — e.g. an RTX 2070 laptop and an RX 9070 XT desktop — gets
  different recommendations. Hardware-dependent values are grouped and
  rewritten for this PC: `-threads N` → this CPU's thread count, `-w`/`-h`
  (and `-width`/`-height`) → the focused monitor's resolution (dropped when
  unknown), `+fps_max N` → the monitor's refresh rate. Any other option with a
  numeric value (`+cvar 2`, `-flag 16`) is grouped across values and shown with
  the most common one.
  Suggestions are only shown; clicking one adds it to the editor and nothing is
  saved until **SAVE**. These are statistics of what players use, not a
  guarantee that an option helps.
- **New games are recognised**: the library flags games installed since the
  deck last looked (**NEW**) and shows how many suggestions fit them (💡 n).
- **Proton version per game**: writes Steam's `CompatToolMapping`
  (`config.vdf`). Offered tools are the ones actually installed:
  `proton_experimental` when "Proton - Experimental" is present, plus every
  `compatibilitytools.d/*/compatibilitytool.vdf` (internal name parsed from the
  file). Official numbered Protons aren't offered because their internal names
  aren't in any local file and won't be guessed.
- Note: ProtonDB's `robots.txt` disallows AI crawlers (including
  `anthropic-ai`). The deck's requests are made by the user's app on demand;
  the test-suite uses local fixtures instead of querying ProtonDB.
- CLI: `protondb <appid…>`, `pdbindex update|status`, `gsuggest <appid>`,
  `gtips <appid…>`, `gseen <key>`, `compattools`, `steamcompat <appid> <tool|default>`.

### 2.9 Gaming health — `GAMING → HEALTH`
- Read-only: every check that fails shows the exact command that fixes it, with
  a COPY button (`wl-copy`). Nothing is installed or changed from the deck.
- **System:** `[multilib]` enabled in `pacman.conf`; `vm.max_map_count` ≥ 1048576;
  `/dev/ntsync` present (kernel sync for Proton/Wine; if the kernel has the
  module but it isn't loaded, the fix loads it and adds it to `modules-load.d`).
- **GPU driver**, per GPU found in `/sys/class/drm/card*/device/vendor` (a
  laptop can have two):
  - NVIDIA: the card is bound to the `nvidia` module; `nvidia-utils` +
    `lib32-nvidia-utils` installed; kernel module (`/sys/module/nvidia/version`),
    `nvidia-utils` and `lib32-nvidia-utils` at the same version (a mismatch
    after an update without rebooting stops games from starting → "Restart the
    PC"; a 32-bit mismatch → `pacman -Syu`); `nvidia_drm modeset` on.
  - AMD: `amdgpu` bound; `mesa`, `lib32-mesa`, `vulkan-radeon`,
    `lib32-vulkan-radeon`; AMDVLK installed → warning with the removal command
    (discontinued by AMD, no longer in the repos, can take over from RADV).
  - Intel: `mesa`, `lib32-mesa`, `vulkan-intel`, `lib32-vulkan-intel`.
- **Vulkan:** `vulkan-icd-loader` + `lib32-vulkan-icd-loader`; `vulkaninfo
  --summary` must list a discrete or integrated GPU (only llvmpipe = broken
  driver). Without `vulkan-tools` this check just says how to enable it.
- **32-bit libraries:** audio (`lib32-pipewire` or `lib32-libpulse`) and
  `lib32-gnutls` (online features of Wine games).
- Installed packages are read from pacman's local db (`/var/lib/pacman/local`),
  so nothing needs root. Every package suggested was checked to exist in the
  repos (Arch/CachyOS, September 2026).
- Verified here: RTX 2070 with 615.71.09 — all green. The AMD and failure paths
  are covered by the tests with a simulated sysfs/pacman db.
- CLI: `health`.

### 2.11 Space cleaner — `SYSTEM → CLEAN`
- No new tab: SYSTEM → CLEAN already had pacman cache, AUR cache, orphans and
  Flatpak runtimes. Three gaming rows were added there (second click confirms):
  - **Shader caches**: the stale driver caches and orphan caches that SHADERS
    finds (`shaderclean orphans` + `stale`).
  - **Orphan prefixes**: Steam prefixes of uninstalled games, deleted through
    `prefix delete` (backup first, refused while in use).
  - **Unused Proton versions**: folders in Steam's `compatibilitytools.d` that
    are not in `config.vdf`'s CompatToolMapping (per game or default "0"), not
    a runner in Umbral's config (Umbral's `GE-Proton` = the newest GE it finds,
    Steam's folder included), not the Proton that made a non-Steam prefix
    (prefix `version` = the tool's `version` file) and not in a running
    process' command line. Proton from Steam or a package isn't touched.
- Verified here: Proton-CachyOS Latest (1.5 GiB, a manual copy no game uses)
  is listed; GE-Proton11-7 is kept because Umbral's "GE-Proton" prefixes use
  it. Faugus/Lutris/Heroic runner references aren't read (none installed).

### Temperature overlay (from 2.12) — `LIBRARY → TEMPS`
- Asked for instead of the full session monitor: one line, CPU and GPU °C, top
  right, over the game. Built from scratch (not MangoHud): `quickshell/overlay.qml`,
  installed as the `control-deck-overlay` Quickshell config, a `PanelWindow` on
  the `WlrLayer.Overlay` layer (above fullscreen windows on Hyprland), empty
  input mask (clicks go to the game), no keyboard focus, on the monitor focused
  when the game starts.
- `control-deck run` starts it when the profile has `overlay: true`, passing its
  own pid: the wrapper then `exec`s into the game command, so that pid lives
  until the game ends (for Proton games it's Steam's reaper/Proton chain). The
  overlay polls `control-deck temps <pid>` every 2 s and quits on `ALIVE=0`.
- Sensors: CPU = hwmon `coretemp` "Package id 0" (Intel), `k10temp`/`zenpower`
  Tctl/Tdie (AMD), else ACPI; GPU = `nvidia-smi` (17 ms here), `amdgpu` hwmon
  "edge", `i915`/`xe` hwmon. Colours: amber ≥ 75 °C, red ≥ 85 °C.
- If Steam's environment has no `WAYLAND_DISPLAY`, the first
  `$XDG_RUNTIME_DIR/wayland-N` socket is used.
- Verified here: preview (`control-deck overlay`, 10 s) shows `CPU 54° · GPU 51°`
  at the top right of DP-3 and closes itself. Only Steam games (through the
  wrapper) get it; Umbral games don't go through the wrapper.
- CLI: `temps [pid]`, `overlay [pid]`.

### 2.14 Visual shaders — `GAMING → FX`
- **One route, both vendors:** vkBasalt, a Vulkan layer. Under Proton every
  D3D9–12 game is drawn through DXVK/VKD3D (Vulkan), so it applies to all of
  them; native Linux games only if they render with Vulkan. The layer is the
  same on AMD (RADV) and NVIDIA, and CAS is AMD FidelityFX sharpening. Not
  offered when the profile forces `PROTON_USE_WINED3D=1` (OpenGL) or for
  non-Steam games (they don't go through the wrapper).
- **Two routes, chosen per game** (FX → ROUTE; ★ marks the recommended one):
  **ReShade** (the real one, below) for D3D9–12 / OpenGL games — presets run
  exactly as made, depth effects included, with ReShade's in-game menu — and
  **vkBasalt** for Vulkan-only games or when nothing should touch the game
  folder. Switching keeps the current look.
- **Install (one click):** `vkbasalt` + `lib32-vkbasalt` from chaotic-aur
  through the deck's pkexec pacman (snapshot first without snap-pac), then the
  shader packages the official ReShade installer enables by default, from
  `crosire/reshade-shaders` `EffectPackages.ini` (Standard effects, SweetFX).
  Other packages are fetched automatically when a preset needs one of their
  files (each package lists its `EffectFiles`). Shaders keep the package's
  folder; textures are flattened, because vkBasalt takes one texture folder.
  Stored in `~/.local/share/control-deck/reshade/`.
- **Quick looks** (vkBasalt's own effects, nothing to download): SHARPEN (CAS
  0.5), SHARPEN + AA (SMAA → CAS 0.4), FXAA, CLARITY (DLS).
- **Presets from the internet:** SweetFX Settings DB (sfx.thelazy.net), the
  per-game ReShade preset site. Its JSON search (`/games/game/search/?query=`)
  is prefilled with the game's name, its game page lists presets, and
  `/games/preset/<id>/download/` gives the preset. Requests only happen on a
  user action; the game pages are cached for a day. No robots.txt or terms
  restrict this.
- **Preset → vkBasalt conversion** (checked in vkBasalt's source, 2023-05
  `4f97f09`): it compiles ReShade FX with "uniforms to spec constants", so a
  preset's values can be set by uniform name in `vkBasalt.conf`. What can't be
  carried over, and is listed as skipped in the tab:
  - effects that read the depth buffer (vkBasalt's `depthCapture` "isn't
    ready");
  - a technique that isn't the first one in its `.fx` (vkBasalt only runs
    `techniques[0]`);
  - vector values whose components differ (every component of a spec constant
    gets the same value), which stay at the shader's default;
  - uniforms share one namespace, so when two effects share a name, the first
    effect's value wins.
  Entries on the site that are only a link or text (no `Techniques=`) are
  refused with what they contain.
- **Online/anti-cheat warning:** AreWeAntiCheatYet `games.json` (MIT) by
  Steam id, plus the Steam store's categories (8 = VAC, 1/9/27/36/38/49 =
  multiplayer/co-op/PvP), both cached for 7 days. Anti-cheat gives a red
  banner and every apply asks for a second click. Multiplayer only gives an
  amber note.
- The wrapper exports `ENABLE_VKBASALT=1` and `VKBASALT_CONFIG_FILE=<game's
  conf>` when the profile has `fx: true`. HOME toggles the effects in game.
- Verified here:
  - The two default packages installed (0.5 MB).
  - A real Cyberpunk 2077 preset from the DB converted: 6 effects applied, 2
    skipped (depth). The extra packages it needed (FXShaders, AstrayFX, legacy)
    were fetched automatically. Every value written matches a real uniform in
    the installed shaders.
  - Deadlock is flagged VAC.
  - vkBasalt itself isn't installed on this PC, so the in-game result is
    untested, as are AMD cards. vkBasalt's bundled ReShadeFX compiler dates
    from 2023, and very new shaders may not compile in it (vkBasalt then
    logs the error).
- CLI: `fx status [key]`, `fx install`, `fx packages`, `fx package <idx>`,
  `fx search <name>`, `fx presets <id>`,
  `fx set <key> builtin:<look>|sfx:<id>|off`,
  `fx mode <key> reshade [exe] [dxgi|d3d9|opengl32] | vkbasalt`,
  `fx exes <key>`, `fx reshade install | off <key>`, `fx key <Home|Insert|F10|F11|F12>`.
- **In-game key** (FX → MENU KEY), one for all games: opens ReShade's menu (`[INPUT] KeyOverlay`, Windows VK code: Home 36, Insert 45, F10 121, F11 122, F12 123) and toggles vkBasalt (`toggleKey`, X11 key name). A change is pushed to every game already set up. F12 is flagged because Steam takes screenshots with it.

#### ReShade under Proton (the DLL route)
Studied from the community's reference script
(kevinlekiller/reshade-steam-proton), then every step checked here:
- **ReShade itself:** `ReShade_Setup_<v>.exe` from reshade.me (the newest
  non-Addon link on its home page, currently 6.8.0). The installer is a zip
  behind an MZ stub, so `bsdtar` pulls `ReShade64.dll` and `ReShade32.dll` out
  of it (no 7z needed). The files are kept under
  `~/.local/share/control-deck/reshade/bin/ReShade-<v>/`, and `current` points
  at the newest, so an UPDATE reaches every game on its next launch.
- **d3dcompiler_47.dll** (ReShade compiles shaders with it on D3D9–11):
  winetricks' method. It's taken from Mozilla's Firefox 62.0.3 installer (32
  and 64-bit), and the installers' SHA-256 must match winetricks' values
  (`721977f3…` / `d6edb4ff…`, verified here). `bsdtar` reads the 7z inside.
- **Which executable:** candidates are the `.exe` files of the game folder,
  minus crash reporters, redistributables, setups and helpers. The ranking
  prefers UE's `-Shipping.exe`, a name that matches the game, an .exe whose
  folder has graphics imports, and big files; launchers, consoles, editors,
  servers and config tools rank down. Here it picks `deadlock.exe`,
  `Balls.exe` and `WH40KRT.exe`.
- **Which API:** the arch comes from the PE header and the API from the
  imports of the .exe and of the DLLs beside it, read with a small PE reader
  (Python, `mmap`; the system objdump here can't read PE files). Unity's
  `UnityPlayer.dll` imports d3d11/dxgi, which maps to `dxgi.dll` (DX10–12);
  d3d9 maps to `d3d9.dll`, and OpenGL-only to `opengl32.dll`. A Vulkan-only
  game is refused, with vkBasalt suggested instead. The tab lets you override
  the executable and the API.
- **Install in the game folder:** only symlinks: `<api>.dll` points to
  ReShade32/64 and `d3dcompiler_47.dll` to ours, unless the game ships its own.
  A game's own `<api>.dll` is never replaced. `ReShade.ini` is created only
  if missing. Otherwise only these keys are set:
  - `EffectSearchPaths` and `TextureSearchPaths` point at the shared shader
    folders with `\**`, which is recursive per ReShade's source
    (`search_path.filename() == L"**"`);
  - `PresetPath` points at `gaming/fx/<game>/ReShadePreset.ini`.
  OFF removes the links (and the ini/log if the deck made them): the folder
  goes back to its exact previous listing (checked on BALL x PIT).
- **Launch:** the wrapper adds `WINEDLLOVERRIDES=d3dcompiler_47=n;<api>=n,b`,
  appended to any overrides already set. Wine then loads ReShade from the
  game folder, and ReShade chains to Proton's DXVK/VKD3D.
- **Wrapper required:** applying a look turns on USE IN STEAM automatically
  when Steam is closed. Otherwise the tab says to close Steam and shows the
  button.
- **Presets:** the SweetFX DB file is saved as the game's `ReShadePreset.ini`
  unchanged; the effect files it names are fetched from the official packages
  (see above). The quick looks are small ReShade presets built from SweetFX
  effects (CAS, SMAA, FXAA, LumaSharpen + Vibrance). In game, HOME opens
  ReShade's menu, and tweaks are saved to that preset.
- Not verified yet: an actual in-game run (needs the game launched through the
  wrapper), AMD, and 32-bit/D3D9/OpenGL titles (none installed here).


#### Saved preset pages and the effects switch
- `fx link add|rm|get steam:<appid> <url> [label]` saves a preset page (Nexus
  links get the label "Nexus #<id>") for a game, even one that isn't
  installed yet. Links are keyed by Steam app id in `gaming/fx-links.json`.
  The FX tab lists them under SAVED, and step 4 then says "Your saved preset:
  … open it, download the file, then IMPORT…". Saved here: KCD2 (1771300) →
  Nexus #144.
- A saved page can carry **notes** (`fx link note`), shown under SAVED. KCD2 #144 holds its author's install guide mapped to what the deck does (IMPORT, dxgi for DX12, MENU KEY, ON/OFF KEY = END).
- **ON/OFF KEY** (ReShade route): ReShade's `[INPUT] KeyEffects`
  (`runtime.cpp`), the "all effects on/off" key that preset guides suggest.
  Choices are END (default, VK 35), F9 or NONE, and a change reaches every
  game already set up.

#### Guided steps (FX → THIS GAME → STEPS)
A checklist built from the game's live state, with the pending step's own button:
1. route (✓ when it's the recommended one; otherwise USE RESHADE ★),
2. install (INSTALL),
3. launch through Control Deck (USE IN STEAM; says to close Steam first),
4. pick a look (quick look, SweetFX DB preset, or SEARCH NEXUS → download →
   IMPORT…),
5. play: the configured key opens ReShade's menu (or toggles vkBasalt).
It can be hidden. When everything is done it collapses to "all set — press
<key>".

#### Importing a downloaded preset (FX → FROM A FILE)
- Many recent games only have presets on Nexus Mods, which answers 403 to
  scripted requests. The flow is: SEARCH NEXUS ↗ (a web search), you download
  the file, then **IMPORT…**. The picker opens in the XDG Downloads folder and
  accepts zip, 7z, rar (all read by bsdtar), .ini or .txt.
- `fx importlist <file>` lists the presets inside: the files with a
  `Techniques=` line, `ReShade.ini` excluded, the most effects first. When
  there's more than one, the tab lets you pick.
- `fx import <key> <file> [preset]`:
  1. Copies the archive's own `.fx`/`.fxh` to `Shaders/imported/<file name>`.
     A name we already have is skipped, so there are no duplicate
     techniques. Its textures go to `Textures`.
  2. Applies the preset through the game's route like any other look
     (`fx set … file:<preset>`). With ReShade it runs as is, and missing
     shaders are fetched from the official packages. With vkBasalt it's
     converted.
  The archive's `ReShade.ini`, `dxgi.dll` and the like are never used, since
  the deck manages those. Switching route keeps an imported look (a copy is
  kept in `gaming/fx/<game>/preset.ini`).

#### My library: presets and settings for every game (FX → MY LIBRARY)
- **SCAN** checks every installed Steam game:
  - **SweetFX Settings DB:** the game's page is matched by exact title (after
    normalising case, symbols, ™/®). From its preset table (preset, added, by,
    screenshots, downloads, shader) the **most downloaded "ReShade"** preset
    is taken; old "SweetFX" presets are ignored.
  - **PCGamingWiki's ReShade page:** reshade.me's Compatibility page embeds
    it. It's read through the MediaWiki API (`action=parse`, sections "Online
    games to avoid" and "Compatibility list", 875 rows) and gives render API,
    status and notes. Depth notes become ReShade's own definitions from
    `ReShade.fxh`: "reversed" → `RESHADE_DEPTH_INPUT_IS_REVERSED=1`,
    "upside down/flipped" → `…_IS_UPSIDE_DOWN=1`, "logarithmic" →
    `…_IS_LOGARITHMIC=1`. Content is CC BY-NC-SA, and every row links back.
  - **Online risk:** the same data as a single game's warning.
  Everything is cached (search/wiki 7 days, game pages 1 day); `scan.json`
  feeds LIBRARY too.
- **SET UP / SET UP ALL** (`fx autoinstall`), for each game:
  1. ReShade is installed in its folder (exe/API detected as above).
  2. The best preset is applied; with none, SHARPEN + AA.
  3. The depth definitions are added to `[GENERAL] PreprocessorDefinitions`
     (comma list, per ReShade's `ini_file.cpp`), merged with the ones already
     there.
  4. The game is wrapped (USE IN STEAM) when Steam is closed.
  **Never touched:** games with anti-cheat (AreWeAntiCheatYet / VAC) and games
  on PCGW's "Online games to avoid". Optional online co-op doesn't exclude a
  game; it just gets an amber note.
- Nexus Mods has many presets for new games, but it answers 403 to scripted
  requests and its API needs a personal key (and premium for direct
  downloads), so each row only offers a web search
  (`site:nexusmods.com <game> reshade preset`).
- **LIBRARY** shows `FX <n>` on games with presets that aren't set up yet
  (from the last scan), so a newly installed game shows up there after SCAN.
- Here: none of the 3 installed games has presets on SweetFX DB or a PCGW
  row. BALL x PIT and Rogue Trader (co-op → amber) are eligible, and Deadlock
  (VAC) is excluded.

### STATUS dashboard
`gstatus` (about 0.25 s here) is polled every 3 s while the tab is open. It
reports:
- **System:** `/proc/cpuinfo` (model, average MHz), hwmon CPU temperature,
  `/proc/loadavg`, `/proc/meminfo` (RAM used = total − available; swap), zram
  from `swapon`, and `/sys/kernel/sched_ext/{state,root/ops}` plus
  `scx_loader`. Here: "disabled", loader active, no scheduler loaded.
- **GPU:**
  - NVIDIA: `nvidia-smi --query-gpu=…,clocks_throttle_reasons.active`. The
    bitmask is decoded with NVML's reasons (idle, app clocks, power cap, hw
    slowdown, sync boost, sw/hw thermal, power brake, display clock).
  - AMD: `gpu_busy_percent`, `mem_info_vram_used/total`, and hwmon
    `power1_average` (or `power1_input`), `power1_cap`, `freq1_input` and the
    edge temperature. Not verified on real AMD hardware yet.
- **Displays:** `hyprctl monitors -j` (size, refresh, VRR).
- **Tools:** versions cached for a day, plus Steam running, ntsync, the
  number of Proton builds, ReShade and vkBasalt.
- **Running game:** uptime from `ps etimes`. The Proton build comes from the
  `…/proton waitforexitandrun` process with the same SteamAppId. Shaders
  come from the game's environment (`ENABLE_VKBASALT=1`, or ReShade's DLL
  overrides).

### GE-Proton updates (SYSTEM → UPDATES)
- Offered only when a GE-Proton build is already installed in Steam's
  `compatibilitytools.d`. The latest release of `GloriousEggroll/proton-ge-custom`
  (GitHub API, cached 6 h) is compared with the installed folders.
- The x86_64 `.tar.gz` is used (`<tag>-x86_64.tar.gz`; older releases name it
  `<tag>.tar.gz`), checked with its `.sha512sum` (`sha512sum -c`), and
  unpacked next to the old ones. It must contain a single `GE-Proton*`
  folder. Checked here: 11-7 unpacks to `GE-Proton11-7-x86_64/`.
- Old builds aren't removed automatically, because games or Umbral may still
  use them. CLEAN → Unused Proton versions lists the ones nothing uses.
- CLI: `proton install [tag]`, `update proton <tag>`.

### Umbral games: TEMPS and FX
- Umbral (≥ 0.10.0) runs `control-deck hook umbral:<id>` before starting a
  game. It gets back `{env, overlay}`: ReShade's
  `WINEDLLOVERRIDES=d3dcompiler_47=n;<api>=n,b`, or vkBasalt's
  `ENABLE_VKBASALT`/`VKBASALT_CONFIG_FILE`, and whether to show TEMPS. Umbral
  merges the environment (its own options and the user's variables win) and
  starts `control-deck overlay <pid>`. GameMode, MangoHud, gamescope and FPS
  limits stay Umbral's own settings.
- FX works from the game's configured `.exe` (always a candidate, however
  small) and its folder. An RPG Maker folder (RGSS*.dll) is detected as a
  2D GDI game: no shader tool can hook it, and the tab says so (Pokémon
  Iberia here).
- The online risk comes from AreWeAntiCheatYet by name. An entry whose
  normalised name (≥ 8 characters) starts the game's name matches, so WoW
  Forever → "World of Warcraft" (Warden) → red warning.
- LIBRARY → an Umbral game has TEMPS and FX chips.

### CPU scheduler (STATUS → CPU · MEMORY)
- `scxctl` (scx-tools) talks to `scx_loader` over D-Bus. Starting, switching
  and stopping are allowed by polkit action `org.scx.loader.manage-schedulers`
  (`auth_admin_keep`: the password is asked, then kept for a while).
  `scx_lavd` has a Gaming mode; modes here are Auto, Gaming, PowerSave,
  LowLatency and Server.
- **LAVD GAMING NOW / STOP**: `scxctl start|switch|stop`.
- **WHILE PLAYING** (`sched playing lavd:gaming`): the wrapper (Steam) or
  `control-deck session <pid> <key>` (Umbral) starts lavd Gaming when the game
  starts, only if no sched-ext scheduler is running, and stops it when the
  last such game ends. A scheduler you started yourself is never touched.
- **AT BOOT**: `default_sched = "scx_lavd"` / `default_mode = "Gaming"` in
  `/etc/scx_loader.toml`, written with pkexec. The file and keys were checked
  in `scx_loader`'s strings and its shipped `/usr/share/scx_loader/config.toml`.
  Needs a confirmation click.
- **NO PASSWORD**: a polkit rule in `/etc/polkit-1/rules.d/49-control-deck-scx.rules`
  allowing that action to this user in a local active session, so WHILE
  PLAYING doesn't prompt at each launch. It relaxes a system policy, so it
  needs a confirmation click, and it can be removed.

### How a game ends (Steam wrapper)
The wrapper now runs the game as its child instead of `exec`, forwarding
TERM/INT/HUP, so it lives exactly as long as the game and knows its exit
code. That code is kept as the wrapper's own. At the end the session is
cleaned up (the scheduler stops if the deck started it). An exit code from 1
to 127 raises a notification "<game> closed with an error": it points to
`~/steam-<appid>.log` when PROTON_LOG wrote one during that run, and otherwise
suggests adding PROTON_LOG=1 to the game's ENV. 128 and above (killed by a
signal, e.g. Steam's STOP) isn't treated as a crash.

### Game profiles between PCs (BACKUP + LIBRARY → CHECK FOR THIS PC)
- SYSTEM → BACKUP now saves a `gaming` block: profiles, each game's looks
  (report, preset, ReShadePreset.ini, vkBasalt.conf), saved preset pages, the
  FX keys and the scheduler setting. RESTORE brings it back along with the
  apps; **GAMING ONLY** (`gaming-import <file>`) brings back just that. Only
  what this PC lacks is added: a profile already here is never overwritten.
- `gaudit` checks every profile against this PC and flags:
  - variables of another GPU vendor (the same classes as the ProtonDB
    suggestions: `__GL_*`/NVAPI → NVIDIA, `RADV_*`/`AMD_*`/`ACO_*`/`RADEONSI*`
    → AMD, `MESA_*` → no effect on NVIDIA);
  - ReShade that is on but not linked in the game's folder here;
  - vkBasalt that is on but not installed.
  LIBRARY shows them in an amber strip. FIX ALL (`gaudit fix all`) drops the
  useless variables and sets ReShade up again, keeping the look; vkBasalt
  points to FX → INSTALL.

### ReShade screenshots
`[SCREENSHOT] SavePath` in each game's ReShade.ini points to
`<XDG Pictures>/ReShade/<game name>`, here `~/Imágenes/ReShade/…`. ReShade
reads ini paths as UTF-8 (`std::filesystem::u8path` in `ini_file.hpp`), so
the accent is fine. It's set when ReShade is installed in a game, and
`fx screenshots` updates the games already set up.

## Compatibility report

| Area | Verified on the reference system | Pending |
|---|---|---|
| Library / launch options / Proton list | read from the real Steam install | writing with Steam closed (covered by tests on a fake Steam tree) |
| Wrapper (`run`) | tests with stubbed gamemoderun/mangohud | a real Steam launch through the wrapper |
| gamemode governor switch | polkit rule and group checked | needs the user in the `gamemode` group |
| Running-game detection | `SteamAppId` read from `/proc/*/environ` (tests) | confirmation while a real game runs |
| ProtonDB | 3 real summaries fetched and cached | endpoint stability (unofficial) |
| Launch-option suggestions | index built from the real Sep 2026 dump (58 850 reports, 6 914 games); Deadlock: 16 suggestions from 264 working reports | — |
| AMD / Intel GPUs | — | 2.1 / 2.5 don't touch the GPU; untested on other vendors |

## Dropped

- **2.4 GPU tuner** (fan curve, power limit, undervolt per game). It was built on
  LACT (per-game LACT profiles with process rules) and then removed on purpose:
  too risky for the benefit, and there were no per-game GPU needs to justify it.
  Use LACT's own GUI if you ever need GPU tuning.
- **2.7 Save backups.** Skipped: the games in use keep their saves in the cloud
  (Steam Cloud, Battle.net), so a local backup adds little.
- **2.8 Unified launcher** (Lutris, Heroic, emulators, AppImages, search).
  Skipped: LIBRARY already lists and launches the Steam and Umbral games, and
  no games are installed through the other launchers.
- **2.10 Update guardian.** Skipped: the UPDATES tab already shows Arch news
  before an upgrade, pacman changes get snapshots (snap-pac or the deck's own),
  and SNAPSHOTS lists what changed since each one; HEALTH catches a driver
  updated without a reboot.
- **2.12 Session monitor** (recording + end-of-game summary) and **2.13
  Bottleneck detector** (which works on those recordings). Skipped: only the
  live part was wanted, as the TEMPS overlay.

## Not implemented yet

Nothing: every module is implemented or listed under Dropped.
