# DirSizes: disk usage scanner (CLI) and sunburst viewer (SwiftUI app).
#
#   make                  build everything (release)
#   make run              launch the app on the start screen (DIR=~/dev scans DIR right away)
#   make demo             launch the app with made-up data
#   make app              build build/DirSizes.app (needed to grant Full Disk Access)
#   make install          install DirSizes.app to /Applications (INSTALL_DIR=~/Applications)
#   make icon             regenerate Resources/AppIcon.icns from Scripts/AppIcon.swift
#   make screenshot       regenerate docs/screenshot.png from the demo data
#   make scan DIR=~/dev   print the largest entries of DIR
#   make bench DIR=~/dev  compare scanner, fts, FileManager and du
#
# Releasing (Developer ID signing, notarization, GitHub release, Homebrew tap):
#
#   make sign-check                      show the identity and notary profile in use
#   make release                         universal, signed, notarized build/DirSizes-<version>.dmg
#   make release-publish VERSION=0.2.0   tag, build, notarize, upload, update the tap
#   make tap VERSION=0.2.0               point the tap at an existing release again

CONFIG    ?= release
DIR       ?= $(HOME)
ARGS      ?=
# Xcode's toolchain matches the SDK; a newer or older one on PATH (e.g. swiftly) may not.
SWIFT     ?= xcrun swift
SWIFTC    ?= xcrun swiftc
# UNIVERSAL=1 builds arm64 and x86_64 in one go; releases always do.
UNIVERSAL ?=
ARCH_FLAGS = $(if $(UNIVERSAL),--arch arm64 --arch x86_64)
# SwiftPM records the deployment target as the SDK version, so macOS treats the app as built
# for macOS 15 and draws it in the old style (gray toolbar icons). Record the real SDK.
SDK_VERSION := $(shell xcrun --show-sdk-version)
LINK_FLAGS = -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker $(SDK_VERSION)

BIN_DIR    = $(shell $(SWIFT) build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path)
APP_NAME   = DirSizes
APP        = build/$(APP_NAME).app
APP_VERSION := $(shell cat VERSION)
BUNDLE_ID ?= de.rnd7.dirsizes
INSTALL_DIR ?= /Applications
ICON       = Resources/AppIcon.icns
ENTITLEMENTS = Resources/DirSizes.entitlements
# Local builds are signed with the Developer ID when there is one: macOS then treats them as
# the same app as the releases, so Full Disk Access and Photos access granted once stay granted
# across rebuilds. Without one (or with LOCAL_IDENTITY=-) the signature is ad-hoc.
LOCAL_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"'),-)

.PHONY: all build run demo scan bench app open-app install icon screenshot clean \
	release release-publish tap sign-check

all: build

build:
	$(SWIFT) build -c $(CONFIG) $(ARCH_FLAGS) $(LINK_FLAGS)

# Runs the binary inside the bundle so the Dock shows the app icon.
# Only scans when DIR is given on the command line; its default is for scan and bench.
# Started through `open`, not by running the binary: macOS checks a process started from a
# terminal against the terminal's permissions, so DirSizes' own Full Disk Access wouldn't
# apply. A copy still running from an earlier build is quit first, since `open` would only
# bring it to the front. Waits until the app quits.
run: app
	-@pkill -f "$(APP)/Contents/MacOS/$(APP_NAME)" && sleep 1
	open -W $(APP) $(if $(filter command line,$(origin DIR)),--args -path $(DIR))

demo: app
	-@pkill -f "$(APP)/Contents/MacOS/$(APP_NAME)" && sleep 1
	open -W $(APP) --args -demo YES

scan: build
	$(BIN_DIR)/dirsizes scan $(DIR) $(ARGS)

bench: build
	$(BIN_DIR)/dirsizes bench $(DIR) $(ARGS)

