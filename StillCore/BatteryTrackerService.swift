import AppKit
import Foundation
import ServiceManagement

@MainActor
enum BatteryTrackerInstallState: Equatable {
    case notInstalled
    case requiresApproval
    case installed
}

@MainActor
final class BatteryTrackerService: ObservableObject {
    static let shared = BatteryTrackerService()
    private static let refreshInterval: TimeInterval = 5

    @Published private(set) var installState: BatteryTrackerInstallState = .notInstalled
    @Published private(set) var runtimeState: BatteryTrackerState?
    @Published private(set) var lastErrorMessage: String = ""

    private let store = BatteryTrackerStateStore()
    private let service = SMAppService.agent(plistName: BatteryTrackerConstants.launchAgentPlistName)
    private var timer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?

    private init() {
        refreshHelperStatus()
        refreshRuntimeState()
        startPolling()
    }
    func installHelper() {
        do {
            try service.register()
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = "Install failed: \(error.localizedDescription)"
        }
        refreshAll()
        scheduleFollowUpRefresh()
    }

    func uninstallHelper() {
        do {
            try service.unregister()
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = "Uninstall failed: \(error.localizedDescription)"
        }
        refreshAll()
    }

    func refreshHelperStatus() {
        switch service.status {
        case .enabled:
            installState = .installed
        case .requiresApproval:
            installState = .requiresApproval
        case .notRegistered, .notFound:
            installState = .notInstalled
        @unknown default:
            installState = .notInstalled
        }
    }

    func refreshRuntimeState() {
        do {
            runtimeState = try store.load()
            if let persistedError = runtimeState?.lastError {
                lastErrorMessage = persistedError
            } else if !lastErrorMessage.hasPrefix("Install failed:") && !lastErrorMessage.hasPrefix("Uninstall failed:") {
                lastErrorMessage = ""
            }
        } catch {
            runtimeState = nil
            lastErrorMessage = "State read failed: \(error.localizedDescription)"
        }
    }

    var runtimeLabel: String {
        switch installState {
        case .notInstalled:
            return "Helper not installed"
        case .requiresApproval:
            return "Helper requires approval"
        case .installed:
            guard let runtimeState else { return "Helper not running" }

            let heartbeatAge = Date().timeIntervalSince(runtimeState.heartbeatAt)
            guard heartbeatAge <= BatteryTrackerConstants.heartbeatTimeout else { return "Helper not running" }

            if runtimeState.lastError != nil {
                return "Helper running with errors"
            }

            return "Helper running"
        }
    }

    var statusText: String {
        guard installState == .installed else { return "" }
        guard let runtimeState else { return "Helper not running" }

        let heartbeatAge = Date().timeIntervalSince(runtimeState.heartbeatAt)
        guard heartbeatAge <= BatteryTrackerConstants.heartbeatTimeout else {
            return "Helper not running"
        }

        let currentPercent = runtimeState.lastComputedStatus?.currentPercent
        guard let currentPercent else { return "" }
        let chargeLine = "Charge: \(currentPercent)% remaining"

        if let computedStatus = runtimeState.lastComputedStatus, let session = runtimeState.session {
            let sleepSuffix = session.sleepSeconds > 0
                ? " + \(formatDuration(session.sleepSeconds)) sleep"
                : ""
            return """
            \(chargeLine)
            On battery: \(formatDuration(computedStatus.activeSeconds))\(sleepSuffix), \(computedStatus.usedPercent)% used
            """
        }

        return chargeLine
    }

    var actionTitle: String? {
        switch installState {
        case .notInstalled:
            return "Install Helper"
        case .requiresApproval:
            return "Enable in System Settings"
        case .installed:
            return statusText == "Helper not running" ? "Start Helper" : nil
        }
    }

    func performPrimaryAction() {
        switch installState {
        case .notInstalled:
            installHelper()
        case .requiresApproval:
            openSystemSettings()
        case .installed:
            installHelper()
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func refreshAll() {
        refreshHelperStatus()
        refreshRuntimeState()
    }

    private func scheduleFollowUpRefresh(delay: TimeInterval = 1) {
        pendingRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        if minutes > 0 || remainingSeconds > 0 {
            return String(format: "%02d:%02d", minutes, remainingSeconds)
        }
        return "\(remainingSeconds)s"
    }

}
