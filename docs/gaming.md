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

2.2 shader-cache assistant · 2.3 A/B benchmark · 2.4 GPU tuner (plan: LACT
backend, which supports NVIDIA and AMD) · 2.6 prefixes · 2.7 save backups ·
2.8 unified launcher · 2.9 Arch gamer health panel · 2.10 update guardian (the
UPDATES/SNAPSHOTS tabs already cover Arch news and snapshots) · 2.11 space
cleaner · 2.12 session monitor · 2.13 bottleneck detector · 2.14 vkBasalt /
ReShade.