# A real bundle gets its own Dock icon, menu bar and its own entry under
# System Settings > Privacy & Security > Full Disk Access. Signed with the Developer ID
# (see LOCAL_IDENTITY), it shares that permission with the releases; ad-hoc signed, macOS
# may ask again after a rebuild. `make release` re-signs it for notarization. The CLI
# ships inside it so the Homebrew cask can link it.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/bin
	cp $(BIN_DIR)/DirSizesApp $(APP)/Contents/MacOS/$(APP_NAME)
	cp $(BIN_DIR)/dirsizes $(APP)/Contents/Resources/bin/dirsizes
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	plutil -create xml1 $(APP)/Contents/Info.plist
	plutil -insert CFBundleName -string $(APP_NAME) $(APP)/Contents/Info.plist
	plutil -insert CFBundleExecutable -string $(APP_NAME) $(APP)/Contents/Info.plist
	plutil -insert CFBundleIdentifier -string $(BUNDLE_ID) $(APP)/Contents/Info.plist
	plutil -insert CFBundlePackageType -string APPL $(APP)/Contents/Info.plist
	plutil -insert CFBundleShortVersionString -string $(APP_VERSION) $(APP)/Contents/Info.plist
	plutil -insert CFBundleVersion -string $(APP_VERSION) $(APP)/Contents/Info.plist
	plutil -insert LSMinimumSystemVersion -string 15.0 $(APP)/Contents/Info.plist
	plutil -insert LSApplicationCategoryType -string public.app-category.utilities $(APP)/Contents/Info.plist
	plutil -insert NSHighResolutionCapable -bool true $(APP)/Contents/Info.plist
	plutil -insert CFBundleIconFile -string AppIcon $(APP)/Contents/Info.plist
	plutil -insert NSAppleEventsUsageDescription -string "DirSizes asks Finder to move items to the Trash that need your administrator password, such as apps from the App Store." $(APP)/Contents/Info.plist
	plutil -insert NSPhotoLibraryUsageDescription -string "DirSizes adds up the sizes of your photos and videos to estimate what iCloud Photos stores. Nothing is changed or uploaded." $(APP)/Contents/Info.plist
	codesign --force --timestamp=none --sign "$(LOCAL_IDENTITY)" $(APP)/Contents/Resources/bin/dirsizes
	codesign --force --timestamp=none --sign "$(LOCAL_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP)
	@echo "Built $(APP)"

open-app: app
	open $(APP)

# Grant Full Disk Access to the installed copy; its fixed location lets macOS remember it.
install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto $(APP) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

# The icon is drawn in code; the generated .icns is checked in so normal builds don't need this.
icon:
	mkdir -p build/AppIcon.iconset
	$(SWIFTC) -O Scripts/AppIcon.swift -o build/appicon
	build/appicon build/AppIcon-1024.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(ICON)
	@echo "Wrote $(ICON)"

# Made-up data (FileTree.demo), dark appearance and an English locale, so the picture is
# the same on every machine and shows nobody's real files.
screenshot: app
	mkdir -p docs
	$(APP)/Contents/MacOS/$(APP_NAME) -demo YES -screenshot "$(CURDIR)/docs/screenshot.png" \
		-AppleInterfaceStyle Dark -AppleLanguages '(en)' -AppleLocale en_US
	@echo "Wrote docs/screenshot.png"

release:
	$(MAKE) --no-print-directory app UNIVERSAL=1 CONFIG=release
	Scripts/release.sh

release-publish:
	@test -n "$(VERSION)" || { echo "usage: make release-publish VERSION=0.2.0"; exit 1; }
	Scripts/publish-release.sh $(VERSION)

tap:
	@test -n "$(VERSION)" || { echo "usage: make tap VERSION=0.2.0"; exit 1; }
	Scripts/update-tap.sh $(VERSION)

sign-check:
	@security find-identity -v -p codesigning | grep "Developer ID Application" \
		|| echo "no Developer ID Application certificate in the keychain"
	@xcrun notarytool history --keychain-profile $(or $(NOTARY_PROFILE),notarytool) >/dev/null 2>&1 \
		&& echo "  notary profile: $(or $(NOTARY_PROFILE),notarytool) ✓" \
		|| echo "  notary profile $(or $(NOTARY_PROFILE),notarytool) is not stored yet, see Scripts/release.sh"

clean:
	$(SWIFT) package clean
	rm -rf build
