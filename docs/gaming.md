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

### 2.4 GPU tuner — `GAMING → GPU` (requires LACT)
> **Requires [LACT](https://github.com/ilya-zlobintsev/LACT)** (`sudo pacman -S lact && sudo systemctl enable --now lactd`).
> Your user must be in LACT's `admin_group` (`wheel` by default) to use its socket. Without LACT the tab only shows how to install it.

- **Why LACT instead of `nvidia-settings`/sysfs**: it supports NVIDIA (NVML/NvAPI —
  `nvidia-settings` can't control fans on Wayland) and AMD with one API, reports
  each card's limits, and — the key safety property — its **profiles with a
  process rule** are applied by the LACT daemon only while that process runs and
  reverted when it exits, independently of Control Deck. Config changes through
  its API must also be confirmed within 5 s or LACT reverts them.
- The deck creates one LACT profile per game, `control-deck:<game>`
  (`create_profile` with a provided config + `{type: process, filter: {name}}`
  rule) and turns LACT's automatic profile switching on with the first one. The
  default (non-profile) GPU settings are never modified.
- Settings: power limit (W), core and memory clock offsets (NVIDIA, per power
  state; AMD RDNA4 too), NVIDIA thermal target, AMD voltage offset (undervolt),
  fan curve presets (quiet / balanced / performance, all reaching 100 % by 85 °C)
  or the driver's fan control.
- Limits: power and target temperature are checked against the card's own range;
  clock/voltage offsets against LACT's limits **and** a conservative band
  (NVIDIA core −300…+100 MHz, memory −1000…+500 MHz; AMD voltage −80…0 mV) —
  a heuristic, not a vendor guarantee. Leaving the band needs **UNLOCK FULL
  RANGE** on purpose; applying always needs a second click ("I accept the risk").
- The game's process name (LACT matches the executable name, resolving Wine
  games from their command line) is found with **DETECT** while the game runs:
  the GPU processes LACT reports (`process_list`) whose environment carries the
  game's `SteamAppId`, largest VRAM user first.
- Verified here (RTX 2070, LACT 0.10.1): status, limits (112.5–250 W, offsets
  ±1000 / −2000…+6000 MHz, target 65–88 °C), process list. Profile creation is
  covered by tests against a simulated daemon; **not applied to the real GPU
  yet**. AMD: follows LACT's documented config (`voltage_offset`, `power_cap`,
  offsets on RDNA4) — the AMD clock-table format is **not verified**.
- CLI: `gpu status`, `gpu profile get|set|delete <key> …`, `gpu detect <key>`.

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

## Not implemented yet

2.7 save backups ·
2.8 unified launcher · 2.9 Arch gamer health panel · 2.10 update guardian (the
UPDATES/SNAPSHOTS tabs already cover Arch news and snapshots) · 2.11 space
cleaner · 2.12 session monitor · 2.13 bottleneck detector · 2.14 vkBasalt /
ReShade.
