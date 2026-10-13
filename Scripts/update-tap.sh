#!/bin/bash
# Points the Homebrew tap (philipparndt/homebrew-dirsizes) at a published release.
#
# Separate from publish-release.sh so it can be rerun alone, e.g. after a failed push.
#
# Usage: Scripts/update-tap.sh <version> [sha256]
#        Scripts/update-tap.sh --print <version> [sha256]   show the cask, change nothing
#
# The checksum is read from build/DirSizes-<version>.dmg.sha256 when not given.
set -euo pipefail

cd "$(dirname "$0")/.."

PRINT=""
if [ "${1:-}" = "--print" ]; then PRINT=1; shift; fi

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: update-tap.sh [--print] <version> [sha256]"; exit 2; }
VERSION="${VERSION#v}"
SHA="${2:-}"

REPO="${DIRSIZES_REPO:-philipparndt/dirsizes}"
TAP="${DIRSIZES_TAP:-philipparndt/homebrew-dirsizes}"
DMG="build/DirSizes-$VERSION.dmg"

if [ -z "$SHA" ]; then
	test -f "$DMG.sha256" || { echo "no $DMG.sha256 and no checksum given"; exit 1; }
	SHA=$(awk '{print $1}' < "$DMG.sha256")
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "not a sha256: $SHA"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CASK="$WORK/dirsizes.rb"

cat > "$CASK" <<RUBY
# typed: strict
# frozen_string_literal: true

cask "dirsizes" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/DirSizes-#{version}.dmg"
  name "DirSizes"
  desc "Fast disk usage scanner with a sunburst chart"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "DirSizes.app"
  binary "#{appdir}/DirSizes.app/Contents/Resources/bin/dirsizes"

  zap trash: [
    "~/Library/Application Support/de.rnd7.dirsizes",
    "~/Library/Preferences/de.rnd7.dirsizes.plist",
    "~/Library/Saved Application State/de.rnd7.dirsizes.savedState",
  ]
end
RUBY

if command -v brew >/dev/null; then
	echo "==> brew style"
	brew style "$CASK" || echo "    (style complained, not fatal)"
fi

if [ -n "$PRINT" ]; then
	cat "$CASK"
	exit 0
fi

command -v gh >/dev/null || { echo "gh is not installed: brew install gh"; exit 1; }

# The cask must describe the file GitHub actually serves, or `brew install` fails with a
# checksum mismatch on somebody else's machine.
PUBLISHED=$(gh release view "v$VERSION" --repo "$REPO" --json assets \
	--jq ".assets[] | select(.name == \"DirSizes-$VERSION.dmg\") | .digest // \"\"" 2>/dev/null || true)
if [ -z "$PUBLISHED" ]; then
	echo "no DirSizes-$VERSION.dmg published at v$VERSION in $REPO, publish the release first" >&2
	exit 1
fi
if [ "$PUBLISHED" != "null" ] && [ "$PUBLISHED" != "sha256:$SHA" ]; then
	echo "the published image is not the one this cask pins:" >&2
	echo "  cask:      sha256:$SHA" >&2
	echo "  published: $PUBLISHED" >&2
	exit 1
fi
echo "==> v$VERSION is published and the image matches"

echo "==> Cloning $TAP"
gh repo clone "$TAP" "$WORK/tap" -- --quiet
mkdir -p "$WORK/tap/Casks"
cp "$CASK" "$WORK/tap/Casks/dirsizes.rb"

cd "$WORK/tap"
# `status`, not `diff`: in a fresh tap the cask is untracked and `git diff` sees nothing.
if [ -z "$(git status --porcelain -- Casks/dirsizes.rb)" ]; then
	echo "==> $TAP already points at $VERSION"
	exit 0
fi
git add Casks/dirsizes.rb
git commit -q -m "DirSizes $VERSION"
# An empty tap has no branch yet; name it main.
git push -q origin HEAD:main
SHORT_TAP="${TAP/\/homebrew-//}"
echo "==> $TAP now installs DirSizes $VERSION"
echo "    brew tap $SHORT_TAP && brew trust $SHORT_TAP"
echo "    brew install --cask dirsizes"
