import Foundation

enum BatteryTrackerConstants {
    private static let helperBundleIdentifierSuffix = ".BatteryTrackerHelper"

    static var launchAgentLabel: String {
        return "\(stateDirectoryName).BatteryTracker"
    }
    static let launchAgentPlistName = "com.github.homm.StillCore.BatteryTracker.plist"
    static var stateDirectoryName: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.github.homm.StillCore"
        if bundleIdentifier.hasSuffix(helperBundleIdentifierSuffix) {
            return String(bundleIdentifier.dropLast(helperBundleIdentifierSuffix.count))
        }
        return bundleIdentifier
    }
    static let stateFilename = "battery-tracker-state.json"
    static let heartbeatTimeout: TimeInterval = 15
}

enum BatteryPowerSource: String, Codable {
    case ac
    case battery
    case unknown
}

enum BatteryChargeStatus: String, Codable {
    case charging
    case onHold
    case charged
    case discharging
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
    var chargeStatus: BatteryChargeStatus = .unknown
    var session: BatteryTrackerSession?
    var lastComputedStatus: BatteryTrackerComputedStatus?
    var lastError: String?

    init(
        schemaVersion: Int = 2,
        helperVersion: String,
        pid: Int32,
        heartbeatAt: Date,
        powerSource: BatteryPowerSource,
        chargeStatus: BatteryChargeStatus = .unknown,
        session: BatteryTrackerSession?,
        lastComputedStatus: BatteryTrackerComputedStatus?,
        lastError: String?
    ) {
        self.schemaVersion = schemaVersion
        self.helperVersion = helperVersion
        self.pid = pid
        self.heartbeatAt = heartbeatAt
        self.powerSource = powerSource
        self.chargeStatus = chargeStatus
        self.session = session
        self.lastComputedStatus = lastComputedStatus
        self.lastError = lastError
    }
}
