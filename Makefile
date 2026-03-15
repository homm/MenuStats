PROJECT := MenuStats.xcodeproj
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build/xcode
DESTINATION ?= platform=macOS

PRODUCTS_DIR := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
APP_PATH := $(PRODUCTS_DIR)/MenuStats.app
PGAUGE_PATH := $(PRODUCTS_DIR)/pgauge
BATTERY_PATH := $(PRODUCTS_DIR)/battery_tracker

.PHONY: help app run pgauge run-pgauge battery run-battery battery-watch clean

help:
	@printf '%s\n' \
		'make app            Build MenuStats.app' \
		'make run            Build and open MenuStats.app' \
		'make pgauge         Build pgauge' \
		'make run-pgauge     Build and run pgauge' \
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
		build

run: app
	open $(APP_PATH)

pgauge:
	xcodebuild -project $(PROJECT) \
		-scheme pgauge \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		build

run-pgauge: pgauge
	$(PGAUGE_PATH)

battery:
	xcodebuild -project $(PROJECT) \
		-scheme battery_tracker \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		build

run-battery: battery
	$(BATTERY_PATH)

battery-watch: battery
	$(BATTERY_PATH) watch

clean:
	rm -rf $(DERIVED_DATA)
