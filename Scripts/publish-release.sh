#!/bin/bash
# Cuts a release: stamps the version, tags it, builds and notarizes from that tag, uploads
# the disk image to GitHub and points the Homebrew tap at it.
#
# The order matters: the version is committed first so the app reports it, the tag comes
# before the build so the binary is the tagged commit, and the upload comes last so a failed
# notarization never leaves an empty release behind.
#
# Usage: make release-publish VERSION=0.2.0
#
# Needs: a Developer ID certificate, a stored notarytool profile (see Scripts/release.sh),
# release notes in docs/release-notes-<version>.md, and `gh` logged in.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: publish-release.sh <version>   e.g. 0.2.0"; exit 2; }
VERSION="${VERSION#v}"
TAG="v$VERSION"
DMG="build/DirSizes-$VERSION.dmg"
NOTES_FILE="docs/release-notes-$VERSION.md"

command -v gh >/dev/null || { echo "gh is not installed: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
	|| { echo "no Developer ID Application certificate in the keychain"; exit 1; }

# Everything that can stop the release is checked before the tag exists.
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "the working tree has changes, commit or stash them first"
	exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
	echo "$TAG already exists"
	exit 1
fi
if [ ! -f "$NOTES_FILE" ]; then
	echo "no release notes at $NOTES_FILE, write them first" >&2
	exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "==> Releasing $TAG from $BRANCH"

CURRENT=$(cat VERSION)
if [ "$CURRENT" != "$VERSION" ]; then
	echo "$VERSION" > VERSION
	git add VERSION
	git commit -q -m "Release $VERSION"
	echo "    version $CURRENT → $VERSION"
fi
git tag -a "$TAG" -m "DirSizes $VERSION"

make --no-print-directory release
test -f "$DMG" || { echo "expected $DMG and it is not there"; exit 1; }

# The tag is pushed first: `gh release create` on a tag GitHub hasn't seen tags whatever
# main is, which isn't necessarily what was built.
git push origin "$BRANCH"
git push origin "$TAG"

NOTES=$(mktemp)
{
	cat "$NOTES_FILE"
	echo
	echo "### Install"
	echo
	echo "    brew tap philipparndt/dirsizes"
	echo "    brew trust philipparndt/dirsizes"
	echo "    brew install --cask dirsizes"
	echo
	echo "Or download \`$(basename "$DMG")\`, open it and drag DirSizes to Applications."
	echo "The app is signed with a Developer ID and notarized. The cask also links the"
	echo "\`dirsizes\` command-line scanner."
	echo
	echo "    shasum -a 256 -c $(basename "$DMG").sha256"
	echo
	echo "Requires macOS 15 or newer, Apple silicon or Intel."
} > "$NOTES"

gh release create "$TAG" "$DMG" "$DMG.sha256" \
	--title "DirSizes $VERSION" \
	--notes-file "$NOTES"
rm -f "$NOTES"

# After the release exists: the cask names a download that has to be there.
Scripts/update-tap.sh "$VERSION"

echo "==> Published $TAG"
gh release view "$TAG" --json url --jq .url
