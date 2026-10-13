#!/bin/bash
# Signs, notarizes and packages build/DirSizes.app into a disk image for other machines.
#
# Run through `make release`, which builds the universal app first.
#
# Needs a "Developer ID Application" certificate in the keychain and a stored notarytool
# profile (NOTARY_PROFILE, default "notarytool"). On a machine without one, once:
#
#   xcrun notarytool store-credentials notarytool \
#       --apple-id <Apple ID> --team-id 643R6YSRER --password <app-specific password>
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/DirSizes.app"
PROFILE="${NOTARY_PROFILE:-notarytool}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
SHIPPING_ID="de.rnd7.dirsizes"

test -d "$APP" || { echo "no $APP, run make release"; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
DMG="build/DirSizes-$VERSION.dmg"

# Full Disk Access grants and preferences are keyed to the identifier; a local
# BUNDLE_ID override must not reach a release.
if [ "$(plist CFBundleIdentifier)" != "$SHIPPING_ID" ]; then
	echo "refusing to release: $APP is $(plist CFBundleIdentifier), not $SHIPPING_ID" >&2
	echo "  rebuild without BUNDLE_ID set" >&2
	exit 1
fi

# The download is the one build whose processor isn't known in advance.
while IFS= read -r -d '' binary; do
	file -b "$binary" | grep -q "Mach-O" || continue
	archs=$(lipo -archs "$binary")
	for wanted in arm64 x86_64; do
		case " $archs " in
			*" $wanted "*) ;;
			*)
				echo "refusing to release: ${binary#"$APP/"} is built for '$archs', which lacks $wanted" >&2
				echo "  rebuild universal: make release" >&2
				exit 1
				;;
		esac
	done
done < <(find "$APP/Contents" -type f -perm -111 -print0)

# --- Sign -----------------------------------------------------------------------------
#
# Inside out and without --deep (deprecated; it signs nested code with the outer options).
# The bundled CLI is a Mach-O outside Contents/MacOS that sealing the app would not re-sign,
# so it gets its own signature first.
echo "==> Signing with: $IDENTITY"
MAIN="$APP/Contents/MacOS/$(plist CFBundleExecutable)"
while IFS= read -r -d '' binary; do
	[ "$binary" = "$MAIN" ] && continue
	file -b "$binary" | grep -q "Mach-O" || continue
	codesign --force --timestamp --options runtime --sign "$IDENTITY" "$binary"
	echo "    signed ${binary#"$APP/"}"
done < <(find "$APP/Contents" -type f -perm -111 -print0)
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- Check before Apple does ------------------------------------------------------------
#
# Notarization takes minutes to answer "Invalid"; these two causes show up here in a second.
echo "==> Checking every Mach-O before uploading"
FAILED=0
while IFS= read -r -d '' binary; do
	file -b "$binary" | grep -q "Mach-O" || continue
	details=$(codesign -dvv "$binary" 2>&1)
	if ! grep -q "Authority=Developer ID Application" <<< "$details"; then
		echo "    not signed with a Developer ID: ${binary#"$APP/"}"
		FAILED=1
	elif ! grep -q "flags=.*runtime" <<< "$details"; then
		echo "    no hardened runtime: ${binary#"$APP/"}"
		FAILED=1
	fi
done < <(find "$APP/Contents" -type f -perm -111 -print0)
[ "$FAILED" -eq 0 ] || { echo "Stopping: Apple would reject this."; exit 1; }

# --- Notarize the app -------------------------------------------------------------------
#
# Stapled before packaging so the ticket travels inside the app people drag out of the
# image; stapling the image doesn't staple its contents. Without its own ticket the app
# asks Apple on first launch and fails on machines that can't reach them.
echo "==> Notarizing the app (waits for Apple)"
ditto -c -k --keepParent "$APP" "$APP.zip"
xcrun notarytool submit "$APP.zip" --keychain-profile "$PROFILE" --wait
rm -f "$APP.zip"
xcrun stapler staple "$APP"

# --- Package ----------------------------------------------------------------------------
echo "==> Making $DMG"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "DirSizes" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the disk image (waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# --- Prove it ---------------------------------------------------------------------------
echo "==> Tickets:"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

# The copy inside the image is the one people actually install.
MOUNT=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
if xcrun stapler validate "$MOUNT/DirSizes.app"; then STAPLED=0; else STAPLED=1; fi
hdiutil detach -quiet "$MOUNT" || true
rmdir "$MOUNT" 2>/dev/null || true
[ "$STAPLED" -eq 0 ] || { echo "Stopping: the app inside $DMG carries no ticket."; exit 1; }

echo "==> Gatekeeper:"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

shasum -a 256 "$DMG" | sed "s#build/##" > "$DMG.sha256"
echo "==> Done: $DMG"
