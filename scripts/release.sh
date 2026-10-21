#!/bin/zsh
# Cuts a Sekisho release on GitHub. Needs a clean tree on main, gh logged in and the release key.
#
#   scripts/release.sh 0.2.0          bumps the version, builds, signs, commits, pushes, releases
#   scripts/release.sh 0.2.0 --beta   the same, published as a GitHub pre-release labelled Beta
#
# Uploads Sekisho-<version>.dmg (drag to Applications), .pkg (Installer) and .zip (the bare app), a detached GPG
# signature for each, and SHA-256 sums.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--beta], for example 0.2.0}
BETA=${2:-}
[[ -z $BETA || $BETA == --beta ]] || { echo "The second argument can only be --beta."; exit 1; }
KEY=4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08
REPO=mostlygino/Sekisho
OUT=build/release
ZIP="$OUT/Sekisho-$VERSION.zip"
DMG="$OUT/Sekisho-$VERSION.dmg"
PKG="$OUT/Sekisho-$VERSION.pkg"

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3."; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "Commit or stash your changes first."; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Releases come from main."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION already exists."; exit 1; fi
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main is not the same as origin/main. Pull or push first."; exit 1; }

# Tests first: a release never ships red.
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} swift test >/dev/null || { echo "Tests failed, nothing released."; exit 1; }

# Until the release commit exists, any failure puts Info.plist back.
trap '[[ -n ${COMMITTED:-} ]] || git checkout -- Info.plist' EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
git diff --quiet Info.plist || git commit -qm "chore: release v$VERSION" Info.plist
COMMITTED=1

SEKISHO_CHANNEL=$([[ -n $BETA ]] && echo Beta || echo Release) SEKISHO_BUILD=$(date +%Y%m%d%H%M) ./make-app.sh >/dev/null
BUILT=build/Sekisho.app
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
[[ $BUILT_VERSION == "$VERSION" ]] || { echo "Built version is $BUILT_VERSION, not $VERSION."; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent "$BUILT" "$ZIP"
scripts/make-installers.sh "$VERSION" "$BUILT" "$OUT" >/dev/null
# Signs only when the key is usable without a prompt (gpg-agent has the passphrase); otherwise the release goes out
# with SHA-256 sums, and scripts/sign-release.sh adds the signatures later.
SIGNED=
if gpg --batch --pinentry-mode error --local-user "$KEY" --detach-sign --output /dev/null "$ZIP" 2>/dev/null; then
  for f in "$DMG" "$PKG" "$ZIP"; do
    gpg --batch --local-user "$KEY" --detach-sign --output "$f.sig" "$f"
    gpg --verify "$f.sig" "$f"
  done
  SIGNED=1
else
  echo "The release key needs its passphrase: releasing unsigned. Run scripts/sign-release.sh $VERSION afterwards."
fi
(cd "$OUT" && shasum -a 256 Sekisho-$VERSION.dmg Sekisho-$VERSION.pkg Sekisho-$VERSION.zip > SHA256SUMS)
NOTES="$OUT/notes.md"
cat > "$NOTES" <<NOTES_END
## Install

- **Sekisho-$VERSION.dmg**: open it and drag Sekisho into Applications.
- **Sekisho-$VERSION.pkg**: the Installer way. Puts Sekisho in Applications.
- **Sekisho-$VERSION.zip**: the bare app, for scripts.

Sekisho is not notarised by Apple yet, so macOS blocks the first open of the .pkg or of the dragged app. Then go to System Settings > Privacy & Security, click Open Anyway, and open it again. That is needed once.

macOS 26 or later, Apple silicon. Sekisho listens on 127.0.0.1:9090, makes its own certificate authority on first launch and asks before it trusts it. It changes the macOS proxy only when you switch it on, and puts the previous setting back when it quits.

Try it without touching your network settings or keychain: \`open -n /Applications/Sekisho.app --args -demo YES\`.

There is no updater yet: install a newer version over this one.

## Verify

$([[ -n $SIGNED ]] && echo "Each file has a detached GPG signature (.sig) from release key \`$KEY\`. SHA-256:" || echo "GPG signatures from release key \`$KEY\` follow. SHA-256:")

\`\`\`
$(cat "$OUT/SHA256SUMS")
\`\`\`
NOTES_END

git tag -a "v$VERSION" -m "Sekisho $VERSION${BETA:+ Beta}"
git push origin main "v$VERSION"
ASSETS=("$DMG" "$PKG" "$ZIP" "$OUT/SHA256SUMS")
[[ -n $SIGNED ]] && ASSETS+=("$DMG.sig" "$PKG.sig" "$ZIP.sig")
if [[ -n $BETA ]]; then
  gh release create "v$VERSION" --repo "$REPO" --prerelease --title "Sekisho $VERSION Beta" --notes-file "$NOTES" --generate-notes "${ASSETS[@]}"
else
  gh release create "v$VERSION" --repo "$REPO" --title "Sekisho $VERSION" --notes-file "$NOTES" --generate-notes "${ASSETS[@]}"
fi
echo "Released Sekisho $VERSION."
