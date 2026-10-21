#!/bin/zsh
# Builds the two ways people install Sekisho, from an already built app:
#   Sekisho-<version>.dmg  a disk image with a drawn background: drag Sekisho into Applications
#   Sekisho-<version>.pkg  an Installer package that puts Sekisho in Applications
#
#   scripts/make-installers.sh 0.1.0 [build/Sekisho.app] [build/release]
# Needs Xcode's tools (pkgbuild, productbuild, tiffutil) and fetches dmgbuild into build/.installer-venv once.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/make-installers.sh <version> [app] [outdir]}
APP=${2:-build/Sekisho.app}
OUT=${3:-build/release}
[[ -d $APP ]] || { echo "No app at $APP. Run ./make-app.sh first."; exit 1; }
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Art: 1x and 2x, joined into TIFFs so Finder and Installer pick the sharp one on Retina screens.
swiftc -O scripts/make-installer-art.swift -o "$WORK/make-art" 2>/dev/null
"$WORK/make-art" "$WORK/art" "$VERSION" >/dev/null
for name in dmg-background installer-light installer-dark; do
  tiffutil -cathidpicheck "$WORK/art/$name.png" "$WORK/art/$name@2x.png" -out "$WORK/art/$name.tiff" 2>/dev/null
done

# DMG, laid out by dmgbuild (it writes Finder's .DS_Store itself, no Finder window opens).
VENV=build/.installer-venv
[[ -x $VENV/bin/dmgbuild ]] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild; }
DMG="$OUT/Sekisho-$VERSION.dmg"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/installer/dmg-settings.py \
  -D app="$APP" -D background="$WORK/art/dmg-background.tiff" -D volume_icon=Resources/AppIcon.icns \
  "Sekisho $VERSION" "$DMG" > /dev/null 2> >(grep -v 'is deprecated' >&2)

# PKG: the app, fixed to /Applications (never relocated onto a copy found elsewhere).
mkdir -p "$WORK/root" "$WORK/resources"
ditto "$APP" "$WORK/root/Sekisho.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/component.plist"
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/component.plist" --install-location /Applications \
  --identifier dev.mostlygino.sekisho --version "$VERSION" "$WORK/Sekisho-app.pkg" 2> >(grep -v '^write: Permission denied$' >&2)

# Installer shows each page on its own, so the stylesheet goes inline.
SIZE=$(( ($(du -sk "$APP" | cut -f1) + 1023) / 1024 ))
for page in welcome conclusion license; do
  python3 -c 'import sys; css=open(sys.argv[1]).read(); html=open(sys.argv[2]).read()
print(html.replace("<link rel=\"stylesheet\" href=\"style.css\">", "<style>"+css+"</style>").replace("__VERSION__", sys.argv[3]).replace("__SIZE__", sys.argv[4]), end="")' \
    scripts/installer/style.css "scripts/installer/$page.html" "$VERSION" "$SIZE" > "$WORK/resources/$page.html"
done
cp "$WORK/art/installer-light.tiff" "$WORK/art/installer-dark.tiff" "$WORK/resources/"
sed "s/__VERSION__/$VERSION/g" scripts/installer/distribution.xml > "$WORK/distribution.xml"
PKG="$OUT/Sekisho-$VERSION.pkg"
productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$PKG"

echo "$DMG"
echo "$PKG"
