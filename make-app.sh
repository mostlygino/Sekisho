#!/bin/sh
# Builds build/Sekisho.app (release, ad-hoc signed).
#   SEKISHO_CHANNEL=Release|Beta|Development (default Development) is stamped into Info.plist with the commit
#   and build date, for the About window.
# SwiftUI macros need the full Xcode toolchain, not only the Command Line Tools.
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product SekishoApp
app=build/Sekisho.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SekishoApp "$app/Contents/MacOS/Sekisho"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/mostlygino.png Resources/tablet.png "$app/Contents/Resources/"
cp "docs/demo/Sekisho demo.sekisho" "$app/Contents/Resources/Demo.sekisho"
# Sekisho's licence and the licences of the packages compiled into it (Apache-2.0 asks for them with binaries).
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE BRAND.md "$app/Contents/Resources/Licenses/"
for dir in .build/checkouts/*; do
  for f in "$dir"/LICENSE* "$dir"/NOTICE*; do [ -f "$f" ] && cp "$f" "$app/Contents/Resources/Licenses/$(basename "$dir")-$(basename "$f")"; done
done
# Signal green for AppKit controls: focus rings, switches, prominent buttons.
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist /dev/null >/dev/null
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit+"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SekishoCommit $commit" "$plist"
/usr/libexec/PlistBuddy -c "Set :SekishoBuildDate $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
/usr/libexec/PlistBuddy -c "Set :SekishoChannel ${SEKISHO_CHANNEL:-Development}" "$plist"
[ -n "${SEKISHO_BUILD:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SEKISHO_BUILD" "$plist"
codesign --force --sign - "$app"
echo "$app"
