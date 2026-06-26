import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

// Identifiers for the abnormal-drain notification and its actionable buttons.
// Shared between the poster (BatteryTrackerService) and the delegate that
// registers the category and handles taps (AppDelegate).
enum AbnormalDrainNotification {
    static let identifier = "com.github.homm.StillCore.abnormalDrain"
    static let categoryIdentifier = "com.github.homm.StillCore.abnormalDrain.category"
    static let openActivityMonitorAction = "com.github.homm.StillCore.abnormalDrain.activityMonitor"
    static let openBatterySettingsAction = "com.github.homm.StillCore.abnormalDrain.batterySettings"
}

@MainActor
enum BatteryTrackerInstallState: Equatable {
    case notInstalled
    case requiresApproval
    case installed
}

enum BatteryChargeStatus {
    case charging
    case onHold
    case charged
    case discharging
}

struct BatteryRuntimeState {
    var batteryTrackerState: BatteryTrackerState?
    var batteryStatus: BatteryStatus

    var currentPercent: Double {
        guard batteryStatus.maxCapacityMah > 0 else { return 0 }
        return Double(batteryStatus.currentCapacityMah) * 100.0 / Double(batteryStatus.maxCapacityMah)
    }

    var chargeStatus: BatteryChargeStatus {
        guard batteryStatus.isOnACPower else { return .discharging }
        if batteryStatus.isCharging { return .charging }
        if batteryStatus.isFullyCharged { return .charged }
        return .onHold
    }

    var activeSeconds: Int? {
        guard let session = batteryTrackerState?.session else { return nil }
        return max(0, Int(Date().timeIntervalSince(session.startedAt).rounded()) - session.sleepSeconds)
    }

    var usedCapacityMah: Int? {
        guard let session = batteryTrackerState?.session else { return nil }
        return max(0, session.startCapacityMah - batteryStatus.currentCapacityMah)
    }

    var usedPercent: Double? {
        guard let usedCapacityMah, batteryStatus.maxCapacityMah > 0 else { return nil }
        return Double(usedCapacityMah) * 100.0 / Double(batteryStatus.maxCapacityMah)
    }

    var abnormalDrainDetected: Bool {
        batteryTrackerState?.abnormalDrainDetected ?? false
    }
}

@MainActor
final class BatteryTrackerService: ObservableObject {
    static let isBatteryAvailable = BatteryStatus.isAvailable
    static let shared = BatteryTrackerService(start: isBatteryAvailable)
    private static let refreshInterval: TimeInterval = 3
    private static var currentHelperVersion: String {
        let infoDictionary = Bundle.main.infoDictionary
        return (infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (infoDictionary?["CFBundleVersion"] as? String)
            ?? "1"
    }

    @Published private(set) var installState: BatteryTrackerInstallState = .notInstalled
    @Published private(set) var runtimeState: BatteryRuntimeState?
    @Published private(set) var lastErrorMessage: String = ""

    // Cached notification permission so the energy menu can reflect a denial without
    // an async lookup. Refreshed lazily; never prompts on its own.
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    // Lets non-SwiftUI code observe runtimeState without exposing write access.
    var runtimeStatePublisher: AnyPublisher<BatteryRuntimeState?, Never> {
        $runtimeState.eraseToAnyPublisher()
    }

    private let store = BatterySessionStore()
    private let service = SMAppService.agent(plistName: BatteryTrackerConstants.launchAgentPlistName)
    private var timer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?

    // Abnormal-drain notification: fire once on the rising edge, with a cooldown so a
    // flapping flag can't spam the user.
    private static let abnormalDrainNotificationCooldown: TimeInterval = 1800
    private var lastAbnormalDrain = false
    private var lastAbnormalNotifiedAt: Date?

    private init(start: Bool) {
        guard start else { return }
        refreshAll()
        restartHelperIfVersionChanged()
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

    func restartHelper(removingState: Bool = false) {
        do {
            if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            if removingState {
                try store.delete()
            }
            try service.register()
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = "Restart failed: \(error.localizedDescription)"
        }
        refreshAll()
        scheduleFollowUpRefresh()
    }

    func restartHelperIfVersionChanged() {
        guard installState == .installed, let batteryTrackerState = runtimeState?.batteryTrackerState else {
            return
        }
        guard batteryTrackerState.helperVersion != Self.currentHelperVersion else {
            return
        }

        restartHelper()
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
        var batteryTrackerState: BatteryTrackerState?
        var stateReadError: String?
        var batteryStatusReadError: String?

        do {
            batteryTrackerState = try store.load()
        } catch {
            stateReadError = "State read failed: \(error.localizedDescription)"
        }

        do {
            runtimeState = BatteryRuntimeState(
                batteryTrackerState: batteryTrackerState,
                batteryStatus: try BatteryStatus.read()
            )
        } catch {
            runtimeState = nil
            batteryStatusReadError = "Battery read failed: \(error.localizedDescription)"
        }

        if let stateReadError {
            lastErrorMessage = stateReadError
        } else if let batteryStatusReadError {
            lastErrorMessage = batteryStatusReadError
        } else if let persistedError = batteryTrackerState?.lastError {
            lastErrorMessage = persistedError
        } else if !lastErrorMessage.hasPrefix("Install failed:") && !lastErrorMessage.hasPrefix("Uninstall failed:") {
            lastErrorMessage = ""
        }

        evaluateAbnormalDrainNotification()
    }

    private func evaluateAbnormalDrainNotification() {
        let detected = isHelperRunning && (runtimeState?.abnormalDrainDetected ?? false)
        defer { lastAbnormalDrain = detected }

        guard detected, !lastAbnormalDrain else { return }
        guard AppSettings.abnormalDrainWarningEnabled else { return }

        let now = Date()
        if let lastNotifiedAt = lastAbnormalNotifiedAt,
           now.timeIntervalSince(lastNotifiedAt) < Self.abnormalDrainNotificationCooldown {
            return
        }
        lastAbnormalNotifiedAt = now

        postAbnormalDrainNotification()
    }

    private func postAbnormalDrainNotification() {
        // Ask for permission only now, the first time we actually need to warn.
        // requestAuthorization is a no-op prompt once the status is determined.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshNotificationAuthorization()
                guard granted else { return }
                self.deliverAbnormalDrainNotification()
            }
        }
    }

