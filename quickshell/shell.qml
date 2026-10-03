import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "es.js" as I18n

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
        // UI language: "en" or "es" (ESP/ENG in the header); saved by the backend
        property string lang: "en"
        function t(s) {
            if (lang !== "es" || typeof s !== "string") return s;
            if (I18n.ES[s] !== undefined) return I18n.ES[s];
            for (var i = 0; i < I18n.PATTERNS.length; i++)
                if (I18n.PATTERNS[i][0].test(s)) return s.replace(I18n.PATTERNS[i][0], I18n.PATTERNS[i][1]);
            var m = /^([0-9][0-9\/]*)( .*)$/.exec(s);             // "6 GAMES", "2/3 READY"
            if (m && I18n.ES[m[2]] !== undefined) return m[1] + I18n.ES[m[2]];
            for (var k in I18n.ES)                                 // "REVIEWING foo…", "FAILED · 3"
                if (/[ #:·] ?$/.test(k) && k.length > 3 && s.indexOf(k) === 0) return I18n.ES[k] + s.slice(k.length);
            return s;
        }
        Component.onCompleted: {
            timerStatusProc.running = true;
            versionProc.running = true;
            loadView();
        }
        // each tab loads its data when it's shown, whatever showed it (tab, header
        // notice, a notification opening the deck on a tab)
        onViewChanged: loadView()
        function loadView() {
            if (view === "manage" && apps.length === 0) refreshApps();
            if (view === "updates" && !updChecked && !updBusy) checkUpdates();
            if (view === "system") openSystem(sysView);
            if (view === "gaming" && games.length === 0) openGaming();
        }

        function srcColor(s) {
            switch (s) {
                case "repo":     return pal.accent;
                case "aur":      return pal.pink;
                case "flatpak":  return pal.sky;
                case "github":   return pal.amber;
                case "appimage": return pal.ok;
                case "deck":     return pal.accentHi;
                case "proton":   return pal.bad;
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
            { t: "DEB",      e: win.t(".deb  (with debtap)") },
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
                default:         return win.t("FILE");
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
        onGameViewChanged: loadGameView()
        function loadGameView() {
            if (gameView === "status") gstatProc.running = true;
            else if (gameView === "shaders") shaderProc.running = true;
            else if (gameView === "bench") { if (selGame && selGameSource === "steam") benchProc.running = true; }
            else if (gameView === "prefixes") { pfxProc.running = true; pfxBakProc.running = true; }
            else if (gameView === "health") healthProc.running = true;
        }
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
        property var    ups: ({})           // upscaler upgrades for the selected game
        property var    gaudit: ({})        // profiles vs this PC
        property var    fx: ({})            // visual shaders: install state + selected game
        property var    fxGames: []         // SweetFX DB games matching the search
        property string fxGameId: ""
        property var    fxPresets: []
        property string fxMsg: ""
        property string fxConfirm: ""       // anti-cheat games: second click applies
        property bool   fxActive: !!fx.current && !!win.gp.fx
        property bool   fxAnticheat: !!fx.online && fx.online.level === "anticheat"
        property var    fxCur: fx.current || ({})   // the applied look, never undefined while fx reloads
        property bool   fxReshade: fx.mode === "reshade"
        property bool   fxGame: selGameSource === "steam" || selGameSource === "umbral"
        property bool   fxUmbral: selGameSource === "umbral"
        property var    fxRsGame: fx.reshade ? fx.reshade.game : null
        property bool   fxReady: fxReshade ? (!!fx.reshade && fx.reshade.ready === true) : (fx.vkbasalt === true && fx.shadersInstalled === true)
        function openFx() {
            gameView = "fx"; fxConfirm = ""; fxTopFor = "";
            if (selGameSource === "steam" || selGameSource === "umbral") {
                fxStatProc.running = true;
                if (fxQuery.text === "" || fxLastGame !== selGame) { fxQuery.text = selGameName; fxLastGame = selGame; fxSearch(selGameName); }
            }
        }
        property string fxLastGame: ""
        property string fxScope: "game"     // game | library
        property string fxImportFile: ""    // archive picked for IMPORT
        property bool   fxGuideOpen: false  // FX: all steps listed (otherwise only the pending ones / a summary)
        property bool   fxDetails: false    // FX: executable, API and keys (advanced)
        property bool   fxAddLink: false    // FX: the win.t("save a preset page") field is open
        property string fxTopFor: ""
        function fxToTop() { fxScroll.contentItem.contentY = 0; }
        // the FX steps, from the game's real state: [done, title, how]
        property var    fxSteps: {
            var key = (fx.key || "Home").toUpperCase(), rs = fxReshade;
            return [
                [(rs ? "reshade" : "vkbasalt") === fx.recommended,
                 (rs ? "reshade" : "vkbasalt") === fx.recommended ? win.t("Route: ") + (rs ? "ReShade" : "vkBasalt")
                                                                  : win.t("Switch to ") + (fx.recommended === "reshade" ? "ReShade" : "vkBasalt"),
                 ((rs ? "reshade" : "vkbasalt") === fx.recommended ? win.t("The recommended one for this game. ") : win.t("Recommended here: ") + (fx.recommended === "reshade" ? "ReShade" : "vkBasalt") + ". ")
                 + win.t(((fx.advice || {}).reasons || [""])[0])],
                [fxReady, win.t("Install ") + (rs ? "ReShade" : "vkBasalt + shaders"),
                 rs ? win.t("Downloaded from reshade.me into your user folder, no password.") : win.t("From chaotic-aur (asks for your password) plus the standard shaders.")],
                fxUmbral
                ? [fx.wrapped === true, win.t("Launch it from Umbral"),
                   fx.wrapped ? win.t("Umbral asks the deck for the shaders/TEMPS each time it starts the game.")
                              : win.t("Needs Umbral 0.10.0 or newer (it asks the deck before launching): update Umbral.")]
                : [fx.wrapped === true, win.t("Launch it through Control Deck"),
                 fx.wrapped ? win.t("Its Steam launch options go through the deck, which loads the shaders.")
                            : (fx.steamRunning ? win.t("Close Steam, then USE IN STEAM.") : win.t("USE IN STEAM puts the deck in its launch options."))],
                [fxActive, win.t("Pick a look"),
                 fxActive ? win.t("Active: ") + fxCur.name + win.t(". Change it any time below.")
                          : ((fx.links || []).length
                             ? win.t("Your saved preset: ") + fx.links[0].label + win.t(" — open it, download the file, then IMPORT…")
                               + (fx.links[0].notes ? win.t(" Its guide, mapped to the deck, is under SAVED below.") : "")
                             : win.t("Below: a QUICK LOOK, a SweetFX DB preset (APPLY), or one from Nexus: SEARCH NEXUS → download it → IMPORT…"))],
                [fxActive && fx.wrapped === true && fxReady, win.t("Play and tweak"),
                 rs ? win.t("Launch the game and press ") + key + win.t(": ReShade's menu, tick/untick effects and move sliders (saved to this game). ")
                      + ((fx.effectsKey || "End") !== "None" ? (fx.effectsKey || "End").toUpperCase() + win.t(" switches all effects on/off. ") : "")
                      + win.t("Turn on Performance Mode once you like it. Screenshots (PRINT SCREEN): ") + (fx.shotsDir || "~/Pictures/ReShade") + "."
                    : win.t("Launch the game; ") + key + win.t(" turns the effects on/off to compare.")]
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
            loadGameView();
        }
        function selectGame(g) {
            selGame = g.key; selGameId = g.id; selGameName = g.name; selGameSource = g.source;
            selGameLaunch = g.launch; selGameCompat = g.compat; selGameWrapped = g.wrapped; selGameObj = g;
            gameLog = ""; if (g.source === "steam" || g.source === "umbral") gprofProc.running = true;
            ups = {}; if (g.source === "steam") upsProc.running = true;
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
        // add or remove a set of VAR=value in the ENV field (saved with SAVE / PLAY)
        function toggleEnvSet(set, on) {
            var names = Object.keys(set || {});
            var rest = gEnv.text.split(/\s+/).filter(function (e) { return e && names.indexOf(e.split("=")[0]) < 0; });
            if (!on) names.forEach(function (n) { rest.push(n + "=" + set[n]); });
            gEnv.text = rest.join(" ");
        }
        // add/remove VAR=1 in the ENV field (saved with SAVE / PLAY)
        function toggleEnv(name) {
            var rest = gEnv.text.split(/\s+/).filter(function (e) { return e && e.split("=")[0] !== name; });
            if (envValue(name) !== "1") rest.push(name + "=1");
            gEnv.text = rest.join(" ");
        }
        function envValue(name) {
            var hit = gEnv.text.split(/\s+/).filter(function (e) { return e.split("=")[0] === name; })[0];
            return hit === undefined ? null : hit.substring(name.length + 1);
        }
        function sugLabel(x, applied, mark) {
            var l = (applied ? "✓ " : mark) + x.token + "  " + x.pct + "%";
            if (x.kind === "env" && !applied) {
                var mine = envValue(x.var);
                if (mine !== null) l += win.t(" · you =") + mine;
            }
            return l;
        }
        function sugTip(x, applied) {
            var t = x.pct + win.t("% of ") + (x.basis === "similar" ? win.t("players with a GPU like yours") : (x.basis === "vendor" ? win.t("players with your GPU vendor") : "players"))
                    + win.t(" who say it works use it (") + x.n + win.t(" reports)");
            if (x.kind === "env" && x.unset !== undefined) t += "; " + x.unset + win.t("% leave it at the default");
            if (x.adapted) t += win.t("; value adapted to this PC");
            return t + (applied ? win.t(". Already in the profile.") : win.t(". Click to add, then SAVE."));
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
        property var stHist: ({ gpuLoad: [], gpuTemp: [], cpuTemp: [], ram: [], vram: [] })
        property string confirmSched: ""    // scheduler changes that touch /etc: second click
        function durationText(sec) {
            var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
            return h > 0 ? h + " h " + m + " min" : (m > 0 ? m + " min" : sec + " s");
        }
        // STATUS is live while it's on screen
        Timer {
            interval: 3000; repeat: true
            running: win.visible && win.view === "gaming" && win.gameView === "status"
            onTriggered: if (!gstatProc.running) gstatProc.running = true
        }
        function playtimeText(sec) {
            if (!sec) return win.t("never played");
            var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
            return (h > 0 ? h + " h " : "") + m + win.t(" min played");
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
            runGame(a.concat(extra || []), win.t("SAVING…"));
        }
        function runBench(v) { pendingRun = v; saveBench([]); }
        function pct(v) { return v === undefined || v === null ? "" : (v > 0 ? "+" : "") + v + "%"; }
        function dateOfEpoch(e) { return e ? new Date(e * 1000).toISOString().substring(0, 10) : "?"; }
        property bool pendingPlay: false
        function playGame() {
            if (selGameSource === "steam") { pendingPlay = true; saveGameProfile(); }
            else runGame(["gplay", selGame], win.t("LAUNCHING…"));
        }
        function saveGameProfile() {
            runGame(["gprofile", "set", selGame,
                     "gamemode=" + (gp.gamemode === true), "mangohud=" + (gp.mangohud === true),
                     "overlay=" + (gp.overlay === true), "ionice=" + (gp.ionice === true), "nice=" + (gp.nice || 0),
                     "env=" + gEnv.text.trim(), "prefix=" + gPrefix.text.trim(), "args=" + gArgs.text.trim()],
                    win.t("SAVING…"));
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
            command: [win.scriptPath, "pickfile", win.t("Choose an icon")]
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
                    if (!gauditProc.running) gauditProc.running = true;
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
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.gstat = JSON.parse(text); } catch (e) { return; }
                    // live history for the STATUS graphs (100 samples ≈ 5 min at 3 s)
                    var h = win.stHist, g = win.gstat.gpu || {}, y = win.gstat.system || {};
                    function push(a, v) { var b = a.concat([v == null ? 0 : v]); return b.length > 100 ? b.slice(b.length - 100) : b; }
                    win.stHist = {
                        gpuLoad: push(h.gpuLoad, g.load), gpuTemp: push(h.gpuTemp, g.temp), cpuTemp: push(h.cpuTemp, y.temp),
                        ram: push(h.ram, y.memTotal ? 100 * y.memUsed / y.memTotal : 0),
                        vram: push(h.vram, g.vramTotal ? 100 * g.vramUsed / g.vramTotal : 0)
                    };
                }
            }
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
                    if (c === 0) { Qt.callLater(function () { win.runGame(["gplay", win.selGame], win.t("LAUNCHING…")); }); return; }
                }
                if (win.gameArgs[0] === "bench" && win.gameArgs[1] === "set" && win.pendingRun !== "") {
                    var v = win.pendingRun; win.pendingRun = "";
                    // started after this handler returns (restarting a Process from its own onExited is unsafe)
                    if (c === 0) { Qt.callLater(function () { win.runGame(["bench", "run", win.selGame, v], win.t("RUN ") + v + "…"); }); return; }
                }
                if (win.gameArgs[0] === "bench") benchProc.running = true;
                if (win.gameArgs[0] === "prefix") { pfxProc.running = true; pfxBakProc.running = true; }
                if (win.gameArgs[0] === "steamcompat") upsProc.running = true;
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
            id: upsProc
            command: [win.scriptPath, "upscale", win.selGame]
            stdout: StdioCollector { onStreamFinished: { try { win.ups = JSON.parse(text); } catch (e) { win.ups = {}; } } }
        }
        Process {
            id: gauditProc
            command: [win.scriptPath, "gaudit"]
            stdout: StdioCollector { onStreamFinished: { try { win.gaudit = JSON.parse(text); } catch (e) { win.gaudit = {}; } } }
        }
        Process {
            id: healthProc
            command: [win.scriptPath, "health"]
            stdout: StdioCollector { onStreamFinished: { try { win.health = JSON.parse(text); } catch (e) { win.health = {}; } } }
        }
        Process { id: fixCopyProc }
        Process {
            id: langProc
            running: true
            command: [win.scriptPath, "uilang"]
            stdout: StdioCollector { onStreamFinished: { var l = text.trim(); if (l === "es" || l === "en") win.lang = l; } }
        }
        Process { id: langSaveProc }
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
            command: [win.scriptPath, "pickfile", win.t("Choose a downloaded ReShade preset"), "@downloads",
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
                        win.fxApply("file:" + win.fxImportFile, win.t("IMPORTING PRESET…"), ["fx", "import", win.selGame, win.fxImportFile]);
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
            command: [win.scriptPath, "pickfile", win.t("Choose a Control Deck backup (.json)")]
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
                    text: cmd === "reboot" ? win.t("Restart the PC") : "$ " + cmd
                    wrapMode: Text.WrapAnywhere
                    color: pal.sky; font.family: win.mono; font.pixelSize: 10
                }
            }
            Chip {
                visible: cmd !== "reboot"
                label: win.copiedFix === cmd ? win.t("COPIED ✓") : win.t("COPY")
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
                    Field { id: bvLabel; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: win.t("name") }
                }
                Field { id: bvEnv; Layout.fillWidth: true; font.pixelSize: 10; placeholderText: win.t("extra env: VAR=1 VAR2=x") }
                Field { id: bvArgs; Layout.fillWidth: true; font.pixelSize: 10; placeholderText: win.t("args (replace the profile's)") }
                Flow {
                    Layout.fillWidth: true; spacing: 4
                    Text { text: "GAMEMODE"; color: pal.dim; font.family: win.mono; font.pixelSize: 8; height: 22; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: [["", win.t("PROFILE")], ["true", "ON"], ["false", "OFF"]]
                        delegate: Chip { required property var modelData; label: modelData[1]; implicitHeight: 22
                                         active: bv.gm === modelData[0]; onClicked: bv.gm = modelData[0] }
                    }
                }
                Flow {
                    Layout.fillWidth: true; spacing: 4
                    Text { text: "PROTON"; color: pal.dim; font.family: win.mono; font.pixelSize: 8; height: 22; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: [{ name: "", display: win.t("AS IS") }].concat(win.tools)
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
                onClicked: { if (win.view === key) win.loadView(); else win.view = key; }
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
            // never narrower than its text (Spanish labels are longer); a fixed width
            // given by a layout still fits: the text shrinks a little as a last resort
            implicitWidth: Math.max(76, mbTxt.implicitWidth + 18)
            width: implicitWidth; height: 30; radius: 6
            color: primary && on ? pal.cardHi : "transparent"
            border.color: primary && on ? tint : pal.border
            border.width: 1
            opacity: on ? 1.0 : 0.4
            Text {
                id: mbTxt
                anchors.centerIn: parent
                width: Math.min(implicitWidth, mb.width - 8)
                horizontalAlignment: Text.AlignHCenter
                fontSizeMode: Text.HorizontalFit; minimumPixelSize: 6
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
                // ESP | ENG
                Row {
                    spacing: 0
                    Repeater {
                        model: [["es", "ESP"], ["en", "ENG"]]
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            width: langTxt.implicitWidth + 14; height: 20; radius: 4
                            color: win.lang === modelData[0] ? pal.accent : "transparent"
                            border.color: pal.border; border.width: win.lang === modelData[0] ? 0 : 1
                            Text {
                                id: langTxt; anchors.centerIn: parent; text: modelData[1]
                                color: win.lang === modelData[0] ? pal.bg : pal.dim
                                font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: if (win.lang !== modelData[0]) { win.lang = modelData[0]; langSaveProc.command = [win.scriptPath, "uilang", modelData[0]]; langSaveProc.running = true; }
                            }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: win.deckUpdate
                    text: win.t("● NEW VERSION"); color: pal.amber; font.family: win.mono
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
                NavTab { label: win.t("INSTALL"); key: "install" }
                NavTab { label: win.t("MANAGE");  key: "manage" }
                NavTab { label: win.t("STORE");   key: "store" }
                NavTab { label: win.t("UPDATES"); key: "updates" }
                NavTab { label: win.t("SYSTEM");  key: "system" }
                NavTab { label: "GAMING";  key: "gaming" }
            }

            // ================= INSTALL VIEW =================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: win.view === "install"
                spacing: 16

            Section {
                Layout.fillWidth: true; label: win.t("STASH")
                info: win.queue.length > 0
                      ? win.queue.length + (win.queue.length === 1 ? win.t(" FILE") : win.t(" FILES"))
                      : win.t("NO FILE")
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
                    text: win.t("DROP PACKAGE(S) HERE"); color: pal.dim; font.family: win.mono
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
                        text: win.t("SUPPORTED FORMATS"); color: pal.dim; font.family: win.mono
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
                    placeholderText: win.t("path, download URL or github.com/user/repo…")
                    enabled: !win.busy
                    onAccepted: win.submitInput(text)
                }
            }

            // status
            Section { Layout.fillWidth: true; label: win.t("STATUS"); info: win.t(win.status) }
            Text {
                Layout.fillWidth: true
                visible: win.queue.length > 0 && win.supportedCount() < win.queue.length
                text: (win.queue.length - win.supportedCount()) + win.t(" file(s) can't be installed and will be skipped (rpm / deb without debtap / unknown).")
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
                    glyph: ""; label: win.t("CLEAR")
                    on: win.queue.length > 0 && !win.busy
                    onClicked: { win.reset(); pathField.text = ""; }
                }
                BarSep {}
                ActBtn {
                    glyph: ""; label: win.t("FOLDER")
                    on: !win.busy
                    onClicked: openProc.running = true
                }
                BarSep {}
                ActBtn {
                    glyph: ""; label: win.busy ? win.t("WORKING") : (win.queue.length > 1 ? win.t("INSTALL ALL") : win.t("INSTALL"))
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
                        placeholderText: win.t("filter…")
                        onTextChanged: win.searchText = text
                    }
                    Chip { label: "A–Z";  active: !win.sortBySize; onClicked: win.sortBySize = false }
                    Chip { label: win.t("SIZE"); active: win.sortBySize;  onClicked: win.sortBySize = true }
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
                                    text: win.t("HIDDEN"); color: pal.pink
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

                Section { Layout.fillWidth: true; label: win.t("EDIT"); info: win.t(win.manageStatus) }

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
                            placeholderText: win.t("app name"); font.pixelSize: 13
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Field {
                                id: iconEdit
                                Layout.fillWidth: true; enabled: win.selPath !== ""
                                placeholderText: win.t("icon name or /path")
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
                        Chip { label: win.t("COPY"); onClicked: win.runQuick(copyProc) }
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
                        Chip { label: win.t("HIDDEN"); tint: pal.pink; active: win.selHidden; onClicked: win.selHidden = !win.selHidden }
                        Chip { label: "TERMINAL"; active: win.selTerminal; onClicked: win.selTerminal = !win.selTerminal }
                    }
                }

                // flatpak permissions (toggle = user override)
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: win.selSource === "flatpak" && win.fpPerms.length > 0
                    Text {
                        Layout.alignment: Qt.AlignTop; Layout.topMargin: 6
                        text: win.t("PERMS"); Layout.preferredWidth: 38; color: pal.dim
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
                            label: win.t("RESET"); tint: pal.bad
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
                                return s ? "  app " + (win.human(s.app) || "–") + win.t("  ·  data ") + (win.human(s.data) || "–") : "";
                            }
                            color: pal.amber; font.family: win.mono; font.pixelSize: 10
                        }
                    }
                    Chip {
                        label: win.selAutostart ? win.t("✓ AUTOSTART") : win.t("AUTOSTART")
                        tint: pal.ok; active: win.selAutostart
                        on: !win.manageBusy
                        onClicked: {
                            win.manageLog = "";
                            win.autostartArgs = [win.selPath, win.selAutostart ? "off" : "on"];
                            autostartProc.running = true;
                        }
                    }
                    Chip {
                        label: win.purge ? win.t("✓ DELETE DATA") : win.t("+ DELETE DATA")
                        tint: pal.bad; active: win.purge
                        on: win.selSource !== "system" && win.selSource !== "wine" && !win.manageBusy
                        onClicked: win.purge = !win.purge
                    }
                    Chip {
                        label: win.showAdvanced ? win.t("LESS ▴") : win.t("MORE ▾")
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
                        glyph: ""; label: win.t("REFRESH")
                        on: !win.manageBusy
                        onClicked: { win.searchText = ""; searchField.text = ""; win.refreshApps(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: win.t("LAUNCH")
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: win.runQuick(launchProc)
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: win.t("FOLDER")
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: win.runQuick(dirProc)
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: win.t("SAVE"); boxed: true
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
                        label: win.confirmUninstall ? win.t("CONFIRM?") : win.t("UNINSTALL")
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

                Section { Layout.fillWidth: true; label: win.t("SEARCH"); info: win.t(win.storeStatus) }

                // query
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: ""; color: pal.accent; font.family: win.mono; font.pixelSize: 12 }
                    Field {
                        id: queryField
                        Layout.fillWidth: true
                        placeholderText: win.t("search repos · AUR · flatpak…  or  github.com/user/repo")
                        enabled: !win.storeBusy
                        onAccepted: win.runSearch(text)
                    }
                    MiniBtn {
                        width: Math.max(78, implicitWidth); height: 34
                        label: win.storeBusy ? "…" : win.t("SEARCH")
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
                        title: win.storeBusy ? win.t("SEARCHING…")
                             : (win.storeQuery === "" ? win.t("TYPE AN APP AND PRESS ENTER")
                                                      : win.t("NO RESULTS FOR «") + win.storeQuery + "»")
                        sub: win.storeQuery === "" && !win.storeBusy
                             ? win.t("official repos · AUR · Flatpak · GitHub releases") : ""
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
                                    width: Math.max(68, implicitWidth)
                                    label: modelData.installed ? win.t("INSTALLED") : (modelData.source === "aur" ? win.t("REVIEW") : win.t("INSTALL"))
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

                    EmptyHint { visible: reviewProc.running; title: win.t("READING THE PKGBUILD…") }

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
                                label: win.review ? win.review.risk + win.t(" risk") : ""
                                tint: win.review ? win.riskColor(win.review.risk) : pal.dim
                            }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: !win.review ? "" :
                                  (win.review.maintainer ? "maintainer " + win.review.maintainer : win.t("ORPHANED (no maintainer)"))
                                  + "  ·  " + win.review.votes + win.t(" votes")
                                  + win.t("  ·  since ") + win.dateOf(win.review.submitted)
                                  + win.t("  ·  updated ") + win.dateOf(win.review.modified)
                            color: pal.dim; font.family: win.mono; font.pixelSize: 10
                        }

                        // findings
                        Text {
                            visible: win.review !== null && win.review.flags.length === 0
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: win.t("✓ No suspicious patterns found. Still, only build packages you trust.")
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
                                text: win.t("Building runs the PKGBUILD on your machine. Read it if anything is flagged.")
                            }
                            MiniBtn {
                                width: Math.max(76, implicitWidth); label: win.t("CANCEL"); primary: false
                                onClicked: { win.review = null; win.storeStatus = win.results.length + " RESULTS"; }
                            }
                            MiniBtn {
                                width: Math.max(120, implicitWidth)
                                tint: win.review ? win.riskColor(win.review.risk) : pal.accent
                                label: !win.review ? "" : (win.review.risk === "high"
                                       ? (win.confirmRisky ? win.t("REALLY BUILD?") : win.t("BUILD ANYWAY"))
                                       : win.t("BUILD & INSTALL"))
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
                    text: win.t("Repos/Flatpak/GitHub install here. AUR packages are reviewed first, then built in a terminal. GitHub installs update from UPDATES.")
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

                Section { Layout.fillWidth: true; label: win.t("UPDATES"); info: win.t(win.updStatus) }

                // opt-in background check
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Chip {
                        label: win.autoCheck ? win.t("✓ AUTO-CHECK ON") : win.t("AUTO-CHECK OFF")
                        tint: pal.ok; active: win.autoCheck
                        on: !win.updBusy
                        onClicked: { win.updLog = ""; win.timerArgs = win.autoCheck ? ["off"] : ["on"]; timerProc.running = true; }
                    }
                    Hint {
                        text: win.autoCheck
                              ? win.t("Checked every 6 h in the background: you get a notification, even with the deck closed.")
                              : win.t("Turn on to get a notification when updates are available (the deck doesn't need to be open).")
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
                        text: win.t("\uf108  This update changes the GPU driver (") + win.driverUpdates.map(function (u) { return u.name + " " + u.old + " → " + u.new; }).join(", ")
                              + win.t("). Every game's shader cache gets rebuilt: expect some stutter the first time you play each game. Old driver caches can be cleaned afterwards in GAMING → SHADERS.")
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
                            text: "\uf1ea  " + win.unreadNews.length + win.t(" Arch news since your last upgrade — some need manual steps. Read them before updating:")
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
                        title: checkProc.running ? win.t("CHECKING FOR UPDATES…")
                             : (win.updChecked ? win.t("ALL UP TO DATE ✓") : win.t("PRESS CHECK"))
                        sub: win.t("repos · AUR · Flatpak · AppImage/GitHub")
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
                                    width: Math.max(68, implicitWidth)
                                    label: modelData.source === "repo" ? win.t("SYSTEM") : win.t("UPDATE")
                                    primary: modelData.source !== "repo"
                                    on: !win.updBusy
                                    onClicked: win.guardedUpdate(["update", modelData.source, modelData.id],
                                                                 win.t("UPDATING ") + modelData.name + "…",
                                                                 modelData.source === "repo")
                                }
                            }
                        }
                    }
                }

                Hint {
                    visible: win.updLog === ""
                    text: win.t("Arch doesn't support partial upgrades: repo packages are updated together (pacman -Syu). AUR opens a terminal.")
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
                        glyph: ""; label: checkProc.running ? win.t("CHECKING") : win.t("CHECK")
                        on: !win.updBusy
                        onClicked: { win.updLog = ""; win.checkUpdates(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: updProc.running ? win.t("WORKING") : win.t("UPDATE ALL")
                        boxed: true
                        on: win.updates.length > 0 && !win.updBusy
                        onClicked: win.guardedUpdate(["updateall"], win.t("UPDATING ALL…"),
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
                    Chip { label: win.t("CLEAN");   active: win.sysView === "clean";   onClicked: win.openSystem("clean") }
                    Chip { label: win.t("BACKUP");  active: win.sysView === "backup";  onClicked: win.openSystem("backup") }
                    Chip { label: win.t("HISTORY"); active: win.sysView === "history"; onClicked: win.openSystem("history") }
                    Chip { label: "SNAPSHOTS"; active: win.sysView === "snapshots"; onClicked: win.openSystem("snapshots") }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignRight
                        text: win.t(win.sysStatus); color: pal.dim; font.family: win.mono
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
                        title: scanProc.running ? win.t("SCANNING THE SYSTEM…") : win.t("PRESS RESCAN")
                    }

                    ListView {
                        id: cleanList
                        anchors.fill: parent; anchors.margins: 4
                        clip: true; spacing: 3
                        // only what can be cleaned gets a row; the rest is one line below
                        model: win.cleanItems.filter(function (x) { return x.count > 0; })
                        ScrollBar.vertical: ScrollBar {}
                        footer: Text {
                            width: cleanList.width - 8; topPadding: 10; leftPadding: 12; rightPadding: 12
                            property var clean: win.cleanItems.filter(function (x) { return x.count === 0; })
                            visible: clean.length > 0
                            text: "✓ " + win.t("Nothing to clean in: ") + clean.map(function (x) { return win.t(x.title); }).join("  ·  ")
                            color: pal.dim; font.family: win.mono; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
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
                                            text: win.t(modelData.title); color: pal.text; font.family: win.mono
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
                                        text: modelData.details ? modelData.details : win.t(modelData.desc)
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                        elide: Text.ElideRight; maximumLineCount: 1
                                    }
                                }
                                MiniBtn {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: Math.max(win.confirmClean === modelData.id ? 84 : 68, implicitWidth)
                                    label: win.confirmClean === modelData.id ? win.t("CONFIRM?") : win.t("CLEAN")
                                    on: !win.sysBusy
                                    onClicked: {
                                        if (["shaders", "prefixes", "protons"].indexOf(modelData.id) >= 0 && win.confirmClean !== modelData.id) {
                                            win.confirmClean = modelData.id; return;
                                        }
                                        win.confirmClean = "";
                                        win.runSys(["clean", modelData.id], win.t("CLEANING…"));
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

                    Section { Layout.fillWidth: true; label: win.t("EXPORT") }
                    Hint {
                        text: win.t("Saves your packages (repos and AUR), Flatpaks, GitHub AppImages and the launchers you edited (with their icons) to ~/control-deck-backup-<date>.json.")
                    }
                    MiniBtn {
                        width: Math.max(120, implicitWidth); height: 34
                        label: win.t("EXPORT BACKUP")
                        on: !win.sysBusy
                        onClicked: win.runSys(["export"], win.t("EXPORTING…"))
                    }

                    Section { Layout.fillWidth: true; label: win.t("RESTORE") }
                    Hint {
                        text: win.t("Installs whatever is missing from a backup: repo packages with pacman, Flatpaks, GitHub AppImages and launchers. AUR packages are built in a terminal.")
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
                            width: Math.max(92, implicitWidth); height: 34
                            label: win.confirmRestore ? win.t("CONFIRM?") : win.t("RESTORE")
                            on: restoreField.text.trim() !== "" && !win.sysBusy
                            onClicked: {
                                if (!win.confirmRestore) { win.confirmRestore = true; return; }
                                win.runSys(["restore", win.expandHome(restoreField.text.trim())], win.t("RESTORING…"));
                            }
                        }
                        MiniBtn {
                            width: Math.max(120, implicitWidth); height: 34; label: win.t("GAMING ONLY"); primary: false
                            on: restoreField.text.trim() !== "" && !win.sysBusy
                            onClicked: win.runSys(["gaming-import", win.expandHome(restoreField.text.trim())], win.t("IMPORTING…"))
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
                        title: win.t("NO OPERATIONS YET")
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
                              ? win.t("snapper has no '") + (win.snapStatus.config || "root") + win.t("' config on this system: nothing to show.")
                              : (win.snapStatus.snappac
                                 ? win.t("snap-pac is installed: every pacman operation already gets a pre/post snapshot.")
                                 : win.t("snap-pac is not installed: the deck takes a snapshot itself before pacman changes."))
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
                                text: win.t("Your snapper config only lets root list snapshots. Load them once with your password, or allow your user to list them (adds you to ALLOW_USERS — reading only; creating still asks for the password).")
                            }
                            RowLayout {
                                spacing: 8
                                MiniBtn { width: Math.max(130, implicitWidth); label: win.t("LOAD (PASSWORD)"); on: !win.sysBusy; onClicked: win.loadSnapshots(true) }
                                MiniBtn { width: Math.max(120, implicitWidth); label: win.t("ALLOW MY USER"); primary: false; on: !win.sysBusy
                                          onClicked: win.runSys(["snapallow"], win.t("ALLOWING…")) }
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
                            title: snapListProc.running ? win.t("LOADING SNAPSHOTS…") : win.t("NO SNAPSHOTS LOADED")
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
                            placeholderText: win.t("description for a new snapshot…")
                        }
                        MiniBtn {
                            width: Math.max(84, implicitWidth); height: 34; label: win.t("CREATE")
                            on: !win.sysBusy
                            onClicked: { win.runSys(["snapcreate", snapDescField.text.trim() || win.t("manual snapshot")], win.t("SNAPSHOTTING…")); snapDescField.text = ""; }
                        }
                        MiniBtn {
                            width: Math.max(110, implicitWidth); height: 34; primary: false
                            label: win.selSnaps.length === 1 ? "DIFF #" + win.selSnaps[0] + win.t(" → NOW") : win.t("DIFF → NOW")
                            on: win.selSnaps.length === 1 && !win.sysBusy
                            onClicked: win.runSys(["snapdiff", String(win.selSnaps[0])], win.t("COMPARING…"))
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
                                return win.t("Auto-cleanup ") + (l.CLEANUP_TIMER === "enabled" ? win.t("runs hourly") : win.t("is OFF (snapper-cleanup.timer disabled)"))
                                     + win.t(": keeps ") + l.NUMBER_LIMIT + win.t(" numbered snapshots (") + l.NUMBER_LIMIT_IMPORTANT
                                     + win.t(" important), none younger than ") + Math.round(l.NUMBER_MIN_AGE / 60) + " min."
                                     + (l.QGROUP ? "" : win.t(" Space limits need Btrfs quotas (off)."));
                            }
                        }
                        MiniBtn {
                            width: Math.max(116, implicitWidth); height: 34; primary: false
                            label: win.confirmSnapCleanup ? win.t("CONFIRM?") : win.t("CLEANUP NOW")
                            on: !win.sysBusy
                            onClicked: {
                                if (!win.confirmSnapCleanup) { win.confirmSnapCleanup = true; return; }
                                win.runSys(["snapcleanup"], win.t("CLEANING UP…"));
                            }
                        }
                        MiniBtn {
                            width: Math.max(112, implicitWidth); height: 34
                            tint: pal.bad
                            label: win.selSnaps.length === 0 ? win.t("DELETE")
                                 : (win.confirmSnapDelete ? win.t("CONFIRM ") + win.selSnaps.length + "?" : win.t("DELETE (") + win.selSnaps.length + ")")
                            on: win.selSnaps.length > 0 && !win.sysBusy
                            onClicked: {
                                if (!win.confirmSnapDelete) {
                                    win.confirmSnapDelete = true;
                                    win.sysLog = win.t("Will delete snapshot(s): #") + win.selSnaps.join(", #") + win.t("\nClick again to confirm.\n");
                                    return;
                                }
                                win.pendingDelete = win.selSnaps.slice();
                                win.confirmSnapDelete = false;
                                win.runSys(["snapdelete"].concat(win.selSnaps.map(String)), win.t("DELETING…"));
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: win.snapStatus.snapper === true
                        Hint {
                            text: win.snapStatus.grubbtrfs
                                  ? win.t("To go back: reboot, open \"Arch Linux snapshots\" in GRUB (grub-btrfs), boot the snapshot and check everything works, then run  sudo snapper rollback  and reboot.")
                                  : win.t("To go back: boot the snapshot from your boot menu (or a live USB), then run  sudo snapper rollback  and reboot.")
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
                        glyph: ""; label: win.t("RESCAN")
                        on: !win.sysBusy
                        onClicked: { win.sysLog = ""; win.openSystem("clean"); win.scanClean(); }
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: win.t("HISTORY")
                        on: !win.sysBusy
                        onClicked: win.openSystem("history")
                    }
                    BarSep {}
                    ActBtn {
                        glyph: ""; label: win.t("APPS DIR")
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
                    Chip { label: win.t("LIBRARY"); active: win.gameView === "library"; onClicked: win.gameView = "library" }
                    Chip { label: win.t("STATUS");  active: win.gameView === "status";  onClicked: win.gameView = "status" }
                    Chip { label: "SHADERS"; active: win.gameView === "shaders"; onClicked: win.gameView = "shaders" }
                    Chip { label: win.t("BENCH");   active: win.gameView === "bench";   onClicked: win.gameView = "bench" }
                    Chip { label: "PREFIXES"; active: win.gameView === "prefixes"; onClicked: win.gameView = "prefixes" }
                    Chip { label: "FX";      active: win.gameView === "fx";      onClicked: win.openFx() }
                    Chip { label: win.t("HEALTH");  active: win.gameView === "health";  onClicked: win.gameView = "health" }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignRight
                        text: win.t(win.gameStatus); color: pal.dim; font.family: win.mono
                        font.pixelSize: 12; font.letterSpacing: 2; elide: Text.ElideLeft
                    }
                }

                // ---- LIBRARY ----
                // profiles that don't fit this PC (moved from the other one via BACKUP)
                Rectangle {
                    Layout.fillWidth: true
                    visible: win.gameView === "library" && (win.gaudit.issues || []).length > 0
                    implicitHeight: auditCol.implicitHeight + 16
                    radius: 8; color: "#1a150c"; border.color: pal.amber; border.width: 1
                    ColumnLayout {
                        id: auditCol
                        anchors.fill: parent; anchors.margins: 8; spacing: 4
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: pal.amber; font.family: win.mono; font.pixelSize: 11; font.bold: true
                                text: win.t("CHECK FOR THIS PC — ") + (win.gaudit.issues || []).length + win.t(" setting(s) don't fit this ")
                                      + String(win.gaudit.vendor || "").toUpperCase() + win.t(" GPU or aren't set up here yet")
                            }
                            MiniBtn {
                                width: Math.max(90, implicitWidth); height: 28; label: win.t("FIX ALL"); on: !win.gameBusy
                                onClicked: win.runGame(["gaudit", "fix", "all"], win.t("ADJUSTING PROFILES…"))
                            }
                        }
                        Repeater {
                            model: win.gaudit.issues || []
                            delegate: Text {
                                required property var modelData
                                Layout.fillWidth: true; elide: Text.ElideRight
                                color: pal.text; font.family: win.mono; font.pixelSize: 10
                                text: "· " + win.gameName(String(modelData.key).replace(/^[a-z]+:/, "")) + ": "
                                      + (modelData.kind === "env" ? modelData.var + win.t(" is ") + (modelData.vendor === "mesa" ? "Mesa" : modelData.vendor.toUpperCase()) + win.t("-only → remove")
                                         : (modelData.kind === "reshade" ? win.t("ReShade isn't installed in its folder on this PC → set it up")
                                            : win.t("vkBasalt isn't installed here → FX → INSTALL")))
                            }
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.minimumHeight: 110
                    visible: win.gameView === "library"
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    EmptyHint {
                        visible: win.games.length === 0
                        title: gamesProc.running ? win.t("READING YOUR LIBRARY…") : win.t("NO GAMES FOUND")
                        sub: gamesProc.running ? "" : win.t("installed Steam games and Umbral games show up here")
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
                                    text: win.t("NEW"); color: pal.amber
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
                                    Tip { visible: fxBadgeMa.containsMouse; text: win.t("ReShade presets for this game on SweetFX DB — see GAMING → FX") }
                                    MouseArea { id: fxBadgeMa; anchors.fill: parent; hoverEnabled: true }
                                }
                                Text {
                                    visible: modelData.wrapped
                                    text: win.t("◆ DECK"); color: pal.accent
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
                            text: win.selGameSource === "steam" ? win.t("PROFILE") : win.t("GAME")
                            color: pal.text; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 4; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: win.selGameName + (win.selGameSource === "steam" && !win.gp.custom ? win.t("  · default profile") : "")
                            color: pal.dim; font.family: win.mono; font.pixelSize: 11
                        }
                        Text {
                            id: pdbTxt
                            visible: win.selGameSource === "steam" && !!(win.pdb[win.selGameId] || {}).total
                            property var d: win.pdb[win.selGameId] || {}
                            text: String(d.tier || "").toUpperCase() + " · " + d.total + win.t(" reports ↗")
                            color: win.tierColor(d.tier); font.family: win.mono; font.pixelSize: 10; font.bold: true
                            font.underline: pdbMa.containsMouse
                            MouseArea {
                                id: pdbMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: Qt.openUrlExternally("https://www.protondb.com/app/" + win.selGameId)
                            }
                            Tip { visible: pdbMa.containsMouse; text: win.t("ProtonDB: score ") + pdbTxt.d.score + win.t(" · trending ") + pdbTxt.d.trendingTier
                                          + win.t(" · confidence ") + pdbTxt.d.confidence + win.t(". Click to open.") }
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
                                text: (win.selGameObj.umbralKind === "battlenet" ? win.t("Battle.net client")
                                       : (win.selGameObj.umbralKind === "blizzard" ? win.t("Battle.net game") : win.t("Own game")))
                                      + "  ·  " + (win.selGameObj.prefixName || "?") + " prefix (" + (win.selGameObj.compat || "?") + ")"
                                      + "  ·  " + win.playtimeText(win.selGameObj.playtime)
                                      + (win.selGameObj.lastPlayed ? win.t("  ·  last ") + String(win.selGameObj.lastPlayed).substring(0, 10) : "")
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideMiddle; visible: !!win.selGameObj.exe
                                color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                text: String(win.selGameObj.exe || "").replace(win.home, "~")
                            }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                text: win.t("Launch options are set in Umbral. Control Deck adds TEMPS and shaders when Umbral 0.10.0+ starts the game.")
                            }
                            RowLayout {
                                spacing: 6
                                Chip {
                                    label: "TEMPS"; tint: pal.ok; active: win.gp.overlay === true; on: !win.gameBusy
                                    tip: win.t("CPU · GPU temperature line at the top right while the game runs")
                                    onClicked: win.runGame(["gprofile", "set", win.selGame, "overlay=" + !(win.gp.overlay === true)], win.t("SAVING…"))
                                }
                                Chip {
                                    label: "FX"; tint: pal.ok; active: win.gp.fx === true
                                    tip: win.t("Visual shaders (ReShade / vkBasalt) for this game")
                                    onClicked: win.openFx()
                                }
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
                            Text { text: win.t("LAUNCH"); Layout.preferredWidth: 52; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Chip { label: "GAMEMODE"; tint: pal.ok; active: win.gp.gamemode === true; onClicked: win.gpSet("gamemode", !win.gp.gamemode) }
                                Chip { label: win.t("MANGOHUD"); tint: pal.ok; active: win.gp.mangohud === true; onClicked: win.gpSet("mangohud", !win.gp.mangohud) }
                                Chip { label: "FX"; tint: pal.ok; active: win.gp.fx === true; onClicked: win.openFx()
                                       tip: win.t("Visual shaders (vkBasalt): sharpening, anti-aliasing, ReShade presets") }
                                Chip { label: "TEMPS"; tint: pal.ok; active: win.gp.overlay === true; onClicked: win.gpSet("overlay", !win.gp.overlay)
                                       tip: win.t("A CPU · GPU temperature line at the top right while the game runs (click-through, closes with the game)") }
                                Chip { label: win.t("IO PRIORITY"); tint: pal.ok; active: win.gp.ionice === true; onClicked: win.gpSet("ionice", !win.gp.ionice)
                                       tip: win.t("ionice best-effort level 0 for the game") }
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
                                Field { id: gPrefix; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: win.t("before the game, e.g. gamescope -f --") }
                                Text { text: "ARGS"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                Field { id: gArgs; Layout.fillWidth: true; font.pixelSize: 11; placeholderText: win.t("after the game, e.g. -novid") }
                            }
                            Text { text: "PROTON"; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                   Layout.alignment: Qt.AlignTop; Layout.topMargin: 6 }
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                Chip {
                                    label: win.t("STEAM DEFAULT"); active: win.selGameCompat === ""
                                    on: !win.gameBusy; tip: win.t("Steam must be closed to change it")
                                    onClicked: win.runGame(["steamcompat", win.selGameId, "default"], win.t("SETTING PROTON…"))
                                }
                                Repeater {
                                    model: win.tools
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.display; active: win.selGameCompat === modelData.name
                                        on: !win.gameBusy; tip: win.t("Steam must be closed to change it")
                                        onClicked: win.runGame(["steamcompat", win.selGameId, modelData.name], win.t("SETTING PROTON…"))
                                    }
                                }
                            }
                            // FSR 4 / DLSS / XeSS upgrades (GE-Proton, Proton-CachyOS)
                            Text { text: win.t("UPSCALE"); color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                   Layout.alignment: Qt.AlignTop; Layout.topMargin: 6 }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                Flow {
                                    Layout.fillWidth: true; spacing: 6
                                    visible: (win.ups.options || []).some(function (o) { return o.available || o.on; })
                                    Repeater {
                                        model: win.ups.options || []
                                        delegate: Chip {
                                            required property var modelData
                                            property bool isOn: win.envValue(modelData.var) === "1"
                                            label: (isOn ? "✓ " : "") + win.t(modelData.label)
                                            tint: pal.ok; active: isOn
                                            on: modelData.available || isOn
                                            tip: modelData.available
                                                 ? (modelData.id === "fsr4" ? win.t("The game's FSR 3.1 runs as FSR 4 (AMD's ML upscaler). Proton downloads the DLL. SAVE to apply.")
                                                    : modelData.id === "optifsr4"
                                                      ? win.t("OptiScaler takes over the game's DLSS / XeSS / FSR and renders it with FSR 4 — pick that upscaler in the game's settings. Proton downloads everything; nothing to install.")
                                                        + (win.ups.preferDirect ? win.t(" This game has FSR 3.1: the plain FSR 4 chip is simpler.") : "")
                                                        + win.t(" Its menu: INSERT (Page Down if INSERT is your shader key).")
                                                    : win.t("Proton swaps in the newest ") + modelData.label.replace(" (newest)", "") + win.t(" DLL. SAVE to apply."))
                                                 : win.t(modelData.why)
                                            onClicked: win.toggleEnvSet(modelData.set, isOn)
                                        }
                                    }
                                    Chip {
                                        visible: (win.ups.options || []).some(function (o) { return o.available && (o.id === "fsr4" || o.id === "dlss"); })
                                        property string iv: (win.ups.options || []).some(function (o) { return o.id === "fsr4" && o.available; }) ? "PROTON_FSR4_INDICATOR" : "PROTON_DLSS_INDICATOR"
                                        label: (win.envValue(iv) === "1" ? "✓ " : "") + win.t("ON-SCREEN CHECK"); active: win.envValue(iv) === "1"
                                        tip: win.t("Shows the upscaler's own watermark in game, to confirm the upgrade is active")
                                        onClicked: win.toggleEnv(iv)
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    // nothing applies: one line, the reasons on hover
                                    property bool none: !(win.ups.options || []).some(function (o) { return o.available || o.on; })
                                    MouseArea { id: upsMa; anchors.fill: parent; hoverEnabled: true; visible: parent.none }
                                    Tip { visible: upsMa.containsMouse; text: (win.ups.options || []).map(function (o) { return win.t(o.label) + ": " + win.t(o.why); }).join("\n") }
                                    text: !win.ups.ships ? "" : none ? win.t("No upscaler upgrade for this game ⓘ") :
                                          win.t("Ships: ") + ([win.ups.ships.fsr31dx12 ? "FSR 3.1 (DX12)" : "", win.ups.ships.fsr31vk ? "FSR 3.1 (Vulkan)" : "",
                                                        win.ups.ships.dlss ? "DLSS" : "", win.ups.ships.xess ? "XeSS" : ""]
                                                       .filter(function (x) { return x; }).join(" · ") || win.t("no swappable upscaler DLL"))
                                          + win.t("  ·  Proton: ") + (win.ups.proton && win.ups.proton.tool ? win.ups.proton.tool : win.t("Steam default"))
                                          + ((win.ups.proton || {}).supports && win.ups.proton.supports.length ? win.t(" (supports upgrades)") : win.t(" (no upgrades: GE-Proton or Proton-CachyOS do)"))
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
                                Text { text: win.t("★ SUGGESTED FOR THIS PC"); color: pal.amber; font.family: win.mono; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    text: !win.sug.index || !win.sug.reports ? "" :
                                          (win.sug.gpuName || "") + " · " + (win.sug.similarReports > 0 ? win.sug.similarReports + win.t(" similar players")
                                          : (win.sug.vendorReports > 0 ? win.sug.vendorReports + " " + String(win.sug.vendor).toUpperCase() + win.t(" players") : win.sug.reports + win.t(" players")))
                                }
                                Chip {
                                    visible: win.sugOthers.length > 0
                                    label: win.sugExpanded ? win.t("LESS ▴") : "+" + win.sugOthers.length + win.t(" MORE ▾")
                                    onClicked: win.sugExpanded = !win.sugExpanded
                                }
                                Chip {
                                    visible: win.pdbStat.present !== true || win.pdbStat.stale === true
                                    label: win.pdbStat.present === true ? win.t("UPDATE DATA") : win.t("GET DATA (70 MB)")
                                    on: !win.gameBusy; tint: pal.amber; active: true
                                    tip: win.t("ProtonDB's open data (every game's reported launch options), indexed locally to ≈5 MB")
                                    onClicked: win.runGame(["pdbindex", "update"], win.t("INDEXING PROTONDB DATA…"))
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
                                text: win.pdbStat.present !== true ? win.t("Get the data once to see what players with hardware like yours use.")
                                      : (!win.sug.index ? "" : (win.sug.reports === 0 ? win.t("No ProtonDB report with launch options for this game yet.")
                                         : (win.sugRecommended.length + win.sugOthers.length === 0 ? win.t("Players don't agree on any launch option for this game.")
                                            : (win.sugRecommended.length === 0 ? win.t("Nothing is used by enough similar players to recommend it. ") : "")
                                              + win.t("Click to add, then SAVE · % of players who say it works · ProtonDB (ODbL) ") + win.pdbStat.date)))
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
                                  : (win.selGameWrapped ? win.t("● Launched through Control Deck")
                                     : win.t("○ Steam options: ") + (win.selGameLaunch || "none"))
                            Tip { visible: stMa.containsMouse && parent.text !== ""; text: win.selGameWrapped ? win.t("The profile applies on every launch from Steam.")
                                          : win.t("USE IN STEAM moves these options into the profile (Steam must be closed).") }
                            MouseArea { id: stMa; anchors.fill: parent; hoverEnabled: true }
                        }
                        MiniBtn {
                            width: Math.max(70, implicitWidth); height: 32; primary: false; label: win.t("RESET")
                            visible: win.selGameSource === "steam" && win.gp.custom === true
                            on: !win.gameBusy
                            onClicked: win.runGame(["gprofile", "reset", win.selGame], win.t("RESETTING…"))
                        }
                        MiniBtn {
                            width: Math.max(120, implicitWidth); height: 32; primary: false
                            visible: win.selGameSource === "steam"
                            label: win.selGameWrapped ? win.t("RESTORE STEAM") : win.t("USE IN STEAM")
                            on: !win.gameBusy
                            onClicked: win.runGame(["steamwrap", win.selGameId, win.selGameWrapped ? "off" : "on"],
                                                   win.selGameWrapped ? win.t("RESTORING…") : win.t("WRAPPING…"))
                        }
                        MiniBtn {
                            width: Math.max(76, implicitWidth); height: 32; label: win.t("SAVE")
                            visible: win.selGameSource === "steam"
                            on: !win.gameBusy
                            onClicked: win.saveGameProfile()
                        }
                        MiniBtn {
                            width: Math.max(76, implicitWidth); height: 32; label: win.t("▶ PLAY"); tint: pal.ok
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
                        text: !win.pfx.prefixes ? "" : win.pfx.prefixes.length + win.t(" prefixes · ") + win.human(win.pfx.total)
                              + ((win.pfx.orphanBytes || 0) > 0 ? " · " + win.human(win.pfx.orphanBytes) + win.t(" in orphans (no game uses them)") : "")
                              + " · " + win.pfxBackups.length + win.t(" backups in ~/control-deck-backups/prefixes")
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.pfx.prefixes || win.pfx.prefixes.length === 0
                            title: pfxProc.running ? win.t("LOOKING FOR PREFIXES…") : win.t("NO WINE/PROTON PREFIXES FOUND")
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
                                            Text { text: win.t(modelData.name); color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true
                                                   elide: Text.ElideRight; Layout.maximumWidth: 300 }
                                            Text { text: win.human(modelData.size); color: pal.amber; font.family: win.mono; font.pixelSize: 10 }
                                            Text { visible: modelData.orphan; text: win.t("ORPHAN"); color: pal.amber; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.running; text: win.t("IN USE"); color: pal.ok; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.kind === "tool" || modelData.kind === "shared"; text: modelData.kind === "tool" ? win.t("TOOL") : win.t("SHARED")
                                                   color: pal.dim; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideMiddle
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: (modelData.version || "?") + "  ·  " + modelData.arch + win.t("  ·  used ") + win.dateOfEpoch(modelData.lastUsed)
                                                  + "  ·  " + modelData.path.replace(win.home, "~")
                                        }
                                    }
                                    MiniBtn { width: Math.max(64, implicitWidth); label: win.t("BACKUP"); primary: false; on: !win.gameBusy && !modelData.running
                                              onClicked: win.runGame(["prefix", "backup", modelData.path], win.t("BACKING UP…")) }
                                    MiniBtn { width: Math.max(60, implicitWidth); label: win.t("CLONE"); primary: false; on: !win.gameBusy && !modelData.running
                                              onClicked: win.runGame(["prefix", "clone", modelData.path], win.t("CLONING…")) }
                                    MiniBtn {
                                        width: Math.max(80, implicitWidth); tint: pal.bad
                                        property string key: "pfx:" + modelData.path
                                        // stands out only where deleting is the suggestion (orphans) or being confirmed
                                        primary: modelData.orphan || win.confirmShader === key
                                        label: win.confirmShader === key ? win.t("CONFIRM?") : win.t("DELETE")
                                        on: !win.gameBusy && !modelData.running && modelData.kind !== "tool" && modelData.kind !== "shared"
                                        onClicked: win.shaderAction(["prefix", "delete", modelData.path], key, win.t("BACKING UP + DELETING…"))
                                    }
                                }
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Hint {
                            text: win.t("DELETE always makes a backup first (a Steam game's prefix is recreated on its next launch — saves kept only in the prefix would be lost without it). CLONE copies the Wine prefix to ~/Games/prefixes (instant on Btrfs). Restore a backup: control-deck prefix restore <backup> <folder>.")
                        }
                        MiniBtn { width: Math.max(100, implicitWidth); label: win.t("BACKUPS ↗"); primary: false; onClicked: pfxOpenProc.running = true }
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
                        EmptyHint { title: win.selGame === "" ? win.t("PICK A GAME IN LIBRARY FIRST") : win.t("A/B BENCHMARKS ARE FOR STEAM GAMES") }
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
                            Text { text: win.t("MEASURE"); color: pal.dim; font.family: win.mono; font.pixelSize: 9 }
                            Repeater {
                                model: [30, 60, 120, 300]
                                delegate: Chip { required property int modelData; label: modelData + " s"; active: win.bench.duration === modelData
                                                 onClicked: win.saveBench(["duration=" + modelData]) }
                            }
                            Text { text: win.t("AFTER"); color: pal.dim; font.family: win.mono; font.pixelSize: 9; Layout.leftMargin: 8 }
                            Repeater {
                                model: [5, 15, 30, 60]
                                delegate: Chip { required property int modelData; label: modelData + " s"; active: win.bench.delay === modelData
                                                 onClicked: win.saveBench(["delay=" + modelData]) }
                            }
                            Item { Layout.fillWidth: true }
                            MiniBtn { width: Math.max(70, implicitWidth); label: win.t("SAVE"); on: !win.gameBusy; onClicked: win.saveBench([]) }
                            MiniBtn { width: Math.max(70, implicitWidth); label: win.t("RUN A"); tint: pal.accent; on: !win.gameBusy && win.selGameWrapped
                                      onClicked: win.runBench("A") }
                            MiniBtn { width: Math.max(70, implicitWidth); label: win.t("RUN B"); tint: pal.pink; on: !win.gameBusy && win.selGameWrapped
                                      onClicked: win.runBench("B") }
                        }
                        Hint {
                            text: !win.selGameWrapped ? win.t("The game must launch through Control Deck: LIBRARY → USE IN STEAM first.")
                                  : win.t("RUN starts the game from Steam; MangoHud records every frame after the delay, for the measured time. Play the same scene in both runs, quit the game, then REFRESH. Variants changing Proton need Steam closed.")
                                    + (win.bench.originalProton ? win.t("  Proton was changed for a run: RESTORE PROTON when done.") : "")
                        }

                        // results
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 150
                            radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                            EmptyHint {
                                visible: !win.bench.results || (!win.bench.results.A && !win.bench.results.B)
                                title: win.t("NO RUNS YET")
                            }
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 10; spacing: 12
                                visible: !!win.bench.results && (!!win.bench.results.A || !!win.bench.results.B)
                                GridLayout {
                                    columns: 4; rowSpacing: 4; columnSpacing: 12
                                    Layout.alignment: Qt.AlignTop
                                    Repeater {
                                        model: [["", "A", "B", win.t("Δ B vs A")],
                                                [win.t("Avg FPS"), "avgFps", "avgFps", "avgFps"], [win.t("1% low"), "low1", "low1", "low1"],
                                                [win.t("0.1% low"), "low01", "low01", ""], [win.t("p99 frame ms"), "p99ms", "p99ms", "p99ms"],
                                                [win.t("Spikes"), "spikes", "spikes", ""], [win.t("CPU load %"), "cpuLoad", "cpuLoad", ""],
                                                [win.t("GPU load %"), "gpuLoad", "gpuLoad", ""], [win.t("GPU max °C"), "gpuTempMax", "gpuTempMax", ""],
                                                [win.t("Frames"), "frames", "frames", ""]]
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
                            MiniBtn { width: Math.max(110, implicitWidth); label: win.t("REFRESH RESULTS"); primary: false; on: !win.gameBusy; onClicked: benchProc.running = true }
                            MiniBtn { width: Math.max(110, implicitWidth); label: win.t("RESTORE PROTON"); primary: false; visible: !!win.bench.originalProton; on: !win.gameBusy
                                      onClicked: win.runGame(["bench", "restore", win.selGame], win.t("RESTORING…")) }
                            MiniBtn { width: Math.max(70, implicitWidth); label: win.t("CLEAR"); tint: pal.bad; primary: false; on: !win.gameBusy
                                      onClicked: win.runGame(["bench", "clear", win.selGame], win.t("CLEARING…")) }
                        }
                    }
                }

                // ---- FX (visual shaders) ----
                // FX: this game / my whole library (fixed above the scrolling part)
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: win.gameView === "fx"
                    Chip { label: win.t("THIS GAME"); active: win.fxScope === "game"; onClicked: win.fxScope = "game" }
                    Chip {
                        label: win.t("MY LIBRARY") + (win.fxEligible > 0 ? "  ·  " + win.fxEligible + win.t(" to set up") : "")
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
                                visible: !win.fxGame
                                title: win.t("PICK A STEAM OR UMBRAL GAME IN LIBRARY")
                            }

                            // header: game · GPU · vkBasalt
                            RowLayout {
                                Layout.fillWidth: true; spacing: 9
                                visible: win.fxGame
                                Rectangle { width: 7; height: 7; color: pal.accent; Layout.alignment: Qt.AlignVCenter }
                                Text { text: win.t("VISUAL SHADERS"); color: pal.text; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 4; font.bold: true }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: win.selGameName; color: pal.dim; font.family: win.mono; font.pixelSize: 11 }
                                Text {
                                    text: (win.fx.gpu || "") + "  ·  " + (win.fxReshade
                                          ? (win.fx.reshade && win.fx.reshade.version ? "ReShade " + win.fx.reshade.version : win.t("ReShade not installed"))
                                          : (win.fx.vkbasalt ? "vkBasalt " + win.fx.version : win.t("vkBasalt not installed")))
                                    color: (win.fxReshade ? (win.fx.reshade || {}).ready : win.fx.vkbasalt) ? pal.dim : pal.amber
                                    font.family: win.mono; font.pixelSize: 10
                                }
                            }

                            // a game no shader tool can hook (2D GDI, e.g. RPG Maker XP)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.fxGame && win.fx.recommended === "none"
                                implicitHeight: noFxTxt.implicitHeight + 16
                                radius: 8; color: pal.card; border.color: pal.amber; border.width: 1
                                Text {
                                    id: noFxTxt
                                    anchors.fill: parent; anchors.margins: 8; wrapMode: Text.WordWrap
                                    color: pal.amber; font.family: win.mono; font.pixelSize: 11
                                    text: win.t("This game is drawn in 2D with GDI (RPG Maker style), not with DirectX, OpenGL or Vulkan: neither ReShade nor vkBasalt can hook it. TEMPS still works (LIBRARY).")
                                }
                            }

                            // guided steps (live state of this game)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.fxGame && !!win.fx.gpu && win.fx.recommended !== "none"
                                implicitHeight: guideCol.implicitHeight + 16
                                radius: 8; color: pal.card; border.width: 1
                                border.color: win.fxStepsDone === 5 ? pal.ok : pal.accent
                                ColumnLayout {
                                    id: guideCol
                                    anchors.fill: parent; anchors.margins: 8; spacing: 5
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Text {
                                            text: win.fxStepsDone === 5 ? win.t("● READY") : win.t("STEPS")
                                            color: win.fxStepsDone === 5 ? pal.ok : pal.text
                                            font.family: win.mono; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.family: win.mono; font.pixelSize: 10
                                            color: win.fxStepsDone === 5 ? pal.text : pal.dim
                                            text: win.fxStepsDone === 5
                                                  ? (win.fxReshade ? "ReShade" : "vkBasalt") + "  ·  " + (win.fxCur.name || "") + " (" + (win.fxCur.applied || 0) + win.t(" effects)")
                                                    + win.t("  ·  menu ") + (win.fx.key || "Home").toUpperCase()
                                                    + (win.fxReshade && (win.fx.effectsKey || "End") !== "None" ? win.t("  ·  on/off ") + (win.fx.effectsKey || "End").toUpperCase() : "")
                                                  : win.fxStepsDone + win.t(" of 5 done — next: ") + ((win.fxSteps.filter(function (s) { return !s[0]; })[0] || ["", ""])[1])
                                        }
                                        Text {
                                            visible: win.fxStepsDone === 5 && (win.fxCur.skipped || []).length > 0
                                            text: "⚠ " + (win.fxCur.skipped || []).length + win.t(" skipped"); color: pal.amber
                                            font.family: win.mono; font.pixelSize: 10
                                            MouseArea { id: skipMa; anchors.fill: parent; hoverEnabled: true }
                                            Tip { visible: skipMa.containsMouse; text: (win.fxCur.skipped || []).map(function (x) { return x.effect + " — " + x.why; }).join("\n") }
                                        }
                                        Chip {
                                            visible: win.fxStepsDone === 5 && win.fxCur.source === "sfx"
                                            label: "PRESET ↗"; onClicked: Qt.openUrlExternally(win.fxCur.url)
                                        }
                                        Chip {
                                            visible: win.fxStepsDone === 5; label: "OFF"; on: !win.gameBusy
                                            tip: win.t("Remove the shaders from this game")
                                            onClicked: win.runGame(["fx", "set", win.selGame, "off"], win.t("TURNING OFF…"))
                                        }
                                        Chip { label: win.fxGuideOpen ? win.t("GUIDE ▴") : win.t("GUIDE ▾"); tip: win.t("Every step, with what each one does"); onClicked: win.fxGuideOpen = !win.fxGuideOpen }
                                    }
                                    Repeater {
                                        // all steps when opened; otherwise just the next one (none when all is done)
                                        model: win.fxSteps.map(function (s, i) { return { s: s, i: i }; })
                                                   .filter(function (x, n, all) {
                                                       return win.fxGuideOpen
                                                           || (!x.s[0] && all.slice(0, n).every(function (y) { return y.s[0]; }));
                                                   })
                                        delegate: RowLayout {
                                            required property var modelData
                                            property int index: modelData.i
                                            property var step: modelData.s
                                            Layout.fillWidth: true; spacing: 8
                                            property bool next: !step[0] && win.fxSteps.slice(0, index).every(function (s) { return s[0]; })
                                            Text {
                                                text: step[0] ? "✓" : String(index + 1)
                                                Layout.preferredWidth: 14; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignTop
                                                color: step[0] ? pal.ok : (next ? pal.amber : pal.dim)
                                                font.family: win.mono; font.pixelSize: 11; font.bold: true
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 1
                                                Text {
                                                    text: step[1]; font.family: win.mono; font.pixelSize: 11; font.bold: next
                                                    color: step[0] ? pal.dim : (next ? pal.text : pal.dim)
                                                }
                                                Text {
                                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                    text: step[2]; color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                                }
                                            }
                                            // the pending step's own button
                                            MiniBtn {
                                                visible: next && index === 0
                                                width: Math.max(140, implicitWidth); height: 28; label: win.fx.recommended === "vkbasalt" ? win.t("USE VKBASALT ★") : win.t("USE RESHADE ★")
                                                on: !win.gameBusy
                                                onClicked: win.fx.recommended === "vkbasalt"
                                                           ? win.fxApply("mode:vkbasalt", win.t("SWITCHING…"), ["fx", "mode", win.selGame, "vkbasalt"])
                                                           : win.fxApply("mode:reshade", win.t("SETTING UP RESHADE…"), ["fx", "mode", win.selGame, "reshade"])
                                            }
                                            MiniBtn {
                                                visible: next && index === 1
                                                width: Math.max(90, implicitWidth); height: 28; label: win.t("INSTALL"); on: !win.gameBusy
                                                onClicked: win.runGame(win.fxReshade ? ["fx", "reshade", "install"] : ["fx", "install"], win.t("INSTALLING…"))
                                            }
                                            MiniBtn {
                                                visible: next && index === 2 && !win.fxUmbral
                                                width: Math.max(120, implicitWidth); height: 28; label: win.t("USE IN STEAM")
                                                on: !win.gameBusy && !win.fx.steamRunning
                                                onClicked: win.runGame(["steamwrap", win.selGameId, "on"], win.t("WRAPPING…"))
                                            }
                                            Chip {
                                                visible: next && index === 3
                                                label: (win.fx.links || []).length ? win.t("OPEN ") + win.fx.links[0].label + " ↗" : win.t("SEARCH NEXUS ↗")
                                                onClicked: Qt.openUrlExternally((win.fx.links || []).length ? win.fx.links[0].url
                                                    : "https://duckduckgo.com/?q=" + encodeURIComponent("site:nexusmods.com " + win.selGameName + " reshade preset"))
                                            }
                                            MiniBtn {
                                                visible: next && index === 3 && (win.fx.links || []).length > 0
                                                width: Math.max(90, implicitWidth); height: 28; label: win.t("IMPORT…")
                                                on: !win.gameBusy && win.fxReady && !fxPickProc.running
                                                onClicked: fxPickProc.running = true
                                            }
                                        }
                                    }
                                }
                            }

                            // route: ReShade (DLL) or vkBasalt (Vulkan layer)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.fxGame && !!win.fx.gpu && win.fx.recommended !== "none"
                                implicitHeight: fxRoute.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    id: fxRoute
                                    anchors.fill: parent; anchors.margins: 10; spacing: 6
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: win.t("ROUTE"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Chip {
                                            property string k: "mode:reshade"
                                            label: win.fxConfirm === k ? win.t("CONFIRM?") : "RESHADE" + (win.fx.recommended === "reshade" ? "  ★" : "")
                                            tint: pal.ok; active: win.fxReshade
                                            on: !win.gameBusy
                                            tip: win.t("ReShade itself: presets exactly as made (depth effects too) and its in-game menu. For D3D9–12 and OpenGL games.")
                                            onClicked: if (!win.fxReshade) win.fxApply(k, win.t("SETTING UP RESHADE…"), ["fx", "mode", win.selGame, "reshade"])
                                        }
                                        Chip {
                                            property string k: "mode:vkbasalt"
                                            label: win.fxConfirm === k ? win.t("CONFIRM?") : "VKBASALT" + (win.fx.recommended === "vkbasalt" ? "  ★" : "")
                                            tint: pal.ok; active: !win.fxReshade
                                            on: !win.gameBusy
                                            tip: win.t("A Vulkan layer: simplest, no files in the game folder; presets are converted and effects that need depth are skipped.")
                                            onClicked: if (win.fxReshade) win.fxApply(k, win.t("SWITCHING…"), ["fx", "mode", win.selGame, "vkbasalt"])
                                        }
                                        // why the ★ one: one line, the full reasons on hover
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: "★ " + win.t(((win.fx.advice || {}).reasons || [""])[0] || "")
                                            MouseArea { id: whyMa; anchors.fill: parent; hoverEnabled: true }
                                            Tip { visible: whyMa.containsMouse; text: ((win.fx.advice || {}).reasons || []).map(win.t).join("\n\n") }
                                        }
                                        Chip {
                                            label: win.fxDetails ? win.t("SETTINGS ▴") : win.t("SETTINGS ▾")
                                            tip: win.t("Executable, graphics API and the in-game keys")
                                            onClicked: win.fxDetails = !win.fxDetails
                                        }
                                    }
                                    // ReShade: which .exe, which API
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxReshade && win.fxDetails
                                        Text { text: win.t("EXECUTABLE"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Flow {
                                            Layout.fillWidth: true; spacing: 6
                                            Repeater {
                                                model: (win.fx.reshade || {}).exes || []
                                                delegate: Chip {
                                                    required property var modelData
                                                    label: modelData.rel + "  ·  " + modelData.arch + "-bit"
                                                    active: !!win.fxRsGame && win.fxRsGame.exe === modelData.path
                                                    on: !win.gameBusy
                                                    tip: win.t("Install ReShade next to this .exe (detected API: ") + modelData.api + ")"
                                                    onClicked: win.runGame(["fx", "mode", win.selGame, "reshade", modelData.path], win.t("MOVING RESHADE…"))
                                                }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxReshade && !!win.fxRsGame && win.fxDetails
                                        Text { text: "HOOKS"; Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["dxgi", "DXGI · DX10–12"], ["d3d9", "D3D9"], ["opengl32", "OPENGL"]]
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData[1]; active: !!win.fxRsGame && win.fxRsGame.api === modelData[0]
                                                on: !win.gameBusy
                                                tip: win.t("Only change it if ReShade doesn't show up in game")
                                                onClicked: win.runGame(["fx", "mode", win.selGame, "reshade", win.fxRsGame.exe, modelData[0]], win.t("SWITCHING API…"))
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: "✓ " + (win.fxRsGame ? win.fxRsGame.api : "") + win.t(".dll + d3dcompiler_47 linked in the game folder · OFF removes them")
                                        }
                                    }
                                    // the in-game key (ReShade's menu / vkBasalt on-off), one for all games
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxDetails
                                        Text { text: win.t("MENU KEY"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["Home", "HOME", ""], ["Insert", "INSERT", ""], ["F10", "F10", ""], ["F11", "F11", ""],
                                                    ["F12", "F12", win.t("Steam takes screenshots with F12 by default")]]
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData[1]; active: (win.fx.key || "Home") === modelData[0]
                                                on: !win.gameBusy; tip: modelData[2]
                                                onClicked: win.runGame(["fx", "key", modelData[0]], win.t("SETTING KEY…"))
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: win.fxReshade ? win.t("opens ReShade's menu in game") : win.t("turns the effects on/off in game")
                                        }
                                    }
                                    // ReShade: one key that switches every effect on/off (the mod guides' "END")
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        visible: win.fxReshade && win.fxDetails
                                        Text { text: win.t("ON/OFF KEY"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["End", "END", win.t("The key most preset guides suggest")], ["F9", "F9", win.t("Some games quick-load with F9")], ["None", win.t("NONE"), win.t("No key: effects stay on")]]
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData[1]; active: (win.fx.effectsKey || "End") === modelData[0]
                                                on: !win.gameBusy; tip: modelData[2]
                                                onClicked: win.runGame(["fx", "effectskey", modelData[0]], win.t("SETTING KEY…"))
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: win.t("switches all effects on/off in game — compare, or drop them in heavy scenes")
                                        }
                                    }
                                    // must launch through the wrapper
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        visible: win.fx.wrapped === false && (win.fxReshade || win.fxActive)
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            color: pal.amber; font.family: win.mono; font.pixelSize: 10
                                            text: win.fxUmbral ? win.t("⚠ Umbral 0.10.0 or newer is needed: it asks the deck for shaders and TEMPS before starting the game. Update Umbral.")
                                                  : win.t("⚠ This game doesn't launch through Control Deck yet, so the shaders won't load. ") + (win.fx.steamRunning ? win.t("Close Steam, then press USE IN STEAM.") : win.t("Press USE IN STEAM."))
                                        }
                                        MiniBtn {
                                            visible: !win.fxUmbral
                                            width: Math.max(120, implicitWidth); height: 28; label: win.t("USE IN STEAM")
                                            on: !win.gameBusy && !win.fx.steamRunning
                                            onClicked: win.runGame(["steamwrap", win.selGameId, "on"], win.t("WRAPPING…"))
                                        }
                                    }
                                }
                            }

                            // one-time setup (ReShade: no password, all user files)
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.fxGame && win.fxReshade && !!win.fx.reshade && win.fx.reshade.ready && win.fx.reshade.update
                                implicitHeight: fxRsSetup.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.accent; border.width: 1
                                RowLayout {
                                    id: fxRsSetup
                                    anchors.fill: parent; anchors.margins: 10; spacing: 10
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        color: pal.text; font.family: win.mono; font.pixelSize: 11
                                        text: win.fx.reshade && win.fx.reshade.update
                                              ? "ReShade " + win.fx.reshade.latest + win.t(" is out (you have ") + win.fx.reshade.version + win.t("). Games pick it up on their next launch.")
                                              : win.t("One-time setup, no password: ReShade ") + ((win.fx.reshade || {}).latest || "") + win.t(" from reshade.me, d3dcompiler_47 (Mozilla's Firefox installer, checksum-verified, like winetricks) and the standard shaders.")
                                    }
                                    MiniBtn {
                                        width: Math.max(96, implicitWidth); height: 32; label: win.fx.reshade && win.fx.reshade.update ? win.t("UPDATE") : win.t("INSTALL")
                                        on: !win.gameBusy
                                        onClicked: win.runGame(["fx", "reshade", "install"], win.t("DOWNLOADING RESHADE…"))
                                    }
                                }
                            }

                            // one-time setup
                            Rectangle {
                                Layout.fillWidth: true
                                // only when it says something the steps don't: chaotic-aur missing, or half installed
                                visible: win.fxGame && !win.fxReshade && !!win.fx.gpu
                                         && ((win.fx.chaotic === false && !win.fx.vkbasalt) || (win.fx.vkbasalt && (!win.fx.vkbasalt32 || !win.fx.shadersInstalled)))
                                implicitHeight: fxSetup.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.accent; border.width: 1
                                RowLayout {
                                    id: fxSetup
                                    anchors.fill: parent; anchors.margins: 10; spacing: 10
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        color: pal.text; font.family: win.mono; font.pixelSize: 11
                                        text: win.fx.chaotic === false && !win.fx.vkbasalt
                                              ? win.t("vkBasalt comes from chaotic-aur, which isn't enabled here. Enable it (or build vkbasalt + lib32-vkbasalt from the AUR), then come back.")
                                              : win.t("One-time setup: vkBasalt (the Vulkan layer that draws the effects, 64 + 32-bit, from chaotic-aur) and the standard ReShade shaders (official packages, ~0.5 MB). Works the same on AMD and NVIDIA.")
                                    }
                                    MiniBtn {
                                        visible: win.fx.chaotic !== false || win.fx.vkbasalt
                                        width: Math.max(96, implicitWidth); height: 32; label: win.t("INSTALL")
                                        on: !win.gameBusy
                                        onClicked: win.runGame(["fx", "install"], win.t("INSTALLING SHADERS…"))
                                    }
                                }
                            }

                            // online / anti-cheat warning
                            Rectangle {
                                Layout.fillWidth: true
                                visible: win.fxGame && !!win.fx.online && win.fx.online.level !== "none"
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
                                          ? win.t("⚠ ONLINE GAME WITH ANTI-CHEAT (") + win.fx.online.anticheats.join(", ") + win.t("). Shaders hook into the game's rendering; an anti-cheat may treat that as a modification and ban the account. Use them only if you accept that risk — applying one here asks for confirmation.")
                                          : win.t("⚠ Online multiplayer game: some online games forbid visual mods in their rules. Check before using shaders there.")
                                }
                            }

                            // route + what's active
                            Rectangle {
                                Layout.fillWidth: true
                                visible: false   // shown in the READY strip now
                                implicitHeight: fxActCol.implicitHeight + 20
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    id: fxActCol
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
                                                  ? win.t("● ACTIVE: ") + win.fxCur.name + "  ·  " + win.fxCur.applied + win.t(" effect") + (win.fxCur.applied > 1 ? "s" : "")
                                                    + ((win.fxCur.skipped || []).length ? "  ·  " + win.fxCur.skipped.length + win.t(" skipped") : "")
                                                  : win.t("○ No shaders on this game")
                                        }
                                        Chip {
                                            visible: win.fxActive && win.fxCur.source === "sfx"
                                            label: "PRESET ↗"; onClicked: Qt.openUrlExternally(win.fxCur.url)
                                        }
                                        MiniBtn {
                                            visible: win.fxActive
                                            width: Math.max(60, implicitWidth); height: 28; primary: false; label: "OFF"
                                            on: !win.gameBusy
                                            onClicked: win.runGame(["fx", "set", win.selGame, "off"], win.t("TURNING OFF…"))
                                        }
                                    }
                                    Repeater {
                                        model: win.fxActive ? (win.fxCur.skipped || []) : []
                                        delegate: Text {
                                            required property var modelData
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            text: "✗ " + modelData.effect + " — " + modelData.why
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                        }
                                    }
                                    Text {
                                        visible: win.fxActive
                                        text: win.fxReshade ? win.t("In game: ") + (win.fx.key || "Home").toUpperCase() + win.t(" opens ReShade's menu — tweak values, switch effects on/off; changes are saved to this game's preset.")
                                                            : win.t("In game: ") + (win.fx.key || "Home").toUpperCase() + win.t(" turns the effects on/off to compare.")
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    }
                                }
                            }

                            // quick looks (vkBasalt's own effects) + presets from the internet
                            Rectangle {
                                // grows only when there is a preset list to show
                                Layout.fillWidth: true
                                Layout.preferredHeight: win.fxPresets.length > 0 ? 400 : fxLooksCol.implicitHeight + 20
                                visible: win.fxGame && !!win.fx.route && (win.fx.route.ok || win.fxReshade) && win.fx.recommended !== "none"
                                radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                                ColumnLayout {
                                    id: fxLooksCol
                                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: win.t("QUICK LOOK"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: [["sharpen", win.t("SHARPEN"), win.t("AMD FidelityFX CAS: crisper image, almost free")],
                                                    ["sharpen-aa", win.t("SHARPEN + AA"), win.t("SMAA anti-aliasing, then CAS sharpening")],
                                                    ["fxaa", "FXAA", win.t("Light anti-aliasing, softer edges")],
                                                    ["clarity", win.t("CLARITY"), win.t("Denoised luma sharpening: detail without boosting grain")]]
                                            delegate: Chip {
                                                required property var modelData
                                                property string k: "builtin:" + modelData[0]
                                                label: win.fxConfirm === k ? win.t("CONFIRM?") : modelData[1]
                                                tint: pal.ok; tip: modelData[2]
                                                active: win.fxActive && win.fxCur.source === "builtin" && win.fxCur.name === modelData[0]
                                                on: !win.gameBusy && win.fxReady
                                                onClicked: win.fxApply(k, win.t("APPLYING…"))
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: win.t("FROM A FILE"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Chip {
                                            label: fxPickProc.running || fxImpListProc.running ? win.t("OPENING…") : win.t("IMPORT…")
                                            tint: pal.ok; on: !win.gameBusy && win.fxReady && !fxPickProc.running
                                            tip: win.t("A preset you downloaded (Nexus Mods…): zip, 7z, rar or .ini. Its own shaders come along; its ReShade.ini/DLLs are ignored.")
                                            onClicked: fxPickProc.running = true
                                        }
                                        Chip {
                                            label: win.t("SEARCH NEXUS ↗"); tip: win.t("Web search for this game's ReShade presets on Nexus Mods")
                                            onClicked: Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent("site:nexusmods.com " + win.selGameName + " reshade preset"))
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: win.t("download it, then IMPORT")
                                        }
                                    }
                                    // preset pages saved for this game (can be saved before installing it)
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text { text: win.t("SAVED"); Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                        Repeater {
                                            model: win.fx.links || []
                                            delegate: Chip {
                                                required property var modelData
                                                label: modelData.label + " ↗"; tip: modelData.url + win.t(" — right-click removes it")
                                                onClicked: Qt.openUrlExternally(modelData.url)
                                                MouseArea {
                                                    anchors.fill: parent; acceptedButtons: Qt.RightButton
                                                    onClicked: win.runGame(["fx", "link", "rm", win.selGame, modelData.url], win.t("REMOVING LINK…"))
                                                }
                                            }
                                        }
                                        Text {
                                            visible: (win.fx.links || []).length === 0 && !win.fxAddLink
                                            Layout.fillWidth: true; color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: win.t("preset pages you keep for this game (e.g. from Nexus)")
                                        }
                                        Item { Layout.fillWidth: true; visible: (win.fx.links || []).length > 0 && !win.fxAddLink }
                                        Chip { visible: !win.fxAddLink; label: win.t("+ LINK"); tip: win.t("Keep a preset page for this game"); onClicked: win.fxAddLink = true }
                                        Field {
                                            id: fxLinkField; Layout.fillWidth: true; font.pixelSize: 10
                                            visible: win.fxAddLink
                                            placeholderText: win.t("paste a preset page (Nexus…) to keep it here")
                                            onAccepted: if (text.trim()) { win.runGame(["fx", "link", "add", win.selGame, text.trim()], win.t("SAVING LINK…")); text = ""; }
                                        }
                                        Chip {
                                            visible: win.fxAddLink
                                            label: win.t("SAVE"); on: fxLinkField.text.trim().indexOf("https://") === 0 && !win.gameBusy
                                            onClicked: { win.runGame(["fx", "link", "add", win.selGame, fxLinkField.text.trim()], win.t("SAVING LINK…")); fxLinkField.text = ""; win.fxAddLink = false; }
                                        }
                                    }
                                    // notes of a saved page (e.g. the preset author's install guide, mapped to the deck)
                                    Repeater {
                                        model: (win.fx.links || []).filter(function (l) { return !!l.notes; })
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: noteTxt.implicitHeight + 14
                                            radius: 6; color: pal.panel; border.color: pal.border; border.width: 1
                                            Text {
                                                id: noteTxt
                                                anchors.fill: parent; anchors.margins: 7
                                                text: modelData.label + " — " + modelData.notes
                                                wrapMode: Text.WordWrap; color: pal.text; font.family: win.mono; font.pixelSize: 10
                                            }
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
                                                             win.fxApply("file:" + f, win.t("IMPORTING PRESET…"), ["fx", "import", win.selGame, f, pth]); }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Text {
                                            text: "PRESETS ⓘ"; Layout.preferredWidth: 92; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1
                                            MouseArea { id: presetsMa; anchors.fill: parent; hoverEnabled: true }
                                            Tip { visible: presetsMa.containsMouse; text: win.t("From SweetFX Settings DB (sfx.thelazy.net), made for ReShade") + (win.fxReshade ? "." : win.t("; in vkBasalt, effects that need the depth buffer are skipped.")) + win.t(" Shaders come from the packages the official ReShade installer lists.") }
                                        }
                                        Field {
                                            id: fxQuery; Layout.fillWidth: true; font.pixelSize: 11
                                            placeholderText: win.t("game name on SweetFX Settings DB")
                                            onAccepted: win.fxSearch(text)
                                        }
                                        Chip { label: fxSearchProc.running ? win.t("SEARCHING…") : win.t("SEARCH"); on: !fxSearchProc.running; onClicked: win.fxSearch(fxQuery.text) }
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
                                        text: win.t(win.fxMsg); color: pal.dim; font.family: win.mono; font.pixelSize: 10
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
                                            border.color: win.fxActive && win.fxCur.id === modelData.id ? pal.ok : pal.border
                                            RowLayout {
                                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 6
                                                Text {
                                                    Layout.fillWidth: true; elide: Text.ElideRight
                                                    text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 11
                                                }
                                                Chip { label: "↗"; tip: win.t("Open the preset's page"); onClicked: Qt.openUrlExternally("https://sfx.thelazy.net/games/preset/" + modelData.id + "/") }
                                                Chip {
                                                    label: win.fxConfirm === k ? win.t("CONFIRM?") : (win.fxActive && win.fxCur.id === modelData.id ? win.t("ACTIVE ✓") : win.t("APPLY"))
                                                    tint: pal.ok; on: !win.gameBusy && win.fxReady
                                                    tip: !win.fxReady ? win.t("Run INSTALL above first")
                                                         : (win.fxReshade ? win.t("Download it and fetch the shaders it needs; ReShade runs it as it is") : win.t("Download, fetch the shaders it needs and convert it for vkBasalt"))
                                                    onClicked: win.fxApply(k, win.t("APPLYING PRESET…"))
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        visible: false   // source details are in the PRESETS tooltip
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        text: win.t("Presets: SweetFX Settings DB (sfx.thelazy.net), made for ReShade") + (win.fxReshade ? "" : win.t(" — in vkBasalt, effects that need the depth buffer are skipped")) + win.t(". Shaders: the packages the official ReShade installer lists.")
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
                                    text: win.t("Every Steam game: the most downloaded ReShade preset on SweetFX Settings DB, the ReShade compatibility list (PCGamingWiki, which reshade.me links) and online/anti-cheat risk. SET UP installs ReShade with that preset — or SHARPEN + AA when there's none — and the depth settings the list gives. Anti-cheat games and games where ReShade is banned are never touched.")
                                }
                                Chip { label: fxScanProc.running ? win.t("SCANNING…") : win.t("SCAN"); on: !fxScanProc.running; onClicked: { fxScanProc.cached = false; fxScanProc.running = true; } }
                                MiniBtn {
                                    width: Math.max(150, implicitWidth); height: 32; label: win.t("SET UP ALL (") + win.fxEligible + ")"
                                    on: !win.gameBusy && win.fxEligible > 0
                                    onClicked: win.runGame(["fx", "autoinstall"].concat(win.fxScan.filter(function (r) { return r.eligible && !r.current; }).map(function (r) { return r.key; })), win.t("SETTING UP ") + win.fxEligible + win.t(" GAME(S)…"))
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
                                                visible: !!modelData.advice
                                                text: !modelData.advice ? "" : (modelData.advice.pick === "none" ? win.t("no shaders possible")
                                                      : "★ " + (modelData.advice.pick === "reshade" ? "ReShade" : "vkBasalt"))
                                                color: modelData.advice && modelData.advice.pick === "none" ? pal.dim : pal.amber
                                                font.family: win.mono; font.pixelSize: 10
                                                MouseArea { id: advMa; anchors.fill: parent; hoverEnabled: true }
                                                Tip { visible: advMa.containsMouse && !!modelData.advice; text: modelData.advice ? modelData.advice.reasons.map(win.t).join("\n") : "" }
                                            }
                                            Text {
                                                visible: !!modelData.current
                                                text: modelData.current ? "● " + (modelData.current.mode === "reshade" ? "ReShade" : "vkBasalt") + " · " + modelData.current.name : ""
                                                color: pal.ok; font.family: win.mono; font.pixelSize: 10; elide: Text.ElideRight; Layout.maximumWidth: 260
                                            }
                                            MiniBtn {
                                                width: Math.max(70, implicitWidth); height: 28; primary: false; label: win.t("OPEN")
                                                onClicked: {
                                                    var g = win.games.filter(function (x) { return x.key === modelData.key; })[0];
                                                    if (g) { win.selectGame(g); win.fxScope = "game"; win.openFx(); }
                                                }
                                            }
                                            MiniBtn {
                                                width: Math.max(80, implicitWidth); height: 28; label: win.t("SET UP")
                                                visible: modelData.eligible
                                                on: !win.gameBusy
                                                onClicked: win.runGame(["fx", "autoinstall", modelData.key], win.t("SETTING UP ") + modelData.name.toUpperCase() + "…")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.family: win.mono; font.pixelSize: 10
                                            color: modelData.sfx && modelData.sfx.count > 0 ? pal.text : pal.dim
                                            visible: modelData.eligible || (modelData.sfx && modelData.sfx.count > 0)
                                            text: modelData.sfx && modelData.sfx.count > 0
                                                  ? "★ " + modelData.sfx.count + win.t(" presets · best: ") + modelData.sfx.best.name + " (" + modelData.sfx.best.downloads + win.t(" downloads)")
                                                  : win.t("No ReShade presets on SweetFX DB → SET UP uses SHARPEN + AA")
                                        }
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            visible: !!modelData.pcgw
                                            font.family: win.mono; font.pixelSize: 9; color: modelData.blocked ? pal.bad : pal.dim
                                            text: modelData.pcgw ? "PCGamingWiki: " + modelData.pcgw.status + " · " + modelData.pcgw.api
                                                  + (modelData.defines.length ? win.t(" · depth: ") + modelData.defines.join(", ") + win.t(" (set automatically)") : "")
                                                  + (modelData.pcgw.notes ? " — " + modelData.pcgw.notes : "") : ""
                                            maximumLineCount: 3; elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            visible: modelData.blocked || (!!modelData.online && modelData.online.level !== "none")
                                            font.family: win.mono; font.pixelSize: 9
                                            color: modelData.blocked || modelData.online.level === "anticheat" ? pal.bad : pal.amber
                                            text: modelData.blocked ? win.t("✗ ReShade is banned or blocked in this game (PCGamingWiki): not touched")
                                                  : (modelData.online.level === "anticheat" ? win.t("✗ Anti-cheat (") + modelData.online.anticheats.join(", ") + win.t("): not touched")
                                                     : win.t("⚠ Has online multiplayer/co-op: fine for single-player, check the game's rules online"))
                                        }
                                        RowLayout {
                                            spacing: 6
                                            Chip {
                                                visible: !!modelData.sfx
                                                label: "PRESETS ↗"; onClicked: Qt.openUrlExternally("https://sfx.thelazy.net/games/game/" + modelData.sfx.id + "/")
                                            }
                                            Chip { label: win.t("SEARCH NEXUS ↗"); tip: win.t("Web search for ReShade presets of this game on Nexus Mods"); onClicked: Qt.openUrlExternally(modelData.nexus) }
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
                                title: fxScanProc.running ? win.t("SCANNING YOUR LIBRARY…") : win.t("PRESS SCAN")
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
                                          ? [win.health.fail > 0 ? win.health.fail + win.t(" problem") + (win.health.fail > 1 ? "s" : "") : "",
                                             win.health.warn > 0 ? win.health.warn + win.t(" warning") + (win.health.warn > 1 ? "s" : "") : ""]
                                            .filter(function (x) { return x; }).join(" · ")
                                            + win.t("  —  nothing is changed from here: copy the command and run it in a terminal")
                                          : win.t("✓ Everything games need is in place (") + (win.health.vendors || []).join(", ").toUpperCase() + ")"
                                }
                                Chip { label: healthProc.running ? win.t("CHECKING…") : win.t("RECHECK"); on: !healthProc.running; onClicked: healthProc.running = true }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                visible: (win.health.installAll || "") !== ""
                                Text { text: win.t("ALL MISSING"); color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                FixLine { Layout.fillWidth: true; cmd: win.health.installAll || "" }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.health.checks
                            title: healthProc.running ? win.t("CHECKING…") : win.t("NO DATA")
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
                                    text: ({ system: win.t("SYSTEM"), driver: win.t("GPU DRIVER"), vulkan: "VULKAN", libs: win.t("32-BIT LIBRARIES") })[modelData.group] || modelData.group.toUpperCase()
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
                                                text: win.t(modelData.label); color: pal.text
                                                font.family: win.mono; font.pixelSize: 11
                                                Layout.preferredWidth: Math.min(implicitWidth, 260); elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                text: win.t(modelData.detail)
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
                              win.t("Drivers: ") + win.shaders.drivers.map(function (d) { return d.name + " " + d.version; }).join(" · ")
                              + (win.shaders.lastDriverUpdate ? win.t("  ·  last driver update ") + win.dateOfEpoch(win.shaders.lastDriverUpdate) : "")
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
                                text: (win.shaders.steamProcessing ? win.t("Steam is compiling shaders right now; cleaning waits until it finishes. ") : "")
                                      + ((win.shaders.staleBytes || 0) > 0 ? win.human(win.shaders.staleBytes) + win.t(" of driver caches weren't used since the last driver update: they are stale. ") : "")
                                      + ((win.shaders.orphanBytes || 0) > 0 ? win.human(win.shaders.orphanBytes) + win.t(" belong to games that are no longer installed.") : "")
                            }
                            MiniBtn {
                                visible: (win.shaders.staleBytes || 0) > 0
                                width: Math.max(104, implicitWidth); label: win.confirmShader === "stale" ? win.t("CONFIRM?") : win.t("CLEAN STALE")
                                on: !win.gameBusy && !win.shaders.steamProcessing
                                onClicked: win.shaderAction(["shaderclean", "stale"], "stale", win.t("CLEANING…"))
                            }
                            MiniBtn {
                                visible: (win.shaders.orphanBytes || 0) > 0
                                width: Math.max(112, implicitWidth); label: win.confirmShader === "orphans" ? win.t("CONFIRM?") : win.t("CLEAN ORPHANS")
                                on: !win.gameBusy && !win.shaders.steamProcessing
                                onClicked: win.shaderAction(["shaderclean", "orphans"], "orphans", win.t("CLEANING…"))
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true
                        EmptyHint {
                            visible: !win.shaders.games || (win.shaders.games.length === 0 && win.shaders.global.length === 0)
                            title: shaderProc.running ? win.t("MEASURING CACHES…") : win.t("NO SHADER CACHES")
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
                                                text: modelData.global ? win.t("DRIVER") : (modelData.installed ? "STEAM" : win.t("ORPHAN"))
                                                color: modelData.global ? pal.sky : (modelData.installed ? pal.accent : pal.bad)
                                                font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
                                            }
                                            Text {
                                                text: modelData.name || (win.t("uninstalled app ") + modelData.id)
                                                color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight
                                                Layout.maximumWidth: 330
                                            }
                                            Text { text: win.human(modelData.total); color: pal.amber; font.family: win.mono; font.pixelSize: 10 }
                                            Text { visible: modelData.stale === true; text: win.t("STALE"); color: pal.amber; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                            Text { visible: modelData.running === true; text: win.t("RUNNING"); color: pal.ok; font.family: win.mono; font.pixelSize: 8; font.bold: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                            text: modelData.global ? modelData.path
                                                  : ["pipelines " + (win.human(modelData.pipelines) || "0"),
                                                     "driver " + (win.human(modelData.driver) || "0"),
                                                     modelData.video > 0 ? "videos " + win.human(modelData.video) : "",
                                                     modelData.dxvk > 0 ? "dxvk " + win.human(modelData.dxvk) : "",
                                                     modelData.other > 0 ? win.t("other ") + win.human(modelData.other) : ""]
                                                    .filter(function (x) { return x !== ""; }).join("  ·  ")
                                        }
                                    }
                                    MiniBtn {
                                        visible: !modelData.global && modelData.driver > 0
                                        width: Math.max(92, implicitWidth); primary: false
                                        property string key: "steam:" + modelData.id + ":driver"
                                        label: win.confirmShader === key ? win.t("CONFIRM?") : win.t("DRIVER CACHE")
                                        on: !win.gameBusy && !modelData.running && !win.shaders.steamProcessing
                                        onClicked: win.shaderAction(["shaderclean", "steam:" + modelData.id, "driver"], key, win.t("CLEANING…"))
                                    }
                                    MiniBtn {
                                        width: Math.max(70, implicitWidth); tint: pal.bad
                                        property string key: (modelData.global ? "global:" + modelData.id : "steam:" + modelData.id + ":all")
                                        label: win.confirmShader === key ? win.t("CONFIRM?") : (modelData.global ? win.t("CLEAN") : win.t("ALL"))
                                        on: !win.gameBusy && !modelData.running && (modelData.global || !win.shaders.steamProcessing)
                                        onClicked: win.shaderAction(modelData.global ? ["shaderclean", "global:" + modelData.id]
                                                                                     : ["shaderclean", "steam:" + modelData.id, "all"], key, win.t("CLEANING…"))
                                    }
                                }
                            }
                        }
                    }
                    Hint {
                        text: win.t("pipelines = Steam's Fossilize recordings (driver-independent, used to pre-compile) · driver = the GPU driver's compiled cache (NVIDIA nvidiav1 / Mesa for AMD-Intel), rebuilt after every driver update. DRIVER CACHE clears only that; ALL clears the game's whole folder. Either way the next launches stutter a little while caches rebuild.")
                    }
                }

                // ---- STATUS ----
                ScrollView {
                    id: stScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: win.gameView === "status"
                    contentWidth: availableWidth
                    clip: true

                    component StatRow: RowLayout {
                        property string label
                        property string value
                        property color tone: pal.text
                        property string note: ""
                        Layout.fillWidth: true; spacing: 8
                        Text { text: label; Layout.preferredWidth: 112; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                        Text { text: value; color: tone; font.family: win.mono; font.pixelSize: 11; elide: Text.ElideRight; Layout.maximumWidth: 260 }
                        Text { Layout.fillWidth: true; text: note; color: pal.dim; font.family: win.mono; font.pixelSize: 9; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                    }
                    component Meter: RowLayout {
                        property string label
                        property real value: 0
                        property real max: 1
                        property string text: ""
                        property real warnAt: 0.85
                        Layout.fillWidth: true; spacing: 8
                        Text { text: label; Layout.preferredWidth: 112; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                        Rectangle {
                            Layout.fillWidth: true; height: 8; radius: 4; color: pal.logBg; border.color: pal.border; border.width: 1
                            Rectangle {
                                height: parent.height; radius: 4
                                width: parent.width * Math.max(0, Math.min(1, max > 0 ? value / max : 0))
                                color: max > 0 && value / max >= warnAt ? pal.amber : pal.accent
                            }
                        }
                        Text { text: parent.text; Layout.preferredWidth: 150; horizontalAlignment: Text.AlignRight; color: pal.text; font.family: win.mono; font.pixelSize: 10 }
                    }
                    component Card: Rectangle {
                        property string title
                        property string sub: ""
                        default property alias content: cardCol.data
                        Layout.fillWidth: true
                        implicitHeight: cardCol.implicitHeight + 20
                        radius: 8; color: pal.card; border.color: pal.border; border.width: 1
                        ColumnLayout {
                            id: cardCol
                            anchors.fill: parent; anchors.margins: 10; spacing: 6
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text { text: title; color: pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2 }
                                Text { Layout.fillWidth: true; text: sub; color: pal.dim; font.family: win.mono; font.pixelSize: 10; elide: Text.ElideRight }
                            }
                        }
                    }
                    // one live series (last 5 minutes while STATUS is open)
                    component Spark: ColumnLayout {
                        id: spark
                        property string label
                        property var values: []
                        property real max: 100
                        property string current: ""
                        property color tint: pal.accent
                        // equal columns: same small preferred width, then fill
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 10; spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: spark.label; color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                            Item { Layout.fillWidth: true }
                            Text { text: spark.current; color: pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: true }
                        }
                        Canvas {
                            id: cv
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 40
                            onWidthChanged: requestPaint(); onHeightChanged: requestPaint()
                            Connections { target: spark; function onValuesChanged() { cv.requestPaint(); } }
                            onPaint: {
                                var c = getContext("2d"); c.reset();
                                c.fillStyle = pal.logBg; c.fillRect(0, 0, width, height);
                                c.strokeStyle = pal.border; c.lineWidth = 1;
                                for (var g = 1; g < 4; g++) { var gy = Math.round(height * g / 4) + 0.5; c.beginPath(); c.moveTo(0, gy); c.lineTo(width, gy); c.stroke(); }
                                var v = spark.values, n = 100;
                                if (!v || v.length < 2) return;
                                var step = width / (n - 1), x0 = width - (v.length - 1) * step;
                                function yOf(val) { return height - 2 - (height - 4) * Math.max(0, Math.min(1, val / spark.max)); }
                                c.beginPath(); c.moveTo(x0, height);
                                for (var i = 0; i < v.length; i++) c.lineTo(x0 + i * step, yOf(v[i]));
                                c.lineTo(width, height); c.closePath();
                                c.fillStyle = Qt.rgba(spark.tint.r, spark.tint.g, spark.tint.b, 0.18); c.fill();
                                c.beginPath();
                                for (var j = 0; j < v.length; j++) { if (j === 0) c.moveTo(x0, yOf(v[0])); else c.lineTo(x0 + j * step, yOf(v[j])); }
                                c.strokeStyle = spark.tint; c.lineWidth = 1.5; c.stroke();
                            }
                        }
                    }

                    ColumnLayout {
                        width: stScroll.availableWidth
                        height: Math.max(implicitHeight, stScroll.availableHeight)
                        spacing: 8

                        // running game (left) · displays (right)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: runRow.implicitHeight + 16
                            radius: 8; color: pal.card; border.width: 1
                            border.color: (win.gstat.running || []).length ? pal.ok : pal.border
                            RowLayout {
                                id: runRow
                                anchors.fill: parent; anchors.margins: 8; spacing: 12
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    RowLayout {
                                        spacing: 8
                                        Text { text: win.t("RUNNING NOW"); color: pal.text; font.family: win.mono; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2 }
                                        Text {
                                            visible: !(win.gstat.running || []).length
                                            text: win.t("no game  ·  Steam ") + ((win.gstat.tools || {}).steam ? win.t("open") : win.t("closed"))
                                            color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                        }
                                    }
                                    Repeater {
                                        model: win.gstat.running || []
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true; spacing: 10
                                            Text { text: "●"; color: pal.ok; font.pixelSize: 10 }
                                            Text { text: win.gameName(modelData.id); color: pal.text; font.family: win.mono; font.pixelSize: 12; font.bold: true }
                                            Text {
                                                Layout.fillWidth: true; elide: Text.ElideRight
                                                color: pal.dim; font.family: win.mono; font.pixelSize: 10
                                                text: [modelData.uptime != null ? win.durationText(modelData.uptime) : "",
                                                       modelData.proton ? modelData.proton : "",
                                                       modelData.fx ? modelData.fx + " on" : "",
                                                       win.gstat.gamemode && win.gstat.gamemode.active ? win.t("GameMode active") : "",
                                                       "pid " + modelData.pid].filter(function (x) { return x; }).join("  ·  ")
                                            }
                                        }
                                    }
                                }
                                Rectangle { width: 1; Layout.fillHeight: true; color: pal.border; visible: (win.gstat.displays || []).length > 0 }
                                ColumnLayout {
                                    spacing: 2
                                    Repeater {
                                        model: win.gstat.displays || []
                                        delegate: RowLayout {
                                            required property var modelData
                                            spacing: 8
                                            Text { text: modelData.name + (modelData.focused ? " ●" : ""); color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1 }
                                            Text { text: modelData.width + "×" + modelData.height + " @ " + Math.round(modelData.hz) + " Hz"; color: pal.text; font.family: win.mono; font.pixelSize: 11 }
                                            Text {
                                                text: modelData.vrr ? "VRR on" : "VRR off"; color: modelData.vrr ? pal.ok : pal.dim
                                                font.family: win.mono; font.pixelSize: 10
                                                MouseArea { id: vrrMa; anchors.fill: parent; hoverEnabled: true }
                                                Tip { visible: vrrMa.containsMouse; text: modelData.vrr ? win.t("Variable refresh rate (FreeSync / G-Sync) is on.") : win.t("Variable refresh rate is off. In Hyprland, misc:vrr turns it on (2 = fullscreen apps only, good for games).") }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // row 1: GPU | CPU · memory (same height)
                        GridLayout {
                            id: stRow1
                            Layout.fillWidth: true
                            columns: stScroll.availableWidth > 780 ? 2 : 1
                            columnSpacing: 8; rowSpacing: 8
                            property real cardH: columns === 2 ? Math.max(gpuCard.implicitHeight, cpuCard.implicitHeight) : -1

                            Card {
                                id: gpuCard
                                Layout.preferredHeight: stRow1.cardH > 0 ? stRow1.cardH : implicitHeight
                                title: "GPU"; sub: (win.gstat.gpu || {}).name || ""
                                StatRow { label: win.t("DRIVER"); value: (win.gstat.gpu || {}).driver || "?" }
                                Meter {
                                    label: win.t("LOAD"); value: (win.gstat.gpu || {}).load || 0; max: 100; warnAt: 2
                                    text: (win.gstat.gpu || {}).load != null ? win.gstat.gpu.load + " %" : "—"
                                }
                                Meter {
                                    label: "VRAM"; value: (win.gstat.gpu || {}).vramUsed || 0; max: (win.gstat.gpu || {}).vramTotal || 0
                                    text: (win.gstat.gpu || {}).vramTotal ? win.human(win.gstat.gpu.vramUsed) + " / " + win.human(win.gstat.gpu.vramTotal) : "—"
                                }
                                Meter {
                                    label: win.t("POWER"); value: (win.gstat.gpu || {}).power || 0; max: (win.gstat.gpu || {}).powerLimit || 0
                                    text: (win.gstat.gpu || {}).power != null ? Math.round(win.gstat.gpu.power) + " W"
                                          + ((win.gstat.gpu || {}).powerLimit ? " / " + Math.round(win.gstat.gpu.powerLimit) + " W" : "") : "—"
                                }
                                StatRow {
                                    label: win.t("TEMPERATURE"); value: (win.gstat.gpu || {}).temp != null ? win.gstat.gpu.temp + " °C" : "—"
                                    tone: (win.gstat.gpu || {}).temp >= 85 ? pal.bad : ((win.gstat.gpu || {}).temp >= 75 ? pal.amber : pal.text)
                                }
                                StatRow {
                                    label: win.t("CLOCK")
                                    value: (win.gstat.gpu || {}).clock != null ? win.gstat.gpu.clock + " MHz"
                                           + ((win.gstat.gpu || {}).clockMax ? " / " + win.gstat.gpu.clockMax : "") : "—"
                                    note: (win.gstat.gpu || {}).pstate ? win.t("state ") + win.gstat.gpu.pstate : ""
                                }
                                StatRow {
                                    visible: ((win.gstat.gpu || {}).limits || []).length > 0
                                    label: win.t("HELD BACK BY")
                                    value: ((win.gstat.gpu || {}).limits || []).join(", ")
                                    tone: ((win.gstat.gpu || {}).limits || []).some(function (x) { return /thermal|slowdown|brake/.test(x); }) ? pal.amber : pal.text
                                    note: ((win.gstat.gpu || {}).limits || []).indexOf("idle") >= 0 ? win.t("nothing heavy to render right now")
                                          : (((win.gstat.gpu || {}).limits || []).indexOf("power cap") >= 0 ? win.t("at its power limit: normal under load, odd at idle") : "")
                                }
                                Item { Layout.fillHeight: true }
                            }

                            Card {
                                id: cpuCard
                                Layout.preferredHeight: stRow1.cardH > 0 ? stRow1.cardH : implicitHeight
                                title: win.t("CPU · MEMORY"); sub: (win.gstat.system || {}).cpu || ""
                                StatRow {
                                    label: "CPU"
                                    value: ((win.gstat.system || {}).threads || "?") + win.t(" threads · ") + ((win.gstat.system || {}).mhz || "?") + " MHz"
                                           + ((win.gstat.system || {}).temp != null ? " · " + win.gstat.system.temp + " °C" : "")
                                    note: (win.gstat.system || {}).load != null ? win.t("load ") + win.gstat.system.load : ""
                                    tone: (win.gstat.system || {}).temp >= 85 ? pal.bad : ((win.gstat.system || {}).temp >= 75 ? pal.amber : pal.text)
                                }
                                StatRow {
                                    label: "GOVERNOR"
                                    value: (win.gstat.governor || "?") + " (" + (win.gstat.cpufreq_driver || "?") + ")"
                                    note: win.gstat.gamemode && win.gstat.gamemode.active ? win.t("GameMode has it on performance") : win.t("GameMode switches it to performance while you play")
                                }
                                Meter {
                                    label: "RAM"; value: (win.gstat.system || {}).memUsed || 0; max: (win.gstat.system || {}).memTotal || 0
                                    text: (win.gstat.system || {}).memTotal ? win.human(win.gstat.system.memUsed) + " / " + win.human(win.gstat.system.memTotal) : "—"
                                }
                                Meter {
                                    label: (win.gstat.system || {}).zram ? "SWAP (ZRAM)" : "SWAP"
                                    value: (win.gstat.system || {}).swapUsed || 0; max: (win.gstat.system || {}).swapTotal || 0
                                    text: (win.gstat.system || {}).swapTotal ? win.human(win.gstat.system.swapUsed) + " / " + win.human(win.gstat.system.swapTotal) : "none"
                                }
                                StatRow { label: "KERNEL"; value: (win.gstat.system || {}).kernel || "?" }
                                StatRow {
                                    property var sc: win.gstat.sched || {}
                                    label: win.t("SCHEDULER")
                                    value: sc.running && sc.current ? "sched-ext: " + sc.current : win.t("kernel default (EEVDF)")
                                    note: !win.gstat.sched ? win.t("scx-tools not installed")
                                          : [sc.whilePlaying ? win.t("while playing: ") + sc.whilePlaying.replace(":", " · ") : "",
                                             sc.bootDefault ? win.t("at boot: ") + sc.bootDefault + (sc.bootMode ? " · " + sc.bootMode : "") : ""]
                                            .filter(function (x) { return x; }).join("  ·  ")
                                }
                                // lavd's Gaming mode: now, only while a game runs, or at every boot
                                Flow {
                                    Layout.fillWidth: true; spacing: 6
                                    visible: !!win.gstat.sched
                                    property var sc: win.gstat.sched || {}
                                    Chip {
                                        label: parent.sc.running ? win.t("STOP") : win.t("LAVD GAMING NOW")
                                        on: !win.gameBusy
                                        tip: parent.sc.running ? win.t("Back to the kernel's scheduler (asks for your password)")
                                             : win.t("scx_lavd in Gaming mode until you stop it or reboot (asks for your password)")
                                        onClicked: win.runGame(parent.sc.running ? ["sched", "stop"] : ["sched", "start", "lavd", "gaming"], win.t("SCHEDULER…"))
                                    }
                                    Chip {
                                        label: win.t("WHILE PLAYING"); tint: pal.ok; active: parent.sc.whilePlaying === "lavd:gaming"
                                        on: !win.gameBusy
                                        tip: win.t("lavd Gaming starts with each game and stops when it closes (only if no scheduler was running)")
                                        onClicked: win.runGame(["sched", "playing", parent.sc.whilePlaying ? "off" : "lavd:gaming"], win.t("SAVING…"))
                                    }
                                    Chip {
                                        label: win.confirmSched === "boot" ? win.t("CONFIRM?") : win.t("AT BOOT")
                                        tint: pal.ok; active: parent.sc.bootDefault === "lavd"
                                        on: !win.gameBusy
                                        tip: win.t("Writes default_sched in /etc/scx_loader.toml (password): lavd Gaming from every boot")
                                        onClicked: {
                                            if (win.confirmSched !== "boot") { win.confirmSched = "boot"; return; }
                                            win.confirmSched = "";
                                            win.runGame(parent.sc.bootDefault === "lavd" ? ["sched", "boot", "none"] : ["sched", "boot", "lavd", "Gaming"], win.t("SCHEDULER…"));
                                        }
                                    }
                                    Chip {
                                        label: win.confirmSched === "nopass" ? win.t("CONFIRM?") : win.t("NO PASSWORD")
                                        tint: pal.ok; active: parent.sc.noPassword === true
                                        on: !win.gameBusy
                                        tip: win.t("A polkit rule so your user switches schedulers without a password (needed for WHILE PLAYING without prompts)")
                                        onClicked: {
                                            if (win.confirmSched !== "nopass") { win.confirmSched = "nopass"; return; }
                                            win.confirmSched = "";
                                            win.runGame(["sched", "nopassword", parent.sc.noPassword ? "off" : "on"], win.t("SCHEDULER…"));
                                        }
                                    }
                                }
                                StatRow {
                                    label: "MAX_MAP_COUNT"; value: String(win.gstat.max_map_count || "?")
                                    tone: win.gstat.max_map_count_ok ? pal.text : pal.amber
                                    note: win.gstat.max_map_count_ok ? win.t("≥ 1048576: enough for any game") : win.t("below 1048576: some games crash (see HEALTH)")
                                }
                                Item { Layout.fillHeight: true }
                            }
                        }

                        // while playing: notifications held, Hyprland without effects
                        Card {
                            Layout.fillWidth: true
                            title: win.t("WHILE PLAYING")
                            sub: win.t("from the first game that starts until the last one closes")
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                property var pl: win.gstat.playing || ({})
                                Chip {
                                    label: (parent.pl.quiet ? "✓ " : "") + win.t("HOLD NOTIFICATIONS")
                                    tint: pal.ok; active: !!parent.pl.quiet; on: !win.gameBusy && (!!parent.pl.notifier || !!parent.pl.quiet)
                                    tip: parent.pl.notifier === "swaync" ? win.t("Do Not Disturb in swaync while you play; notifications wait in its panel")
                                       : parent.pl.notifier === "dunst" ? win.t("Pauses dunst while you play; what arrived shows when the game closes")
                                       : win.t("Needs dunst or swaync running")
                                    onClicked: win.runGame(["playing", "quiet", parent.pl.quiet ? "off" : "on"], win.t("SAVING…"))
                                }
                                Chip {
                                    label: (parent.pl.lite ? "✓ " : "") + win.t("NO ANIMATIONS / BLUR")
                                    tint: pal.ok; active: !!parent.pl.lite; on: !win.gameBusy && (!!parent.pl.hyprland || !!parent.pl.lite)
                                    tip: parent.pl.hyprland ? win.t("Hyprland animations, blur and shadows off while you play, back as they were after")
                                                            : win.t("Only on Hyprland")
                                    onClicked: win.runGame(["playing", "lite", parent.pl.lite ? "off" : "on"], win.t("SAVING…"))
                                }
                                Text {
                                    Layout.fillWidth: true; color: pal.dim; font.family: win.mono; font.pixelSize: 9; elide: Text.ElideRight
                                    text: win.t("Games launched through the deck (Steam) or Umbral 0.10+.")
                                }
                            }
                        }
                        // last game sessions (recorded while each game ran)
                        Card {
                            Layout.fillWidth: true
                            title: win.t("LAST SESSIONS")
                            sub: (win.gstat.sessions || []).length ? "" : win.t("play a game: a summary appears here when it closes")
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text {
                                    Layout.fillWidth: true; color: pal.dim; font.family: win.mono; font.pixelSize: 9
                                    text: win.t("Temperatures, load and power are sampled every 5 s while a game runs (Steam through the deck, Umbral 0.10+).")
                                }
                                Chip {
                                    label: win.gstat.sessionSummary === false ? win.t("SUMMARY OFF") : win.t("✓ SUMMARY")
                                    tint: pal.ok; active: win.gstat.sessionSummary !== false; on: !win.gameBusy
                                    tip: win.t("Record each game session and notify a summary when it ends")
                                    onClicked: win.runGame(["sessions", win.gstat.sessionSummary === false ? "on" : "off"], win.t("SAVING…"))
                                }
                            }
                            Repeater {
                                model: win.gstat.sessions || []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: 10
                                    Text { text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 11; elide: Text.ElideRight; Layout.preferredWidth: 190 }
                                    Text {
                                        text: new Date(modelData.start * 1000).toLocaleString(Qt.locale(), "dd/MM HH:mm") + " · " + win.durationText(modelData.duration)
                                        color: pal.dim; font.family: win.mono; font.pixelSize: 10; Layout.preferredWidth: 150
                                    }
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        font.family: win.mono; font.pixelSize: 10
                                        color: (modelData.gpuTempMax || 0) >= 85 || (modelData.cpuTempMax || 0) >= 90 ? pal.amber : pal.text
                                        text: [modelData.gpuTempMax != null ? "GPU " + modelData.gpuTempMax + "°" : "",
                                               modelData.cpuTempMax != null ? "CPU " + modelData.cpuTempMax + "°" : "",
                                               modelData.gpuLoadAvg != null ? win.t("load ") + Math.round(modelData.gpuLoadAvg) + "%" : "",
                                               modelData.gpuPowerMax != null ? Math.round(modelData.gpuPowerMax) + " W" : "",
                                               modelData.vramMax != null ? "VRAM " + (modelData.vramMax / 1024).toFixed(1) + " GB" : ""]
                                              .filter(function (x) { return x; }).join("  ·  ")
                                    }
                                    // GPU temperature over the session
                                    Canvas {
                                        width: 90; height: 18
                                        property var pts: modelData.gpuTempLine || []
                                        onPaint: {
                                            var c = getContext("2d"); c.reset();
                                            var v = pts.filter(function (x) { return x != null; });
                                            if (v.length < 2) return;
                                            var lo = Math.min.apply(null, v) - 2, hi = Math.max.apply(null, v) + 2;
                                            c.strokeStyle = pal.amber; c.lineWidth = 1.2; c.beginPath();
                                            for (var i = 0; i < v.length; i++) {
                                                var x = i * (width - 1) / (v.length - 1), y = height - 1 - (height - 2) * (v[i] - lo) / (hi - lo);
                                                if (i === 0) c.moveTo(x, y); else c.lineTo(x, y);
                                            }
                                            c.stroke();
                                        }
                                    }
                                }
                            }
                        }

                        // row 2: tools + library (left) | live history (fills the rest of the tab)
                        GridLayout {
                            id: stRow2
                            Layout.fillWidth: true; Layout.fillHeight: true
                            columns: stScroll.availableWidth > 780 ? 2 : 1
                            columnSpacing: 8; rowSpacing: 8

                            ColumnLayout {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignTop
                            Layout.fillHeight: stRow2.columns === 2
                            spacing: 8
                            Card {
                                title: win.t("GAMING TOOLS")
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    StatRow {
                                        label: "GAMEMODE"
                                        value: !win.gstat.gamemode ? "" : (!win.gstat.gamemode.installed ? win.t("not installed")
                                               : ((win.gstat.tools || {}).gamemode || "") + (win.gstat.gamemode.active ? win.t(" · active") : win.t(" · idle")))
                                        tone: win.gstat.gamemode && win.gstat.gamemode.installed ? pal.text : pal.amber
                                        note: !win.gstat.gamemode ? "" : (win.gstat.gamemode.ingroup ? win.t("in the gamemode group")
                                              : (win.gstat.gamemode.pending ? win.t("group added: log out and back in") : win.t("not in the gamemode group: it can't switch the governor")))
                                    }
                                    MiniBtn {
                                        visible: !!win.gstat.gamemode && !win.gstat.gamemode.ingroup && !win.gstat.gamemode.pending
                                        width: Math.max(96, implicitWidth); height: 26; label: win.confirmJoin ? win.t("CONFIRM?") : win.t("JOIN GROUP")
                                        on: !win.gameBusy
                                        onClicked: {
                                            if (!win.confirmJoin) { win.confirmJoin = true; return; }
                                            win.confirmJoin = false;
                                            win.runGame(["gamejoin"], win.t("JOINING…"));
                                        }
                                    }
                                }
                                StatRow { label: win.t("MANGOHUD"); value: win.gstat.mangohud ? ((win.gstat.tools || {}).mangohud || "installed") : win.t("not installed"); tone: win.gstat.mangohud ? pal.text : pal.amber }
                                StatRow { label: "GAMESCOPE"; value: win.gstat.gamescope ? ((win.gstat.tools || {}).gamescope || "installed") : win.t("not installed (optional)") }
                                StatRow { label: "STEAM"; value: (win.gstat.tools || {}).steam ? win.t("running") : win.t("closed"); note: ((win.gstat.tools || {}).protons || 0) + win.t(" Proton builds available") }
                                StatRow { label: "NTSYNC"; value: (win.gstat.tools || {}).ntsync ? win.t("available") : win.t("not available"); note: win.t("kernel sync for Wine/Proton") }
                                StatRow {
                                    label: "SHADERS"
                                    value: [(win.gstat.tools || {}).reshade ? "ReShade " + win.gstat.tools.reshade : "",
                                            (win.gstat.tools || {}).vkbasalt ? "vkBasalt " + win.gstat.tools.vkbasalt.replace(/-[^-]*$/, "") : ""]
                                           .filter(function (x) { return x; }).join(" · ") || win.t("none installed")
                                    note: "GAMING → FX"
                                }
                            }

                            Card {
                                Layout.fillHeight: stRow2.columns === 2
                                property var lib: win.gstat.library || {}
                                title: win.t("LIBRARY · STORAGE")
                                sub: lib.games ? lib.games.steam + " Steam · " + lib.games.umbral + " Umbral · " + lib.games.wrapped + win.t(" through the deck · ") + lib.games.fx + win.t(" with shaders") : ""
                                Repeater {
                                    model: (win.gstat.library || {}).disks || []
                                    delegate: Meter {
                                        required property var modelData
                                        label: win.t("DISK ") + modelData.mount
                                        value: modelData.size - modelData.free; max: modelData.size; warnAt: 0.9
                                        text: win.human(modelData.free) + win.t(" free of ") + win.human(modelData.size)
                                    }
                                }
                                StatRow {
                                    label: win.t("SHADER CACHES")
                                    value: (win.gstat.library || {}).shaders ? win.human(win.gstat.library.shaders.total) : "—"
                                    note: (win.gstat.library || {}).shaders && (win.gstat.library.shaders.stale + win.gstat.library.shaders.orphan) > 0
                                          ? win.human(win.gstat.library.shaders.stale + win.gstat.library.shaders.orphan) + win.t(" can be cleaned (SHADERS)") : win.t("nothing to clean")
                                }
                                StatRow {
                                    label: "PREFIXES"
                                    value: (win.gstat.library || {}).prefixes ? win.human(win.gstat.library.prefixes.total) + " · " + win.gstat.library.prefixes.count : "—"
                                    note: (win.gstat.library || {}).prefixes && win.gstat.library.prefixes.orphans > 0
                                          ? win.gstat.library.prefixes.orphans + win.t(" orphan(s) (PREFIXES)") : win.t("no orphans")
                                }
                                StatRow {
                                    label: win.t("GPU DRIVER")
                                    value: (win.gstat.library || {}).driverUpdate ? win.t("updated ") + win.dateOfEpoch(win.gstat.library.driverUpdate) : "—"
                                    note: (win.gstat.library || {}).driverPkgs || ""
                                }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    StatRow {
                                        label: win.t("HEALTH")
                                        property var h: (win.gstat.library || {}).health || {}
                                        value: h.fail === undefined ? "—" : (h.fail === 0 && h.warn === 0 ? win.t("all good")
                                               : [h.fail ? h.fail + win.t(" problem(s)") : "", h.warn ? h.warn + win.t(" warning(s)") : ""].filter(function (x) { return x; }).join(" · "))
                                        tone: h.fail > 0 ? pal.bad : (h.warn > 0 ? pal.amber : pal.ok)
                                    }
                                    Chip { label: win.t("HEALTH →"); onClicked: { win.gameView = "health"; healthProc.running = true; } }
                                }
                                Text { text: win.t("RECENTLY PLAYED"); color: pal.dim; font.family: win.mono; font.pixelSize: 9; font.letterSpacing: 1; Layout.topMargin: 4 }
                                Repeater {
                                    model: (win.gstat.library || {}).recent || []
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true; spacing: 8
                                        Text { text: modelData.name; color: pal.text; font.family: win.mono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Text { text: win.playtimeText(modelData.minutes * 60); color: pal.dim; font.family: win.mono; font.pixelSize: 10 }
                                        Text { text: win.dateOfEpoch(modelData.last); color: pal.dim; font.family: win.mono; font.pixelSize: 10; Layout.preferredWidth: 90; horizontalAlignment: Text.AlignRight }
                                    }
                                }
                                Item { Layout.fillHeight: true }
                            }
                            }

                            Card {
                                Layout.fillHeight: true; Layout.minimumHeight: 230
                                title: win.t("LIVE"); sub: win.t("last 5 minutes while STATUS is open")
                                GridLayout {
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    columns: 2; columnSpacing: 10; rowSpacing: 8
                                    Spark {
                                        label: win.t("GPU LOAD"); values: win.stHist.gpuLoad; max: 100
                                        current: (win.gstat.gpu || {}).load != null ? win.gstat.gpu.load + " %" : "—"
                                    }
                                    Spark {
                                        label: "GPU °C"; values: win.stHist.gpuTemp; max: 100; tint: pal.amber
                                        current: (win.gstat.gpu || {}).temp != null ? win.gstat.gpu.temp + " °C" : "—"
                                    }
                                    Spark {
                                        label: "CPU °C"; values: win.stHist.cpuTemp; max: 100; tint: pal.pink
                                        current: (win.gstat.system || {}).temp != null ? win.gstat.system.temp + " °C" : "—"
                                    }
                                    Spark {
                                        label: win.t("RAM · VRAM %"); values: win.stHist.ram; max: 100; tint: pal.sky
                                        current: Math.round(win.stHist.ram.length ? win.stHist.ram[win.stHist.ram.length - 1] : 0) + " % · "
                                                 + Math.round(win.stHist.vram.length ? win.stHist.vram[win.stHist.vram.length - 1] : 0) + " %"
                                    }
                                }
                            }
                        }
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
                        glyph: ""; label: win.t("REFRESH")
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
