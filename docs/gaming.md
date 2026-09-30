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

2.14 vkBasalt /
ReShade.
