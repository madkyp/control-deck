import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ShellRoot {
    FloatingWindow {
        id: win
        title: "Install Deck"
        implicitWidth: 600
        implicitHeight: 680
        color: pal.bg

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
        }
        readonly property string mono: "JetBrainsMono Nerd Font"

        // ---- install state (queue) --------------------------------------
        property string scriptPath: Quickshell.env("HOME") + "/.local/bin/install-any"
        property var    queue: []          // [{path,name,type,label,supported}]
        property var    queuePaths: []     // paths awaiting detection
        property var    installPaths: []   // supported paths sent to install
        readonly property var formats: [
            { t: "APPIMAGE", e: ".AppImage  .appimage" },
            { t: "PACMAN",   e: ".pkg.tar.zst  .pkg.tar.xz  .pkg.tar.gz  .pkg.tar" },
            { t: "FLATPAK",  e: ".flatpak" },
            { t: "TAR",      e: ".tar  .tar.gz  .tgz  .tar.xz  .tar.zst  .tar.bz2" }
        ]
        property string logText: ""
        property string status: "AWAITING FILE"
        property color  statusColor: pal.dim
        property bool   busy: installProc.running || detectManyProc.running

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

        // ---- manage state -----------------------------------------------
        property string view: "install"
        property var apps: []
        property var appsFiltered: []
        property string searchText: ""
        property string selPath: ""
        property string selName: ""
        property string selIcon: ""
        property string selResolvedIcon: ""
        property string selSource: ""
        property string selPkg: ""
        property string selAction: ""
        property string manageLog: ""
        property string manageStatus: "SELECT AN APP"
        property bool confirmUninstall: false
        property bool manageBusy: editProc.running || uninstallProc.running
                                  || listProc.running || infoProc.running

        property string appsInfo: "0 / 0"
        onAppsChanged: applyFilter()
        onSearchTextChanged: applyFilter()
        function applyFilter() {
            var q = searchText.toLowerCase();
            if (!q) appsFiltered = apps;
            else appsFiltered = apps.filter(function(a){ return a.name.toLowerCase().indexOf(q) >= 0; });
            appsInfo = appsFiltered.length + " / " + apps.length;
        }
        function refreshApps() {
            selPath = ""; selName = ""; selIcon = ""; selResolvedIcon = "";
            selSource = ""; selPkg = ""; selAction = ""; confirmUninstall = false;
            listProc.running = true;
        }
        function selectApp(p) { confirmUninstall = false; manageLog = ""; selPath = p; infoProc.running = true; }

        // ---- store state (search & install by name) ---------------------
        property string storeQuery: ""
        property var    results: []
        property var    installArgs: []
        property string storeLog: ""
        property string storeStatus: "BUSCA UNA APP"
        property bool   storeBusy: searchProc.running || storeInstallProc.running

        function srcColor(s) {
            return s === "repo" ? pal.accent : (s === "aur" ? pal.pink : "#7dcfff");
        }
        function runSearch(q) {
            if (!q || q.trim() === "") return;
            storeQuery = q.trim(); results = []; storeLog = "";
            storeStatus = "BUSCANDO…";
            searchProc.running = true;
        }
        function installPkg(src, id, remote) {
            installArgs = [src, id, remote || ""];
            storeLog = "";
            storeStatus = "INSTALANDO " + id + "…";
            storeInstallProc.running = true;
        }

        // ---- backend processes ------------------------------------------
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
            }
        }
        Process {
            id: openProc
            command: ["xdg-open", Quickshell.env("HOME") + "/Applications"]
        }
        Process {
            id: listProc
            command: [win.scriptPath, "list"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try { win.apps = JSON.parse(text); }
                    catch (e) { win.apps = []; }
                    win.manageStatus = win.apps.length + " APPS";
                }
            }
        }
        Process {
            id: infoProc
            command: [win.scriptPath, "appinfo", win.selPath]
            stdout: StdioCollector {
                onStreamFinished: {
                    var n = "", ic = "", ri = "", sc = "", pk = "", ac = "";
                    var L = text.split("\n");
                    for (var i = 0; i < L.length; i++) {
                        var idx = L[i].indexOf("="); if (idx < 0) continue;
                        var k = L[i].substring(0, idx), v = L[i].substring(idx + 1);
                        if (k === "NAME") n = v; else if (k === "ICON") ic = v;
                        else if (k === "RESOLVED_ICON") ri = v; else if (k === "SOURCE") sc = v;
                        else if (k === "PKG") pk = v; else if (k === "ACTION") ac = v;
                    }
                    win.selName = n; win.selIcon = ic; win.selResolvedIcon = ri;
                    win.selSource = sc; win.selPkg = pk; win.selAction = ac;
                    nameEdit.text = n; iconEdit.text = ic;
                    win.manageStatus = sc.toUpperCase();
                }
            }
        }
        Process {
            id: editProc
            command: [win.scriptPath, "edit", win.selPath, nameEdit.text, iconEdit.text]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { win.manageStatus = c === 0 ? "SAVED ✓" : "SAVE FAILED"; win.refreshApps(); }
        }
        Process {
            id: uninstallProc
            command: [win.scriptPath, "uninstall", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            onExited: (c, s) => { win.manageStatus = c === 0 ? "REMOVED ✓" : "FAILED · " + c; win.confirmUninstall = false; win.refreshApps(); }
        }
        Process {
            id: pickProc
            command: [win.scriptPath, "pickfile", "Elige un icono"]
            stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p) iconEdit.text = p; } }
        }
        Process {
            id: previewProc
            command: [win.scriptPath, "rmpreview", win.selPath]
            stdout: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.manageLog += l + "\n" }
        }
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
            id: storeInstallProc
            command: [win.scriptPath, "installpkg"].concat(win.installArgs)
            stdout: SplitParser { onRead: (l) => win.storeLog += l + "\n" }
            stderr: SplitParser { onRead: (l) => win.storeLog += l + "\n" }
            onExited: (c, s) => {
                if (c === 0) { win.storeStatus = "DONE ✓"; }
                else { win.storeStatus = "FAILED · " + c; }
            }
        }

        // ---- reusable bits ----------------------------------------------
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
                onClicked: { win.view = key; if (key === "manage" && win.apps.length === 0) win.refreshApps(); }
            }
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
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: pal.border }

            // nav
            RowLayout {
                spacing: 26
                NavTab { label: "INSTALL"; key: "install" }
                NavTab { label: "MANAGE";  key: "manage" }
                NavTab { label: "STORE";   key: "store" }
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

                // supported formats (shown while the queue is empty)
                ColumnLayout {
                    visible: win.queue.length === 0
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

            // manual path fallback (Wayland DnD safety net)
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: ">"; color: pal.accent; font.family: win.mono; font.pixelSize: 13 }
                TextField {
                    id: pathField
                    Layout.fillWidth: true
                    placeholderText: "paste path…"
                    placeholderTextColor: pal.dim
                    color: pal.text; font.family: win.mono; font.pixelSize: 12
                    background: Rectangle {
                        color: "transparent"
                        border.color: pal.border; border.width: 1; radius: 6
                    }
                    leftPadding: 10
                    onAccepted: if (text.trim()) win.loadFile(text.trim())
                }
            }

            // status
            Section { Layout.fillWidth: true; label: "STATUS"; info: win.status }
            Text {
                Layout.fillWidth: true
                visible: win.queue.length > 0 && win.supportedCount() < win.queue.length
                text: (win.queue.length - win.supportedCount()) + " archivo(s) no instalable(s) se omitirán (deb/rpm/desconocido)."
                color: pal.bad; font.family: win.mono; font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // log
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 150
                radius: 8; color: "#07070c"
                border.color: pal.border; border.width: 1
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 10
                    clip: true
                    TextArea {
                        readOnly: true
                        text: win.logText || "// log output"
                        color: win.logText ? pal.text : pal.dim
                        font.family: win.mono; font.pixelSize: 11
                        wrapMode: TextArea.WordWrap
                        background: null
                        onTextChanged: cursorPosition = length
                    }
                }
            }

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
                Rectangle { width: 1; Layout.preferredHeight: 46; color: pal.border }
                ActBtn {
                    glyph: ""; label: "FOLDER"
                    on: !win.busy
                    onClicked: openProc.running = true
                }
                Rectangle { width: 1; Layout.preferredHeight: 46; color: pal.border }
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

                // search
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: ""; color: pal.accent; font.family: win.mono; font.pixelSize: 12 }
                    TextField {
                        id: searchField
                        Layout.fillWidth: true
                        placeholderText: "filter…"; placeholderTextColor: pal.dim
                        color: pal.text; font.family: win.mono; font.pixelSize: 12; leftPadding: 10
                        background: Rectangle { color: "transparent"; border.color: pal.border; border.width: 1; radius: 6 }
                        onTextChanged: win.searchText = text
                    }
                }

                // app list
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
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
                    Layout.fillWidth: true; spacing: 12
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
                        TextField {
                            id: nameEdit
                            Layout.fillWidth: true; enabled: win.selPath !== ""
                            placeholderText: "app name"; placeholderTextColor: pal.dim
                            color: pal.text; font.family: win.mono; font.pixelSize: 13; leftPadding: 10
                            background: Rectangle { color: "transparent"; border.color: pal.border; border.width: 1; radius: 6 }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            TextField {
                                id: iconEdit
                                Layout.fillWidth: true; enabled: win.selPath !== ""
                                placeholderText: "icon name or /path"; placeholderTextColor: pal.dim
                                color: pal.text; font.family: win.mono; font.pixelSize: 12; leftPadding: 10
                                background: Rectangle { color: "transparent"; border.color: pal.border; border.width: 1; radius: 6 }
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

                Text {
                    Layout.fillWidth: true; visible: win.selAction !== ""
                    text: win.selAction
                    color: win.selSource === "system" ? pal.bad : pal.dim
                    font.family: win.mono; font.pixelSize: 11; wrapMode: Text.WordWrap
                }
                } // end editor panel

                // manage log
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 84
                    visible: win.manageLog !== ""
                    radius: 8; color: "#07070c"; border.color: pal.border; border.width: 1
                    ScrollView {
                        anchors.fill: parent; anchors.margins: 8; clip: true
                        TextArea {
                            readOnly: true
                            text: win.manageLog || "// output"
                            color: win.manageLog ? pal.text : pal.dim
                            font.family: win.mono; font.pixelSize: 11
                            wrapMode: TextArea.WordWrap; background: null
                            onTextChanged: cursorPosition = length
                        }
                    }
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
                    Rectangle { width: 1; Layout.preferredHeight: 46; color: pal.border }
                    ActBtn {
                        glyph: ""; label: "SAVE"; boxed: true
                        on: win.selPath !== "" && !win.manageBusy
                        onClicked: { win.manageLog = ""; editProc.running = true; }
                    }
                    Rectangle { width: 1; Layout.preferredHeight: 46; color: pal.border }
                    ActBtn {
                        glyph: ""
                        label: win.confirmUninstall ? "CONFIRM?" : "UNINSTALL"
                        on: win.selPath !== "" && win.selSource !== "system" && !win.manageBusy
                        onClicked: {
                            if (!win.confirmUninstall) {
                                win.confirmUninstall = true;
                                win.manageLog = "";
                                if (win.selSource === "pacman") {
                                    win.manageStatus = "REVISA Y CONFIRMA";
                                    previewProc.running = true;   // show what pacman -Rns removes
                                } else {
                                    win.manageStatus = "CLICK AGAIN TO CONFIRM";
                                }
                            } else {
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
                    Text { text: ""; color: pal.accent; font.family: win.mono; font.pixelSize: 12 }
                    TextField {
                        id: queryField
                        Layout.fillWidth: true
                        placeholderText: "buscar app en repos · AUR · flatpak…"
                        placeholderTextColor: pal.dim
                        color: pal.text; font.family: win.mono; font.pixelSize: 12; leftPadding: 10
                        enabled: !win.storeBusy
                        background: Rectangle { color: "transparent"; border.color: pal.border; border.width: 1; radius: 6 }
                        onAccepted: win.runSearch(text)
                    }
                    Rectangle {
                        Layout.preferredWidth: 78; Layout.preferredHeight: 34
                        radius: 6
                        color: win.storeBusy ? pal.card : pal.cardHi
                        border.color: pal.accent; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: win.storeBusy ? "…" : "SEARCH"
                            color: pal.accentHi; font.family: win.mono; font.pixelSize: 10; font.letterSpacing: 1
                        }
                        MouseArea {
                            anchors.fill: parent; enabled: !win.storeBusy
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.runSearch(queryField.text)
                        }
                    }
                }

                // results
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    radius: 8; color: pal.panel; border.color: pal.border; border.width: 1; clip: true

                    // empty / loading hint
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        visible: win.results.length === 0
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "力"
                            color: "#141127"; font.pixelSize: 96; font.bold: true
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: win.storeBusy ? "BUSCANDO…"
                                 : (win.storeQuery === "" ? "ESCRIBE UNA APP Y PULSA ENTER"
                                                          : "SIN RESULTADOS PARA «" + win.storeQuery + "»")
                            color: pal.dim; font.family: win.mono; font.pixelSize: 12; font.letterSpacing: 2
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: win.storeQuery === "" && !win.storeBusy
                            text: "busca en repos oficiales · AUR · Flatpak"
                            color: pal.dim; font.family: win.mono; font.pixelSize: 10
                        }
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
                                // source badge
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 62; height: 20; radius: 4
                                    color: "transparent"
                                    border.color: win.srcColor(modelData.source); border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.source.toUpperCase()
                                        color: win.srcColor(modelData.source)
                                        font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
                                    }
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
                                // install / installed
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 68; height: 30; radius: 6
                                    color: modelData.installed ? "transparent" : pal.cardHi
                                    border.color: modelData.installed ? pal.border : pal.accent
                                    border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.installed ? "INSTALLED" : "INSTALL"
                                        color: modelData.installed ? pal.dim : pal.accentHi
                                        font.family: win.mono; font.pixelSize: 8; font.bold: true; font.letterSpacing: 1
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !modelData.installed && !win.storeBusy
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: win.installPkg(modelData.source, modelData.id, modelData.remote)
                                    }
                                }
                            }
                        }
                    }
                }

                // hint for AUR
                Text {
                    Layout.fillWidth: true
                    visible: win.storeLog === ""
                    text: "Repos/Flatpak se instalan aquí. AUR abre un terminal para compilar (pide sudo)."
                    color: pal.dim; font.family: win.mono; font.pixelSize: 10; wrapMode: Text.WordWrap
                }

                // install log
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 96
                    visible: win.storeLog !== ""
                    radius: 8; color: "#07070c"; border.color: pal.border; border.width: 1
                    ScrollView {
                        anchors.fill: parent; anchors.margins: 8; clip: true
                        TextArea {
                            readOnly: true
                            text: win.storeLog
                            color: pal.text; font.family: win.mono; font.pixelSize: 11
                            wrapMode: TextArea.WordWrap; background: null
                            onTextChanged: cursorPosition = length
                        }
                    }
                }
            } // ================= end STORE VIEW =================
        }
    }
}
