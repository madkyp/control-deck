import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ShellRoot {
    FloatingWindow {
        id: win
        title: "Control Deck"
        implicitWidth: 660
        implicitHeight: 760
        color: pal.bg
        // closing the window ends the process: a windowless instance would
        // reopen its window on every reload (each install/update of shell.qml).
        // A reload also closes the old window, but destroys this timer with it.
        onClosed: quitTimer.start()
        Timer { id: quitTimer; interval: 1500; onTriggered: Qt.quit() }

        // ---- palette (CONTROL DECK) -------------------------------------
        QtObject {
            id: pal
            readonly property color bg:       "#0a0a10"
            readonly property color panel:    "#101018"
            readonly property color card:     "#14121f"
            readonly property color cardHi:   "#191428"
            readonly property color border:   "#2a2740"
            readonly property color accent:   "#b9a3e3"
            readonly property color accentHi: "#cbb8f4"
            readonly property color pink:     "#d9a7d0"
            readonly property color text:     "#d8d4e8"
            readonly property color dim:      "#6a6580"
            readonly property color ok:       "#a6e3a1"
            readonly property color bad:      "#f38ba8"
            readonly property color sky:      "#7dcfff"
            readonly property color amber:    "#e0af68"
            readonly property color logBg:    "#07070c"
        }
        readonly property string mono: "JetBrainsMono Nerd Font"
        readonly property string home: Quickshell.env("HOME")
        property string scriptPath: Quickshell.env("CONTROL_DECK_BIN") || (home + "/.local/bin/control-deck")
        // CONTROL_DECK_VIEW=manage|store|updates|system opens straight on a tab
        property string view: Quickshell.env("CONTROL_DECK_VIEW") || "install"
        Component.onCompleted: {
            timerStatusProc.running = true;
            versionProc.running = true;
            if (view === "manage") refreshApps();
            if (view === "updates") checkUpdates();
            if (view === "system") openSystem(sysView);
            if (view === "gaming") openGaming();
        }

        function srcColor(s) {
            switch (s) {
                case "repo":     return pal.accent;
                case "aur":      return pal.pink;
                case "flatpak":  return pal.sky;
                case "github":   return pal.amber;
                case "appimage": return pal.ok;
                case "deck":     return pal.accentHi;
                default:         return pal.dim;
            }
        }
        function riskColor(r) { return r === "high" ? pal.bad : (r === "medium" ? pal.amber : pal.ok); }
        function expandHome(p) { return p.charAt(0) === "~" ? home + p.substring(1) : p; }
        function human(b) {
            if (!b) return "";
            var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
            while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
            return (i === 0 ? b : b.toFixed(b < 10 ? 1 : 0)) + " " + u[i];
        }

        // ---- install state (queue) --------------------------------------
        property var    queue: []          // [{path,name,type,label,supported}]
        property var    queuePaths: []     // paths awaiting detection
        property var    installPaths: []   // supported paths sent to install
        property string fetchUrl: ""
        property string fetchedPath: ""
        readonly property var formats: [
            { t: "APPIMAGE", e: ".AppImage  .appimage" },
            { t: "PACMAN",   e: ".pkg.tar.zst  .pkg.tar.xz  .pkg.tar.gz  .pkg.tar" },
            { t: "FLATPAK",  e: ".flatpak" },
            { t: "TAR",      e: ".tar  .tar.gz  .tgz  .tar.xz  .tar.zst  .tar.bz2" },
            { t: "DEB",      e: ".deb  (with debtap)" },
            { t: "URL",      e: "https://…  ·  github.com/user/repo" }
        ]
        property string logText: ""
        property string status: "AWAITING FILE"
        property color  statusColor: pal.dim
        property bool   busy: installProc.running || detectManyProc.running || fetchProc.running

        function typeShort(t) {
            switch (t) {
                case "appimage": return "APPIMG";
                case "pacman":   return "PKG";
                case "flatpak":  return "FLATPAK";
                case "tar":      return "TAR";
                case "deb":      return "DEB";
                case "rpm":      return "RPM";
                default:         return "FILE";
            }
        }
        function supportedCount() {
            return queue.filter(function (q) { return q.supported === "yes"; }).length;
        }
        function reset() {
            queue = []; queuePaths = []; installPaths = []; logText = "";
            status = "AWAITING FILE"; statusColor = pal.dim;
        }
        function pathFromUrl(u) {
            return decodeURIComponent(String(u).replace(/^file:\/\//, ""));
        }
        function loadFiles(paths) {
            if (!paths || paths.length === 0) return;
            logText = ""; queue = []; queuePaths = paths;
            status = "ANALYZING…"; statusColor = pal.pink;
            detectManyProc.running = true;
        }
        function loadFile(p) { if (p) loadFiles([p]); }
        // path field: local path · direct download URL · GitHub repo
        function submitInput(t) {
            t = t.trim();
            if (!t) return;
            var isUrl = /^https?:\/\//.test(t);
            var isRepoPage = t.indexOf("github.com/") >= 0 && t.indexOf("/releases/download/") < 0;
            var isRepoSpec = !isUrl && t.charAt(0) !== "/" && t.charAt(0) !== "~"
                             && /^[\w.-]+\/[\w.-]+$/.test(t);
            if (isRepoPage || isRepoSpec) {
                view = "store"; queryField.text = t; runSearch(t);
            } else if (isUrl) {
                fetchUrl = t; fetchedPath = ""; logText = ""; queue = [];
                status = "DOWNLOADING…"; statusColor = pal.pink;
                fetchProc.running = true;
            } else {
                loadFile(expandHome(t));
            }
        }

        // ---- manage state -----------------------------------------------
        property var apps: []
        property var appsFiltered: []
        property var sizes: ({})           // {path: {app, data}}
        property bool sortBySize: false
        property string searchText: ""
        property string selPath: ""
        property string selName: ""
        property string selIcon: ""
        property string selResolvedIcon: ""
        property string selSource: ""
        property string selPkg: ""
        property string selAppId: ""
        property string selAction: ""
        property string selGithub: ""
        property bool   selHidden: false
        property bool   selTerminal: false
        property bool   selAutostart: false
        property string selIssue: ""       // diagnosis (static or after a failed launch)
        property var    selFixes: []       // [{kind,label}]
        property var    fpPerms: []        // flatpak permissions of the selected app
        property string fixKind: ""
        property var    autostartArgs: []
        property var    fpArgs: []
        property bool   showAdvanced: false
        property bool   purge: false
        property var    editArgs: []
        property var    uninstallArgs: []
        property string manageLog: ""
        property string manageStatus: "SELECT AN APP"
        property bool confirmUninstall: false
        property bool manageBusy: editProc.running || uninstallProc.running
                                  || listProc.running || infoProc.running
                                  || launchProc.running || fixProc.running
                                  || autostartProc.running || fpSetProc.running

        property string appsInfo: "0 / 0"
        onAppsChanged: applyFilter()
        onSearchTextChanged: applyFilter()
        onSortBySizeChanged: applyFilter()
        onSizesChanged: if (sortBySize) applyFilter()
        onPurgeChanged: { confirmUninstall = false; manageLog = ""; }
        function sizeOf(p) { var s = sizes[p]; return s ? s.app + s.data : 0; }
        function applyFilter() {
            var q = searchText.toLowerCase();
            var l = !q ? apps.slice() : apps.filter(function(a){ return a.name.toLowerCase().indexOf(q) >= 0; });
            if (sortBySize) l.sort(function (a, b) { return sizeOf(b.path) - sizeOf(a.path); });
            appsFiltered = l;
            appsInfo = appsFiltered.length + " / " + apps.length;
        }
        function refreshApps() {
            selPath = ""; selName = ""; selIcon = ""; selResolvedIcon = ""; selAppId = "";
            selSource = ""; selPkg = ""; selAction = ""; selGithub = ""; fpPerms = [];
            confirmUninstall = false; purge = false;
            listProc.running = true;
        }
        function selectApp(p) { confirmUninstall = false; purge = false; manageLog = ""; selPath = p; infoProc.running = true; }
        function runQuick(proc) { manageLog = ""; proc.running = true; }
        // ISSUE= / FIX=kind|LABEL lines from the backend
        function takeDiag(line) {
            if (line.indexOf("ISSUE=") === 0) { selIssue = line.substring(6); return true; }
            if (line.indexOf("FIX=") === 0) {
                var v = line.substring(4), i = v.indexOf("|");
                selFixes = selFixes.concat([{ kind: v.substring(0, i), label: v.substring(i + 1) }]);
                return true;
            }
            return false;
        }
        function applyFix(kind) { fixKind = kind; manageLog = ""; manageStatus = "FIXING…"; fixProc.running = true; }
        // Electron/Chromium flags for native Wayland, inserted before field codes
        function withWaylandFlags(e) {
            if (e.indexOf("ozone-platform") >= 0) return e;
            var f = "--enable-features=UseOzonePlatform --ozone-platform=wayland";
            var m = e.match(/\s%[fFuUdDnNickvm]/);
            return m ? e.slice(0, m.index) + " " + f + e.slice(m.index) : e + " " + f;
        }

        // ---- store state (search & install by name) ---------------------
        property string storeQuery: ""
        property var    results: []
        property var    installArgs: []
        property string storeLog: ""
        property string storeStatus: "SEARCH FOR AN APP"
        property var    review: null        // AUR review shown before building
        property string reviewPkg: ""
        property bool   confirmRisky: false
        property bool   storeBusy: searchProc.running || storeInstallProc.running || reviewProc.running

        function runSearch(q) {
            if (!q || q.trim() === "") return;
            storeQuery = q.trim(); results = []; storeLog = ""; review = null;
            storeStatus = "SEARCHING…";
            searchProc.running = true;
        }
        function installPkg(src, id, remote) {
            if (src === "aur" && (!review || review.name !== id)) {
                // AUR packages are reviewed before they are built
                reviewPkg = id; review = null; confirmRisky = false; storeLog = "";
                storeStatus = "REVIEWING " + id + "…";
                reviewProc.running = true;
                return;
            }
            installArgs = [src, id, remote || ""];
            storeLog = ""; review = null;
            storeStatus = "INSTALLING " + (src === "github" ? id.split("/").pop() : id) + "…";
            storeInstallProc.running = true;
        }
        function dateOf(epoch) { return epoch ? new Date(epoch * 1000).toISOString().substring(0, 10) : "?"; }

        // ---- updates state ----------------------------------------------
        property var    updates: []
        property var    updArgs: []
        property var    timerArgs: []
        property string updLog: ""
        property string updStatus: "NOT CHECKED"
        property bool   updChecked: false
        property bool   autoCheck: false
        property bool   updBusy: checkProc.running || updProc.running || timerProc.running
        property var    news: []            // Arch news; unread = since the last full upgrade
        property var    unreadNews: news.filter(function (n) { return n.unread; })
        property bool   newsAck: false      // user saw the news warning for this check
        property string deckVersion: ""
        property bool   deckUpdate: updates.some(function (u) { return u.source === "deck"; })
        // pending GPU driver updates (NVIDIA / Mesa / AMD) rebuild every shader cache
        property var    driverUpdates: updates.filter(function (u) {
            return u.source === "repo" && /^(lib32-)?(nvidia(-[0-9]+xx)?-utils|nvidia-open-dkms|mesa|vulkan-(radeon|intel|nouveau)|amdvlk)$/.test(u.name);
        })

        function checkUpdates() {
            updates = []; updStatus = "CHECKING…"; newsAck = false;
            checkProc.running = true; newsProc.running = true;
        }
        function runUpdate(args, label) {
            updArgs = args; updLog = "";
            updStatus = label; updProc.running = true;
        }
        // a system upgrade with unread Arch news needs a second click
        function guardedUpdate(args, label, touchesRepos) {
            if (touchesRepos && unreadNews.length > 0 && !newsAck) {
                newsAck = true;
                updStatus = "READ THE ARCH NEWS FIRST · CLICK AGAIN";
                return;
            }
            runUpdate(args, label);
        }

        // ---- gaming state -----------------------------------------------
        property string gameView: "library"
        property var    games: []
        property var    gstat: ({})
        property var    pdb: ({})           // ProtonDB summaries by appid
        property var    tools: []           // Proton versions Steam can use
        property var    gp: ({})            // profile being edited
        property var    gameArgs: []
        property string gameLog: ""
        property string gameStatus: ""
        property string selGame: ""
        property string selGameId: ""
        property string selGameName: ""
        property string selGameSource: ""
        property string selGameLaunch: ""
        property string selGameCompat: ""
        property bool   selGameWrapped: false
        property var    selGameObj: ({})
        property bool   confirmJoin: false
        property var    sug: ({})           // launch options players use (ProtonDB open data)
        property var    tips: ({})          // suggestion count per appid
        property var    pdbStat: ({})       // local ProtonDB index status
        property var    shaders: ({})       // shader caches (per game + driver)
        property var    health: ({})        // gaming health checks
        property var    fx: ({})            // visual shaders: install state + selected game
        property var    fxGames: []         // SweetFX DB games matching the search
        property string fxGameId: ""
        property var    fxPresets: []
        property string fxMsg: ""
        property string fxConfirm: ""       // anti-cheat games: second click applies
        property bool   fxActive: !!fx.current && !!win.gp.fx
        property bool   fxAnticheat: !!fx.online && fx.online.level === "anticheat"
        property bool   fxReshade: fx.mode === "reshade"
        property var    fxRsGame: fx.reshade ? fx.reshade.game : null
        property bool   fxReady: fxReshade ? (!!fx.reshade && fx.reshade.ready === true) : (fx.vkbasalt === true && fx.shadersInstalled === true)
        function openFx() {
            gameView = "fx"; fxConfirm = ""; fxTopFor = "";
            if (selGameSource === "steam") {
                fxStatProc.running = true;
                if (fxQuery.text === "" || fxLastGame !== selGame) { fxQuery.text = selGameName; fxLastGame = selGame; fxSearch(selGameName); }
            }
        }
        property string fxLastGame: ""
        property string fxScope: "game"     // game | library
        property string fxImportFile: ""    // archive picked for IMPORT
        property bool   fxGuideOpen: true   // FX steps card (per session)
        property string fxTopFor: ""
        function fxToTop() { fxScroll.contentItem.contentY = 0; }
        // the FX steps, from the game's real state: [done, title, how]
        property var    fxSteps: {
            var key = (fx.key || "Home").toUpperCase(), rs = fxReshade;
            return [
                [rs || fx.recommended === "vkbasalt", "Route: " + (rs ? "ReShade" : "vkBasalt"),
                 rs ? "ReShade itself runs presets exactly as made. vkBasalt (ROUTE below) only for Vulkan games."
                    : (fx.recommended === "vkbasalt" ? "This game renders with Vulkan: vkBasalt is the one that works."
                       : "ReShade is recommended here: presets run exactly as made (depth effects too), with its in-game menu.")],
                [fxReady, "Install " + (rs ? "ReShade" : "vkBasalt + shaders"),
                 rs ? "Downloaded from reshade.me into your user folder, no password." : "From chaotic-aur (asks for your password) plus the standard shaders."],
                [fx.wrapped === true, "Launch it through Control Deck",
                 fx.wrapped ? "Its Steam launch options go through the deck, which loads the shaders."
                            : (fx.steamRunning ? "Close Steam, then USE IN STEAM." : "USE IN STEAM puts the deck in its launch options.")],
                [fxActive, "Pick a look",
                 fxActive ? "Active: " + fx.current.name + ". Change it any time below."
                          : "Below: a QUICK LOOK, a SweetFX DB preset (APPLY), or one from Nexus: SEARCH NEXUS → download it → IMPORT…"],
                [fxActive && fx.wrapped === true && fxReady, "Play and tweak",
                 rs ? "Launch the game and press " + key + ": ReShade's menu, tick/untick effects and move sliders (saved to this game). Turn on Performance Mode once you like it."
                    : "Launch the game; " + key + " turns the effects on/off to compare."]
            ];
        }
        property int    fxStepsDone: fxSteps.filter(function (s) { return s[0]; }).length
        property var    fxImportList: []    // its presets, when there's more than one
        property var    fxScan: []          // fx scan: every game's best preset / compatibility
        property var    fxScanByKey: { var m = {}; fxScan.forEach(function (r) { m[r.key] = r; }); return m; }
        property int    fxEligible: fxScan.filter(function (r) { return r.eligible && !r.current; }).length
        function fxSearch(q) {
            if (!q || fxSearchProc.running) return;
            fxGames = []; fxPresets = []; fxGameId = ""; fxMsg = "";
            fxSearchProc.command = [scriptPath, "fx", "search", q]; fxSearchProc.running = true;
        }
        function fxLoadPresets(id) {
            fxGameId = id; fxPresets = []; fxMsg = "Loading presets…";
            fxPresetsProc.command = [scriptPath, "fx", "presets", id]; fxPresetsProc.running = true;
        }
        function fxApply(k, label, cmd) {
            if (fxAnticheat && fxConfirm !== k) { fxConfirm = k; return; }
            fxConfirm = "";
            runGame(cmd || ["fx", "set", selGame, k], label);
        }
        property string copiedFix: ""       // fix command just copied (for feedback)
        property string confirmShader: ""   // target awaiting a second click
        property var    bench: ({})         // A/B benchmark of the selected game
        property string benchLoadedFor: ""  // game whose variants are in the editors (unsaved edits survive refreshes)
        property string pendingRun: ""      // "A"/"B": run right after the variants are saved
        property var    pfx: ({})           // Wine/Proton prefixes
        property var    pfxBackups: []
        property bool   sugExpanded: false
        property var    sugRecommended: (sug.suggestions || []).filter(function (x) { return x.recommended; })
        property var    sugOthers: (sug.suggestions || []).filter(function (x) { return x.foryou && !x.recommended; })
        property bool   gameBusy: gamesProc.running || gameProc.running || gprofProc.running

        function tierColor(t) {
            switch (t) {
                case "platinum": return "#b4c7dc";
                case "gold":     return pal.amber;
                case "silver":   return "#a6a6a6";
                case "bronze":   return "#cd7f32";
                case "borked":   return pal.bad;
                default:         return pal.dim;
            }
        }
        function gameName(id) {
            var g = games.filter(function (x) { return x.id === String(id); })[0];
            return g ? g.name : "app " + id;
        }
        function openGaming() {
            gamesProc.running = true; gstatProc.running = true; toolsProc.running = true; pdbStatProc.running = true;
        }
        function selectGame(g) {
            selGame = g.key; selGameId = g.id; selGameName = g.name; selGameSource = g.source;
            selGameLaunch = g.launch; selGameCompat = g.compat; selGameWrapped = g.wrapped; selGameObj = g;
            gameLog = ""; if (g.source === "steam") gprofProc.running = true;
            sug = {}; sugExpanded = false; if (g.source === "steam") sugProc.running = true;
            if (g.new) { seenProc.command = [scriptPath, "gseen", g.key]; seenProc.running = true; }
            fx = {}; fxConfirm = ""; if (gameView === "fx") openFx();
        }
        // is a suggestion already part of the profile being edited?
        function sugApplied(x) {
            if (x.kind === "env") return (" " + gEnv.text + " ").indexOf(" " + x.token + " ") >= 0;
            if (x.kind === "arg") return (" " + gArgs.text + " ").indexOf(" " + x.token + " ") >= 0;
            if (x.token === "gamemoderun") return gp.gamemode === true;
            if (x.token === "mangohud") return gp.mangohud === true;
            return (" " + gPrefix.text + " ").indexOf(" " + x.token + " ") >= 0;
        }
        // value this profile already gives to a suggested env var ("" if unset)
        function envValue(name) {
            var hit = gEnv.text.split(/\s+/).filter(function (e) { return e.split("=")[0] === name; })[0];
            return hit === undefined ? null : hit.substring(name.length + 1);
        }
        function sugLabel(x, applied, mark) {
            var l = (applied ? "✓ " : mark) + x.token + "  " + x.pct + "%";
            if (x.kind === "env" && !applied) {
                var mine = envValue(x.var);
                if (mine !== null) l += " · you =" + mine;
            }
            return l;
        }
        function sugTip(x, applied) {
            var t = x.pct + "% of " + (x.basis === "similar" ? "players with a GPU like yours" : (x.basis === "vendor" ? "players with your GPU vendor" : "players"))
                    + " who say it works use it (" + x.n + " reports)";
            if (x.kind === "env" && x.unset !== undefined) t += "; " + x.unset + "% leave it at the default";
            if (x.adapted) t += "; value adapted to this PC";
            return t + (applied ? ". Already in the profile." : ". Click to add, then SAVE.");
        }
        // add a suggestion to the editor (saved with SAVE, never automatically)
        function applySug(x) {
            if (sugApplied(x)) return;
            if (x.kind === "env") {
                var name = x.token.split("=")[0];
                var rest = gEnv.text.split(/\s+/).filter(function (e) { return e && e.split("=")[0] !== name; });
                gEnv.text = rest.concat([x.token]).join(" ");
            } else if (x.kind === "arg") {
                gArgs.text = (gArgs.text.trim() + " " + x.token).trim();
            } else if (x.token === "gamemoderun") { gpSet("gamemode", true); }
            else if (x.token === "mangohud") { gpSet("mangohud", true); }
            else { gPrefix.text = (gPrefix.text.trim() + " " + (x.token === "gamescope" ? "gamescope -f --" : x.token)).trim(); }
        }
        function playtimeText(sec) {
            if (!sec) return "never played";
            var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
            return (h > 0 ? h + " h " : "") + m + " min played";
        }
        function gpSet(k, v) { var o = Object.assign({}, gp); o[k] = v; gp = o; }
        function envString(e) {
            return Object.keys(e || {}).map(function (k) { return k + "=" + e[k]; }).join(" ");
        }
        function runGame(args, label) { gameArgs = args; gameLog = ""; gameStatus = label; confirmShader = ""; gameProc.running = true; }
        // destructive shader actions need a second click on the same button
        function shaderAction(args, key, label) {
            if (confirmShader !== key) { confirmShader = key; return; }
            runGame(args, label);
        }
        function loadBench() {
            [benchA, benchB].forEach(function (w) {
                var x = bench[w.v] || {};
                w.label = x.label || w.v; w.env = x.env || ""; w.args = x.args || "";
                w.gm = x.gamemode || ""; w.proton = x.proton || "";
            });
        }
        function saveBench(extra) {
            var a = ["bench", "set", selGame];
            [benchA, benchB].forEach(function (w) {
                a = a.concat([w.v, "label=" + w.label.trim(), "env=" + w.env.trim(), "args=" + w.args.trim(),
                              "gamemode=" + w.gm, "proton=" + w.proton]);
            });
            runGame(a.concat(extra || []), "SAVING…");
        }
        function runBench(v) { pendingRun = v; saveBench([]); }
        function pct(v) { return v === undefined || v === null ? "" : (v > 0 ? "+" : "") + v + "%"; }
        function dateOfEpoch(e) { return e ? new Date(e * 1000).toISOString().substring(0, 10) : "?"; }
        property bool pendingPlay: false
        function playGame() {
            if (selGameSource === "steam") { pendingPlay = true; saveGameProfile(); }
            else runGame(["gplay", selGame], "LAUNCHING…");
        }
        function saveGameProfile() {
            runGame(["gprofile", "set", selGame,
                     "gamemode=" + (gp.gamemode === true), "mangohud=" + (gp.mangohud === true),
                     "overlay=" + (gp.overlay === true), "ionice=" + (gp.ionice === true), "nice=" + (gp.nice || 0),
                     "env=" + gEnv.text.trim(), "prefix=" + gPrefix.text.trim(), "args=" + gArgs.text.trim()],
                    "SAVING…");
        }

        // ---- system state (clean · backup · history) --------------------
        property string sysView: "clean"
        property var    cleanItems: []
        property string confirmClean: ""    // gaming rows delete big things: second click confirms
        property var    history: []
        property var    sysArgs: []
        property string sysLog: ""
        property string sysStatus: ""
        property bool   confirmRestore: false
        property bool   sysBusy: scanProc.running || sysProc.running || histProc.running
                                 || snapListProc.running || snapStatusProc.running
        property var    snapStatus: ({})
        property var    snapshots: []
        property var    selSnaps: []        // snapshot numbers ticked in the list
        property bool   confirmSnapDelete: false
        property bool   confirmSnapCleanup: false
        property var    snapLimits: ({})
        property var    pendingDelete: []
        onSelSnapsChanged: confirmSnapDelete = false
        property var    snapListArgs: ["snaplist"]

        function runSys(args, label) {
            sysArgs = args; sysLog = ""; sysStatus = label;
            sysProc.running = true;
        }
        function scanClean() { cleanItems = []; confirmClean = ""; sysStatus = "SCANNING…"; scanProc.running = true; }
        function openSystem(sub) {
            sysView = sub;
            if (sub === "clean" && cleanItems.length === 0 && !scanProc.running) scanClean();
            if (sub === "history") histProc.running = true;
            if (sub === "snapshots") { snapStatusProc.running = true; snapLimitsProc.running = true; }
        }
        // tick/untick a snapshot; a pre and its post always go together
        function toggleSnap(item) {
            var nums = [item.num];
            snapshots.forEach(function (x) {
                if ((x.type === "post" && x.pre === item.num) || (item.type === "post" && x.num === item.pre))
                    nums.push(x.num);
            });
            var on = selSnaps.indexOf(item.num) < 0;
            var sel = selSnaps.filter(function (n) { return nums.indexOf(n) < 0; });
            selSnaps = on ? sel.concat(nums).sort(function (a, b) { return a - b; }) : sel;
        }
        function loadSnapshots(asRoot) {
            snapListArgs = asRoot ? ["snaplist", "--root"] : ["snaplist"];
            snapListProc.running = true;
        }

        // ---- backend processes: install ---------------------------------
        Process {
            id: detectManyProc
            command: [win.scriptPath, "detectmany"].concat(win.queuePaths)
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.queue = JSON.parse(text); }
                    catch (e) { win.queue = []; }
                    var sup = win.supportedCount();
                    if (win.queue.length === 0) { win.status = "AWAITING FILE"; win.statusColor = pal.dim; }
                    else if (sup === 0) { win.status = "NONE INSTALLABLE"; win.statusColor = pal.bad; }
                    else { win.status = sup + "/" + win.queue.length + " READY"; win.statusColor = pal.accent; }
                }
            }
        }
        Process {
            id: installProc
            command: [win.scriptPath, "installmany"].concat(win.installPaths)
            stdout: SplitParser { onRead: (line) => win.logText += line + "\n" }
            stderr: SplitParser { onRead: (line) => win.logText += line + "\n" }
            onExited: (code, st) => {
                if (code === 0) { win.status = "DONE ✓"; win.statusColor = pal.ok; }
                else            { win.status = "DONE WITH ERRORS"; win.statusColor = pal.bad; }
                win.apps = [];   // MANAGE reloads on next visit
            }
        }
        Process {
            id: fetchProc
            command: [win.scriptPath, "fetch", win.fetchUrl]
            stdout: SplitParser {
                onRead: (l) => {
                    if (l.indexOf("FILE=") === 0) win.fetchedPath = l.substring(5);
                    else win.logText += l + "\n";
                }
            }
            stderr: SplitParser { onRead: (l) => win.logText += l + "\n" }
            onExited: (c, s) => {
                if (c === 0 && win.fetchedPath) win.loadFile(win.fetchedPath);
                else { win.status = "DOWNLOAD FAILED"; win.statusColor = pal.bad; }
            }
        }
        Process {
            id: openProc
            command: ["xdg-open", win.home + "/Applications"]
        }

        // ---- backend processes: manage ----------------------------------
        Process {
            id: listProc
            command: [win.scriptPath, "list"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.apps = JSON.parse(text); }
                    catch (e) { win.apps = []; }
                    win.manageStatus = win.apps.length + " APPS";
                    sizesProc.running = true;   // slower: fills in afterwards
                }
            }
        }
        Process {
            id: sizesProc
            command: [win.scriptPath, "sizes"]
            stdout: StdioCollector {
                onStreamFinished: { try { win.sizes = JSON.parse(text); } catch (e) {} }
            }
        }
        Process {
            id: infoProc
            command: [win.scriptPath, "appinfo", win.selPath]
            stdout: StdioCollector {
                onStreamFinished: {
                    var m = {};
                    var L = text.split("\n");
                    win.selIssue = ""; win.selFixes = [];
                    for (var i = 0; i < L.length; i++) {
                        if (win.takeDiag(L[i])) continue;
                        var idx = L[i].indexOf("="); if (idx < 0) continue;
                        m[L[i].substring(0, idx)] = L[i].substring(idx + 1);
                    }
                    win.selName = m.NAME || ""; win.selIcon = m.ICON || "";
                    win.selResolvedIcon = m.RESOLVED_ICON || ""; win.selSource = m.SOURCE || "";
                    win.selPkg = m.PKG || ""; win.selAction = m.ACTION || "";
                    win.selGithub = m.GITHUB || ""; win.selAppId = m.APPID || "";
                    win.selHidden = m.NODISPLAY === "true";
                    win.selTerminal = m.TERMINAL === "true";
                    win.selAutostart = m.AUTOSTART === "true";
                    nameEdit.text = win.selName; iconEdit.text = win.selIcon;
                    execEdit.text = m.EXEC || ""; catEdit.text = m.CATEGORIES || "";
                    win.manageStatus = win.selSource.toUpperCase()
                                       + (win.selGithub ? " · " + win.selGithub : "");
                    win.fpPerms = [];
                    if (win.selSource === "flatpak" && win.selAppId) fpProc.running = true;
                }
            }
        }
        Process {
            id: editProc
            command: [win.scriptPath, "edit"].concat(win.editArgs)
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { win.manageStatus = c === 0 ? "SAVED ✓" : "SAVE FAILED"; win.refreshApps(); }
        }
        Process {
            id: uninstallProc
            command: [win.scriptPath, "uninstall"].concat(win.uninstallArgs)
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { win.manageStatus = c === 0 ? "REMOVED ✓" : "FAILED · " + c; win.confirmUninstall = false; win.refreshApps(); }
        }
        Process {
            id: pickProc
            command: [win.scriptPath, "pickfile", "Choose an icon"]
            stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p) iconEdit.text = p; } }
        }
        Process {
            id: previewProc
            command: [win.scriptPath, "rmpreview", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { if (win.purge) leftoverProc.running = true; }
        }
        Process {
            id: leftoverProc
            command: [win.scriptPath, "leftovers", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
        }
        Process {
            id: launchProc
            command: [win.scriptPath, "launch", win.selPath]
            stdout: SplitParser { onRead: (l) => { if (!win.takeDiag(l)) win.manageLog += l + "\n"; } }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onStarted: { win.selIssue = ""; win.selFixes = []; win.manageStatus = "LAUNCHING…"; }
            onExited: (c, s) => { win.manageStatus = c === 0 ? "RUNNING ▶" : "LAUNCH FAILED ✗"; }
        }
        Process {
            id: fixProc
            command: [win.scriptPath, "fix", win.selPath, win.fixKind]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => {
                win.manageStatus = c === 0 ? "FIXED ✓" : "FIX FAILED";
                infoProc.running = true;   // re-check the app
            }
        }
        Process {
            id: autostartProc
            command: [win.scriptPath, "autostart"].concat(win.autostartArgs)
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { infoProc.running = true; }
        }
        Process {
            id: fpProc
            command: [win.scriptPath, "fpperms", win.selAppId]
            stdout: StdioCollector {
                onStreamFinished: { try { win.fpPerms = JSON.parse(text); } catch (e) { win.fpPerms = []; } }
            }
        }
        Process {
            id: fpSetProc
            command: [win.scriptPath].concat(win.fpArgs)
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { fpProc.running = true; }
        }
        Process {
            id: dirProc
            command: [win.scriptPath, "opendir", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
        }
        Process {
            id: copyProc
            command: [win.scriptPath, "copyexec", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
        }

        // ---- backend processes: store -----------------------------------
        Process {
            id: searchProc
            command: [win.scriptPath, "search", win.storeQuery]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.results = JSON.parse(text); }
                    catch (e) { win.results = []; }
                    win.storeStatus = win.results.length + " RESULTS";
                }
            }
        }
        Process {
            id: reviewProc
            command: [win.scriptPath, "aurreview", win.reviewPkg]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.review = JSON.parse(text); } catch (e) { win.review = null; }
                    win.storeStatus = win.review ? "RISK: " + win.review.risk.toUpperCase() : "REVIEW FAILED";
                }
            }
            stderr: SplitParser { onRead: (l) => win.storeLog += l + "\n" }
        }
        Process {
            id: storeInstallProc
            command: [win.scriptPath, "installpkg"].concat(win.installArgs)
            stdout: SplitParser { onRead: (l) => win.storeLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.storeLog += l + "\n" }
            onExited: (c, s) => {
                if (c === 0) { win.storeStatus = "DONE ✓"; }
                else { win.storeStatus = "FAILED · " + c; }
                win.apps = [];
            }
        }

        // ---- backend processes: updates ---------------------------------
        Process {
            id: checkProc
            command: [win.scriptPath, "updates"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.updates = JSON.parse(text); }
                    catch (e) { win.updates = []; }
                    win.updChecked = true;
                    win.updStatus = win.updates.length === 0 ? "UP TO DATE ✓" : win.updates.length + " PENDING";
                }
            }
        }
        Process {
            id: updProc
            command: [win.scriptPath].concat(win.updArgs)
            stdout: SplitParser { onRead: (l) => win.updLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.updLog += l + "\n" }
            onExited: (c, s) => {
                win.updStatus = c === 0 ? "DONE ✓" : "FAILED · " + c;
                // AUR builds keep going in their terminal; everything else is re-checked
                if (!(win.updArgs[0] === "update" && win.updArgs[1] === "aur")) win.checkUpdates();
            }
        }
        Process {
            id: newsProc
            command: [win.scriptPath, "news"]
            stdout: StdioCollector {
                onStreamFinished: { try { win.news = JSON.parse(text); } catch (e) { win.news = []; } }
            }
        }
        Process {
            id: versionProc
            command: [win.scriptPath, "version"]
            stdout: StdioCollector {
                onStreamFinished: {
                    var m = text.match(/^SHORT=(.*)$/m);
                    win.deckVersion = m ? m[1] : "";
                }
            }
        }
        Process {
            id: timerStatusProc
            command: [win.scriptPath, "timer", "status"]
            stdout: StdioCollector { onStreamFinished: win.autoCheck = text.trim() === "on" }
        }
        Process {
            id: timerProc
            command: [win.scriptPath, "timer"].concat(win.timerArgs)
            stdout: SplitParser { onRead: (l) => win.updLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.updLog += l + "\n" }
            onExited: (c, s) => { timerStatusProc.running = true; }
        }

        // ---- backend processes: system ----------------------------------
        Process {
            id: scanProc
            command: [win.scriptPath, "cleanscan"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.cleanItems = JSON.parse(text); }
                    catch (e) { win.cleanItems = []; }
                    var n = win.cleanItems.filter(function (i) { return i.count > 0; }).length;
                    win.sysStatus = n === 0 ? "ALL CLEAN ✓" : n + " TO CLEAN";
                }
            }
        }
        Process {
            id: sysProc
            command: [win.scriptPath].concat(win.sysArgs)
            stdout: SplitParser { onRead: (l) => win.sysLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.sysLog += l + "\n" }
            onExited: (c, s) => {
                win.sysStatus = c === 0 ? "DONE ✓" : "FAILED · " + c;
                win.confirmRestore = false;
                if (win.sysArgs[0] === "clean") scanProc.running = true;
                if (win.sysArgs[0] === "restore") win.apps = [];
                if (win.sysArgs[0] === "snapcreate") win.loadSnapshots(!win.snapStatus.canlist);
                if (win.sysArgs[0] === "snapdelete" && c === 0) {
                    win.snapshots = win.snapshots.filter(function (x) { return win.pendingDelete.indexOf(x.num) < 0; });
                    win.selSnaps = [];
                }
                if (win.sysArgs[0] === "snapcleanup") { win.confirmSnapCleanup = false; win.loadSnapshots(!win.snapStatus.canlist); }
                if (win.sysArgs[0] === "snapallow") snapStatusProc.running = true;
                histProc.running = true;
            }
        }
        Process {
            id: histProc
            command: [win.scriptPath, "history"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.history = JSON.parse(text); }
                    catch (e) { win.history = []; }
                }
            }
        }
        Process {
            id: snapStatusProc
            command: [win.scriptPath, "snapstatus"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.snapStatus = JSON.parse(text); } catch (e) { win.snapStatus = {}; }
                    if (win.snapStatus.canlist) win.loadSnapshots(false);
                }
            }
        }
        Process {
            id: snapListProc
            command: [win.scriptPath].concat(win.snapListArgs)
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.snapshots = JSON.parse(text); } catch (e) { win.snapshots = []; }
                    win.selSnaps = [];
                    if (win.sysView === "snapshots") win.sysStatus = win.snapshots.length + " SNAPSHOTS";
                }
            }
            stderr: SplitParser { onRead: (l) => win.sysLog += l + "\n" }
        }
        Process {
            id: snapLimitsProc
            command: [win.scriptPath, "snaplimits"]
            stdout: StdioCollector {
                onStreamFinished: {
                    var m = {};
                    text.split("\n").forEach(function (l) {
                        var i = l.indexOf("="); if (i > 0) m[l.substring(0, i)] = l.substring(i + 1);
                    });
                    win.snapLimits = m;
                }
            }
        }
        Process {
            id: assistantProc
            command: ["setsid", "-f", "btrfs-assistant-launcher"]
        }
        Process {
            id: gamesProc
            command: [win.scriptPath, "games"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.games = JSON.parse(text); } catch (e) { win.games = []; }
                    if (win.fxScan.length === 0 && !fxScanProc.running) { fxScanProc.cached = true; fxScanProc.running = true; }
                    win.gameStatus = win.games.length + " GAMES";
                    // keep the selection in sync (launch options / Proton may have changed)
                    var cur = win.games.filter(function (g) { return g.key === win.selGame; })[0];
                    if (cur) { win.selGameLaunch = cur.launch; win.selGameCompat = cur.compat; win.selGameWrapped = cur.wrapped; }
                    var ids = win.games.filter(function (g) { return g.source === "steam"; }).map(function (g) { return g.id; });
                    if (ids.length > 0) {
                        pdbProc.command = [win.scriptPath, "protondb"].concat(ids); pdbProc.running = true;
                        tipsProc.command = [win.scriptPath, "gtips"].concat(ids); tipsProc.running = true;
                    }
                }
            }
        }
        Process {
            id: pdbProc
            stdout: StdioCollector { onStreamFinished: { try { win.pdb = JSON.parse(text); } catch (e) {} } }
        }
        Process {
            id: gstatProc
            command: [win.scriptPath, "gstatus"]
            stdout: StdioCollector { onStreamFinished: { try { win.gstat = JSON.parse(text); } catch (e) {} } }
        }
        Process {
            id: toolsProc
            command: [win.scriptPath, "compattools"]
            stdout: StdioCollector { onStreamFinished: { try { win.tools = JSON.parse(text); } catch (e) { win.tools = []; } } }
        }
        Process {
            id: gprofProc
            command: [win.scriptPath, "gprofile", "get", win.selGame]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.gp = JSON.parse(text); } catch (e) { win.gp = {}; }
                    gEnv.text = win.envString(win.gp.env); gPrefix.text = win.gp.prefix || ""; gArgs.text = win.gp.args || "";
                }
            }
        }
        Process {
            id: gameProc
            command: [win.scriptPath].concat(win.gameArgs)
            stdout: SplitParser { onRead: (l) => win.gameLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.gameLog += l + "\n" }
            onExited: (c, s) => {
                win.gameStatus = c === 0 ? "DONE ✓" : (c === 3 ? "CLOSE STEAM FIRST" : "FAILED · " + c);
                gamesProc.running = true; gstatProc.running = true; pdbStatProc.running = true;
                if (win.gameArgs[0] === "pdbindex" && win.selGameId) sugProc.running = true;
                if (win.gameArgs[0] === "shaderclean") shaderProc.running = true;
                // PLAY on a Steam game saves the editor first, then launches
                if (win.gameArgs[0] === "gprofile" && win.gameArgs[1] === "set" && win.pendingPlay) {
                    win.pendingPlay = false;
                    if (c === 0) { Qt.callLater(function () { win.runGame(["gplay", win.selGame], "LAUNCHING…"); }); return; }
                }
                if (win.gameArgs[0] === "bench" && win.gameArgs[1] === "set" && win.pendingRun !== "") {
                    var v = win.pendingRun; win.pendingRun = "";
                    // started after this handler returns (restarting a Process from its own onExited is unsafe)
                    if (c === 0) { Qt.callLater(function () { win.runGame(["bench", "run", win.selGame, v], "RUN " + v + "…"); }); return; }
                }
                if (win.gameArgs[0] === "bench") benchProc.running = true;
                if (win.gameArgs[0] === "prefix") { pfxProc.running = true; pfxBakProc.running = true; }
                if (win.gameArgs[0] === "fx" || (win.gameArgs[0] === "steamwrap" && win.gameView === "fx")) fxStatProc.running = true;
                if (win.gameArgs[0] === "fx" && win.fxScope === "library") { fxScanProc.cached = false; fxScanProc.running = true; }
                if (win.selGame) gprofProc.running = true;
            }
        }
        Process {
            id: sugProc
            command: [win.scriptPath, "gsuggest", win.selGameId]
            stdout: StdioCollector { onStreamFinished: { try { win.sug = JSON.parse(text); } catch (e) { win.sug = {}; } } }
        }
        Process {
            id: tipsProc
            stdout: StdioCollector { onStreamFinished: { try { win.tips = JSON.parse(text); } catch (e) {} } }
        }
        Process {
            id: pdbStatProc
            command: [win.scriptPath, "pdbindex", "status"]
            stdout: StdioCollector { onStreamFinished: { try { win.pdbStat = JSON.parse(text); } catch (e) { win.pdbStat = {}; } } }
        }
        Process { id: seenProc }
        Process {
            id: pfxProc
            command: [win.scriptPath, "prefixes"]
            stdout: StdioCollector { onStreamFinished: { try { win.pfx = JSON.parse(text); } catch (e) { win.pfx = {}; } } }
        }
        Process {
            id: pfxBakProc
            command: [win.scriptPath, "prefix", "backups"]
            stdout: StdioCollector { onStreamFinished: { try { win.pfxBackups = JSON.parse(text); } catch (e) { win.pfxBackups = []; } } }
        }
        Process {
            id: pfxOpenProc
            command: ["xdg-open", win.home + "/control-deck-backups/prefixes"]
        }
        Process {
            id: benchProc
            command: [win.scriptPath, "bench", "get", win.selGame]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.bench = JSON.parse(text); } catch (e) { win.bench = {}; }
                    if (win.benchLoadedFor !== win.selGame) { win.loadBench(); win.benchLoadedFor = win.selGame; }
                    benchChart.requestPaint();
                }
            }
        }
        Process {
            id: healthProc
            command: [win.scriptPath, "health"]
            stdout: StdioCollector { onStreamFinished: { try { win.health = JSON.parse(text); } catch (e) { win.health = {}; } } }
        }
        Process { id: fixCopyProc }
        Process {
            id: fxStatProc
            command: [win.scriptPath, "fx", "status", win.selGame]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.fx = JSON.parse(text); } catch (e) { win.fx = {}; }
                    // a new game (or the tab just opened) starts at the top: loading content can leave it scrolled
                    if (win.fxTopFor !== win.selGame) { win.fxTopFor = win.selGame; Qt.callLater(win.fxToTop); }
                }
            }
        }
        Process {
            id: fxPickProc
            command: [win.scriptPath, "pickfile", "Choose a downloaded ReShade preset", "@downloads",
                      "ReShade preset (zip, 7z, rar, ini) | *.zip *.7z *.rar *.ini *.txt"]
            stdout: StdioCollector {
                onStreamFinished: {
                    var f = text.trim(); if (!f) return;
                    win.fxImportFile = f; win.fxImportList = []; win.fxMsg = "Reading " + f.replace(/^.*\//, "") + "…";
                    fxImpListProc.command = [win.scriptPath, "fx", "importlist", f]; fxImpListProc.running = true;
                }
            }
        }
        Process {
            id: fxImpListProc
            stdout: StdioCollector {
                onStreamFinished: {
                    var l = []; try { l = JSON.parse(text); } catch (e) { }
                    if (l.length === 0) { win.fxMsg = "No ReShade preset in that file (it needs a Techniques= line)."; return; }
                    if (l.length === 1) {
                        win.fxMsg = "";
                        win.fxApply("file:" + win.fxImportFile, "IMPORTING PRESET…", ["fx", "import", win.selGame, win.fxImportFile]);
                    } else { win.fxImportList = l; win.fxMsg = l.length + " presets in this file: pick one"; }
                }
            }
        }
        Process {
            id: fxScanProc
            property bool cached: false
            command: [win.scriptPath, "fx", "scan"].concat(cached ? ["--cached"] : [])
            stdout: StdioCollector { onStreamFinished: { try { win.fxScan = JSON.parse(text); } catch (e) { } } }
        }
        Process {
            id: fxSearchProc
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.fxGames = JSON.parse(text); } catch (e) { win.fxGames = []; }
                    if (win.fxGames.length === 0) win.fxMsg = "No game with that name on SweetFX Settings DB: try another name, or use a quick look.";
                    else win.fxLoadPresets(win.fxGames[0].id);
                }
            }
        }
        Process {
            id: fxPresetsProc
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.fxPresets = JSON.parse(text); } catch (e) { win.fxPresets = []; }
                    win.fxMsg = win.fxPresets.length === 0 ? "This game has no presets yet." : win.fxPresets.length + " presets — newest first";
                    Qt.callLater(win.fxToTop);
                }
            }
        }
        Timer { id: copiedTimer; interval: 1800; onTriggered: win.copiedFix = "" }
        Process {
            id: shaderProc
            command: [win.scriptPath, "shadercache"]
            stdout: StdioCollector { onStreamFinished: { try { win.shaders = JSON.parse(text); } catch (e) { win.shaders = {}; } } }
        }
        Process {
            id: steamOpenProc
            command: ["setsid", "-f", "steam"]
        }
        Process {
            id: pickRestoreProc
            command: [win.scriptPath, "pickfile", "Choose a Control Deck backup (.json)"]
            stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p) restoreField.text = p; } }
        }

        // ---- reusable bits ----------------------------------------------
        // hover hint in the deck's colours (Qt's default tooltip is a white box)
        component Tip: ToolTip {
            id: tipc
            delay: 450
            padding: 7
            width: Math.min(380, tipText.implicitWidth + leftPadding + rightPadding)
            contentItem: Text {
                id: tipText
                text: tipc.text; wrapMode: Text.WordWrap
                color: pal.text; font.family: win.mono; font.pixelSize: 10
            }
            background: Rectangle { color: pal.cardHi; border.color: pal.accent; border.width: 1; radius: 6 }
        }
        // a fix command, shown and copied, never run
        component FixLine: RowLayout {
            property string cmd
            spacing: 6
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: fixTxt.implicitHeight + 10
                radius: 4; color: pal.logBg; border.color: pal.border; border.width: 1
                Text {
                    id: fixTxt
                    anchors.fill: parent; anchors.margins: 5
                    text: cmd === "reboot" ? "Restart the PC" : "$ " + cmd
                    wrapMode: Text.WrapAnywhere
                    color: pal.sky; font.family: win.mono; font.pixelSize: 10
                }
            }
            Chip {
                visible: cmd !== "reboot"
                label: win.copiedFix === cmd ? "COPIED ✓" : "COPY"
                tint: pal.ok; active: win.copiedFix === cmd
                onClicked: {
                    fixCopyProc.command = ["wl-copy", "--", cmd];
                    fixCopyProc.running = true;
                    win.copiedFix = cmd; copiedTimer.restart();
                }
            }
        }
        component Section: RowLayout {
            property string label
            property string info: ""
            spacing: 9
            Rectangle { width: 7; height: 7; color: pal.accent; Layout.alignment: Qt.AlignVCenter }
            Text {
                text: label
                color: pal.text; font.family: win.mono
                font.pixelSize: 12; font.letterSpacing: 4; font.bold: true
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: info !== ""
                text: info; elide: Text.ElideLeft
                color: pal.dim; font.family: win.mono
                font.pixelSize: 12; font.letterSpacing: 2
            }
        }

        component ActBtn: Item {
            id: ab
            property string glyph
            property string label
            property bool boxed: false
            property bool on: true
            signal clicked
            Layout.fillWidth: true
            implicitHeight: col.implicitHeight
            opacity: on ? 1.0 : 0.3

            ColumnLayout {
                id: col
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: 40; implicitHeight: 40; radius: 8
                    color: ab.boxed && ab.on ? pal.cardHi : "transparent"
                    border.color: ab.boxed && ab.on ? pal.accent : "transparent"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: ab.glyph; font.family: win.mono; font.pixelSize: 18
                        color: ab.boxed && ab.on ? pal.accentHi : pal.text
                    }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: ab.label; color: pal.dim; font.family: win.mono
                    font.pixelSize: 10; font.letterSpacing: 2
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: ab.on
                cursorShape: Qt.PointingHandCursor
                onClicked: ab.clicked()
            }
        }

        component BarSep: Rectangle { width: 1; Layout.preferredHeight: 46; color: pal.border }
        // one variant of an A/B benchmark
        component BenchVariant: Rectangle {
            id: bv
            property string v
            property color tint
            property alias label: bvLabel.text
            property alias env: bvEnv.text
            property alias args: bvArgs.text
            property string gm: ""        // "", "true", "false"
            property string proton: ""    // "" = as is
            Layout.fillWidth: true
            implicitHeight: bvCol.implicitHeight + 16
            radius: 8; color: pal.card; border.width: 1; border.color: tint
            ColumnLayout {
                id: bvCol
                anchors.fill: parent; anchors.margins: 8; spacing: 6
                RowLayout {
                    spacing: 6
                    Text { text: bv.v; color: bv.tint; font.family: win.mono; font.pixelSize: 13; font.bold: true }
                    Field { id: bvLabel; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: "name" }
                }
                Field { id: bvEnv; Layout.fillWidth: true; font.pixelSize: 10; placeholderText: "extra env: VAR=1 VAR2=x" }
                Field { id: bvArgs; Layout.fillWidth: true; font.pixelSize: 10; placeholderText: "args (replace the profile's)" }
                Flow {
                    Layout.fillWidth: true; spacing: 4
                    Text { text: "GAMEMODE"; color: pal.dim; font.family: win.mono; font.pixelSize: 8; height: 22; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: [["", "PROFILE"], ["true", "ON"], ["false", "OFF"]]
                        delegate: Chip { required property var modelData; label: modelData[1]; implicitHeight: 22
                                         active: bv.gm === modelData[0]; onClicked: bv.gm = modelData[0] }
                    }
                }
                Flow {
                    Layout.fillWidth: true; spacing: 4
                    Text { text: "PROTON"; color: pal.dim; font.family: win.mono; font.pixelSize: 8; height: 22; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: [{ name: "", display: "AS IS" }].concat(win.tools)
                        delegate: Chip { required property var modelData; label: modelData.display; implicitHeight: 22
                                         active: bv.proton === modelData.name; onClicked: bv.proton = modelData.name }
                    }
                }
            }
        }


        component NavTab: Item {
            property string label
            property string key
            implicitWidth: nt.implicitWidth + 6
            implicitHeight: 28
            Text {
                id: nt
                anchors.left: parent.left; anchors.top: parent.top
                text: label; font.family: win.mono; font.pixelSize: 12
                font.letterSpacing: 3; font.bold: true
                color: win.view === key ? pal.accentHi : pal.dim
            }
            Rectangle {
                anchors.left: parent.left; anchors.bottom: parent.bottom
                width: nt.implicitWidth; height: 2; color: pal.accent
                visible: win.view === key
            }
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: {
                    win.view = key;
                    if (key === "manage" && win.apps.length === 0) win.refreshApps();
                    if (key === "updates" && !win.updChecked && !win.updBusy) win.checkUpdates();
                    if (key === "system") win.openSystem(win.sysView);
                    if (key === "gaming" && win.games.length === 0) win.openGaming();
                }
            }
        }

        // small toggle / button chip
        component Chip: Rectangle {
            id: chip
            property string label
            property bool active: false
            property bool on: true
            property color tint: pal.accent
            property string tip: ""
            signal clicked
            implicitWidth: ct.implicitWidth + 16
            implicitHeight: 26
            radius: 5
            opacity: on ? 1.0 : 0.35
            color: active ? pal.cardHi : "transparent"
            border.color: active ? tint : pal.border
            border.width: 1
            Text {
                id: ct
                anchors.centerIn: parent
                text: chip.label; font.family: win.mono; font.pixelSize: 9
                font.bold: true; font.letterSpacing: 1
                color: chip.active ? chip.tint : pal.dim
            }
            MouseArea {
                id: chipMa
                anchors.fill: parent; enabled: chip.on; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: chip.clicked()
            }
            Tip { visible: chip.tip !== "" && chipMa.containsMouse; text: chip.tip }
        }

        // source badge
        component Badge: Rectangle {
            property string label
            property color tint: pal.accent
            width: 62; height: 20; radius: 4
            color: "transparent"
            border.color: tint; border.width: 1
            Text {
                anchors.centerIn: parent
                text: label.toUpperCase(); color: tint
                font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
            }
        }

        component Field: TextField {
            placeholderTextColor: pal.dim
            color: pal.text; font.family: win.mono; font.pixelSize: 12; leftPadding: 10
            background: Rectangle { color: "transparent"; border.color: pal.border; border.width: 1; radius: 6 }
        }

        // small boxed button (row actions)
        component MiniBtn: Rectangle {
            id: mb
            property string label
            property bool on: true
            property bool primary: true
            property color tint: pal.accent
            signal clicked
            width: 76; height: 30; radius: 6
            color: primary && on ? pal.cardHi : "transparent"
            border.color: primary && on ? tint : pal.border
            border.width: 1
            opacity: on ? 1.0 : 0.4
            Text {
                anchors.centerIn: parent
                text: mb.label
                color: mb.primary && mb.on ? pal.accentHi : pal.dim
                font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
            }
            MouseArea {
                anchors.fill: parent; enabled: mb.on
                cursorShape: Qt.PointingHandCursor
                onClicked: mb.clicked()
            }
        }

        component LogBox: Rectangle {
            id: lb
            property string content: ""
            property string placeholder: "// log output"
            property int base: 170
            property bool expanded: false
            Layout.preferredHeight: expanded ? Math.max(base * 2.5, 420) : base
            Layout.minimumHeight: 60
            radius: 8; color: pal.logBg
            border.color: pal.border; border.width: 1
            ScrollView {
                anchors.fill: parent
                anchors.margins: 8
                anchors.rightMargin: 30
                clip: true
                TextArea {
                    readOnly: true
                    text: lb.content || lb.placeholder
                    color: lb.content ? pal.text : pal.dim
                    font.family: win.mono; font.pixelSize: 11
                    wrapMode: TextArea.WordWrap
                    background: null
                    onTextChanged: cursorPosition = length
                }
            }
            // expand / shrink
            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6
                width: 22; height: 22; radius: 4
                color: expandMa.containsMouse ? pal.cardHi : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: lb.expanded ? "" : ""
                    color: pal.dim; font.family: win.mono; font.pixelSize: 11
                }
                MouseArea {
                    id: expandMa
                    anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: lb.expanded = !lb.expanded
                }
            }
        }

        // centered placeholder for empty panels
        component EmptyHint: ColumnLayout {
            property string title
            property string sub: ""
            anchors.centerIn: parent
            spacing: 8
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "力"; color: "#141127"; font.pixelSize: 96; font.bold: true
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: title; color: pal.dim; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 2
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                visible: sub !== ""
                text: sub; color: pal.dim; font.family: win.mono; font.pixelSize: 10
            }
        }

        component Hint: Text {
            Layout.fillWidth: true
            color: pal.dim; font.family: win.mono; font.pixelSize: 10; wrapMode: Text.WordWrap
        }

        // ---- layout ------------------------------------------------------
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 16

            // header
            RowLayout {
                spacing: 12
                Text { text: "力"; color: pal.accent; font.pixelSize: 22; font.bold: true }
                Text {
                    text: "CONTROL DECK"; color: pal.text; font.family: win.mono
                    font.pixelSize: 16; font.letterSpacing: 6; font.bold: true
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: win.deckUpdate
                    text: "● NEW VERSION"; color: pal.amber; font.family: win.mono
                    font.pixelSize: 10; font.letterSpacing: 2; font.bold: true
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: win.view = "updates"
                    }
                }
                Text {
                    visible: win.deckVersion !== ""
                    text: win.deckVersion; color: pal.dim; font.family: win.mono; font.pixelSize: 10
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

            // nav
            RowLayout {
                spacing: 18
                NavTab { label: "INSTALL"; key: "install" }
                NavTab { label: "MANAGE";  key: "manage" }
                NavTab { label: "STORE";   key: "store" }
                NavTab { label: "UPDATES"; key: "updates" }
                NavTab { label: "SYSTEM";  key: "system" }
                NavTab { label: "GAMING";  key: "gaming" }
            }

            // ================= INSTALL VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "install"
                spacing: 16

            Section {
                Layout.fillWidth: true; label: "STASH"
                info: win.queue.length > 0
                      ? win.queue.length + (win.queue.length === 1 ? " FILE" : " FILES")
                      : "NO FILE"
            }

            // drop zone
            Rectangle {
                id: dropZone
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 100
                radius: 10
                color: dropArea.containsDrag ? pal.cardHi : pal.panel
                border.color: dropArea.containsDrag ? pal.accent : pal.border
                border.width: 1
                clip: true

                // dot grid
                Canvas {
                    id: grid
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.fillStyle = "#1b1830";
                        var step = 24;
                        for (var x = step / 2; x < width; x += step)
                            for (var y = step / 2; y < height; y += step) {
                                ctx.beginPath(); ctx.arc(x, y, 1.1, 0, 6.2832); ctx.fill();
                            }
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }

                // watermark
                Text {
                    anchors.centerIn: parent
                    text: "力"; font.pixelSize: 150; font.bold: true
                    color: "#141127"; visible: win.queue.length === 0
                }
                Text {
                    anchors.centerIn: parent
                    visible: win.queue.length === 0
                    y: parent.height / 2 + 40
                    text: "DROP PACKAGE(S) HERE"; color: pal.dim; font.family: win.mono
                    font.pixelSize: 12; font.letterSpacing: 3
                }

                // supported formats (shown while the queue is empty and there's room)
                ColumnLayout {
                    visible: win.queue.length === 0 && dropZone.height >= 280
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottomMargin: 16
                    spacing: 3
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "SUPPORTED FORMATS"; color: pal.dim; font.family: win.mono
                        font.pixelSize: 9; font.letterSpacing: 3; bottomPadding: 4
                    }
                    Repeater {
                        model: win.formats
                        delegate: RowLayout {
                            required property var modelData
                            spacing: 10
                            Text {
                                Layout.preferredWidth: 74; horizontalAlignment: Text.AlignRight
                                text: modelData.t; color: pal.accent; font.family: win.mono
                                font.pixelSize: 10; font.bold: true; font.letterSpacing: 1
                            }
                            Text {
                                text: modelData.e; color: pal.dim; font.family: win.mono
                                font.pixelSize: 10
                            }
                        }
                    }
                }

                // single-file card
                Rectangle {
                    visible: win.queue.length === 1
                    x: 18; y: 18
                    width: 128; height: 128; radius: 10
                    color: pal.cardHi
                    border.color: (win.queue.length === 1 && win.queue[0].supported === "yes") ? pal.accent : pal.bad
                    border.width: 1
                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 20
                        spacing: 6
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: ""; font.family: win.mono; font.pixelSize: 34
                            color: pal.accentHi
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: win.queue.length === 1 ? win.typeShort(win.queue[0].type) : ""
                            color: pal.accent; font.family: win.mono
                            font.pixelSize: 11; font.letterSpacing: 2; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: win.queue.length === 1 ? win.queue[0].name : ""
                            color: pal.text; font.family: win.mono
                            font.pixelSize: 10; elide: Text.ElideMiddle
                        }
                    }
                }

                // multi-file queue list
                ListView {
                    visible: win.queue.length > 1
                    anchors.fill: parent; anchors.margins: 14
                    clip: true; spacing: 4
                    model: win.queue
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width - 8; height: 40; radius: 8
                        color: pal.cardHi
                        border.color: modelData.supported === "yes" ? pal.border : pal.bad
                        border.width: 1
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                            Text {
                                Layout.fillWidth: true; text: modelData.name
                                color: pal.text; font.family: win.mono; font.pixelSize: 12; elide: Text.ElideMiddle
                            }
                            Text {
                                text: win.typeShort(modelData.type)
                                color: modelData.supported === "yes" ? pal.accent : pal.bad
                                font.family: win.mono; font.pixelSize: 10; font.letterSpacing: 1; font.bold: true
                            }
                        }
                    }
                }

                DropArea {
                    id: dropArea
                    anchors.fill: parent
                    onDropped: (drop) => {
                        if (drop.hasUrls && drop.urls.length > 0) {
                            var ps = [];
                            for (var i = 0; i < drop.urls.length; i++)
                                ps.push(win.pathFromUrl(drop.urls[i]));
                            win.loadFiles(ps);
                        }
                    }
                }
            }

            // manual path / URL / GitHub repo (also the Wayland DnD safety net)
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: ">"; color: pal.accent; font.family: win.mono; font.pixelSize: 13 }
                Field {
                    id: pathField
                    Layout.fillWidth: true
                    placeholderText: "path, download URL or github.com/user/repo…"
                    enabled: !win.busy
                    onAccepted: win.submitInput(text)
                }
            }

            // status
            Section { Layout.fillWidth: true; label: "STATUS"; info: win.status }
            Text {
                Layout.fillWidth: true
                visible: win.queue.length > 0 && win.supportedCount() < win.queue.length
                text: (win.queue.length - win.supportedCount()) + " file(s) can't be installed and will be skipped (rpm / deb without debtap / unknown)."
                color: pal.bad; font.family: win.mono; font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            LogBox { Layout.fillWidth: true; base: 190; content: win.logText }

            Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

            // action bar
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                ActBtn {
                    glyph: ""; label: "CLEAR"
                    on: win.queue.length > 0 && !win.busy
                    onClicked: { win.reset(); pathField.text = ""; }
                }
                BarSep {}
                ActBtn {
                    glyph: ""; label: "FOLDER"
                    on: !win.busy
                    onClicked: openProc.running = true
                }
                BarSep {}
                ActBtn {
                    glyph: ""; label: win.busy ? "WORKING" : (win.queue.length > 1 ? "INSTALL ALL" : "INSTALL")
                    boxed: true
                    on: win.supportedCount() > 0 && !win.busy
                    onClicked: {
                        win.installPaths = win.queue
                            .filter(function (q) { return q.supported === "yes"; })
                            .map(function (q) { return q.path; });
                        win.logText = "";
                        win.status = "INSTALLING…"; win.statusColor = pal.pink;
                        installProc.running = true;
                    }
                }
            }
            } // ================= end INSTALL VIEW =================

            // ================= MANAGE VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "manage"
                spacing: 12

                Section { Layout.fillWidth: true; label: "APPS"; info: win.appsInfo }

                // search + sort
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: ""; color: pal.accent; font.family: win.mono; font.pixelSize: 12 }
                    Field {
                        id: searchField
                        Layout.fillWidth: true
                        placeholderText: "filter…"
                        onTextChanged: win.searchText = text
                    }
                    Chip { label: "A–Z";  active: !win.sortBySize; onClicked: win.sortBySize = false }
                    Chip { label: "SIZE"; active: win.sortBySize;  onClicked: win.sortBySize = true }
                }

                // app list
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.minimumHeight: 120
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                    ListView {
                        id: appList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 2
                        model: win.appsFiltered
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: appList.width - 8; height: 34; radius: 6
                            color: win.selPath === modelData.path ? pal.cardHi : "transparent"
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                opacity: modelData.hidden ? 0.45 : 1.0
                                Item {
                                    width: 22; height: 22
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 6; height: 6; radius: 3
                                        visible: appIcon.status !== Image.Ready
                                        color: win.selPath === modelData.path ? pal.accent : pal.border
                                    }
                                    Image {
                                        id: appIcon
                                        anchors.fill: parent
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true; smooth: true
                                        sourceSize.width: 22; sourceSize.height: 22
                                        source: modelData.resolved ? "file://" + modelData.resolved : ""
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name; color: pal.text; font.family: win.mono
                                    font.pixelSize: 12; elide: Text.ElideRight
                                }
                                Text {
                                    visible: modelData.hidden
                                    text: "HIDDEN"; color: pal.pink
                                    font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                }
                                Text {
                                    Layout.preferredWidth: 58; horizontalAlignment: Text.AlignRight
                                    text: win.human(win.sizeOf(modelData.path))
                                    color: win.sortBySize ? pal.amber : pal.dim
                                    font.family: win.mono; font.pixelSize: 9
                                }
                                Text {
                                    Layout.preferredWidth: 58; horizontalAlignment: Text.AlignRight
                                    text: modelData.source.toUpperCase(); color: pal.dim
                                    font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: win.selectApp(modelData.path)
                            }
                        }
                    }
                }

                // editor — only appears once an app is selected
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 10
                    visible: win.selPath !== ""

                Section { Layout.fillWidth: true; label: "EDIT"; info: win.manageStatus }

                // editor row: icon preview + fields
                RowLayout {
                    Layout.fillWidth: true; spacing: 14
                    Rectangle {
                        width: 72; height: 72; radius: 10
                        color: pal.card; border.color: pal.border; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            visible: iconPreview.status !== Image.Ready
                            text: ""; font.family: win.mono; font.pixelSize: 26; color: pal.dim
                        }
                        Image {
                            id: iconPreview
                            anchors.centerIn: parent; width: 52; height: 52
                            fillMode: Image.PreserveAspectFit; smooth: true; asynchronous: true
                            source: {
                                var p = iconEdit.text.trim();
                                if (p.charAt(0) === "/") return "file://" + p;
                                if (win.selResolvedIcon) return "file://" + win.selResolvedIcon;
                                return "";
                            }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 8
                        Field {
                            id: nameEdit
                            Layout.fillWidth: true; enabled: win.selPath !== ""
                            placeholderText: "app name"; font.pixelSize: 13
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Field {
                                id: iconEdit
                                Layout.fillWidth: true; enabled: win.selPath !== ""
                                placeholderText: "icon name or /path"
                            }
                            Rectangle {
                                width: 40; height: 34; radius: 6
                                color: pal.card; border.color: pal.border; border.width: 1
                                Text { anchors.centerIn: parent; text: ""; font.family: win.mono; font.pixelSize: 15; color: pal.accent }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (win.selPath) pickProc.running = true
                                }
                            }
                        }
                    }
                }

                // advanced fields: Exec · categories · flags
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: win.showAdvanced
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "EXEC"; Layout.preferredWidth: 38; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                        Field {
                            id: execEdit
                            Layout.fillWidth: true
                            placeholderText: "program %U   ·   env VAR=1 program --flag"
                            font.pixelSize: 11
                        }
                        Chip { label: "WAYLAND"; tint: pal.sky; onClicked: execEdit.text = win.withWaylandFlags(execEdit.text) }
                        Chip { label: "COPY"; onClicked: win.runQuick(copyProc) }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "CATS"; Layout.preferredWidth: 38; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                        Field {
                            id: catEdit
                            Layout.fillWidth: true
                            placeholderText: "Game;Utility;Development;…"
                            font.pixelSize: 11
                        }
                        Chip { label: "HIDDEN"; tint: pal.pink; active: win.selHidden; onClicked: win.selHidden = !win.selHidden }
                        Chip { label: "TERMINAL"; active: win.selTerminal; onClicked: win.selTerminal = !win.selTerminal }
                    }
                }

                // flatpak permissions (toggle = user override)
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: win.selSource === "flatpak" && win.fpPerms.length > 0
                    Text {
                        Layout.alignment: Qt.AlignTop; Layout.topMargin: 6
                        text: "PERMS"; Layout.preferredWidth: 38; color: pal.dim
                        font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: win.fpPerms
                            delegate: Chip {
                                required property var modelData
                                label: (modelData.granted ? "✓ " : "") + modelData.label.toUpperCase()
                                active: modelData.granted; tint: pal.sky
                                on: !win.manageBusy
                                onClicked: {
                                    win.manageLog = "";
                                    win.fpArgs = ["fpset", win.selAppId, modelData.key, modelData.granted ? "off" : "on"];
                                    fpSetProc.running = true;
                                }
                            }
                        }
                        Chip {
                            label: "RESET"; tint: pal.bad
                            on: !win.manageBusy
                            onClicked: { win.manageLog = ""; win.fpArgs = ["fpreset", win.selAppId]; fpSetProc.running = true; }
                        }
                    }
                }

                // diagnosis: why it doesn't start + one-click fixes
                Rectangle {
                    Layout.fillWidth: true
                    visible: win.selIssue !== ""
                    implicitHeight: issueRow.implicitHeight + 16
                    radius: 6; color: "#1a0f16"; border.color: pal.bad; border.width: 1
                    RowLayout {
                        id: issueRow
                        anchors.fill: parent; anchors.margins: 8; spacing: 8
                        Text { text: ""; color: pal.bad; font.family: win.mono; font.pixelSize: 13 }
                        Text {
                            Layout.fillWidth: true
                            text: win.selIssue; color: pal.text; wrapMode: Text.WordWrap
                            font.family: win.mono; font.pixelSize: 10
                        }
                        Repeater {
                            model: win.selFixes
                            delegate: Chip {
                                required property var modelData
                                label: modelData.label; tint: pal.ok; active: true
                                on: !win.manageBusy
                                onClicked: win.applyFix(modelData.kind)
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text {
                            Layout.fillWidth: true
                            text: win.selAction
                            color: win.selSource === "system" ? pal.bad : pal.dim
                            font.family: win.mono; font.pixelSize: 10; wrapMode: Text.WordWrap
                            maximumLineCount: 2; elide: Text.ElideRight
                        }
                        Text {
                            visible: win.sizes[win.selPath] !== undefined
                            text: {
                                var s = win.sizes[win.selPath];
                                return s ? "  app " + (win.human(s.app) || "–") + "  ·  data " + (win.human(s.data) || "–") : "";
                            }
                            color: pal.amber; font.family: win.mono; font.pixelSize: 10
                        }
                    }
                    Chip {
                        label: win.selAutostart ? "✓ AUTOSTART" : "AUTOSTART"
                        tint: pal.ok; active: win.selAutostart
                        on: !win.manageBusy
                        onClicked: {
                            win.manageLog = "";
                            win.autostartArgs = [win.selPath, win.selAutostart ? "off" : "on"];
                            autostartProc.running = true;
                        }
                    }
                    Chip {
                        label: win.purge ? "✓ DELETE DATA" : "+ DELETE DATA"
                        tint: pal.bad; active: win.purge
                        on: win.selSource !== "system" && win.selSource !== "wine" && !win.manageBusy
                        onClicked: win.purge = !win.purge
                    }
                    Chip {
                        label: win.showAdvanced ? "LESS ▴" : "MORE ▾"
                        active: win.showAdvanced
                        onClicked: win.showAdvanced = !win.showAdvanced
                    }
                }
                } // end editor panel

                LogBox {
                    Layout.fillWidth: true; base: 150
                    visible: win.manageLog !== ""
                    content: win.manageLog
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

                // manage action bar
                RowLayout {
                    Layout.fillWidth: true; spacing: 0
                    ActBtn {
                        glyph: ""; label: "REFRESH"
                        on: !win.manageBusy
                        onClicked: { win.searchText = ""; searchField.text = ""; win.refreshApps(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "LAUNCH"
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: win.runQuick(launchProc)
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "FOLDER"
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: win.runQuick(dirProc)
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "SAVE"; boxed: true
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: {
                            var a = [win.selPath, "NAME=" + nameEdit.text, "ICON=" + iconEdit.text];
                            if (win.showAdvanced)
                                a = a.concat(["EXEC=" + execEdit.text, "CATEGORIES=" + catEdit.text]);
                            a = a.concat(["NODISPLAY=" + win.selHidden, "TERMINAL=" + win.selTerminal]);
                            win.editArgs = a;
                            win.manageLog = "";
                            editProc.running = true;
                        }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""
                        label: win.confirmUninstall ? "CONFIRM?" : "UNINSTALL"
                        on: win.selPath !== "" && win.selSource !== "system" && !win.manageBusy
                        onClicked: {
                            if (!win.confirmUninstall) {
                                win.confirmUninstall = true;
                                win.manageLog = "";
                                if (win.selSource === "pacman") {
                                    win.manageStatus = "REVIEW AND CONFIRM";
                                    previewProc.running = true;   // pacman -Rns preview (+ leftovers)
                                } else if (win.purge) {
                                    win.manageStatus = "REVIEW AND CONFIRM";
                                    leftoverProc.running = true;
                                } else {
                                    win.manageStatus = "CLICK AGAIN TO CONFIRM";
                                }
                            } else {
                                win.uninstallArgs = win.purge ? [win.selPath, "--purge"] : [win.selPath];
                                uninstallProc.running = true;
                            }
                        }
                    }
                }
            } // ================= end MANAGE VIEW =================

            // ================= STORE VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "store"
                spacing: 12

                Section { Layout.fillWidth: true; label: "SEARCH"; info: win.storeStatus }

                // query
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: ""; color: pal.accent; font.family: win.mono; font.pixelSize: 12 }
                    Field {
                        id: queryField
                        Layout.fillWidth: true
                        placeholderText: "search repos · AUR · flatpak…  or  github.com/user/repo"
                        enabled: !win.storeBusy
                        onAccepted: win.runSearch(text)
                    }
                    MiniBtn {
                        width: 78; height: 34
                        label: win.storeBusy ? "…" : "SEARCH"
                        on: !win.storeBusy
                        onClicked: win.runSearch(queryField.text)
                    }
                }

                // results
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.review === null && !reviewProc.running
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.results.length === 0
                        title: win.storeBusy ? "SEARCHING…"
                             : (win.storeQuery === "" ? "TYPE AN APP AND PRESS ENTER"
                                                      : "NO RESULTS FOR «" + win.storeQuery + "»")
                        sub: win.storeQuery === "" && !win.storeBusy
                             ? "official repos · AUR · Flatpak · GitHub releases" : ""
                    }

                    ListView {
                        id: resultList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 3
                        model: win.results
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: resultList.width - 8; height: 56; radius: 8
                            color: pal.card; border.color: pal.border; border.width: 1
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                Badge {
                                    Layout.alignment: Qt.AlignVCenter
                                    label: modelData.source; tint: win.srcColor(modelData.source)
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 1
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Text {
                                            text: modelData.name; color: pal.text; font.family: win.mono
                                            font.pixelSize: 12; font.bold: true; elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Text {
                                            text: modelData.version; color: pal.dim
                                            font.family: win.mono; font.pixelSize: 9
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.desc; color: pal.dim; font.family: win.mono
                                        font.pixelSize: 10; elide: Text.ElideRight; maximumLineCount: 1
                                    }
                                }
                                MiniBtn {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 68
                                    label: modelData.installed ? "INSTALLED" : (modelData.source === "aur" ? "REVIEW" : "INSTALL")
                                    primary: !modelData.installed
                                    on: !modelData.installed && !win.storeBusy
                                    onClicked: win.installPkg(modelData.source, modelData.id, modelData.remote)
                                }
                            }
                        }
                    }
                }

                // AUR review: shown before building a package
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.review !== null || reviewProc.running
                    radius: 8; color: pal.panel; clip: true
                    border.color: win.review ? win.riskColor(win.review.risk) : pal.border; border.width: 1

                    EmptyHint { visible: reviewProc.running; title: "READING THE PKGBUILD…" }

                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 12; spacing: 8
                        visible: win.review !== null

                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                text: win.review ? win.review.name + "  " + win.review.version : ""
                                color: pal.text; font.family: win.mono; font.pixelSize: 13; font.bold: true
                            }
                            Badge {
                                width: 84
                                label: win.review ? win.review.risk + " risk" : ""
                                tint: win.review ? win.riskColor(win.review.risk) : pal.dim
                            }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: !win.review ? "" :
                                  (win.review.maintainer ? "maintainer " + win.review.maintainer : "ORPHANED (no maintainer)")
                                  + "  ·  " + win.review.votes + " votes"
                                  + "  ·  since " + win.dateOf(win.review.submitted)
                                  + "  ·  updated " + win.dateOf(win.review.modified)
                            color: pal.dim; font.family: win.mono; font.pixelSize: 10
                        }

                        // findings
                        Text {
                            visible: win.review !== null && win.review.flags.length === 0
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "✓ No suspicious patterns found. Still, only build packages you trust."
                            color: pal.ok; font.family: win.mono; font.pixelSize: 10
                        }
                        Repeater {
                            model: win.review ? win.review.flags : []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true; spacing: 8
                                Text {
                                    Layout.preferredWidth: 58
                                    text: "● " + modelData.level.toUpperCase()
                                    color: win.riskColor(modelData.level)
                                    font.family: win.mono; font.pixelSize: 9; font.bold: true
                                }
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    text: modelData.text; color: pal.text
                                    font.family: win.mono; font.pixelSize: 10
                                }
                                Text {
                                    text: modelData.where; color: pal.dim
                                    font.family: win.mono; font.pixelSize: 9
                                }
                            }
                        }

                        // the PKGBUILD itself
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            radius: 6; color: pal.logBg; border.color: pal.border; border.width: 1
                            ScrollView {
                                anchors.fill: parent; anchors.margins: 8; clip: true
                                TextArea {
                                    readOnly: true
                                    text: !win.review ? "" : win.review.pkgbuild
                                          + (win.review.install ? "\n# ─────────── .install ───────────\n" + win.review.install : "")
                                    color: pal.text; font.family: win.mono; font.pixelSize: 10
                                    wrapMode: TextArea.NoWrap; background: null
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            Hint {
                                text: "Building runs the PKGBUILD on your machine. Read it if anything is flagged."
                            }
                            MiniBtn {
                                width: 76; label: "CANCEL"; primary: false
                                onClicked: { win.review = null; win.storeStatus = win.results.length + " RESULTS"; }
                            }
                            MiniBtn {
                                width: 120
                                tint: win.review ? win.riskColor(win.review.risk) : pal.accent
                                label: !win.review ? "" : (win.review.risk === "high"
                                       ? (win.confirmRisky ? "REALLY BUILD?" : "BUILD ANYWAY")
                                       : "BUILD & INSTALL")
                                on: !win.storeBusy
                                onClicked: {
                                    if (win.review.risk === "high" && !win.confirmRisky) { win.confirmRisky = true; return; }
                                    win.installPkg("aur", win.review.name, "aur");
                                }
                            }
                        }
                    }
                }

                Hint {
                    visible: win.storeLog === ""
                    text: "Repos/Flatpak/GitHub install here. AUR packages are reviewed first, then built in a terminal. GitHub installs update from UPDATES."
                }

                LogBox {
                    Layout.fillWidth: true; base: 170
                    visible: win.storeLog !== ""
                    content: win.storeLog
                }
            } // ================= end STORE VIEW =================

            // ================= UPDATES VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "updates"
                spacing: 12

                Section { Layout.fillWidth: true; label: "UPDATES"; info: win.updStatus }

                // opt-in background check
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Chip {
                        label: win.autoCheck ? "✓ AUTO-CHECK ON" : "AUTO-CHECK OFF"
                        tint: pal.ok; active: win.autoCheck
                        on: !win.updBusy
                        onClicked: { win.updLog = ""; win.timerArgs = win.autoCheck ? ["off"] : ["on"]; timerProc.running = true; }
                    }
                    Hint {
                        text: win.autoCheck
                              ? "Checked every 6 h in the background: you get a notification, even with the deck closed."
                              : "Turn on to get a notification when updates are available (the deck doesn't need to be open)."
                    }
                }

                // GPU driver in this update → shader caches will be rebuilt
                Rectangle {
                    Layout.fillWidth: true
                    visible: win.driverUpdates.length > 0
                    implicitHeight: drvText.implicitHeight + 16
                    radius: 8; color: "#0c1520"; border.color: pal.sky; border.width: 1
                    Text {
                        id: drvText
                        anchors.fill: parent; anchors.margins: 8; wrapMode: Text.WordWrap
                        color: pal.sky; font.family: win.mono; font.pixelSize: 10
                        text: "\uf108  This update changes the GPU driver (" + win.driverUpdates.map(function (u) { return u.name + " " + u.old + " → " + u.new; }).join(", ")
                              + "). Every game's shader cache gets rebuilt: expect some stutter the first time you play each game. Old driver caches can be cleaned afterwards in GAMING → SHADERS."
                    }
                }

                // Arch news published since the last full upgrade
                Rectangle {
                    Layout.fillWidth: true
                    visible: win.unreadNews.length > 0
                    implicitHeight: newsCol.implicitHeight + 18
                    radius: 8; color: "#1a150c"; border.color: pal.amber; border.width: 1
                    ColumnLayout {
                        id: newsCol
                        anchors.fill: parent; anchors.margins: 9; spacing: 6
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "\uf1ea  " + win.unreadNews.length + " Arch news since your last upgrade — some need manual steps. Read them before updating:"
                            color: pal.amber; font.family: win.mono; font.pixelSize: 10; font.bold: true
                        }
                        Repeater {
                            model: win.unreadNews
                            delegate: ColumnLayout {
                                required property var modelData
                                Layout.fillWidth: true; spacing: 1
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    text: modelData.date + "  " + modelData.title
                                    color: pal.text; font.family: win.mono; font.pixelSize: 11; font.underline: newsMa.containsMouse
                                    MouseArea {
                                        id: newsMa
                                        anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Qt.openUrlExternally(modelData.link)
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                                    text: modelData.summary; color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.updates.length === 0
                        title: checkProc.running ? "CHECKING FOR UPDATES…"
                             : (win.updChecked ? "ALL UP TO DATE ✓" : "PRESS CHECK")
                        sub: "repos · AUR · Flatpak · AppImage/GitHub"
                    }

                    ListView {
                        id: updList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 3
                        model: win.updates
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: updList.width - 8; height: 46; radius: 8
                            color: pal.card; border.color: pal.border; border.width: 1
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                Badge {
                                    Layout.alignment: Qt.AlignVCenter
                                    label: modelData.source; tint: win.srcColor(modelData.source)
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name; color: pal.text; font.family: win.mono
                                    font.pixelSize: 12; font.bold: true; elide: Text.ElideRight
                                }
                                Text {
                                    Layout.maximumWidth: 220
                                    text: (modelData.old ? modelData.old + "  →  " : "→  ") + modelData.new
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    elide: Text.ElideLeft
                                }
                                MiniBtn {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 68
                                    label: modelData.source === "repo" ? "SYSTEM" : "UPDATE"
                                    primary: modelData.source !== "repo"
                                    on: !win.updBusy
                                    onClicked: win.guardedUpdate(["update", modelData.source, modelData.id],
                                                                 "UPDATING " + modelData.name + "…",
                                                                 modelData.source === "repo")
                                }
                            }
                        }
                    }
                }

                Hint {
                    visible: win.updLog === ""
                    text: "Arch doesn't support partial upgrades: repo packages are updated together (pacman -Syu). AUR opens a terminal."
                }

                LogBox {
                    Layout.fillWidth: true; base: 210
                    visible: win.updLog !== ""
                    content: win.updLog
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

                RowLayout {
                    Layout.fillWidth: true; spacing: 0
                    ActBtn {
                        glyph: ""; label: checkProc.running ? "CHECKING" : "CHECK"
                        on: !win.updBusy
                        onClicked: { win.updLog = ""; win.checkUpdates(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: updProc.running ? "WORKING" : "UPDATE ALL"
                        boxed: true
                        on: win.updates.length > 0 && !win.updBusy
                        onClicked: win.guardedUpdate(["updateall"], "UPDATING ALL…",
                                                     win.updates.some(function (u) { return u.source === "repo"; }))
                    }
                }
            } // ================= end UPDATES VIEW =================

            // ================= SYSTEM VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "system"
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Chip { label: "CLEAN";   active: win.sysView === "clean";   onClicked: win.openSystem("clean") }
                    Chip { label: "BACKUP";  active: win.sysView === "backup";  onClicked: win.openSystem("backup") }
                    Chip { label: "HISTORY"; active: win.sysView === "history"; onClicked: win.openSystem("history") }
                    Chip { label: "SNAPSHOTS"; active: win.sysView === "snapshots"; onClicked: win.openSystem("snapshots") }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignRight
                        text: win.sysStatus; color: pal.dim; font.family: win.mono
                        font.pixelSize: 12; font.letterSpacing: 2; elide: Text.ElideLeft
                    }
                }

                // ---- CLEAN ----
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.sysView === "clean"
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.cleanItems.length === 0
                        title: scanProc.running ? "SCANNING THE SYSTEM…" : "PRESS RESCAN"
                    }

                    ListView {
                        id: cleanList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 3
                        model: win.cleanItems
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: cleanList.width - 8; height: 62; radius: 8
                            color: pal.card; border.color: pal.border; border.width: 1
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 10
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Text {
                                            text: modelData.title; color: pal.text; font.family: win.mono
                                            font.pixelSize: 12; font.bold: true
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.count + (modelData.size ? "  ·  " + modelData.size : "")
                                            color: modelData.count > 0 ? pal.amber : pal.dim
                                            font.family: win.mono; font.pixelSize: 10
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.details ? modelData.details : modelData.desc
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                        elide: Text.ElideRight; maximumLineCount: 1
                                    }
                                }
                                MiniBtn {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: win.confirmClean === modelData.id ? 84 : 68
                                    label: modelData.count === 0 ? "OK ✓" : (win.confirmClean === modelData.id ? "CONFIRM?" : "CLEAN")
                                    primary: modelData.count > 0
                                    on: modelData.count > 0 && !win.sysBusy
                                    onClicked: {
                                        if (["shaders", "prefixes", "protons"].indexOf(modelData.id) >= 0 && win.confirmClean !== modelData.id) {
                                            win.confirmClean = modelData.id; return;
                                        }
                                        win.confirmClean = "";
                                        win.runSys(["clean", modelData.id], "CLEANING…");
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- BACKUP ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.sysView === "backup"
                    spacing: 12

                    Section { Layout.fillWidth: true; label: "EXPORT" }
                    Hint {
                        text: "Saves your packages (repos and AUR), Flatpaks, GitHub AppImages and the launchers you edited (with their icons) to ~/control-deck-backup-<date>.json."
                    }
                    MiniBtn {
                        width: 120; height: 34
                        label: "EXPORT BACKUP"
                        on: !win.sysBusy
                        onClicked: win.runSys(["export"], "EXPORTING…")
                    }

                    Section { Layout.fillWidth: true; label: "RESTORE" }
                    Hint {
                        text: "Installs whatever is missing from a backup: repo packages with pacman, Flatpaks, GitHub AppImages and launchers. AUR packages are built in a terminal."
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Field {
                            id: restoreField
                            Layout.fillWidth: true
                            placeholderText: "~/control-deck-backup-….json"
                            onTextChanged: win.confirmRestore = false
                        }
                        Rectangle {
                            width: 40; height: 34; radius: 6
                            color: pal.card; border.color: pal.border; border.width: 1
                            Text { anchors.centerIn: parent; text: ""; font.family: win.mono; font.pixelSize: 15; color: pal.accent }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: pickRestoreProc.running = true
                            }
                        }
                        MiniBtn {
                            width: 92; height: 34
                            label: win.confirmRestore ? "CONFIRM?" : "RESTORE"
                            on: restoreField.text.trim() !== "" && !win.sysBusy
                            onClicked: {
                                if (!win.confirmRestore) { win.confirmRestore = true; return; }
                                win.runSys(["restore", win.expandHome(restoreField.text.trim())], "RESTORING…");
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }

                // ---- HISTORY ----
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.sysView === "history"
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.history.length === 0
                        title: "NO OPERATIONS YET"
                    }

                    ListView {
                        id: histList
                        anchors.fill: parent; anchors.margins: 6
                        clip: true; spacing: 1
                        model: win.history
                        ScrollBar.vertical: ScrollBar {}
                        delegate: RowLayout {
                            required property var modelData
                            width: histList.width - 12; height: 26; spacing: 10
                            Text {
                                text: modelData.date.substring(5, 16); color: pal.dim
                                font.family: win.mono; font.pixelSize: 10
                            }
                            Text {
                                Layout.preferredWidth: 110
                                text: modelData.action.toUpperCase(); elide: Text.ElideRight
                                color: modelData.result === "ok" ? pal.accent : pal.bad
                                font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                            }
                            Text {
                                Layout.preferredWidth: 64
                                text: modelData.source; color: win.srcColor(modelData.source)
                                font.family: win.mono; font.pixelSize: 9; elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.target; color: pal.text
                                font.family: win.mono; font.pixelSize: 11; elide: Text.ElideMiddle
                            }
                            Text {
                                text: modelData.result === "ok" ? "✓" : "✗"
                                color: modelData.result === "ok" ? pal.ok : pal.bad
                                font.family: win.mono; font.pixelSize: 11
                            }
                        }
                    }
                }

                // ---- SNAPSHOTS ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.sysView === "snapshots"
                    spacing: 10

                    Hint {
                        text: !win.snapStatus.snapper
                              ? "snapper has no '" + (win.snapStatus.config || "root") + "' config on this system: nothing to show."
                              : (win.snapStatus.snappac
                                 ? "snap-pac is installed: every pacman operation already gets a pre/post snapshot."
                                 : "snap-pac is not installed: the deck takes a snapshot itself before pacman changes.")
                    }

                    // listing needs root unless the user was allowed (opt-in)
                    Rectangle {
                        Layout.fillWidth: true
                        visible: win.snapStatus.snapper === true && !win.snapStatus.canlist && win.snapshots.length === 0
                        implicitHeight: permCol.implicitHeight + 20
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1
                        ColumnLayout {
                            id: permCol
                            anchors.fill: parent; anchors.margins: 10; spacing: 8
                            Hint {
                                text: "Your snapper config only lets root list snapshots. Load them once with your password, or allow your user to list them (adds you to ALLOW_USERS — reading only; creating still asks for the password)."
                            }
                            RowLayout {
                                spacing: 8
                                MiniBtn { width: 130; label: "LOAD (PASSWORD)"; on: !win.sysBusy; onClicked: win.loadSnapshots(true) }
                                MiniBtn { width: 120; label: "ALLOW MY USER"; primary: false; on: !win.sysBusy
                                          onClicked: win.runSys(["snapallow"], "ALLOWING…") }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        Layout.minimumHeight: 110
                        visible: win.snapStatus.snapper === true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                        EmptyHint {
                            visible: win.snapshots.length === 0
                            title: snapListProc.running ? "LOADING SNAPSHOTS…" : "NO SNAPSHOTS LOADED"
                        }

                        ListView {
                            id: snapList
                            anchors.fill: parent; anchors.margins: 4
                            clip: true; spacing: 2
                            model: win.snapshots
                            ScrollBar.vertical: ScrollBar {}
                            delegate: Rectangle {
                                required property var modelData
                                width: snapList.width - 8; height: 30; radius: 6
                                property bool ticked: win.selSnaps.indexOf(modelData.num) >= 0
                                color: ticked ? pal.cardHi : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                    Text {
                                        text: parent.parent.ticked ? "\uf14a" : "\uf096"
                                        color: parent.parent.ticked ? pal.accent : pal.dim
                                        font.family: win.mono; font.pixelSize: 12
                                    }
                                    Text {
                                        Layout.preferredWidth: 44
                                        text: "#" + modelData.num; color: pal.accent
                                        font.family: win.mono; font.pixelSize: 11; font.bold: true
                                    }
                                    Text {
                                        Layout.preferredWidth: 118
                                        text: modelData.date.substring(0, 16); color: pal.dim
                                        font.family: win.mono; font.pixelSize: 10
                                    }
                                    Text {
                                        Layout.preferredWidth: 44
                                        text: modelData.type; color: modelData.type === "single" ? pal.amber : pal.dim
                                        font.family: win.mono; font.pixelSize: 9
                                    }
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        text: (modelData.important ? "★ " : "") + modelData.desc
                                        color: pal.text; font.family: win.mono; font.pixelSize: 11
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: win.toggleSnap(modelData)
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: win.snapStatus.snapper === true
                        Field {
                            id: snapDescField
                            Layout.fillWidth: true
                            placeholderText: "description for a new snapshot…"
                        }
                        MiniBtn {
                            width: 84; height: 34; label: "CREATE"
                            on: !win.sysBusy
                            onClicked: { win.runSys(["snapcreate", snapDescField.text.trim() || "manual snapshot"], "SNAPSHOTTING…"); snapDescField.text = ""; }
                        }
                        MiniBtn {
                            width: 110; height: 34; primary: false
                            label: win.selSnaps.length === 1 ? "DIFF #" + win.selSnaps[0] + " → NOW" : "DIFF → NOW"
                            on: win.selSnaps.length === 1 && !win.sysBusy
                            onClicked: win.runSys(["snapdiff", String(win.selSnaps[0])], "COMPARING…")
                        }
                    }

                    // deleting: ticked snapshots, or snapper's own cleanup rules
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: win.snapStatus.snapper === true
                        Hint {
                            text: {
                                var l = win.snapLimits;
                                if (!l.NUMBER_LIMIT) return "";
                                return "Auto-cleanup " + (l.CLEANUP_TIMER === "enabled" ? "runs hourly" : "is OFF (snapper-cleanup.timer disabled)")
                                     + ": keeps " + l.NUMBER_LIMIT + " numbered snapshots (" + l.NUMBER_LIMIT_IMPORTANT
                                     + " important), none younger than " + Math.round(l.NUMBER_MIN_AGE / 60) + " min."
                                     + (l.QGROUP ? "" : " Space limits need Btrfs quotas (off).");
                            }
                        }
                        MiniBtn {
                            width: 116; height: 34; primary: false
                            label: win.confirmSnapCleanup ? "CONFIRM?" : "CLEANUP NOW"
                            on: !win.sysBusy
                            onClicked: {
                                if (!win.confirmSnapCleanup) { win.confirmSnapCleanup = true; return; }
                                win.runSys(["snapcleanup"], "CLEANING UP…");
                            }
                        }
                        MiniBtn {
                            width: 112; height: 34
                            tint: pal.bad
                            label: win.selSnaps.length === 0 ? "DELETE"
                                 : (win.confirmSnapDelete ? "CONFIRM " + win.selSnaps.length + "?" : "DELETE (" + win.selSnaps.length + ")")
                            on: win.selSnaps.length > 0 && !win.sysBusy
                            onClicked: {
                                if (!win.confirmSnapDelete) {
                                    win.confirmSnapDelete = true;
                                    win.sysLog = "Will delete snapshot(s): #" + win.selSnaps.join(", #") + "\nClick again to confirm.\n";
                                    return;
                                }
                                win.pendingDelete = win.selSnaps.slice();
                                win.confirmSnapDelete = false;
                                win.runSys(["snapdelete"].concat(win.selSnaps.map(String)), "DELETING…");
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: win.snapStatus.snapper === true
                        Hint {
                            text: win.snapStatus.grubbtrfs
                                  ? "To go back: reboot, open \"Arch Linux snapshots\" in GRUB (grub-btrfs), boot the snapshot and check everything works, then run  sudo snapper rollback  and reboot."
                                  : "To go back: boot the snapshot from your boot menu (or a live USB), then run  sudo snapper rollback  and reboot."
                        }
                        Chip {
                            visible: win.snapStatus.assistant === true
                            label: "BTRFS ASSISTANT"
                            onClicked: assistantProc.running = true
                        }
                    }
                }

                LogBox {
                    Layout.fillWidth: true; base: 210
                    visible: win.sysLog !== ""
                    content: win.sysLog
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

                RowLayout {
                    Layout.fillWidth: true; spacing: 0
                    ActBtn {
                        glyph: ""; label: "RESCAN"
                        on: !win.sysBusy
                        onClicked: { win.sysLog = ""; win.openSystem("clean"); win.scanClean(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "HISTORY"
                        on: !win.sysBusy
                        onClicked: win.openSystem("history")
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "APPS DIR"
                        onClicked: openProc.running = true
                    }
                }
            } // ================= end SYSTEM VIEW =================
            // ================= GAMING VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "gaming"
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Chip { label: "LIBRARY"; active: win.gameView === "library"; onClicked: win.gameView = "library" }
                    Chip { label: "STATUS";  active: win.gameView === "status";  onClicked: { win.gameView = "status"; gstatProc.running = true; } }
                    Chip { label: "SHADERS"; active: win.gameView === "shaders"; onClicked: { win.gameView = "shaders"; shaderProc.running = true; } }
                    Chip { label: "BENCH";   active: win.gameView === "bench";   onClicked: { win.gameView = "bench"; if (win.selGame && win.selGameSource === "steam") benchProc.running = true; } }
                    Chip { label: "PREFIXES"; active: win.gameView === "prefixes"; onClicked: { win.gameView = "prefixes"; pfxProc.running = true; pfxBakProc.running = true; } }
                    Chip { label: "FX";      active: win.gameView === "fx";      onClicked: win.openFx() }
                    Chip { label: "HEALTH";  active: win.gameView === "health";  onClicked: { win.gameView = "health"; healthProc.running = true; } }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignRight
                        text: win.gameStatus; color: pal.dim; font.family: win.mono
                        font.pixelSize: 12; font.letterSpacing: 2; elide: Text.ElideLeft
                    }
                }

                // ---- LIBRARY ----
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.minimumHeight: 110
                    visible: win.gameView === "library"
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.games.length === 0
                        title: gamesProc.running ? "READING YOUR LIBRARY…" : "NO GAMES FOUND"
                        sub: gamesProc.running ? "" : "installed Steam games and Umbral games show up here"
                    }

                    ListView {
                        id: gameList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 2
                        model: win.games
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: gameList.width - 8; height: 34; radius: 6
                            color: win.selGame === modelData.key ? pal.cardHi : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                Badge { label: modelData.source; tint: modelData.source === "umbral" ? pal.pink : pal.sky; width: 58 }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 12
                                }
                                Text {
                                    visible: modelData.new === true
                                    text: "NEW"; color: pal.amber
                                    font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                                }
                                Text {
                                    visible: (win.tips[modelData.id] || 0) > 0
                                    text: "★ " + win.tips[modelData.id]; color: pal.amber
                                    font.family: win.mono; font.pixelSize: 9
                                }
                                Text {
                                    property var r: win.fxScanByKey[modelData.key]
                                    visible: !!r && !!r.sfx && r.sfx.count > 0 && !r.current && r.eligible
                                    text: "FX " + (r && r.sfx ? r.sfx.count : ""); color: pal.pink
                                    font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                                    Tip { visible: fxBadgeMa.containsMouse; text: "ReShade presets for this game on SweetFX DB — see GAMING → FX" }
                                    MouseArea { id: fxBadgeMa; anchors.fill: parent; hoverEnabled: true }
                                }
                                Text {
                                    visible: modelData.wrapped
                                    text: "◆ DECK"; color: pal.accent
                                    font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                                }
                                Text {
                                    Layout.preferredWidth: 70; horizontalAlignment: Text.AlignRight
                                    text: (win.pdb[modelData.id] || {}).tier ? String(win.pdb[modelData.id].tier).toUpperCase() : ""
                                    color: win.tierColor((win.pdb[modelData.id] || {}).tier)
                                    font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                                }
                                Text {
                                    Layout.preferredWidth: 56; horizontalAlignment: Text.AlignRight
                                    text: win.human(modelData.size); color: pal.dim
                                    font.family: win.mono; font.pixelSize: 9
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: win.selectGame(modelData)
                            }
                        }
                    }
                }

                // profile editor of the selected game
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 10
                    visible: win.gameView === "library" && win.selGame !== ""

                    // header: game + ProtonDB verdict
                    RowLayout {
                        Layout.fillWidth: true; spacing: 9
                        Rectangle { width: 7; height: 7; color: pal.accent; Layout.alignment: Qt.AlignVCenter }
                        Text {
                            text: win.selGameSource === "steam" ? "PROFILE" : "GAME"
                            color: pal.text; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 4; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: win.selGameName + (win.selGameSource === "steam" && !win.gp.custom ? "  · default profile" : "")
                            color: pal.dim; font.family: win.mono; font.pixelSize: 11
                        }
                        Text {
                            id: pdbTxt
                            visible: win.selGameSource === "steam" && !!(win.pdb[win.selGameId] || {}).total
                            property var d: win.pdb[win.selGameId] || {}
                            text: String(d.tier || "").toUpperCase() + " · " + d.total + " reports ↗"
                            color: win.tierColor(d.tier); font.family: win.mono; font.pixelSize: 10; font.bold: true
                            font.underline: pdbMa.containsMouse
                            MouseArea {
                                id: pdbMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: Qt.openUrlExternally("https://www.protondb.com/app/" + win.selGameId)
                            }
                            Tip { visible: pdbMa.containsMouse; text: "ProtonDB: score " + pdbTxt.d.score + " · trending " + pdbTxt.d.trendingTier
                                          + " · confidence " + pdbTxt.d.confidence + ". Click to open." }
                        }
                    }

                    // Umbral games: info only; their options live in Umbral
                    Rectangle {
                        Layout.fillWidth: true
                        visible: win.selGameSource === "umbral"
                        implicitHeight: umbCol.implicitHeight + 20
                        radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                        ColumnLayout {
                            id: umbCol
                            anchors.fill: parent; anchors.margins: 10; spacing: 4
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: pal.text; font.family: win.mono; font.pixelSize: 11
                                text: (win.selGameObj.umbralKind === "battlenet" ? "Battle.net client"
                                       : (win.selGameObj.umbralKind === "blizzard" ? "Battle.net game" : "Own game"))
                                      + "  ·  " + (win.selGameObj.prefixName || "?") + " prefix (" + (win.selGameObj.compat || "?") + ")"
                                      + "  ·  " + win.playtimeText(win.selGameObj.playtime)
                                      + (win.selGameObj.lastPlayed ? "  ·  last " + String(win.selGameObj.lastPlayed).substring(0, 10) : "")
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideMiddle; visible: !!win.selGameObj.exe
                                color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                text: String(win.selGameObj.exe || "").replace(win.home, "~")
                            }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                text: "Launch options are set in Umbral."
                            }
                        }
                    }

                    // launch settings (Steam)
                    Rectangle {
                        Layout.fillWidth: true
                        visible: win.selGameSource === "steam"
                        implicitHeight: launchGrid.implicitHeight + 20
                        radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                        GridLayout {
                            id: launchGrid
                            anchors.fill: parent; anchors.margins: 10
                            columns: 2; columnSpacing: 12; rowSpacing: 8
                            Text { text: "LAUNCH"; Layout.preferredWidth: 52; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Chip { label: "GAMEMODE"; tint: pal.ok; active: win.gp.gamemode === true; onClicked: win.gpSet("gamemode", !win.gp.gamemode) }
                                Chip { label: "MANGOHUD"; tint: pal.ok; active: win.gp.mangohud === true; onClicked: win.gpSet("mangohud", !win.gp.mangohud) }
                                Chip { label: "FX"; tint: pal.ok; active: win.gp.fx === true; onClicked: win.openFx()
                                       tip: "Visual shaders (vkBasalt): sharpening, anti-aliasing, ReShade presets" }
                                Chip { label: "TEMPS"; tint: pal.ok; active: win.gp.overlay === true; onClicked: win.gpSet("overlay", !win.gp.overlay)
                                       tip: "A CPU · GPU temperature line at the top right while the game runs (click-through, closes with the game)" }
                                Chip { label: "IO PRIORITY"; tint: pal.ok; active: win.gp.ionice === true; onClicked: win.gpSet("ionice", !win.gp.ionice)
                                       tip: "ionice best-effort level 0 for the game" }
                                Item { Layout.fillWidth: true }
                                Text { text: "NICE"; color: pal.dim; font.family: win.mono; font.pixelSize: 9 }
                                Repeater {
                                    model: [0, -5, -10]
                                    delegate: Chip {
                                        required property var modelData
                                        label: String(modelData); active: win.gp.nice === modelData
                                        onClicked: win.gpSet("nice", modelData)
                                    }
                                }
                            }
                            Text { text: "ENV"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                            Field { id: gEnv; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: "VAR=value VAR2=value" }
                            Text { text: "PREFIX"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Field { id: gPrefix; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: "before the game, e.g. gamescope -f --" }
                                Text { text: "ARGS"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                Field { id: gArgs; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: "after the game, e.g. -novid" }
                            }
                            Text { text: "PROTON"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                   Layout.alignment: Qt.AlignTop; Layout.topMargin: 6 }
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                Chip {
                                    label: "STEAM DEFAULT"; active: win.selGameCompat === ""
                                    on: !win.gameBusy; tip: "Steam must be closed to change it"
                                    onClicked: win.runGame(["steamcompat", win.selGameId, "default"], "SETTING PROTON…")
                                }
                                Repeater {
                                    model: win.tools
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.display; active: win.selGameCompat === modelData.name
                                        on: !win.gameBusy; tip: "Steam must be closed to change it"
                                        onClicked: win.runGame(["steamcompat", win.selGameId, modelData.name], "SETTING PROTON…")
                                    }
                                }
                            }
                        }
                    }

                    // suggestions from players with hardware like this PC (Steam)
                    Rectangle {
                        Layout.fillWidth: true
                        visible: win.selGameSource === "steam"
                        implicitHeight: sugCol.implicitHeight + 20
                        radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                        ColumnLayout {
                            id: sugCol
                            anchors.fill: parent; anchors.margins: 10; spacing: 8
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text { text: "★ SUGGESTED FOR THIS PC"; color: pal.amber; font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    text: !win.sug.index || !win.sug.reports ? "" :
                                          (win.sug.gpuName || "") + " · " + (win.sug.similarReports > 0 ? win.sug.similarReports + " similar players"
                                          : (win.sug.vendorReports > 0 ? win.sug.vendorReports + " " + String(win.sug.vendor).toUpperCase() + " players" : win.sug.reports + " players"))
                                }
                                Chip {
                                    visible: win.sugOthers.length > 0
                                    label: win.sugExpanded ? "LESS ▴" : "+" + win.sugOthers.length + " MORE ▾"
                                    onClicked: win.sugExpanded = !win.sugExpanded
                                }
                                Chip {
                                    visible: win.pdbStat.present !== true || win.pdbStat.stale === true
                                    label: win.pdbStat.present === true ? "UPDATE DATA" : "GET DATA (70 MB)"
                                    on: !win.gameBusy; tint: pal.amber; active: true
                                    tip: "ProtonDB's open data (every game's reported launch options), indexed locally to ≈5 MB"
                                    onClicked: win.runGame(["pdbindex", "update"], "INDEXING PROTONDB DATA…")
                                }
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                visible: win.sugRecommended.length > 0
                                Repeater {
                                    model: win.sugRecommended
                                    delegate: Chip {
                                        required property var modelData
                                        property bool applied: win.sugApplied(modelData)
                                        label: win.sugLabel(modelData, applied, "★ ")
                                        tint: pal.amber; active: true; opacity: applied ? 0.55 : 1.0
                                        tip: win.sugTip(modelData, applied)
                                        onClicked: win.applySug(modelData)
                                    }
                                }
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                visible: win.sugExpanded && win.sugOthers.length > 0
                                Repeater {
                                    model: win.sugOthers
                                    delegate: Chip {
                                        required property var modelData
                                        property bool applied: win.sugApplied(modelData)
                                        label: win.sugLabel(modelData, applied, "+ ")
                                        tint: pal.ok; active: applied
                                        tip: win.sugTip(modelData, applied)
                                        onClicked: win.applySug(modelData)
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                text: win.pdbStat.present !== true ? "Get the data once to see what players with hardware like yours use."
                                      : (!win.sug.index ? "" : (win.sug.reports === 0 ? "No ProtonDB report with launch options for this game yet."
                                         : (win.sugRecommended.length + win.sugOthers.length === 0 ? "Players don't agree on any launch option for this game."
                                            : (win.sugRecommended.length === 0 ? "Nothing is used by enough similar players to recommend it. " : "")
                                              + "Click to add, then SAVE · % of players who say it works · ProtonDB (ODbL) " + win.pdbStat.date)))
                            }
                        }
                    }

                    // status + actions
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            font.family: win.mono; font.pixelSize: 10
                            color: win.selGameSource === "steam" && win.selGameWrapped ? pal.ok : pal.dim
                            text: win.selGameSource !== "steam" ? ""
                                  : (win.selGameWrapped ? "● Launched through Control Deck"
                                     : "○ Steam options: " + (win.selGameLaunch || "none"))
                            Tip { visible: stMa.containsMouse && parent.text !== ""; text: win.selGameWrapped ? "The profile applies on every launch from Steam."
                                          : "USE IN STEAM moves these options into the profile (Steam must be closed)." }
                            MouseArea { id: stMa; anchors.fill: parent; hoverEnabled: true }
                        }
                        MiniBtn {
                            width: 70; height: 32; primary: false; label: "RESET"
                            visible: win.selGameSource === "steam" && win.gp.custom === true
                            on: !win.gameBusy
                            onClicked: win.runGame(["gprofile", "reset", win.selGame], "RESETTING…")
                        }
                        MiniBtn {
                            width: 120; height: 32; primary: false
                            visible: win.selGameSource === "steam"
                            label: win.selGameWrapped ? "RESTORE STEAM" : "USE IN STEAM"
                            on: !win.gameBusy
                            onClicked: win.runGame(["steamwrap", win.selGameId, win.selGameWrapped ? "off" : "on"],
                                                   win.selGameWrapped ? "RESTORING…" : "WRAPPING…")
                        }
                        MiniBtn {
                            width: 76; height: 32; label: "SAVE"
                            visible: win.selGameSource === "steam"
                            on: !win.gameBusy
                            onClicked: win.saveGameProfile()
                        }
                        MiniBtn {
                            width: 76; height: 32; label: "▶ PLAY"; tint: pal.ok
                            on: !win.gameBusy
                            onClicked: win.playGame()
                        }
                    }
                }

                // ---- PREFIXES ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "prefixes"
                    spacing: 8

                    Hint {
                        text: !win.pfx.prefixes ? "" : win.pfx.prefixes.length + " prefixes · " + win.human(win.pfx.total)
                              + ((win.pfx.orphanBytes || 0) > 0 ? " · " + win.human(win.pfx.orphanBytes) + " in orphans (games no longer installed)" : "")
                              + " · " + win.pfxBackups.length + " backups in ~/control-deck-backups/prefixes"
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.pfx.prefixes || win.pfx.prefixes.length === 0
                            title: pfxProc.running ? "LOOKING FOR PREFIXES…" : "NO WINE/PROTON PREFIXES FOUND"
                        }
                        ListView {
                            id: pfxList
                            anchors.fill: parent; anchors.margins: 4
                            clip: true; spacing: 3
                            model: win.pfx.prefixes || []
                            ScrollBar.vertical: ScrollBar {}
                            delegate: Rectangle {
                                required property var modelData
                                width: pfxList.width - 8; height: 52; radius: 8
                                color: pal.card; border.width: 1
                                border.color: modelData.orphan ? pal.amber : (modelData.running ? pal.ok : pal.border)
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 2
                                        RowLayout {
                                            spacing: 8
                                            Text { text: modelData.owner.toUpperCase(); color: win.srcColor(modelData.owner === "steam" ? "flatpak" : "aur")
                                                   font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1 }
                                            Text { text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true
                                                   elide: Text.ElideRight; Layout.maximumWidth: 300 }
                                            Text { text: win.human(modelData.size); color: pal.amber; font.family: win.mono; font.pixelSize: 10 }
                                            Text { visible: modelData.orphan; text: "ORPHAN"; color: pal.amber; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.running; text: "IN USE"; color: pal.ok; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.kind === "tool" || modelData.kind === "shared"; text: modelData.kind.toUpperCase()
                                                   color: pal.dim; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideMiddle
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: (modelData.version || "?") + "  ·  " + modelData.arch + "  ·  used " + win.dateOfEpoch(modelData.lastUsed)
                                                  + "  ·  " + modelData.path.replace(win.home, "~")
                                        }
                                    }
                                    MiniBtn { width: 64; label: "BACKUP"; primary: false; on: !win.gameBusy && !modelData.running
                                              onClicked: win.runGame(["prefix", "backup", modelData.path], "BACKING UP…") }
                                    MiniBtn { width: 60; label: "CLONE"; primary: false; on: !win.gameBusy && !modelData.running
                                              onClicked: win.runGame(["prefix", "clone", modelData.path], "CLONING…") }
                                    MiniBtn {
                                        width: 80; tint: pal.bad
                                        property string key: "pfx:" + modelData.path
                                        label: win.confirmShader === key ? "CONFIRM?" : "DELETE"
                                        on: !win.gameBusy && !modelData.running && modelData.kind !== "tool" && modelData.kind !== "shared"
                                        onClicked: win.shaderAction(["prefix", "delete", modelData.path], key, "BACKING UP + DELETING…")
                                    }
                                }
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Hint {
                            text: "DELETE always makes a backup first (a Steam game's prefix is recreated on its next launch — saves kept only in the prefix would be lost without it). CLONE copies the Wine prefix to ~/Games/prefixes (instant on Btrfs). Restore a backup: control-deck prefix restore <backup> <folder>."
                        }
                        MiniBtn { width: 100; label: "BACKUPS ↗"; primary: false; onClicked: pfxOpenProc.running = true }
                    }
                }

                // ---- BENCH (A/B) ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "bench"
                    spacing: 8

                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: win.selGame === "" || win.selGameSource !== "steam"
                        EmptyHint { title: win.selGame === "" ? "PICK A GAME IN LIBRARY FIRST" : "A/B BENCHMARKS ARE FOR STEAM GAMES" }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 8
                        visible: win.selGame !== "" && win.selGameSource === "steam"

                        Section { Layout.fillWidth: true; label: "A / B"; info: win.selGameName }

                        // the two variants side by side
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            BenchVariant { id: benchA; v: "A"; tint: pal.accent }
                            BenchVariant { id: benchB; v: "B"; tint: pal.pink }
                        }

                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            Text { text: "MEASURE"; color: pal.dim; font.family: win.mono; font.pixelSize: 9 }
                            Repeater {
                                model: [30, 60, 120, 300]
                                delegate: Chip { required property int modelData; label: modelData + " s"; active: win.bench.duration === modelData
                                                 onClicked: win.saveBench(["duration=" + modelData]) }
                            }
                            Text { text: "AFTER"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; Layout.leftMargin: 8 }
                            Repeater {
                                model: [5, 15, 30, 60]
                                delegate: Chip { required property int modelData; label: modelData + " s"; active: win.bench.delay === modelData
                                                 onClicked: win.saveBench(["delay=" + modelData]) }
                            }
                            Item { Layout.fillWidth: true }
                            MiniBtn { width: 70; label: "SAVE"; on: !win.gameBusy; onClicked: win.saveBench([]) }
                            MiniBtn { width: 70; label: "RUN A"; tint: pal.accent; on: !win.gameBusy && win.selGameWrapped
                                      onClicked: win.runBench("A") }
                            MiniBtn { width: 70; label: "RUN B"; tint: pal.pink; on: !win.gameBusy && win.selGameWrapped
                                      onClicked: win.runBench("B") }
                        }
                        Hint {
                            text: !win.selGameWrapped ? "The game must launch through Control Deck: LIBRARY → USE IN STEAM first."
                                  : "RUN starts the game from Steam; MangoHud records every frame after the delay, for the measured time. Play the same scene in both runs, quit the game, then REFRESH. Variants changing Proton need Steam closed."
                                    + (win.bench.originalProton ? "  Proton was changed for a run: RESTORE PROTON when done." : "")
                        }

                        // results
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 150
                            radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                            EmptyHint {
                                visible: !win.bench.results || (!win.bench.results.A && !win.bench.results.B)
                                title: "NO RUNS YET"
                            }
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 10; spacing: 12
                                visible: !!win.bench.results && (!!win.bench.results.A || !!win.bench.results.B)
                                GridLayout {
                                    columns: 4; rowSpacing: 4; columnSpacing: 12
                                    Layout.alignment: Qt.AlignTop
                                    Repeater {
                                        model: [["", "A", "B", "Δ B vs A"],
                                                ["Avg FPS", "avgFps", "avgFps", "avgFps"], ["1% low", "low1", "low1", "low1"],
                                                ["0.1% low", "low01", "low01", ""], ["p99 frame ms", "p99ms", "p99ms", "p99ms"],
                                                ["Spikes", "spikes", "spikes", ""], ["CPU load %", "cpuLoad", "cpuLoad", ""],
                                                ["GPU load %", "gpuLoad", "gpuLoad", ""], ["GPU max °C", "gpuTempMax", "gpuTempMax", ""],
                                                ["Frames", "frames", "frames", ""]]
                                        delegate: Item {
                                            required property var modelData
                                            required property int index
                                            Layout.columnSpan: 4; Layout.fillWidth: true; implicitHeight: 16
                                            RowLayout {
                                                anchors.fill: parent; spacing: 12
                                                property var ra: (win.bench.results || {}).A
                                                property var rb: (win.bench.results || {}).B
                                                Text { Layout.preferredWidth: 96; text: modelData[0]; color: pal.dim; font.family: win.mono; font.pixelSize: 10 }
                                                Text { Layout.preferredWidth: 60; color: index === 0 ? pal.accent : pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: index === 0
                                                       text: index === 0 ? ((win.bench.A || {}).label || "A") : (parent.ra ? String(parent.ra[modelData[1]]) : "—") }
                                                Text { Layout.preferredWidth: 60; color: index === 0 ? pal.pink : pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: index === 0
                                                       text: index === 0 ? ((win.bench.B || {}).label || "B") : (parent.rb ? String(parent.rb[modelData[2]]) : "—") }
                                                Text {
                                                    Layout.preferredWidth: 70; font.family: win.mono; font.pixelSize: 10
                                                    property var d: index === 0 || modelData[3] === "" || !win.bench.compare ? undefined : win.bench.compare[modelData[3]]
                                                    // higher FPS is better; lower frametime is better
                                                    color: index === 0 ? pal.dim : (d === undefined ? pal.dim
                                                           : ((modelData[3] === "p99ms" ? -d : d) >= 0 ? pal.ok : pal.bad))
                                                    text: index === 0 ? modelData[3] : (d === undefined ? "" : win.pct(d))
                                                }
                                            }
                                        }
                                    }
                                }
                                // frametime curves (worst frame per bucket)
                                Canvas {
                                    id: benchChart
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    onWidthChanged: requestPaint()
                                    onHeightChanged: requestPaint()
                                    onPaint: {
                                        var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
                                        var r = win.bench.results || {}, a = r.A ? r.A.series : [], b = r.B ? r.B.series : [];
                                        var p99 = Math.max(r.A ? r.A.p99ms : 0, r.B ? r.B.p99ms : 0);
                                        var ymax = Math.max(p99 * 1.6, 5);
                                        ctx.strokeStyle = "#2a2740"; ctx.lineWidth = 1;
                                        [16.7, 33.3].forEach(function (ms) {
                                            if (ms > ymax) return;
                                            var y = height - ms / ymax * height;
                                            ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke();
                                            ctx.fillStyle = "#6a6580"; ctx.font = "9px monospace"; ctx.fillText(ms + " ms", 2, y - 2);
                                        });
                                        function line(sr, col) {
                                            if (!sr || sr.length < 2) return;
                                            ctx.strokeStyle = col; ctx.lineWidth = 1.2; ctx.beginPath();
                                            for (var i = 0; i < sr.length; i++) {
                                                var x = i / (sr.length - 1) * width, y = height - Math.min(sr[i], ymax) / ymax * height;
                                                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                                            }
                                            ctx.stroke();
                                        }
                                        line(a, "#b9a3e3"); line(b, "#d9a7d0");
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Item { Layout.fillWidth: true }
                            MiniBtn { width: 110; label: "REFRESH RESULTS"; primary: false; on: !win.gameBusy; onClicked: benchProc.running = true }
                            MiniBtn { width: 110; label: "RESTORE PROTON"; primary: false; visible: !!win.bench.originalProton; on: !win.gameBusy
                                      onClicked: win.runGame(["bench", "restore", win.selGame], "RESTORING…") }
                            MiniBtn { width: 70; label: "CLEAR"; tint: pal.bad; primary: false; on: !win.gameBusy
                                      onClicked: win.runGame(["bench", "clear", win.selGame], "CLEARING…") }
                        }
                    }
                }

                // ---- FX (visual shaders) ----
                // FX: this game / my whole library (fixed above the scrolling part)
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: win.gameView === "fx"
                    Chip { label: "THIS GAME"; active: win.fxScope === "game"; onClicked: win.fxScope = "game" }
                    Chip {
                        label: "MY LIBRARY" + (win.fxEligible > 0 ? "  ·  " + win.fxEligible + " to set up" : "")
                        active: win.fxScope === "library"
                        onClicked: { win.fxScope = "library"; if (win.fxScan.length === 0 && !fxScanProc.running) { fxScanProc.cached = false; fxScanProc.running = true; } }
                    }
                    Item { Layout.fillWidth: true }
                }

                ScrollView {
                    id: fxScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "fx"
                    contentWidth: availableWidth
                    clip: true
                    ColumnLayout {
                        width: fxScroll.availableWidth
                        spacing: 8

                        ColumnLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: win.fxScope === "game"

                            EmptyHint {
                                Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 40; anchors.centerIn: undefined
                                visible: win.selGameSource !== "steam"
                                title: "PICK A STEAM GAME IN LIBRARY"
                            }

                            // header: game · GPU · vkBasalt
                            RowLayout {
                                Layout.fillWidth: true; spacing: 9
                                visible: win.selGameSource === "steam"
                                Rectangle { width: 7; height: 7; color: pal.accent; Layout.alignment: Qt.AlignVCenter }
                                Text { text: "VISUAL SHADERS"; color: pal.text; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 4; font.bold: true }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: win.selGameName; color: pal.dim; font.family: win.mono; font.pixelSize: 11 }
                                Text {
                                    text: (win.fx.gpu || "") + "  ·  " + (win.fxReshade
                                          ? (win.fx.reshade && win.fx.reshade.version ? "ReShade " + win.fx.reshade.version : "ReShade not installed")
                                          : (win.fx.vkbasalt ? "vkBasalt " + win.fx.version : "vkBasalt not installed"))
                                    color: (win.fxReshade ? (win.fx.reshade || {}).ready : win.fx.vkbasalt) ? pal.dim : pal.amber
                                    font.family: win.mono; font.pixelSize: 10
                                }
                            }

                            // guided steps (live state of this game)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && !!win.fx.gpu
                                implicitHeight: guideCol.implicitHeight + 16
                                radius: 8; color: pal.card; border.width: 1
                                border.color: win.fxStepsDone === 5 ? pal.ok : pal.accent
                                ColumnLayout {
                                    id: guideCol
                                    anchors.fill: parent; anchors.margins: 8; spacing: 5
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Text { text: "STEPS"; color: pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2 }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.family: win.mono; font.pixelSize: 10
                                            color: win.fxStepsDone === 5 ? pal.ok : pal.dim
                                            text: win.fxStepsDone === 5 ? "✓ all set — launch the game and press " + (win.fx.key || "Home").toUpperCase()
                                                                        : win.fxStepsDone + " / 5 done"
                                        }
                                        Chip { label: win.fxGuideOpen ? "HIDE ▴" : "SHOW ▾"; onClicked: win.fxGuideOpen = !win.fxGuideOpen }
                                    }
                                    Repeater {
                                        model: win.fxGuideOpen ? win.fxSteps : []
                                        delegate: RowLayout {
                                            required property var modelData
                                            required property int index
                                            Layout.fillWidth: true; spacing: 8
                                            property bool next: !modelData[0] && win.fxSteps.slice(0, index).every(function (s) { return s[0]; })
                                            Text {
                                                text: modelData[0] ? "✓" : String(index + 1)
                                                Layout.preferredWidth: 14; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignTop
                                                color: modelData[0] ? pal.ok : (next ? pal.amber : pal.dim)
                                                font.family: win.mono; font.pixelSize: 11; font.bold: true
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 1
                                                Text {
                                                    text: modelData[1]; font.family: win.mono; font.pixelSize: 11; font.bold: next
                                                    color: modelData[0] ? pal.dim : (next ? pal.text : pal.dim)
                                                }
                                                Text {
                                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                    text: modelData[2]; color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                                }
                                            }
                                            // the pending step's own button
                                            MiniBtn {
                                                visible: next && index === 0
                                                width: 130; height: 28; label: "USE RESHADE ★"; on: !win.gameBusy
                                                onClicked: win.fxApply("mode:reshade", "SETTING UP RESHADE…", ["fx", "mode", win.selGame, "reshade"])
                                            }
                                            MiniBtn {
                                                visible: next && index === 1
                                                width: 90; height: 28; label: "INSTALL"; on: !win.gameBusy
                                                onClicked: win.runGame(win.fxReshade ? ["fx", "reshade", "install"] : ["fx", "install"], "INSTALLING…")
                                            }
                                            MiniBtn {
                                                visible: next && index === 2
                                                width: 120; height: 28; label: "USE IN STEAM"
                                                on: !win.gameBusy && !win.fx.steamRunning
                                                onClicked: win.runGame(["steamwrap", win.selGameId, "on"], "WRAPPING…")
                                            }
                                            Chip {
                                                visible: next && index === 3
                                                label: "SEARCH NEXUS ↗"
                                                onClicked: Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent("site:nexusmods.com " + win.selGameName + " reshade preset"))
                                            }
                                        }
                                    }
                                }
                            }

                            // route: ReShade (DLL) or vkBasalt (Vulkan layer)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && !!win.fx.gpu
                                implicitHeight: fxRoute.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    id: fxRoute
                                    anchors.fill: parent; anchors.margins: 10; spacing: 6
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: "ROUTE"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Chip {
                                            property string k: "mode:reshade"
                                            label: win.fxConfirm === k ? "CONFIRM?" : "RESHADE" + (win.fx.recommended === "reshade" ? "  ★" : "")
                                            tint: pal.ok; active: win.fxReshade
                                            on: !win.gameBusy
                                            tip: "ReShade itself: presets exactly as made (depth effects too) and its in-game menu. For D3D9–12 and OpenGL games."
                                            onClicked: if (!win.fxReshade) win.fxApply(k, "SETTING UP RESHADE…", ["fx", "mode", win.selGame, "reshade"])
                                        }
                                        Chip {
                                            property string k: "mode:vkbasalt"
                                            label: win.fxConfirm === k ? "CONFIRM?" : "VKBASALT" + (win.fx.recommended === "vkbasalt" ? "  ★" : "")
                                            tint: pal.ok; active: !win.fxReshade
                                            on: !win.gameBusy
                                            tip: "A Vulkan layer: simplest, no files in the game folder; presets are converted and effects that need depth are skipped."
                                            onClicked: if (win.fxReshade) win.fxApply(k, "SWITCHING…", ["fx", "mode", win.selGame, "vkbasalt"])
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: "★ recommended: " + (win.fx.recommended === "vkbasalt"
                                                  ? "this game renders with Vulkan, ReShade's DLL can't hook it"
                                                  : "full presets (depth effects included) and ReShade's in-game menu")
                                        }
                                    }
                                    // ReShade: which .exe, which API
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxReshade
                                        Text { text: "EXECUTABLE"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Flow {
                                            Layout.fillWidth: true; spacing: 6
                                            Repeater {
                                                model: (win.fx.reshade || {}).exes || []
                                                delegate: Chip {
                                                    required property var modelData
                                                    label: modelData.rel + "  ·  " + modelData.arch + "-bit"
                                                    active: !!win.fxRsGame && win.fxRsGame.exe === modelData.path
                                                    on: !win.gameBusy
                                                    tip: "Install ReShade next to this .exe (detected API: " + modelData.api + ")"
                                                    onClicked: win.runGame(["fx", "mode", win.selGame, "reshade", modelData.path], "MOVING RESHADE…")
                                                }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxReshade && !!win.fxRsGame
                                        Text { text: "HOOKS"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["dxgi", "DXGI · DX10–12"], ["d3d9", "D3D9"], ["opengl32", "OPENGL"]]
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData[1]; active: !!win.fxRsGame && win.fxRsGame.api === modelData[0]
                                                on: !win.gameBusy
                                                tip: "Only change it if ReShade doesn't show up in game"
                                                onClicked: win.runGame(["fx", "mode", win.selGame, "reshade", win.fxRsGame.exe, modelData[0]], "SWITCHING API…")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: "✓ " + (win.fxRsGame ? win.fxRsGame.api : "") + ".dll + d3dcompiler_47 linked in the game folder · OFF removes them"
                                        }
                                    }
                                    // the in-game key (ReShade's menu / vkBasalt on-off), one for all games
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: "MENU KEY"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["Home", "HOME", ""], ["Insert", "INSERT", ""], ["F10", "F10", ""], ["F11", "F11", ""],
                                                    ["F12", "F12", "Steam takes screenshots with F12 by default"]]
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData[1]; active: (win.fx.key || "Home") === modelData[0]
                                                on: !win.gameBusy; tip: modelData[2]
                                                onClicked: win.runGame(["fx", "key", modelData[0]], "SETTING KEY…")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: win.fxReshade ? "opens ReShade's menu in game" : "turns the effects on/off in game"
                                        }
                                    }
                                    // must launch through the wrapper
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        visible: win.fx.wrapped === false && (win.fxReshade || win.fxActive)
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            color: pal.amber; font.family: win.mono; font.pixelSize: 10
                                            text: "⚠ This game doesn't launch through Control Deck yet, so the shaders won't load. " + (win.fx.steamRunning ? "Close Steam, then press USE IN STEAM." : "Press USE IN STEAM.")
                                        }
                                        MiniBtn {
                                            width: 120; height: 28; label: "USE IN STEAM"
                                            on: !win.gameBusy && !win.fx.steamRunning
                                            onClicked: win.runGame(["steamwrap", win.selGameId, "on"], "WRAPPING…")
                                        }
                                    }
                                }
                            }

                            // one-time setup (ReShade: no password, all user files)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && win.fxReshade && !!win.fx.reshade && (!win.fx.reshade.ready || win.fx.reshade.update)
                                implicitHeight: fxRsSetup.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.accent; border.width: 1
                                RowLayout {
                                    id: fxRsSetup
                                    anchors.fill: parent; anchors.margins: 10; spacing: 10
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        color: pal.text; font.family: win.mono; font.pixelSize: 11
                                        text: win.fx.reshade && win.fx.reshade.update
                                              ? "ReShade " + win.fx.reshade.latest + " is out (you have " + win.fx.reshade.version + "). Games pick it up on their next launch."
                                              : "One-time setup, no password: ReShade " + ((win.fx.reshade || {}).latest || "") + " from reshade.me, d3dcompiler_47 (Mozilla's Firefox installer, checksum-verified, like winetricks) and the standard shaders."
                                    }
                                    MiniBtn {
                                        width: 96; height: 32; label: win.fx.reshade && win.fx.reshade.update ? "UPDATE" : "INSTALL"
                                        on: !win.gameBusy
                                        onClicked: win.runGame(["fx", "reshade", "install"], "DOWNLOADING RESHADE…")
                                    }
                                }
                            }

                            // one-time setup
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && !win.fxReshade && !!win.fx.gpu && (!win.fx.vkbasalt || !win.fx.vkbasalt32 || !win.fx.shadersInstalled)
                                implicitHeight: fxSetup.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.accent; border.width: 1
                                RowLayout {
                                    id: fxSetup
                                    anchors.fill: parent; anchors.margins: 10; spacing: 10
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        color: pal.text; font.family: win.mono; font.pixelSize: 11
                                        text: win.fx.chaotic === false && !win.fx.vkbasalt
                                              ? "vkBasalt comes from chaotic-aur, which isn't enabled here. Enable it (or build vkbasalt + lib32-vkbasalt from the AUR), then come back."
                                              : "One-time setup: vkBasalt (the Vulkan layer that draws the effects, 64 + 32-bit, from chaotic-aur) and the standard ReShade shaders (official packages, ~0.5 MB). Works the same on AMD and NVIDIA."
                                    }
                                    MiniBtn {
                                        visible: win.fx.chaotic !== false || win.fx.vkbasalt
                                        width: 96; height: 32; label: "INSTALL"
                                        on: !win.gameBusy
                                        onClicked: win.runGame(["fx", "install"], "INSTALLING SHADERS…")
                                    }
                                }
                            }

                            // online / anti-cheat warning
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && !!win.fx.online && win.fx.online.level !== "none"
                                implicitHeight: fxWarn.implicitHeight + 16
                                radius: 8; border.width: 1
                                color: win.fxAnticheat ? "#1f0d14" : "#1a150c"
                                border.color: win.fxAnticheat ? pal.bad : pal.amber
                                Text {
                                    id: fxWarn
                                    anchors.fill: parent; anchors.margins: 8
                                    wrapMode: Text.WordWrap; font.family: win.mono; font.pixelSize: 10
                                    color: win.fxAnticheat ? pal.bad : pal.amber
                                    text: win.fxAnticheat
                                          ? "⚠ ONLINE GAME WITH ANTI-CHEAT (" + win.fx.online.anticheats.join(", ") + "). Shaders hook into the game's rendering; an anti-cheat may treat that as a modification and ban the account. Use them only if you accept that risk — applying one here asks for confirmation."
                                          : "⚠ Online multiplayer game: some online games forbid visual mods in their rules. Check before using shaders there."
                                }
                            }

                            // route + what's active
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.selGameSource === "steam" && !!win.fx.route
                                implicitHeight: fxCur.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    id: fxCur
                                    anchors.fill: parent; anchors.margins: 10; spacing: 6
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        font.family: win.mono; font.pixelSize: 10
                                        visible: !win.fxReshade
                                        color: (win.fx.route || {}).ok ? pal.dim : pal.bad
                                        text: ((win.fx.route || {}).ok ? "✓ " : "✗ ") + ((win.fx.route || {}).reason || "")
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.family: win.mono; font.pixelSize: 11; font.bold: true
                                            color: win.fxActive ? pal.ok : pal.dim
                                            text: win.fxActive
                                                  ? "● ACTIVE: " + win.fx.current.name + "  ·  " + win.fx.current.applied + " effect" + (win.fx.current.applied > 1 ? "s" : "")
                                                    + ((win.fx.current.skipped || []).length ? "  ·  " + win.fx.current.skipped.length + " skipped" : "")
                                                  : "○ No shaders on this game"
                                        }
                                        Chip {
                                            visible: win.fxActive && win.fx.current.source === "sfx"
                                            label: "PRESET ↗"; onClicked: Qt.openUrlExternally(win.fx.current.url)
                                        }
                                        MiniBtn {
                                            visible: win.fxActive
                                            width: 60; height: 28; primary: false; label: "OFF"
                                            on: !win.gameBusy
                                            onClicked: win.runGame(["fx", "set", win.selGame, "off"], "TURNING OFF…")
                                        }
                                    }
                                    Repeater {
                                        model: win.fxActive ? (win.fx.current.skipped || []) : []
                                        delegate: Text {
                                            required property var modelData
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            text: "✗ " + modelData.effect + " — " + modelData.why
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                        }
                                    }
                                    Text {
                                        visible: win.fxActive
                                        text: win.fxReshade ? "In game: " + (win.fx.key || "Home").toUpperCase() + " opens ReShade's menu — tweak values, switch effects on/off; changes are saved to this game's preset."
                                                            : "In game: " + (win.fx.key || "Home").toUpperCase() + " turns the effects on/off to compare."
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    }
                                }
                            }

                            // quick looks (vkBasalt's own effects) + presets from the internet
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 380
                                visible: win.selGameSource === "steam" && !!win.fx.route && (win.fx.route.ok || win.fxReshade)
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: "QUICK LOOK"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["sharpen", "SHARPEN", "AMD FidelityFX CAS: crisper image, almost free"],
                                                    ["sharpen-aa", "SHARPEN + AA", "SMAA anti-aliasing, then CAS sharpening"],
                                                    ["fxaa", "FXAA", "Light anti-aliasing, softer edges"],
                                                    ["clarity", "CLARITY", "Denoised luma sharpening: detail without boosting grain"]]
                                            delegate: Chip {
                                                required property var modelData
                                                property string k: "builtin:" + modelData[0]
                                                label: win.fxConfirm === k ? "CONFIRM?" : modelData[1]
                                                tint: pal.ok; tip: modelData[2]
                                                active: win.fxActive && win.fx.current.source === "builtin" && win.fx.current.name === modelData[0]
                                                on: !win.gameBusy && win.fxReady
                                                onClicked: win.fxApply(k, "APPLYING…")
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: "FROM A FILE"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Chip {
                                            label: fxPickProc.running || fxImpListProc.running ? "OPENING…" : "IMPORT…"
                                            tint: pal.ok; on: !win.gameBusy && win.fxReady && !fxPickProc.running
                                            tip: "A preset you downloaded (Nexus Mods…): zip, 7z, rar or .ini. Its own shaders come along; its ReShade.ini/DLLs are ignored."
                                            onClicked: fxPickProc.running = true
                                        }
                                        Chip {
                                            label: "SEARCH NEXUS ↗"; tip: "Web search for this game's ReShade presets on Nexus Mods"
                                            onClicked: Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent("site:nexusmods.com " + win.selGameName + " reshade preset"))
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: "download it, then IMPORT"
                                        }
                                    }
                                    Flow {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxImportList.length > 1
                                        Repeater {
                                            model: win.fxImportList
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData.path.replace(/^.*\//, "") + "  ·  " + modelData.effects + " fx"
                                                tip: modelData.path; tint: pal.ok
                                                on: !win.gameBusy
                                                onClicked: { var f = win.fxImportFile, pth = modelData.path; win.fxImportList = [];
                                                             win.fxApply("file:" + f, "IMPORTING PRESET…", ["fx", "import", win.selGame, f, pth]); }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: "PRESETS"; Layout.preferredWidth: 80; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Field {
                                            id: fxQuery; Layout.fillWidth: true; font.pixelSize: 11
                                            placeholderText: "game name on SweetFX Settings DB"
                                            onAccepted: win.fxSearch(text)
                                        }
                                        Chip { label: fxSearchProc.running ? "SEARCHING…" : "SEARCH"; on: !fxSearchProc.running; onClicked: win.fxSearch(fxQuery.text) }
                                    }
                                    Flow {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxGames.length > 1
                                        Repeater {
                                            model: win.fxGames
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData.title; active: win.fxGameId === modelData.id
                                                onClicked: win.fxLoadPresets(modelData.id)
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        visible: win.fxMsg !== ""
                                        text: win.fxMsg; color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                    }
                                    ListView {
                                        id: fxList
                                        Layout.fillWidth: true; Layout.fillHeight: true
                                        clip: true; spacing: 3
                                        model: win.fxPresets
                                        ScrollBar.vertical: ScrollBar {}
                                        delegate: Rectangle {
                                            required property var modelData
                                            property string k: "sfx:" + modelData.id
                                            width: fxList.width - 10; height: 34; radius: 6
                                            color: pal.panel; border.width: 1
                                            border.color: win.fxActive && win.fx.current.id === modelData.id ? pal.ok : pal.border
                                            RowLayout {
                                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 6
                                                Text {
                                                    Layout.fillWidth: true; elide: Text.ElideRight
                                                    text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 11
                                                }
                                                Chip { label: "↗"; tip: "Open the preset's page"; onClicked: Qt.openUrlExternally("https://sfx.thelazy.net/games/preset/" + modelData.id + "/") }
                                                Chip {
                                                    label: win.fxConfirm === k ? "CONFIRM?" : (win.fxActive && win.fx.current.id === modelData.id ? "ACTIVE ✓" : "APPLY")
                                                    tint: pal.ok; on: !win.gameBusy && win.fxReady
                                                    tip: !win.fxReady ? "Run INSTALL above first"
                                                         : (win.fxReshade ? "Download it and fetch the shaders it needs; ReShade runs it as it is" : "Download, fetch the shaders it needs and convert it for vkBasalt")
                                                    onClicked: win.fxApply(k, "APPLYING PRESET…")
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        text: "Presets: SweetFX Settings DB (sfx.thelazy.net), made for ReShade" + (win.fxReshade ? "" : " — in vkBasalt, effects that need the depth buffer are skipped") + ". Shaders: the packages the official ReShade installer lists."
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    }
                                }
                            }
                        }

                        // ---- MY LIBRARY: best preset + known settings for every game ----
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 8
                            visible: win.fxScope === "library"
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                    text: "Every Steam game: the most downloaded ReShade preset on SweetFX Settings DB, the ReShade compatibility list (PCGamingWiki, which reshade.me links) and online/anti-cheat risk. SET UP installs ReShade with that preset — or SHARPEN + AA when there's none — and the depth settings the list gives. Anti-cheat games and games where ReShade is banned are never touched."
                                }
                                Chip { label: fxScanProc.running ? "SCANNING…" : "SCAN"; on: !fxScanProc.running; onClicked: { fxScanProc.cached = false; fxScanProc.running = true; } }
                                MiniBtn {
                                    width: 150; height: 32; label: "SET UP ALL (" + win.fxEligible + ")"
                                    on: !win.gameBusy && win.fxEligible > 0
                                    onClicked: win.runGame(["fx", "autoinstall"].concat(win.fxScan.filter(function (r) { return r.eligible && !r.current; }).map(function (r) { return r.key; })), "SETTING UP " + win.fxEligible + " GAME(S)…")
                                }
                            }
                            Repeater {
                                model: win.fxScan
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    implicitHeight: libCol.implicitHeight + 16
                                    radius: 8; color: pal.card; border.width: 1
                                    border.color: modelData.blocked || (modelData.online && modelData.online.level === "anticheat") ? pal.bad
                                                  : (modelData.current ? pal.ok : pal.border)
                                    ColumnLayout {
                                        id: libCol
                                        anchors.fill: parent; anchors.margins: 8; spacing: 4
                                        RowLayout {
                                            Layout.fillWidth: true; spacing: 8
                                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true }
                                            Text {
                                                visible: !!modelData.current
                                                text: modelData.current ? "● " + (modelData.current.mode === "reshade" ? "ReShade" : "vkBasalt") + " · " + modelData.current.name : ""
                                                color: pal.ok; font.family: win.mono; font.pixelSize: 10; elide: Text.ElideRight; Layout.maximumWidth: 260
                                            }
                                            MiniBtn {
                                                width: 70; height: 28; primary: false; label: "OPEN"
                                                onClicked: {
                                                    var g = win.games.filter(function (x) { return x.key === modelData.key; })[0];
                                                    if (g) { win.selectGame(g); win.fxScope = "game"; win.openFx(); }
                                                }
                                            }
                                            MiniBtn {
                                                width: 80; height: 28; label: "SET UP"
                                                visible: modelData.eligible
                                                on: !win.gameBusy
                                                onClicked: win.runGame(["fx", "autoinstall", modelData.key], "SETTING UP " + modelData.name.toUpperCase() + "…")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.family: win.mono; font.pixelSize: 10
                                            color: modelData.sfx && modelData.sfx.count > 0 ? pal.text : pal.dim
                                            visible: modelData.eligible || (modelData.sfx && modelData.sfx.count > 0)
                                            text: modelData.sfx && modelData.sfx.count > 0
                                                  ? "★ " + modelData.sfx.count + " presets · best: " + modelData.sfx.best.name + " (" + modelData.sfx.best.downloads + " downloads)"
                                                  : "No ReShade presets on SweetFX DB → SET UP uses SHARPEN + AA"
                                        }
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            visible: !!modelData.pcgw
                                            font.family: win.mono; font.pixelSize: 9; color: modelData.blocked ? pal.bad : pal.dim
                                            text: modelData.pcgw ? "PCGamingWiki: " + modelData.pcgw.status + " · " + modelData.pcgw.api
                                                  + (modelData.defines.length ? " · depth: " + modelData.defines.join(", ") + " (set automatically)" : "")
                                                  + (modelData.pcgw.notes ? " — " + modelData.pcgw.notes : "") : ""
                                            maximumLineCount: 3; elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            visible: modelData.blocked || (!!modelData.online && modelData.online.level !== "none")
                                            font.family: win.mono; font.pixelSize: 9
                                            color: modelData.blocked || modelData.online.level === "anticheat" ? pal.bad : pal.amber
                                            text: modelData.blocked ? "✗ ReShade is banned or blocked in this game (PCGamingWiki): not touched"
                                                  : (modelData.online.level === "anticheat" ? "✗ Anti-cheat (" + modelData.online.anticheats.join(", ") + "): not touched"
                                                     : "⚠ Has online multiplayer/co-op: fine for single-player, check the game's rules online")
                                        }
                                        RowLayout {
                                            spacing: 6
                                            Chip {
                                                visible: !!modelData.sfx
                                                label: "PRESETS ↗"; onClicked: Qt.openUrlExternally("https://sfx.thelazy.net/games/game/" + modelData.sfx.id + "/")
                                            }
                                            Chip { label: "SEARCH NEXUS ↗"; tip: "Web search for ReShade presets of this game on Nexus Mods"; onClicked: Qt.openUrlExternally(modelData.nexus) }
                                            Chip {
                                                visible: !!modelData.pcgw
                                                label: "PCGW ↗"; onClicked: Qt.openUrlExternally("https://www.pcgamingwiki.com/wiki/ReShade#Compatibility_list")
                                            }
                                        }
                                    }
                                }
                            }
                            EmptyHint {
                                Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 30; anchors.centerIn: undefined
                                visible: win.fxScan.length === 0
                                title: fxScanProc.running ? "SCANNING YOUR LIBRARY…" : "PRESS SCAN"
                            }
                        }
                    }
                }

                // ---- HEALTH ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "health"
                    spacing: 8

                    // summary + everything missing in one command
                    Rectangle {
                        Layout.fillWidth: true
                        visible: !!win.health.checks
                        implicitHeight: hSum.implicitHeight + 20
                        radius: 8; color: pal.card; border.width: 1
                        border.color: win.health.fail > 0 ? pal.bad : (win.health.warn > 0 ? pal.amber : pal.ok)
                        ColumnLayout {
                            id: hSum
                            anchors.fill: parent; anchors.margins: 10; spacing: 8
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    font.family: win.mono; font.pixelSize: 11; font.bold: true
                                    color: win.health.fail > 0 ? pal.bad : (win.health.warn > 0 ? pal.amber : pal.ok)
                                    text: win.health.fail > 0 || win.health.warn > 0
                                          ? [win.health.fail > 0 ? win.health.fail + " problem" + (win.health.fail > 1 ? "s" : "") : "",
                                             win.health.warn > 0 ? win.health.warn + " warning" + (win.health.warn > 1 ? "s" : "") : ""]
                                            .filter(function (x) { return x; }).join(" · ")
                                            + "  —  nothing is changed from here: copy the command and run it in a terminal"
                                          : "✓ Everything games need is in place (" + (win.health.vendors || []).join(", ").toUpperCase() + ")"
                                }
                                Chip { label: healthProc.running ? "CHECKING…" : "RECHECK"; on: !healthProc.running; onClicked: healthProc.running = true }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                visible: (win.health.installAll || "") !== ""
                                Text { text: "ALL MISSING"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                FixLine { Layout.fillWidth: true; cmd: win.health.installAll || "" }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.health.checks
                            title: healthProc.running ? "CHECKING…" : "NO DATA"
                        }
                        ListView {
                            id: healthList
                            anchors.fill: parent; anchors.margins: 6
                            clip: true; spacing: 4
                            model: win.health.checks || []
                            ScrollBar.vertical: ScrollBar {}
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                width: healthList.width - 12; spacing: 4
                                property color stColor: modelData.status === "ok" ? pal.ok : (modelData.status === "fail" ? pal.bad
                                                        : (modelData.status === "warn" ? pal.amber : pal.sky))
                                Text {
                                    visible: index === 0 || healthList.model[index - 1].group !== modelData.group
                                    Layout.topMargin: index === 0 ? 2 : 8
                                    text: ({ system: "SYSTEM", driver: "GPU DRIVER", vulkan: "VULKAN", libs: "32-BIT LIBRARIES" })[modelData.group] || modelData.group.toUpperCase()
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 2; font.bold: true
                                }
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: hRow.implicitHeight + 14
                                    radius: 6; color: pal.card; border.width: 1
                                    border.color: modelData.status === "ok" || modelData.status === "info" ? pal.border : stColor
                                    ColumnLayout {
                                        id: hRow
                                        anchors.fill: parent; anchors.margins: 7; spacing: 5
                                        RowLayout {
                                            Layout.fillWidth: true; spacing: 8
                                            Text {
                                                text: ({ ok: "✓", fail: "✗", warn: "!", info: "i" })[modelData.status]
                                                color: stColor; font.family: win.mono; font.pixelSize: 12; font.bold: true
                                                Layout.preferredWidth: 12; horizontalAlignment: Text.AlignHCenter
                                            }
                                            Text {
                                                text: modelData.label; color: pal.text
                                                font.family: win.mono; font.pixelSize: 11
                                                Layout.preferredWidth: Math.min(implicitWidth, 260); elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                text: modelData.detail
                                                color: modelData.status === "ok" ? pal.dim : pal.text
                                                font.family: win.mono; font.pixelSize: 10
                                            }
                                        }
                                        FixLine {
                                            Layout.fillWidth: true; Layout.leftMargin: 20
                                            visible: modelData.fix !== ""
                                            cmd: modelData.fix
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- SHADERS ----
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "shaders"
                    spacing: 8

                    Hint {
                        text: !win.shaders.drivers ? "" :
                              "Drivers: " + win.shaders.drivers.map(function (d) { return d.name + " " + d.version; }).join(" · ")
                              + (win.shaders.lastDriverUpdate ? "  ·  last driver update " + win.dateOfEpoch(win.shaders.lastDriverUpdate) : "")
                    }
                    // stale after a driver update / orphaned / Steam busy
                    Rectangle {
                        Layout.fillWidth: true
                        visible: (win.shaders.staleBytes || 0) > 0 || (win.shaders.orphanBytes || 0) > 0 || win.shaders.steamProcessing === true
                        implicitHeight: shBanner.implicitHeight + 16
                        radius: 8; color: "#1a150c"; border.color: pal.amber; border.width: 1
                        RowLayout {
                            id: shBanner
                            anchors.fill: parent; anchors.margins: 8; spacing: 8
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: pal.amber; font.family: win.mono; font.pixelSize: 10
                                text: (win.shaders.steamProcessing ? "Steam is compiling shaders right now; cleaning waits until it finishes. " : "")
                                      + ((win.shaders.staleBytes || 0) > 0 ? win.human(win.shaders.staleBytes) + " of driver caches weren't used since the last driver update: they are stale. " : "")
                                      + ((win.shaders.orphanBytes || 0) > 0 ? win.human(win.shaders.orphanBytes) + " belong to games that are no longer installed." : "")
                            }
                            MiniBtn {
                                visible: (win.shaders.staleBytes || 0) > 0
                                width: 104; label: win.confirmShader === "stale" ? "CONFIRM?" : "CLEAN STALE"
                                on: !win.gameBusy && !win.shaders.steamProcessing
                                onClicked: win.shaderAction(["shaderclean", "stale"], "stale", "CLEANING…")
                            }
                            MiniBtn {
                                visible: (win.shaders.orphanBytes || 0) > 0
                                width: 112; label: win.confirmShader === "orphans" ? "CONFIRM?" : "CLEAN ORPHANS"
                                on: !win.gameBusy && !win.shaders.steamProcessing
                                onClicked: win.shaderAction(["shaderclean", "orphans"], "orphans", "CLEANING…")
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.shaders.games || (win.shaders.games.length === 0 && win.shaders.global.length === 0)
                            title: shaderProc.running ? "MEASURING CACHES…" : "NO SHADER CACHES"
                        }
                        ListView {
                            id: shaderList
                            anchors.fill: parent; anchors.margins: 4
                            clip: true; spacing: 3
                            model: (win.shaders.games || []).concat((win.shaders.global || []).map(function (g) {
                                return { global: true, id: g.id, name: g.label, total: g.size, stale: g.stale, path: g.path, installed: true };
                            }))
                            ScrollBar.vertical: ScrollBar {}
                            delegate: Rectangle {
                                required property var modelData
                                width: shaderList.width - 8; height: 50; radius: 8
                                color: pal.card; border.color: modelData.stale ? pal.amber : pal.border; border.width: 1
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 2
                                        RowLayout {
                                            spacing: 8
                                            Text {
                                                text: modelData.global ? "DRIVER" : (modelData.installed ? "STEAM" : "ORPHAN")
                                                color: modelData.global ? pal.sky : (modelData.installed ? pal.accent : pal.bad)
                                                font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
                                            }
                                            Text {
                                                text: modelData.name || ("uninstalled app " + modelData.id)
                                                color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight
                                                Layout.maximumWidth: 330
                                            }
                                            Text { text: win.human(modelData.total); color: pal.amber; font.family: win.mono; font.pixelSize: 10 }
                                            Text { visible: modelData.stale === true; text: "STALE"; color: pal.amber; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.running === true; text: "RUNNING"; color: pal.ok; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: modelData.global ? modelData.path
                                                  : ["pipelines " + (win.human(modelData.pipelines) || "0"),
                                                     "driver " + (win.human(modelData.driver) || "0"),
                                                     modelData.video > 0 ? "videos " + win.human(modelData.video) : "",
                                                     modelData.dxvk > 0 ? "dxvk " + win.human(modelData.dxvk) : "",
                                                     modelData.other > 0 ? "other " + win.human(modelData.other) : ""]
                                                    .filter(function (x) { return x !== ""; }).join("  ·  ")
                                        }
                                    }
                                    MiniBtn {
                                        visible: !modelData.global && modelData.driver > 0
                                        width: 92; primary: false
                                        property string key: "steam:" + modelData.id + ":driver"
                                        label: win.confirmShader === key ? "CONFIRM?" : "DRIVER CACHE"
                                        on: !win.gameBusy && !modelData.running && !win.shaders.steamProcessing
                                        onClicked: win.shaderAction(["shaderclean", "steam:" + modelData.id, "driver"], key, "CLEANING…")
                                    }
                                    MiniBtn {
                                        width: 70; tint: pal.bad
                                        property string key: (modelData.global ? "global:" + modelData.id : "steam:" + modelData.id + ":all")
                                        label: win.confirmShader === key ? "CONFIRM?" : (modelData.global ? "CLEAN" : "ALL")
                                        on: !win.gameBusy && !modelData.running && (modelData.global || !win.shaders.steamProcessing)
                                        onClicked: win.shaderAction(modelData.global ? ["shaderclean", "global:" + modelData.id]
                                                                                     : ["shaderclean", "steam:" + modelData.id, "all"], key, "CLEANING…")
                                    }
                                }
                            }
                        }
                    }
                    Hint {
                        text: "pipelines = Steam's Fossilize recordings (driver-independent, used to pre-compile) · driver = the GPU driver's compiled cache (NVIDIA nvidiav1 / Mesa for AMD-Intel), rebuilt after every driver update. DRIVER CACHE clears only that; ALL clears the game's whole folder. Either way the next launches stutter a little while caches rebuild."
                    }
                }

                // ---- STATUS ----
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "status"
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 14; spacing: 12
                        visible: win.gstat.gamemode !== undefined

                        component StatLine: RowLayout {
                            property string label
                            property string value
                            property bool good: true
                            property string note: ""
                            Layout.fillWidth: true; spacing: 10
                            Text { text: good ? "✓" : "!"; color: good ? pal.ok : pal.amber; font.family: win.mono; font.pixelSize: 12; font.bold: true }
                            Text { text: label; Layout.preferredWidth: 150; color: pal.text; font.family: win.mono; font.pixelSize: 11; font.bold: true }
                            Text { text: value; color: good ? pal.dim : pal.amber; font.family: win.mono; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; text: note; color: pal.dim; font.family: win.mono; font.pixelSize: 9; wrapMode: Text.WordWrap }
                        }

                        StatLine {
                            label: "GameMode"
                            good: !!win.gstat.gamemode && win.gstat.gamemode.installed
                            value: !win.gstat.gamemode ? "" : (!win.gstat.gamemode.installed ? "not installed"
                                   : (win.gstat.gamemode.active ? "active now" : "installed, idle"))
                            note: "raises the CPU governor while a game runs and puts it back when the game exits"
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            StatLine {
                                label: "gamemode group"
                                good: !!win.gstat.gamemode && win.gstat.gamemode.ingroup
                                value: !win.gstat.gamemode ? "" : (win.gstat.gamemode.ingroup ? "member"
                                       : (win.gstat.gamemode.pending ? "added · not active yet" : "not a member"))
                                note: !win.gstat.gamemode || win.gstat.gamemode.ingroup ? ""
                                      : (win.gstat.gamemode.pending
                                         ? "log out of your desktop session (back to the login screen) or reboot: groups are only read at login"
                                         : "without it gamemode can't switch the governor (no password prompt during games) and nice < 0 is refused")
                            }
                            MiniBtn {
                                visible: !!win.gstat.gamemode && !win.gstat.gamemode.ingroup && !win.gstat.gamemode.pending
                                width: 96; label: win.confirmJoin ? "CONFIRM?" : "JOIN GROUP"
                                on: !win.gameBusy
                                onClicked: {
                                    if (!win.confirmJoin) { win.confirmJoin = true; return; }
                                    win.confirmJoin = false;
                                    win.runGame(["gamejoin"], "JOINING…");
                                }
                            }
                        }
                        StatLine {
                            label: "CPU governor"
                            good: true
                            value: (win.gstat.governor || "?") + "  (" + (win.gstat.cpufreq_driver || "?") + ")"
                            note: "switched to performance by gamemode during a game"
                        }
                        StatLine {
                            label: "vm.max_map_count"
                            good: win.gstat.max_map_count_ok === true
                            value: String(win.gstat.max_map_count || "?")
                            note: win.gstat.max_map_count_ok ? "already ≥ 1048576 (Arch default), enough for games like Star Citizen or DayZ"
                                                             : "below 1048576: some games crash; Arch's filesystem package sets 1048576"
                        }
                        StatLine { label: "MangoHud"; good: win.gstat.mangohud === true; value: win.gstat.mangohud ? "installed" : "missing (pacman -S mangohud lib32-mangohud)" }
                        StatLine { label: "gamescope"; good: win.gstat.gamescope === true; value: win.gstat.gamescope ? "installed" : "missing (optional)" }
                        StatLine {
                            label: "Running now"
                            good: true
                            value: !win.gstat.running || win.gstat.running.length === 0 ? "no game"
                                   : win.gstat.running.map(function (r) { return win.gameName(r.id) + " (pid " + r.pid + ")"; }).join(", ")
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                LogBox {
                    Layout.fillWidth: true; base: 150
                    visible: win.gameLog !== ""
                    content: win.gameLog
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

                RowLayout {
                    Layout.fillWidth: true; spacing: 0
                    ActBtn {
                        glyph: ""; label: "REFRESH"
                        on: !win.gameBusy
                        onClicked: { win.gameLog = ""; win.openGaming(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: "STEAM"
                        onClicked: steamOpenProc.running = true
                    }
                }
            } // ================= end GAMING VIEW =================

        }
    }
}
