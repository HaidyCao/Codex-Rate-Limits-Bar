APP_NAME := Codex Rate Limits Bar
BUNDLE_ID := local.codex.rate-limits-bar
PRODUCT := CodexRateLimitsBar
CONFIG ?= release
VERIFY_ARTIFACTS := $(CURDIR)/.build/verification
BENCHMARK_MIB ?= 256
BUILD_DIR := .build/$(CONFIG)
DIST_DIR := dist
APP_DIR := $(DIST_DIR)/$(APP_NAME).app
CONTENTS := $(APP_DIR)/Contents
USER_APPS := $(HOME)/Applications
INSTALLED_APP := $(USER_APPS)/$(APP_NAME).app

.PHONY: build test run open stop install-user uninstall-user install-plugin clean verify verify-local-usage verify-plugin-install verify-ui verify-bundle verify-live benchmark

build:
	swift build -c $(CONFIG)
	rm -rf "$(APP_DIR)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BUILD_DIR)/$(PRODUCT)" "$(CONTENTS)/MacOS/$(PRODUCT)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp -R "$(BUILD_DIR)/CodexRateLimitsBar_CodexRateLimitsCore.bundle" "$(CONTENTS)/Resources/"
	chmod +x "$(CONTENTS)/MacOS/$(PRODUCT)"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(PRODUCT)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	-xattr -cr "$(APP_DIR)"
	codesign --force --deep --sign - "$(APP_DIR)"

test:
	python3 Tests/Support/run_isolated.py swift test --skip ScannerPerformanceTests

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

install-plugin: install-user
	"$(INSTALLED_APP)/Contents/MacOS/$(PRODUCT)" install-plugin --source "$(CURDIR)/plugins/codex-usage-monitor"

# Default validation uses fake credentials, isolated Foundation home, and no network.
verify: test verify-ui verify-bundle verify-plugin-install

verify-local-usage: build
	python3 Tests/Integration/verify_local_usage.py "$(CONTENTS)/MacOS/$(PRODUCT)" --artifacts "$(VERIFY_ARTIFACTS)/fixtures"

verify-ui: verify-local-usage
	python3 Tests/UI/verify_menu.py --config "$(CONFIG)" --artifacts "$(VERIFY_ARTIFACTS)"

verify-bundle: build
	python3 Tests/Integration/verify_bundle.py "$(APP_DIR)"

verify-plugin-install: build
	python3 Tests/Integration/verify_plugin_install.py "$(CONTENTS)/MacOS/$(PRODUCT)" --artifacts "$(VERIFY_ARTIFACTS)/plugin-install.json"

# Explicit opt-in: this reads the caller's real Codex account.
verify-live: build
	@"$(CONTENTS)/MacOS/$(PRODUCT)" rate-limits

# Optimized, synthetic fixture. No user logs or credentials are needed.
benchmark:
	USAGE_RUN_BENCHMARKS=1 USAGE_BENCHMARK_MIB="$(BENCHMARK_MIB)" USAGE_BENCHMARK_OUTPUT="$(VERIFY_ARTIFACTS)/benchmark.json" python3 Tests/Support/run_isolated.py swift test -c release --filter ScannerPerformanceTests

clean:
	rm -rf .build "$(DIST_DIR)"
