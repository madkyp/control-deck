import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "es.js" as I18n

ShellRoot {
    FloatingWindow {
        id: win
        title: "System Deck"
        implicitWidth: 660
        implicitHeight: 760
        color: pal.bg
        // closing the window ends the process: a windowless instance would
        // reopen its window on every reload (each install/update of shell.qml).
        // A reload also closes the old window, but destroys this timer with it.
        onClosed: quitTimer.start()
        Timer { id: quitTimer; interval: 1500; onTriggered: Qt.quit() }

        // ---- palette (SYSTEM DECK) --------------------------------------
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
        property string scriptPath: Quickshell.env("SYSTEM_DECK_BIN") || (home + "/.local/bin/system-deck")
        // SYSTEM_DECK_VIEW=manage|store|updates|system opens straight on a tab
        property string view: Quickshell.env("SYSTEM_DECK_VIEW") || "install"
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

        // STORE: which source to show (all | repo | aur | flatpak | github)
        property string storeFilter: "all"
        function tagTone(tone) { return tone === "ok" ? pal.ok : (tone === "bad" ? pal.bad : (tone === "warn" ? pal.amber : pal.sky)); }
        function tagTip(t) {
            if (t.indexOf("▲") === 0) return win.t("AUR votes: users who vouch for the package");
            if (/\/mo$/.test(t)) return win.t("Flathub installs last month");
            return ({ "★ RECOMMENDED": win.t("The most trustworthy result named like your search"),
                      "OFFICIAL": win.t("Official Arch / CachyOS repository: built and signed by the distribution"),
                      "PREBUILT AUR": win.t("chaotic-aur: AUR packages built by a third party; trust is the AUR package's"),
                      "THIRD-PARTY REPO": win.t("A repository that isn't Arch's or CachyOS's"),
                      "POPULAR": win.t("100+ votes on the AUR"),
                      "FEW VOTES": win.t("Under 10 votes: few people have checked it"),
                      "NEW · FEW VOTES": win.t("Uploaded under 30 days ago with few votes: the usual shape of malicious AUR packages. Read its review carefully."),
                      "ORPHAN": win.t("No maintainer: nobody updates or checks it"),
                      "OUT OF DATE": win.t("Flagged out of date on the AUR"),
                      "VERIFIED": win.t("Flathub verified the developer: it comes from the app's own authors") })[t] || "";
        }
        function runSearch(q) {
            if (!q || q.trim() === "") return;
            storeFilter = "all";
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

        // ---- system state (clean · backup · history) --------------------
        property string sysView: "clean"
        property var    cleanItems: []
        property string confirmClean: ""    // gaming rows delete big things: second click confirms
        property var    history: []
        // one row per burst of actions on the same thing (e.g. PLAY ×3 + GAME PROFILE on a game)
        property var histRows: {
            var out = [];
            history.forEach(function (h) {
                var tm = Date.parse(h.date.replace(" ", "T")), name = h.name || h.target, last = out[out.length - 1];
                if (last && last.name === name && last.source === h.source && last.result === h.result && last.t0 - tm <= 600000) {
                    var a = last.acts.filter(function (x) { return x.a === h.action; })[0];
                    if (a) a.n++; else last.acts.push({ a: h.action, n: 1 });
                    last.t0 = tm;
                } else out.push({ date: h.date, name: name, source: h.source, result: h.result, t0: tm, acts: [{ a: h.action, n: 1 }] });
            });
            return out;
        }
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

        // saves the ESP/ENG choice (uilang <es|en>)
        Process { id: langSaveProc }

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
            id: pickRestoreProc
            command: [win.scriptPath, "pickfile", win.t("Choose a System Deck backup (.json)")]
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
                    text: lb.content || win.t(lb.placeholder)
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
                    text: "SYSTEM DECK"; color: pal.text; font.family: win.mono
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

                // watermark, centred in the room above the formats list
                Text {
                    id: dropMark
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: fmtList.visible ? -(fmtList.height + 16) / 2 : 0
                    text: "力"; font.pixelSize: 150; font.bold: true
                    color: "#141127"; visible: win.queue.length === 0
                }
                Text {
                    anchors.centerIn: dropMark
                    visible: win.queue.length === 0
                    text: win.t("DROP PACKAGE(S) HERE"); color: pal.dim; font.family: win.mono
                    font.pixelSize: 12; font.letterSpacing: 3
                }

                // supported formats (shown while the queue is empty and there's room)
                ColumnLayout {
                    id: fmtList
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

                // filter by source (only the sources the search found)
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: win.review === null && !reviewProc.running && win.results.length > 0
                    Repeater {
                        model: ["all", "repo", "aur", "flatpak", "github"].filter(function (s) {
                            return s === "all" || win.results.some(function (r) { return r.source === s; });
                        })
                        delegate: Chip {
                            required property var modelData
                            property int n: modelData === "all" ? win.results.length : win.results.filter(function (r) { return r.source === modelData; }).length
                            label: (modelData === "all" ? win.t("ALL") : modelData.toUpperCase()) + "  " + n
                            active: win.storeFilter === modelData
                            onClicked: win.storeFilter = modelData
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: win.t("hover a tag to see what it means"); color: pal.dim
                        font.family: win.mono; font.pixelSize: 9
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
                        model: win.storeFilter === "all" ? win.results : win.results.filter(function (r) { return r.source === win.storeFilter; })
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: resultList.width - 8; height: 56; radius: 8
                            color: pal.card; border.width: 1
                            border.color: modelData.recommended ? pal.ok : pal.border
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
                                            Layout.maximumWidth: 260
                                        }
                                        // trust tags: official, votes, installs, verified… and the risky ones
                                        Repeater {
                                            model: modelData.tags || []
                                            delegate: Rectangle {
                                                required property var modelData
                                                implicitWidth: tagTxt.implicitWidth + 10; implicitHeight: 15; radius: 3
                                                color: "transparent"; border.width: 1; border.color: win.tagTone(modelData.tone)
                                                Text {
                                                    id: tagTxt; anchors.centerIn: parent
                                                    text: win.t(modelData.t.replace(/\/mo$/, "")) + (/\/mo$/.test(modelData.t) ? win.t("/mo") : "")
                                                    color: win.tagTone(modelData.tone)
                                                    font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
                                                }
                                                MouseArea { id: tagMa; anchors.fill: parent; hoverEnabled: true }
                                                Tip { visible: tagMa.containsMouse && text !== ""; text: win.tagTip(modelData.t) }
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
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
                              + win.t("). Every game's shader cache gets rebuilt: expect some stutter the first time you play each game. Old driver caches can be cleaned afterwards in Gaming Deck → SHADERS.")
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
                                    onClicked: win.runSys(["clean", modelData.id], win.t("CLEANING…"))
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
                        text: win.t("Saves your packages (repos and AUR), Flatpaks, GitHub AppImages and the launchers you edited (with their icons) to ~/system-deck-backup-<date>.json.")
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
                            placeholderText: "~/system-deck-backup-….json"
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
                        model: win.histRows
                        ScrollBar.vertical: ScrollBar {}
                        delegate: RowLayout {
                            required property var modelData
                            width: histList.width - 12; height: 26; spacing: 10
                            Text {
                                text: modelData.date.substring(5, 16); color: pal.dim
                                font.family: win.mono; font.pixelSize: 10
                            }
                            Text {
                                Layout.preferredWidth: 220
                                text: modelData.acts.map(function (a) { return win.t(a.a).toUpperCase() + (a.n > 1 ? " ×" + a.n : ""); }).join(" + ")
                                elide: Text.ElideRight
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
                                text: modelData.name; color: pal.text
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

                    // no snapper: keep the column tall so the window doesn't spread out around it
                    Item { Layout.fillHeight: true; visible: win.snapStatus.snapper !== true }

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

        }
    }
}
