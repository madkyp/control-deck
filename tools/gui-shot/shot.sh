#!/bin/bash
# Screenshots of the GUI in a throw-away window (developer tool, Hyprland + grim).
#   tools/gui-shot/shot.sh <block.qml> <out dir> [first-shot second] [shots]
# <block.qml> is pasted into the window (after `property string gameView`), e.g. a
# Timer that switches views; one shot every 10 s from <first>. The window is
# floated at 933×1000, closed afterwards; warnings go to <out dir>/qml.log.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; repo="$here/../.."
block="$1"; out="$2"; first="${3:-14}"; shots="${4:-1}"
work="$(mktemp -d)"; mkdir -p "$out"
python3 - "$repo/quickshell/shell.qml" "$block" "$work/shell.qml" <<'PY'
import sys
t = open(sys.argv[1]).read().replace('title: "System Deck"', 'title: "CD close test 7731"', 1)
anchor = '        property string lang: "en"\n'
assert anchor in t
open(sys.argv[3], 'w').write(t.replace(anchor, anchor + open(sys.argv[2]).read(), 1))
PY
cp "$repo/quickshell/es.js" "$work/"
SYSTEM_DECK_BIN="$repo/bin/system-deck" timeout $(( first + 10 * shots + 20 )) qs -p "$work" > "$out/qml.log" 2>&1 & qp=$!
start=$(date +%s); sleep 4
a="$(hyprctl clients -j | jq -r '.[] | select(.title == "CD close test 7731") | .address' | head -1)"
id="$(hyprctl clients -j | jq -r '.[] | select(.title == "CD close test 7731") | .stableId' | head -1)"
w="hl.get_window('address:$a')"
hyprctl eval "hl.dispatch(hl.dsp.window.float({action = 'enable', window = $w}))" >/dev/null 2>&1 || hyprctl dispatch setfloating "address:$a" >/dev/null
hyprctl eval "hl.dispatch(hl.dsp.window.resize({x = 933, y = 1000, window = $w}))" >/dev/null 2>&1 || hyprctl dispatch resizewindowpixel exact 933 1000,"address:$a" >/dev/null
for ((k = 0; k < shots; k++)); do
    t=$(( first + 10 * k )); while (( $(date +%s) - start < t )); do sleep 1; done
    grim -T "$id" "$out/shot$k.png"
done
timeout 8 qs -p "$here/closer.qml" >/dev/null 2>&1; kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null; rm -rf "$work"
sed -E 's/\x1b\[[0-9;]*m//g' "$out/qml.log" | grep -iE 'warn|error|binding loop' | head -5
echo "windows left: $(hyprctl clients -j | jq '[.[] | select(.title == "CD close test 7731")] | length')"
