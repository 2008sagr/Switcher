APP_NAME   = Switcher
BUNDLE_ID  = com.switcher.app
BUILD_DIR  = .build/release
APP_DIR    = $(APP_NAME).app
CONTENTS   = $(APP_DIR)/Contents
VOL_NAME   = $(APP_NAME)
DMG_TMP    = .dmg-tmp.dmg
DMG_NAME   = $(APP_NAME).dmg

.PHONY: all build bundle sign run dmg clean cert

# Default target: build + bundle
all: bundle

# Compile с Swift Package Manager (release mode).
# Собираем только продукт SwitcherApp: цель SwitcherTests использует
# @testable import и не компилируется в release-конфигурации (SwiftPM
# не включает -enable-testing вне debug) — эта цель нужна только для
# `swift run SwitcherTests` и не должна попадать в .app.
build:
	swift build -c release --product SwitcherApp 2>&1

# Create proper .app bundle
bundle: build
	@echo "📦 Creating $(APP_DIR)..."
	@rm -rf $(APP_DIR)
	@mkdir -p $(CONTENTS)/MacOS
	@mkdir -p $(CONTENTS)/Resources
	@cp $(BUILD_DIR)/SwitcherApp $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist        $(CONTENTS)/
	@cp Resources/AppIcon.icns      $(CONTENTS)/Resources/
	@cp -R $(BUILD_DIR)/Switcher_SwitcherCore.bundle $(CONTENTS)/Resources/
	@echo "✅ Bundle created: $(APP_DIR)"

# Подпись стабильной локальной идентичностью.
#
# Зачем не ad-hoc: macOS привязывает разрешение Accessibility к «требованию к
# коду». При ad-hoc это отпечаток самого бинарника (cdhash), поэтому КАЖДАЯ
# пересборка выглядит для системы новым приложением, и выданное разрешение
# перестаёт действовать — приложение молча перестаёт ловить клавиатуру.
# С сертификатом требование выглядит так:
#     identifier "com.switcher.app" and certificate leaf = H"..."
# отпечатка бинарника в нём нет, и разрешение переживает пересборки.
#
# Если сертификата на машине нет — откатываемся на ad-hoc, чтобы сборка не
# ломалась у того, кто его не создавал. Создать: make cert
SIGN_IDENTITY ?= Switcher Dev Signing

sign: bundle
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "🔏 Подписываю как «$(SIGN_IDENTITY)»..."; \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_DIR); \
		echo "✅ Подписано (разрешение Accessibility переживёт пересборку)"; \
	else \
		echo "⚠️  Идентичность «$(SIGN_IDENTITY)» не найдена — подписываю ad-hoc."; \
		echo "⚠️  Разрешение Accessibility придётся выдавать заново после КАЖДОЙ сборки."; \
		echo "⚠️  Исправить один раз: make cert"; \
		codesign --force --deep --sign - $(APP_DIR); \
	fi

# Разовое создание локального сертификата для подписи.
# Доверять ему не требуется: доверие нужно для проверки подписи, а не для
# подписания — codesign работает и с недоверенным сертификатом.
cert:
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "✅ Идентичность «$(SIGN_IDENTITY)» уже есть."; \
	else \
		echo "🔑 Создаю сертификат «$(SIGN_IDENTITY)»..."; \
		tmp=$$(mktemp -d); \
		printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=$(SIGN_IDENTITY)\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n' > $$tmp/ext.cnf; \
		openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
			-keyout $$tmp/key.pem -out $$tmp/cert.pem -config $$tmp/ext.cnf 2>/dev/null; \
		openssl pkcs12 -export -out $$tmp/b.p12 -inkey $$tmp/key.pem -in $$tmp/cert.pem \
			-name "$(SIGN_IDENTITY)" -passout pass:switcher 2>/dev/null; \
		security import $$tmp/b.p12 -k ~/Library/Keychains/login.keychain-db \
			-P switcher -T /usr/bin/codesign; \
		rm -rf $$tmp; \
		echo "✅ Готово. Теперь: make run, затем выдать разрешение Accessibility ОДИН раз."; \
	fi

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
