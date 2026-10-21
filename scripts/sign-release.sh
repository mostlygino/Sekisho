#!/bin/zsh
# Adds detached GPG signatures to a published release that went out unsigned (the key needed its passphrase).
# Downloads the assets, checks them against SHA256SUMS, signs each and uploads the .sig files.
#
#   scripts/sign-release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/sign-release.sh <version>}
KEY=4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08
REPO=mostlygino/Sekisho
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh release download "v$VERSION" --repo "$REPO" --dir "$WORK" --pattern "Sekisho-$VERSION.*" --pattern SHA256SUMS
(cd "$WORK" && shasum -a 256 -c SHA256SUMS)
for f in "$WORK"/Sekisho-$VERSION.{dmg,pkg,zip}; do
  gpg --local-user "$KEY" --detach-sign --output "$f.sig" "$f"
  gpg --verify "$f.sig" "$f"
done
gh release upload "v$VERSION" --repo "$REPO" --clobber "$WORK"/*.sig
notes=$(gh release view "v$VERSION" --repo "$REPO" --json body -q .body)
gh release edit "v$VERSION" --repo "$REPO" --notes "${notes/GPG signatures from release key \`$KEY\` follow./Each file has a detached GPG signature (.sig) from release key \`$KEY\`.}"
echo "Signed the v$VERSION assets."
