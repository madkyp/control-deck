// Control Deck — in-game temperature line.
// Started by `control-deck overlay <pid>` (the game's wrapper); drawn on the
// Wayland overlay layer, top right, click-through; quits when <pid> exits.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

ShellRoot {
    id: root
    property string bin: Quickshell.env("CD_OVERLAY_BIN") || "control-deck"
    property string pid: Quickshell.env("CD_OVERLAY_PID") || ""
    property string cpu: ""
    property string gpu: ""
    // the monitor focused when the game started (where it opens)
    property var startScreen: {
        var m = Hyprland.focusedMonitor;
        if (m) for (var i = 0; i < Quickshell.screens.length; i++)
            if (Quickshell.screens[i].name === m.name) return Quickshell.screens[i];
        return Quickshell.screens[0];
    }

    function tempColor(t) {
        var n = parseInt(t);
        if (isNaN(n)) return "#6a6580";
        return n >= 85 ? "#f38ba8" : (n >= 75 ? "#e0af68" : "#d8d4e8");
    }

    PanelWindow {
        screen: root.startScreen
        anchors { top: true; right: true }
        margins { top: 10; right: 14 }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "control-deck-overlay"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}
        color: "transparent"
        implicitWidth: line.implicitWidth + 18
        implicitHeight: line.implicitHeight + 8
        visible: root.cpu !== "" || root.gpu !== ""

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: "#b30a0a10"
            border.color: "#2a2740"; border.width: 1
            Row {
                id: line
                anchors.centerIn: parent
                spacing: 6
                Text { text: "CPU"; color: "#b9a3e3"; font.family: "monospace"; font.pixelSize: 13; font.bold: true }
                Text { text: root.cpu !== "" ? root.cpu + "°" : "–"; color: root.tempColor(root.cpu); font.family: "monospace"; font.pixelSize: 13; font.bold: true }
                Text { text: "·"; color: "#6a6580"; font.family: "monospace"; font.pixelSize: 13 }
                Text { text: "GPU"; color: "#b9a3e3"; font.family: "monospace"; font.pixelSize: 13; font.bold: true }
                Text { text: root.gpu !== "" ? root.gpu + "°" : "–"; color: root.tempColor(root.gpu); font.family: "monospace"; font.pixelSize: 13; font.bold: true }
            }
        }
    }

    Process {
        id: poll
        command: [root.bin, "temps", root.pid]
        stdout: StdioCollector {
            onStreamFinished: {
                var alive = true;
                text.split("\n").forEach(function (l) {
                    var i = l.indexOf("="); if (i < 0) return;
                    var k = l.substring(0, i), v = l.substring(i + 1);
                    if (k === "CPU") root.cpu = v;
                    else if (k === "GPU") root.gpu = v;
                    else if (k === "ALIVE") alive = v === "1";
                });
                if (!alive) Qt.quit();
            }
        }
    }
    Timer {
        interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!poll.running) poll.running = true
    }
}
