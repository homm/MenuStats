PROJECT := MenuStats.xcodeproj
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build
DESTINATION ?= platform=macOS,arch=arm64
POWERMETRICS_INTERVAL ?= 500
XCODEBUILD_FLAGS := \
	-quiet \
	-hideShellScriptEnvironment \
	ENABLE_CODE_COVERAGE=NO \
	CLANG_COVERAGE_MAPPING=NO \
	GCC_GENERATE_TEST_COVERAGE_FILES=NO

PRODUCTS_DIR := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
APP_PATH := $(PRODUCTS_DIR)/MenuStats.app
APP_EXEC_PATH := $(APP_PATH)/Contents/MacOS/MenuStats
PGAUGE_PATH := $(PRODUCTS_DIR)/pgauge
BATTERY_PATH := $(PRODUCTS_DIR)/battery_tracker

.PHONY: help app run open-app pgauge run-pgauge run-pgauge-live battery run-battery battery-watch clean

help:
		@printf '%s\n' \
			'make app            Build MenuStats.app' \
			'make run            Build and run MenuStats in this terminal' \
			'make open-app       Build and open MenuStats.app' \
			'make pgauge         Build pgauge' \
			'make run-pgauge     Build and run pgauge with sample input' \
			'make run-pgauge-live Build and run pgauge with powermetrics' \
			'make battery        Build battery_tracker' \
			'make run-battery    Build and run battery_tracker' \
			'make battery-watch  Build and run battery_tracker watch' \
			'make clean          Remove $(DERIVED_DATA)'

app:
	xcodebuild -project $(PROJECT) \
		-scheme MenuStats \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_FLAGS) \
		build

run: app
	$(APP_EXEC_PATH)

open-app: app
	open "$(abspath $(APP_PATH))"

pgauge:
	xcodebuild -project $(PROJECT) \
		-scheme pgauge \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_FLAGS) \
		build

run-pgauge: pgauge
	cat pgauge/sample.plist | $(PGAUGE_PATH)
	@printf '\n'

run-pgauge-live: pgauge
	sudo /usr/bin/powermetrics --samplers cpu_power --format plist -i $(POWERMETRICS_INTERVAL) | $(PGAUGE_PATH)

battery:
	xcodebuild -project $(PROJECT) \
		-scheme battery_tracker \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_FLAGS) \
		build

run-battery: battery
	$(BATTERY_PATH)

battery-watch: battery
	$(BATTERY_PATH) watch

clean:
	rm -rf $(DERIVED_DATA) default.profraw
