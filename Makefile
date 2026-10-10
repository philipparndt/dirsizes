# DirSizes: disk usage scanner (CLI) and sunburst viewer (SwiftUI app).
#
#   make                  build everything (release)
#   make run DIR=~/dev    launch the app and scan DIR
#   make app              build build/DirSizes.app (needed to grant Full Disk Access)
#   make install          install DirSizes.app to /Applications (INSTALL_DIR=~/Applications)
#   make icon             regenerate Resources/AppIcon.icns from Scripts/AppIcon.swift
#   make scan DIR=~/dev   print the largest entries of DIR
#   make bench DIR=~/dev  compare scanner, fts, FileManager and du

CONFIG    ?= release
DIR       ?= $(HOME)
ARGS      ?=

BIN_DIR    = .build/$(CONFIG)
APP_NAME   = DirSizes
APP        = build/$(APP_NAME).app
BUNDLE_ID ?= local.dirsizes
INSTALL_DIR ?= /Applications
ICON       = Resources/AppIcon.icns

.PHONY: all build run scan bench app open-app install icon clean

all: build

build:
	swift build -c $(CONFIG)

# Runs the binary inside the bundle so the Dock shows the app icon.
run: app
	$(APP)/Contents/MacOS/$(APP_NAME) -path $(DIR)

scan: build
	$(BIN_DIR)/dirsizes scan $(DIR) $(ARGS)

bench: build
	$(BIN_DIR)/dirsizes bench $(DIR) $(ARGS)

# A real bundle gets its own Dock icon, menu bar and its own entry under
# System Settings > Privacy & Security > Full Disk Access. The signature is ad-hoc,
# so macOS may ask for that permission again after a rebuild.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN_DIR)/DirSizesApp $(APP)/Contents/MacOS/$(APP_NAME)
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	plutil -create xml1 $(APP)/Contents/Info.plist
	plutil -insert CFBundleName -string $(APP_NAME) $(APP)/Contents/Info.plist
	plutil -insert CFBundleExecutable -string $(APP_NAME) $(APP)/Contents/Info.plist
	plutil -insert CFBundleIdentifier -string $(BUNDLE_ID) $(APP)/Contents/Info.plist
	plutil -insert CFBundlePackageType -string APPL $(APP)/Contents/Info.plist
	plutil -insert CFBundleShortVersionString -string 0.1.0 $(APP)/Contents/Info.plist
	plutil -insert LSMinimumSystemVersion -string 15.0 $(APP)/Contents/Info.plist
	plutil -insert NSHighResolutionCapable -bool true $(APP)/Contents/Info.plist
	plutil -insert CFBundleIconFile -string AppIcon $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
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
	swiftc -O Scripts/AppIcon.swift -o build/appicon
	build/appicon build/AppIcon-1024.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(ICON)
	@echo "Wrote $(ICON)"

clean:
	swift package clean
	rm -rf build
