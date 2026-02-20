APP_NAME   = Switcher
BUNDLE_ID  = com.switcher.app
BUILD_DIR  = .build/release
APP_DIR    = $(APP_NAME).app
CONTENTS   = $(APP_DIR)/Contents
VOL_NAME   = $(APP_NAME)
DMG_TMP    = .dmg-tmp.dmg
DMG_NAME   = $(APP_NAME).dmg

.PHONY: all build bundle sign run dmg clean

# Default target: build + bundle
all: bundle

# Compile with Swift Package Manager (release mode)
build:
	swift build -c release 2>&1

# Create proper .app bundle
bundle: build
	@echo "📦 Creating $(APP_DIR)..."
	@rm -rf $(APP_DIR)
	@mkdir -p $(CONTENTS)/MacOS
	@mkdir -p $(CONTENTS)/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/
	@cp Resources/Info.plist        $(CONTENTS)/
	@cp Resources/AppIcon.icns      $(CONTENTS)/Resources/
	@echo "✅ Bundle created: $(APP_DIR)"

# Ad-hoc code sign (no Apple ID needed for local use)
sign: bundle
	@echo "🔏 Signing $(APP_DIR)..."
	@codesign --force --deep --sign - $(APP_DIR)
	@echo "✅ Signed"

# Build, sign, and launch
run: sign
	@echo "🚀 Launching $(APP_NAME)..."
	@open $(APP_DIR)

# Build a distributable DMG (drag-to-Applications layout)
dmg: sign
	@echo "💿 Building DMG..."
	@rm -f "$(DMG_TMP)" "$(DMG_NAME)"
	@# Create writable disk image (60 MB, plenty of headroom)
	@hdiutil create -size 60m -fs HFS+ -volname "$(VOL_NAME)" \
		-ov "$(DMG_TMP)" > /dev/null
	@# Mount it (hidden from Finder sidebar so it doesn't pop up)
	@hdiutil attach "$(DMG_TMP)" \
		-mountpoint "/Volumes/$(VOL_NAME)" -nobrowse > /dev/null
	@# Populate
	@cp -r "$(APP_DIR)" "/Volumes/$(VOL_NAME)/"
	@ln -s /Applications "/Volumes/$(VOL_NAME)/Applications"
	@# Arrange icons via Finder AppleScript
	@osascript Resources/dmg-layout.applescript "$(VOL_NAME)" 2>/dev/null || true
	@sleep 1 && sync
	@# Unmount
	@hdiutil detach "/Volumes/$(VOL_NAME)" > /dev/null
	@# Convert to compressed read-only image
	@hdiutil convert "$(DMG_TMP)" -format UDZO -imagekey zlib-level=9 \
		-o "$(DMG_NAME)" > /dev/null
	@rm -f "$(DMG_TMP)"
	@echo "✅ $(DMG_NAME) ($$(du -sh $(DMG_NAME) | cut -f1))"

# Remove build artifacts
clean:
	@rm -rf .build $(APP_DIR) $(DMG_NAME) $(DMG_TMP)
	@echo "🧹 Cleaned"

# Show which accessibility permission is granted
check-permissions:
	@osascript -e 'tell application "System Events" to get name of every process'
