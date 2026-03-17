PROJECT := MenuStats.xcodeproj
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build
XCODEBUILD_FLAGS := \
	-quiet -hideShellScriptEnvironment \
	ENABLE_CODE_COVERAGE=NO

PRODUCTS_DIR = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
APP_PATH = $(PRODUCTS_DIR)/MenuStats.app
APP_EXEC_PATH = $(APP_PATH)/Contents/MacOS/MenuStats
BATTERY_PATH = $(PRODUCTS_DIR)/battery_tracker
PROFILE_TRACE ?= $(DERIVED_DATA)/MenuStats-Time-Profiler.trace
PROFILE_TEMPLATE ?= Time Profiler

.PHONY: help app run open-app battery run-battery battery-watch benchmarks profile clean

help:
		@printf '%s\n' \
			'make app            Build MenuStats.app' \
			'make run            Build and run MenuStats in this terminal' \
			'make open-app       Build and open MenuStats.app' \
			'make battery        Build battery_tracker' \
			'make run-battery    Build and run battery_tracker' \
			'make battery-watch  Build and run battery_tracker watch' \
			'make profile        Build MenuStats and launch xctrace Time Profiler' \
			'make benchmarks     Run charts benchmarks' \
			'make clean          Remove $(DERIVED_DATA)'

app:
	xcodebuild -project $(PROJECT) build \
	-scheme MenuStats -configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	$(XCODEBUILD_FLAGS)

run: app
	$(APP_EXEC_PATH)

open-app: app
	open "$(APP_PATH)"

benchmarks:
	swift run -c release --package-path Benchmarks MenuStatsBenchmarks \
		--time-unit us --columns name,time,throughput,std,iterations

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

battery:
	xcodebuild -project $(PROJECT) build \
	-scheme battery_tracker -configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	$(XCODEBUILD_FLAGS)


run-battery: battery
	$(BATTERY_PATH)

battery-watch: battery
	$(BATTERY_PATH) watch

clean:
	rm -rf $(DERIVED_DATA) default.profraw
