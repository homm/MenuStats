# StillCore

StillCore is a macOS menu bar utility for Apple Silicon metrics. It shows live charts for SoC power, temperature, frequency, and usage, and includes an optional background helper for tracking battery usage sessions.

<img src="static/app.png" alt="StillCore app screenshot" width="516">

## Requirements

- macOS 14 or newer
- Apple Silicon Mac

## Download

Prebuilt downloads are not published yet. For now, build StillCore from source.

## Build From Source

Building from source requires Xcode with Swift 6 support and network access for Swift Package dependencies.

Create a local DMG from source:

```sh
make release-dmg
```

This creates the Release `StillCore.dmg`.

Remove build artifacts:

```sh
make clean
```

## Development

Development builds use `CONFIGURATION=Debug` by default.
Pass `CONFIGURATION=Release` to build and run the Release configuration with the same command.

Build and run from the terminal:

```sh
make run
```

Build and open the app bundle:

```sh
make open-app
```

Rebuild the app and restart the battery helper if it is already registered:

```sh
make helper-restart
```

Launch Instruments Time Profiler for a Release build:

```sh
make profile
```

## Local Metrics Core Development

Use `LOCAL=1` when you want to develop or test StillCore together
with local changes in the metrics collection core.

Additional requirements:

- Rust toolchain with Cargo
- Xcode command line tools
- Local checkouts of `macmon` and `macmon-bindings` next to this repository

Clone the sibling repositories and build the local `macmon` xcframework:

```sh
cd ..
git clone --branch cluster-independent https://github.com/homm/macmon.git
git clone https://github.com/homm/macmon-bindings.git
cd macmon
make xcframework
cd ../StillCore
```

Build and open StillCore against the local metrics core:

```sh
LOCAL=1 make open-app
```

`LOCAL=1` uses `StillCore.local.xcworkspace`, expects `../macmon/dist/CMacmon.xcframework`,
and uses the sibling `../macmon-bindings` checkout.