    private func deliverAbnormalDrainNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Battery Is Draining Quickly"
        content.body = "StillCore noticed higher power use over the last few minutes."
        // Calm advisory: banner only, no sound. The category adds the action buttons.
        content.categoryIdentifier = AbnormalDrainNotification.categoryIdentifier

        // Stable identifier coalesces repeats into a single Notification Center entry.
        let request = UNNotificationRequest(
            identifier: AbnormalDrainNotification.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Refreshes the cached notification permission. Never prompts.
    func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self?.notificationAuthorization = status
            }
        }
    }

    /// Requests notification permission at a moment the user has clearly opted in
    /// (e.g. enabling the warning). Only prompts while the status is undetermined;
    /// reports whether permission ended up granted so the caller can reflect it.
    func requestNotificationAuthorization(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.refreshNotificationAuthorization()
                completion(granted)
            }
        }
    }

    var runtimeLabel: String {
        switch installState {
        case .notInstalled:
            return "Battery tracker is not installed"
        case .requiresApproval:
            return "Helper requires approval"
        case .installed:
            guard let batteryTrackerState = runtimeState?.batteryTrackerState else {
                return "Battery tracker is not running"
            }

            let heartbeatAge = Date().timeIntervalSince(batteryTrackerState.heartbeatAt)
            guard heartbeatAge <= BatteryTrackerConstants.heartbeatTimeout else {
                return "Battery tracker is not running"
            }

            if batteryTrackerState.lastError != nil {
                return "Helper running with errors"
            }

            return "Helper running"
        }
    }

    var statusText: String {
        guard let runtimeState else { return "Helper not running" }

        if
            isHelperRunning,
            let session = runtimeState.batteryTrackerState?.session,
            let activeSeconds = runtimeState.activeSeconds,
            let usedPercent = runtimeState.usedPercent
        {
            let activeDuration = formatDuration(activeSeconds)
            let sleepSuffix: String
            if session.sleepSeconds > 0 {
                sleepSuffix = " + \(formatDuration(session.sleepSeconds)) sleep"
            } else {
                sleepSuffix = ""
            }
            let warningPrefix = runtimeState.abnormalDrainDetected ? "⚠︎ " : ""
            return "\(warningPrefix)Drained \(Int(usedPercent.rounded()))% over \(activeDuration)\(sleepSuffix)"
        }

        return chargeStatusText(runtimeState.chargeStatus)
    }

    var actionTitle: String? {
        switch installState {
        case .notInstalled:
            return "Install"
        case .requiresApproval:
            return "Open System Settings"
        case .installed:
            if !lastErrorMessage.isEmpty {
                return "Restart Helper"
            }
            return isHelperRunning ? nil : "Start Helper"
        }
    }

    func performPrimaryAction() {
        switch installState {
        case .notInstalled:
            installHelper()
        case .requiresApproval:
            openSystemSettings()
        case .installed:
            restartHelper()
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else {
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

    private var isHelperRunning: Bool {
        guard installState == .installed, let batteryTrackerState = runtimeState?.batteryTrackerState else {
            return false
        }

        let heartbeatAge = Date().timeIntervalSince(batteryTrackerState.heartbeatAt)
        return heartbeatAge <= BatteryTrackerConstants.heartbeatTimeout && batteryTrackerState.lastError == nil
    }

    private func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func chargeStatusText(_ status: BatteryChargeStatus) -> String {
        switch status {
        case .charging:
            return "Charging"
        case .onHold:
            return "On Hold"
        case .charged:
            return "Charged"
        case .discharging:
            return ""
        }
    }

}
