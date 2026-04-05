import Foundation
import IOKit

private enum BatteryTrackerEngineError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Battery information is unavailable."
        }
    }
}

private struct BatterySnapshot {
    var currentCapacityMah: Int
    var maxCapacityMah: Int
    var isOnACPower: Bool

    var currentPercent: Int {
        guard maxCapacityMah > 0 else { return 0 }
        return Int((Double(currentCapacityMah) * 100.0 / Double(maxCapacityMah)).rounded())
    }

    var powerSource: BatteryPowerSource {
        isOnACPower ? .ac : .battery
    }
}

struct BatteryTrackerEngine {
    private static let pollInterval: TimeInterval = 5
    private static let sleepThreshold: TimeInterval = 10

    private let store: BatteryTrackerStateStore
    private let helperVersion: String

    init(
        store: BatteryTrackerStateStore = BatteryTrackerStateStore(),
        helperVersion: String = BatteryTrackerEngine.defaultHelperVersion()
    ) {
        self.store = store
        self.helperVersion = helperVersion
    }

    func run() -> Never {
        while true {
            let cycleStartedAt = Date()

            do {
                var state = try store.load() ?? makeState(now: cycleStartedAt)
                let snapshot = try readBatterySnapshot()
                state = update(state: state, snapshot: snapshot, now: cycleStartedAt)
                try store.save(state)
            } catch {
                do {
                    try store.save(makeErrorState(message: error.localizedDescription, now: cycleStartedAt))
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                }
            }

            let elapsed = Date().timeIntervalSince(cycleStartedAt)
            let sleepDuration = max(1, Int((Self.pollInterval - elapsed).rounded(.up)))
            sleep(UInt32(sleepDuration))
        }
    }

    private func update(state: BatteryTrackerState, snapshot: BatterySnapshot, now: Date) -> BatteryTrackerState {
        var nextState = state
        var session = nextState.session
        var computedStatus = BatteryTrackerComputedStatus(
            activeSeconds: 0,
            usedPercent: 0,
            usedCapacityMah: 0,
            currentPercent: snapshot.currentPercent,
            currentCapacityMah: snapshot.currentCapacityMah
        )

        if let previousCheck = session?.lastCheckAt {
            let elapsed = now.timeIntervalSince(previousCheck)
            if elapsed > Self.sleepThreshold {
                session?.sleepSeconds += max(0, Int(elapsed.rounded()) - Int(Self.pollInterval))
            }
        }

        if snapshot.isOnACPower {
            session = nil
        } else {
            if session == nil {
                session = BatteryTrackerSession(
                    startedAt: now,
                    startPercent: snapshot.currentPercent,
                    startCapacityMah: snapshot.currentCapacityMah,
                    sleepSeconds: 0,
                    lastCheckAt: now
                )
            }

            if var activeSession = session {
                activeSession.lastCheckAt = now
                session = activeSession
                computedStatus = makeComputedStatus(session: activeSession, snapshot: snapshot, now: now)
            }
        }

        nextState.helperVersion = helperVersion
        nextState.pid = getpid()
        nextState.heartbeatAt = now
        nextState.powerSource = snapshot.powerSource
        nextState.session = session
        nextState.lastComputedStatus = computedStatus
        nextState.lastError = nil
        return nextState
    }

    private func makeComputedStatus(
        session: BatteryTrackerSession,
        snapshot: BatterySnapshot,
        now: Date
    ) -> BatteryTrackerComputedStatus {
        let activeSeconds = max(
            0,
            Int(now.timeIntervalSince(session.startedAt).rounded()) - session.sleepSeconds
        )

        return BatteryTrackerComputedStatus(
            activeSeconds: activeSeconds,
            usedPercent: session.startPercent - snapshot.currentPercent,
            usedCapacityMah: session.startCapacityMah - snapshot.currentCapacityMah,
            currentPercent: snapshot.currentPercent,
            currentCapacityMah: snapshot.currentCapacityMah
        )
    }

    private func makeState(now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            powerSource: .unknown,
            session: nil,
            lastComputedStatus: nil,
            lastError: nil
        )
    }

    private func makeErrorState(message: String, now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            powerSource: .unknown,
            session: nil,
            lastComputedStatus: nil,
            lastError: message
        )
    }

    private func readBatterySnapshot() throws -> BatterySnapshot {
        let entry = openBatteryEntry()
        guard entry != IO_OBJECT_NULL else {
            throw BatteryTrackerEngineError.unavailable
        }
        defer { IOObjectRelease(entry) }

        guard
            let currentCapacity = intProperty(entry: entry, key: "AppleRawCurrentCapacity")
                ?? intProperty(entry: entry, key: "CurrentCapacity"),
            let maxCapacity = intProperty(entry: entry, key: "AppleRawMaxCapacity")
                ?? intProperty(entry: entry, key: "MaxCapacity"),
            let isOnACPower = boolProperty(entry: entry, key: "ExternalConnected")
        else {
            throw BatteryTrackerEngineError.unavailable
        }

        return BatterySnapshot(
            currentCapacityMah: currentCapacity,
            maxCapacityMah: maxCapacity,
            isOnACPower: isOnACPower
        )
    }

    private func openBatteryEntry() -> io_registry_entry_t {
        var iterator = io_iterator_t()
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }
        return IOIteratorNext(iterator)
    }

    private func intProperty(entry: io_registry_entry_t, key: String) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return value as? Int
        }
        return nil
    }

    private func boolProperty(entry: io_registry_entry_t, key: String) -> Bool? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value as? Bool
        }
        return nil
    }

    private static func defaultHelperVersion() -> String {
        let infoDictionary = Bundle.main.infoDictionary
        return (infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (infoDictionary?["CFBundleVersion"] as? String)
            ?? "1"
    }
}
