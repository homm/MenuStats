import Foundation

struct BatteryTrackerEngine {
    private static let pollInterval: TimeInterval = 5
    private static let sleepThreshold: TimeInterval = 10

    // Abnormal-drain detection tuning.
    private static let anomalyWindow: TimeInterval = 900     // trailing window kept in history (15 min)
    private static let anomalyMinWindow: TimeInterval = 300  // min data span before judging (5 min)
    private static let anomalyMinSession: TimeInterval = 1800 // min active session before judging (30 min)
    private static let anomalyMultiplier: Double = 1.5       // recent rate must be >= this * session average

    private let store: BatterySessionStore
    private let helperVersion: String

    init(
        store: BatterySessionStore = BatterySessionStore(),
        helperVersion: String = BatteryTrackerEngine.defaultHelperVersion()
    ) {
        self.store = store
        self.helperVersion = helperVersion
    }

    func run() -> Never {
        while true {
            autoreleasepool {
                let cycleStartedAt = Date()

                do {
                    var state = try store.load() ?? makeState(now: cycleStartedAt)
                    let batteryStatus = try BatteryStatus.read()
                    state = update(state: state, batteryStatus: batteryStatus, now: cycleStartedAt)
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
    }

    private func update(state: BatteryTrackerState, batteryStatus: BatteryStatus, now: Date) -> BatteryTrackerState {
        var nextState = state
        var session = nextState.session
        var sleepGapDetected = false

        if let previousCheck = session?.lastCheckAt {
            let elapsed = now.timeIntervalSince(previousCheck)
            if elapsed > Self.sleepThreshold {
                session?.sleepSeconds += max(0, Int(elapsed.rounded()) - Int(Self.pollInterval))
                sleepGapDetected = true
            }
        }

        var abnormalDrainDetected = false

        if batteryStatus.isOnACPower {
            session = nil
        } else {
            if session == nil {
                session = BatteryTrackerSession(
                    startedAt: now,
                    startCapacityMah: batteryStatus.currentCapacityMah,
                    sleepSeconds: 0,
                    lastCheckAt: now,
                    capacityHistory: nil
                )
            }

            if var activeSession = session {
                activeSession.lastCheckAt = now

                let reading = BatteryCapacityReading(
                    at: now,
                    capacityMah: batteryStatus.currentCapacityMah,
                    powerSaveMode: batteryStatus.powerSaveMode
                )
                // A sleep gap makes the trailing rate meaningless; start the window fresh.
                var history = sleepGapDetected ? [] : (activeSession.capacityHistory ?? [])
                history.append(reading)
                let cutoff = now.addingTimeInterval(-Self.anomalyWindow)
                history.removeAll { $0.at < cutoff }
                activeSession.capacityHistory = history

                abnormalDrainDetected = Self.evaluateAbnormalDrain(
                    session: activeSession,
                    batteryStatus: batteryStatus,
                    now: now
                )

                session = activeSession
            }
        }

        nextState.helperVersion = helperVersion
        nextState.pid = getpid()
        nextState.heartbeatAt = now
        nextState.session = session
        nextState.lastError = nil
        nextState.abnormalDrainDetected = abnormalDrainDetected
        return nextState
    }

    /// Returns true when the trailing-window drain rate is sustainedly faster than the
    /// session average. Pure function of its inputs so it is easy to reason about/test.
    static func evaluateAbnormalDrain(
        session: BatteryTrackerSession,
        batteryStatus: BatteryStatus,
        now: Date
    ) -> Bool {
        // Session must be mature enough for the average to be a trustworthy baseline.
        let activeSeconds = Int(now.timeIntervalSince(session.startedAt).rounded()) - session.sleepSeconds
        guard Double(activeSeconds) >= anomalyMinSession else { return false }

        let history = session.capacityHistory ?? []
        guard let oldest = history.first, let newest = history.last else { return false }

        // Need a sustained span of recent data, all in the same energy mode so a mode
        // switch (e.g. toggling Low Power Mode) doesn't masquerade as abnormal drain.
        let windowSpan = newest.at.timeIntervalSince(oldest.at)
        guard windowSpan >= anomalyMinWindow else { return false }
        guard history.allSatisfy({ $0.powerSaveMode == batteryStatus.powerSaveMode }) else { return false }

        let recentDrainMah = oldest.capacityMah - newest.capacityMah
        guard recentDrainMah > 0 else { return false }
        let recentRate = Double(recentDrainMah) / windowSpan

        let sessionDrainMah = session.startCapacityMah - batteryStatus.currentCapacityMah
        guard sessionDrainMah > 0, activeSeconds > 0 else { return false }
        let sessionRate = Double(sessionDrainMah) / Double(activeSeconds)
        guard sessionRate > 0 else { return false }

        return recentRate >= anomalyMultiplier * sessionRate
    }

    private func makeState(now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            session: nil,
            lastError: nil
        )
    }

    private func makeErrorState(message: String, now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            session: nil,
            lastError: message
        )
    }

    private static func defaultHelperVersion() -> String {
        let infoDictionary = Bundle.main.infoDictionary
        return (infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (infoDictionary?["CFBundleVersion"] as? String)
            ?? "1"
    }
}
