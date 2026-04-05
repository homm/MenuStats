import Foundation

struct BatteryTrackerStateStore {
    private let fileManager: FileManager = .default
    let fileURL: URL

    init(fileURL: URL = BatteryTrackerStateStore.defaultFileURL()) {
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

    static func defaultFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent(BatteryTrackerConstants.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(BatteryTrackerConstants.stateFilename, isDirectory: false)
    }
}
