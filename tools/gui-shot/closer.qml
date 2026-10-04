// closes the test window opened by tools/gui-shot/shot.sh (by its title)
import Quickshell
import Quickshell.Wayland
import QtQuick
ShellRoot {
    Timer {
        interval: 500; running: true; repeat: true
        property int tries: 0
        onTriggered: {
            var l = ToplevelManager.toplevels.values;
            for (var i = 0; i < l.length; i++)
                if (l[i].title === "CD close test 7731") { l[i].close(); Qt.quit(); return; }
            if (++tries > 10) Qt.quit();
        }
    }
}
