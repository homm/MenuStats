import Foundation

enum BatteryTrackerConstants {
    static let appBundleIdentifier = "com.github.homm.StillCore"
    static let launchAgentLabel = "com.github.homm.StillCore.BatteryTracker"
    static let launchAgentPlistName = "\(launchAgentLabel).plist"
    static let stateDirectoryName = appBundleIdentifier
    static let stateFilename = "battery-tracker-state.json"
    static let heartbeatTimeout: TimeInterval = 15
}

enum BatteryPowerSource: String, Codable {
    case ac
    case battery
    case unknown
}

struct BatteryTrackerSession: Codable {
    var startedAt: Date
    var startPercent: Int
    var startCapacityMah: Int
    var sleepSeconds: Int
    var lastCheckAt: Date
}

struct BatteryTrackerComputedStatus: Codable {
    var activeSeconds: Int
    var usedPercent: Int
    var usedCapacityMah: Int
    var currentPercent: Int
    var currentCapacityMah: Int
}

struct BatteryTrackerState: Codable {
    var schemaVersion: Int
    var helperVersion: String
    var pid: Int32
    var heartbeatAt: Date
    var powerSource: BatteryPowerSource
    var session: BatteryTrackerSession?
    var lastComputedStatus: BatteryTrackerComputedStatus?
    var lastError: String?

    init(
        schemaVersion: Int = 1,
        helperVersion: String,
        pid: Int32,
        heartbeatAt: Date,
        powerSource: BatteryPowerSource,
        session: BatteryTrackerSession?,
        lastComputedStatus: BatteryTrackerComputedStatus?,
        lastError: String?
    ) {
        self.schemaVersion = schemaVersion
        self.helperVersion = helperVersion
        self.pid = pid
        self.heartbeatAt = heartbeatAt
        self.powerSource = powerSource
        self.session = session
        self.lastComputedStatus = lastComputedStatus
        self.lastError = lastError
    }
}
