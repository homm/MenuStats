NAME := StillCore
LOCAL ?=
WORKSPACE ?=
CONFIGURATION ?= Debug
DEVELOPMENT_TEAM ?=
NOTARY_PROFILE ?= $(NAME)-Notarization
DERIVED_DATA := .build
XCODEBUILD_FLAGS := \
	-quiet -hideShellScriptEnvironment \
	ENABLE_CODE_COVERAGE=NO
NOTARIZATION_FLAGS := \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
	OTHER_CODE_SIGN_FLAGS="--timestamp"

ifneq ($(LOCAL),)
    WORKSPACE := $(NAME).local
    MACMON_XCFRAMEWORK_PATH := ../macmon/dist/CMacmon.xcframework
    export MACMON_XCFRAMEWORK_PATH
endif

ifneq ($(DEVELOPMENT_TEAM),)
    XCODEBUILD_FLAGS += DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)
endif

XCODE_CONTAINER := -project $(NAME).xcodeproj
ifneq ($(WORKSPACE),)
    XCODE_CONTAINER := -workspace $(WORKSPACE).xcworkspace
endif

PRODUCTS_DIR = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
APP_PATH = $(PRODUCTS_DIR)/$(NAME).app
APP_EXEC_PATH = $(APP_PATH)/Contents/MacOS/$(NAME)
HELPER_LABEL = com.github.homm.StillCore.BatteryTracker
HELPER_STATE_PATH = $(HOME)/Library/Application Support/com.github.homm.StillCore/battery-tracker-state.json
PROFILE_TRACE ?= $(DERIVED_DATA)/$(NAME)-Time-Profiler.trace
PROFILE_TEMPLATE ?= Time Profiler
DMG_PATH = $(NAME).dmg
DMG_STAGING_DIR = $(DERIVED_DATA)/dmg

.PHONY: help
help:
	@printf '%s\n' \
		'make app            Build $(NAME).app' \
		'LOCAL=1 make app    Build with local workspace and local macmon xcframework' \
		'make run            Build and run $(NAME) in this terminal' \
		'make open-app       Build and open $(NAME).app' \
		'make release        Build Release, create $(NAME).dmg, submit for notarization' \
		'  DEVELOPMENT_TEAM=... Team id passed to xcodebuild signing settings' \
		'  NOTARY_PROFILE=... Keychain profile for notarytool (default: $(NOTARY_PROFILE))' \
		'make helper-restart Build app and restart battery helper' \
		'make profile        Build $(NAME) and launch xctrace Time Profiler' \
		'make benchmarks     Run charts benchmarks' \
		'make clean          Remove .build'

.PHONY: app
app:
	xcodebuild $(XCODE_CONTAINER) build \
	-scheme $(NAME) -configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	$(XCODEBUILD_FLAGS)

.PHONY: release
release: XCODEBUILD_FLAGS += $(NOTARIZATION_FLAGS)
release: release-dmg
	@if xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		:; \
	else \
		echo ""; \
		echo "Missing or invalid notarytool keychain profile: $(NOTARY_PROFILE)"; \
		echo ""; \
		echo "Create it once with:"; \
		echo "  xcrun notarytool store-credentials \"$(NOTARY_PROFILE)\" --apple-id \"<apple-id>\" --team-id \"$(if $(DEVELOPMENT_TEAM),$(DEVELOPMENT_TEAM),<team-id>)\""; \
		echo ""; \
		echo "notarytool will then prompt for the app-specific password and save it in Keychain."; \
		exit 1; \
	fi
	xcrun notarytool submit "$(DMG_PATH)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	@echo "Release artifact: $(DMG_PATH)"

.PHONY: release-dmg
release-dmg: CONFIGURATION=Release
release-dmg: app
	rm -f "$(DMG_PATH)"
	rm -rf "$(DMG_STAGING_DIR)"
	mkdir -p "$(DMG_STAGING_DIR)"
	cp -R "$(APP_PATH)" "$(DMG_STAGING_DIR)/"
	ln -s /Applications "$(DMG_STAGING_DIR)/Applications"
	hdiutil create -volname "$(NAME)" \
		-srcfolder "$(DMG_STAGING_DIR)" \
		-ov -format UDZO \
		"$(DMG_PATH)"

.PHONY: run
run: app
	$(APP_EXEC_PATH)

.PHONY: open-app
open-app: app
	open "$(APP_PATH)"

.PHONY: helper-restart
helper-restart: app
	rm -f "$(HELPER_STATE_PATH)"
	@echo "Restarting helper..."
	@if launchctl print "gui/$$(id -u)/$(HELPER_LABEL)" >/dev/null 2>&1; then \
		launchctl kickstart -k "gui/$$(id -u)/$(HELPER_LABEL)"; \
		echo "Helper restarted."; \
	else \
		echo "Helper is not registered in launchd. Start it from the StillCore UI."; \
		exit 1; \
	fi

.PHONY: benchmarks
benchmarks:
	swift run -c release --package-path Benchmarks Benchmarks \
		--time-unit us --columns name,time,throughput,std,iterations

.PHONY: profile
profile: CONFIGURATION=Release
profile: app
	rm -rf "$(PROFILE_TRACE)"
	@set -e; \
	"$(APP_EXEC_PATH)" & \
	app_pid=$$!; \
	echo "Profiling PID $$app_pid"; \
	xcrun xctrace record \
	--template "$(PROFILE_TEMPLATE)" \
	--output "$(PROFILE_TRACE)" \
	--attach "$$app_pid"; \
	open "$(PROFILE_TRACE)"

.PHONY: clean
clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "./Benchmarks/.build"
