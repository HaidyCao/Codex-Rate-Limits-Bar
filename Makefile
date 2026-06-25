APP_NAME := Codex Rate Limits Bar
BUNDLE_ID := local.codex.rate-limits-bar
PRODUCT := CodexRateLimitsBar
CONFIG := release
BUILD_DIR := .build/$(CONFIG)
DIST_DIR := dist
APP_DIR := $(DIST_DIR)/$(APP_NAME).app
CONTENTS := $(APP_DIR)/Contents
USER_APPS := $(HOME)/Applications
INSTALLED_APP := $(USER_APPS)/$(APP_NAME).app

.PHONY: build run open stop install-user uninstall-user clean verify

build:
	swift build -c $(CONFIG)
	rm -rf "$(APP_DIR)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources/Scripts"
	cp "$(BUILD_DIR)/$(PRODUCT)" "$(CONTENTS)/MacOS/$(PRODUCT)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp scripts/codex_rate_limits.js "$(CONTENTS)/Resources/Scripts/codex_rate_limits.js"
	chmod +x "$(CONTENTS)/MacOS/$(PRODUCT)" "$(CONTENTS)/Resources/Scripts/codex_rate_limits.js"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(PRODUCT)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	-xattr -cr "$(APP_DIR)"
	codesign --force --deep --sign - "$(APP_DIR)"

run: build
	open -n -g "$(APP_DIR)"

open:
	open -n -g "$(APP_DIR)"

stop:
	-pkill -f "$(APP_NAME).app/Contents/MacOS/$(PRODUCT)"

install-user: build
	-pkill -f "$(INSTALLED_APP)/Contents/MacOS/$(PRODUCT)"
	mkdir -p "$(USER_APPS)"
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(APP_DIR)" "$(INSTALLED_APP)"
	-xattr -cr "$(INSTALLED_APP)"
	codesign --force --deep --sign - "$(INSTALLED_APP)"
	open -g "$(INSTALLED_APP)"

uninstall-user:
	-pkill -f "$(INSTALLED_APP)/Contents/MacOS/$(PRODUCT)"
	rm -rf "$(INSTALLED_APP)"

verify:
	@node scripts/codex_rate_limits.js rate-limits

clean:
	rm -rf .build "$(DIST_DIR)"
