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

struct BatteryTrackerSession: Codable {
    var startedAt: Date
    var startCapacityMah: Int
    var sleepSeconds: Int
    var lastCheckAt: Date
}

struct BatteryTrackerState: Codable {
    var schemaVersion: Int = 2
    var helperVersion: String = ""
    var pid: Int32 = 0
    var heartbeatAt: Date = .distantPast
    var session: BatteryTrackerSession?
    var lastError: String?
}

struct BatterySessionStore {
    private let fileManager: FileManager = .default
    let fileURL: URL

    init(fileURL: URL = BatterySessionStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> BatteryTrackerState? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BatteryTrackerState.self, from: data)
    }

    func save(_ state: BatteryTrackerState) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    static func defaultFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent(BatteryTrackerConstants.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(BatteryTrackerConstants.stateFilename, isDirectory: false)
    }
}
