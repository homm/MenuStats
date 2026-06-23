import AppKit
import Combine
import MacmonSwift

@MainActor
private struct StatusItemDisplayDescriptor {
    let displayName: String
    let persistenceValue: String
    let source: StatusItemDisplaySource
}

private enum StatusItemDisplaySource {
    case metrics((Metrics) -> Double?, (Double) -> String)
    case batteryIcon
    case batteryStatus((BatteryRuntimeState) -> String?)
}

@MainActor
final class StatusItemController: NSObject {
    private static let maxSelectedModes = 4

    private var primaryStatusItem: NSStatusItem?
    private let menu: NSMenu
    private let onPrimaryStatusItemChanged: (NSStatusItem?) -> Void
    private var statusMetricsSubscription: AnyCancellable?
    private var statusBatterySubscription: AnyCancellable?
    private var lastMetrics: Metrics?
    private var lastBatteryState: BatteryRuntimeState?
    private var displayDescriptors: [StatusItemDisplayDescriptor] = []
    private var selectedModes: [String] = []

    init(
        menu: NSMenu,
        onPrimaryStatusItemChanged: @escaping (NSStatusItem?) -> Void
    ) {
        self.menu = menu
        self.onPrimaryStatusItemChanged = onPrimaryStatusItemChanged
        super.init()

        ensurePrimaryStatusItem()

        statusMetricsSubscription = AppDependencies.shared.metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.updateStatusItemMetrics(metrics)
            }

        statusBatterySubscription = BatteryTrackerService.shared.runtimeStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusItemBatteryState(state)
            }
    }

    private func ensurePrimaryStatusItem() {
        guard primaryStatusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = nil
        button.font = AppFonts.statusItemButton
        button.toolTip = AppPresentation.statusItemToolTip
        primaryStatusItem = statusItem
        onPrimaryStatusItemChanged(statusItem)
        applyCombinedDisplay()
    }

    private func updateStatusItemMetrics(_ metrics: Metrics) {
        lastMetrics = metrics
        if displayDescriptors.isEmpty {
            buildStatusItemMenu(with: metrics)
            applySelectedModes(AppSettings.statusItemDisplayModes)
        } else {
            applyCombinedDisplay()
        }
    }

    private func updateStatusItemBatteryState(_ state: BatteryRuntimeState?) {
        lastBatteryState = state
        applyCombinedDisplay()
    }

    private func formatStatusItemPower(_ value: Double) -> String {
        String(format: "%4.1f W", locale: FormatLocale.posix, value)
    }

    private func formatStatusItemTemperature(_ value: Double) -> String {
        String(format: "%2.0f °C", locale: FormatLocale.posix, value)
    }

    private func formatStatusItemUsage(_ value: Double) -> String {
        String(format: "%4.1f%%", locale: FormatLocale.posix, value * 100.0)
    }

    private func formatStatusItemPercent(_ value: Double) -> String {
        String(format: "%3.0f%%", locale: FormatLocale.posix, value)
    }

    private func formatStatusItemBatteryPercent(_ state: BatteryRuntimeState) -> String? {
        formatStatusItemPercent(state.currentPercent)
    }

    private func formatStatusItemFrequency(_ valueGHz: Double) -> String {
        String(format: "%4.2f GHz", locale: FormatLocale.posix, valueGHz)
    }

    private func formatStatusItemMemoryGb(_ valueGb: Double) -> String {
        String(format: "%4.1f GB", locale: FormatLocale.posix, valueGb)
    }

    private func buildStatusItemMenu(with metrics: Metrics) {
        displayDescriptors = makeStatusItemDisplayDescriptors(metrics: metrics)
        menu.insertItem(.separator(), at: 0)
        for descriptor in displayDescriptors.reversed() {
            let item = NSMenuItem(
                title: descriptor.displayName,
                action: #selector(toggleStatusItemDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = descriptor.persistenceValue
            menu.insertItem(item, at: 0)
        }
    }

    private func formattedDisplayPart(for descriptor: StatusItemDisplayDescriptor) -> String? {
        switch descriptor.source {
        case .metrics(let getValue, let formatValue):
            guard let lastMetrics, let value = getValue(lastMetrics) else { return nil }
            return formatValue(value).trimmingCharacters(in: .whitespaces)
        case .batteryStatus(let formatValue):
            guard let lastBatteryState, let title = formatValue(lastBatteryState) else { return nil }
            return title.trimmingCharacters(in: .whitespaces)
        case .batteryIcon:
            return nil
        }
    }

    private func applyBatteryIcon(to statusItem: NSStatusItem) {
        guard let lastBatteryState else {
            applyStatusItemIcon(to: statusItem)
            return
        }
        let image = BatteryIndicatorImage.make(
            state: lastBatteryState,
            usesSecondaryMask: true
        )
        applyStatusItemImage(image, to: statusItem)
    }

    private func applyStatusItemIcon(to statusItem: NSStatusItem) {
        let image = NSImage(
            systemSymbolName: AppPresentation.statusItemSystemImageName,
            accessibilityDescription: AppPresentation.statusItemToolTip
        )
        image?.isTemplate = true
        applyStatusItemImage(image, to: statusItem)
    }

    private func applyStatusItemImage(_ image: NSImage?, to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        button.image = image
        button.title = ""
    }

    private func applyStatusItemTitle(_ title: String, to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        let leadingSpaces = title.prefix { $0 == " " }
        let remainingTitle = title.dropFirst(leadingSpaces.count).replacingOccurrences(of: " ", with: "\u{2006}")
        let displayTitle = String(repeating: "\u{2007}", count: leadingSpaces.count) + remainingTitle
        if button.image != nil {
            button.image = nil
        }
        if button.title != displayTitle {
            button.title = displayTitle
        }
    }

    private func applyCombinedDisplay() {
        guard let statusItem = primaryStatusItem else { return }

        if selectedModes.isEmpty {
            applyStatusItemIcon(to: statusItem)
            return
        }

        if selectedModes.count == 1,
            selectedModes[0] == "batteryIcon"
        {
            applyBatteryIcon(to: statusItem)
            return
        }

        let parts = selectedModes.compactMap { mode in
            displayDescriptors
                .first { $0.persistenceValue == mode }
                .flatMap { formattedDisplayPart(for: $0) }
        }

        if parts.isEmpty {
            applyStatusItemIcon(to: statusItem)
        } else {
            applyStatusItemTitle(parts.joined(separator: " "), to: statusItem)
        }
    }

    private func applySelectedModes(_ modes: [String]) {
        let validModes = modes.filter { mode in
            displayDescriptors.contains { $0.persistenceValue == mode }
        }
        selectedModes = validModes
        AppSettings.statusItemDisplayModes = validModes
        updateMenuCheckStates()
        applyCombinedDisplay()
    }

    private func updateMenuCheckStates() {
        for item in menu.items {
            guard let persistenceValue = item.representedObject as? String else { continue }
            item.state = selectedModes.contains(persistenceValue) ? .on : .off
        }
    }

    @objc private func toggleStatusItemDisplayMode(_ sender: NSMenuItem) {
        guard let persistenceValue = sender.representedObject as? String else { return }
        var modes = selectedModes
        if modes.contains(persistenceValue) {
            modes.removeAll { $0 == persistenceValue }
        } else {
            guard modes.count < Self.maxSelectedModes else {
                NSSound.beep()
                return
            }
            modes.append(persistenceValue)
        }
        applySelectedModes(modes)
    }

    private func makeStatusItemDisplayDescriptors(metrics: Metrics) -> [StatusItemDisplayDescriptor] {
        var descriptors: [StatusItemDisplayDescriptor] = []

        if BatteryTrackerService.isBatteryAvailable {
            descriptors += [
                StatusItemDisplayDescriptor(
                    displayName: "Battery percent",
                    persistenceValue: "batteryPercent",
                    source: .batteryStatus(formatStatusItemBatteryPercent)
                ),
                StatusItemDisplayDescriptor(
                    displayName: "Battery icon",
                    persistenceValue: "batteryIcon",
                    source: .batteryIcon
                ),
            ]
        }

        descriptors += [
            StatusItemDisplayDescriptor(
                displayName: "System power",
                persistenceValue: "systemPower",
                source: .metrics(
                    { metrics in Double(metrics.power.board) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Chip power",
                persistenceValue: "chipPower",
                source: .metrics(
                    { metrics in Double(metrics.power.package) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Temperature",
                persistenceValue: "maxTemperature",
                source: .metrics(
                    { metrics in
                        Double(max(metrics.temperature.cpuAverage, metrics.temperature.gpuAverage))
                    },
                    formatStatusItemTemperature
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "CPU load",
                persistenceValue: "totalCpuLoad",
                source: .metrics(
                    { metrics in
                        let totalUnits = metrics.cpu_usage.reduce(0) {
                            $0 + Int($1.units)
                        }
                        let weightedUsage = metrics.cpu_usage.reduce(0 as Float) {
                            $0 + ($1.usage * Float($1.units))
                        }
                        return totalUnits > 0 ? Double(weightedUsage / Float(totalUnits)) : 0
                    },
                    formatStatusItemUsage
                )
            ),
        ]

        descriptors += metrics.cpu_usage.enumerated().flatMap { index, cluster in
            [
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) load",
                    persistenceValue: "cpuClusterLoad:\(index)",
                    source: .metrics(
                        { metrics in
                            guard metrics.cpu_usage.indices.contains(index) else { return nil }
                            return Double(metrics.cpu_usage[index].usage)
                        },
                        formatStatusItemUsage
                    )
                ),
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) frequency",
                    persistenceValue: "cpuClusterFrequency:\(index)",
                    source: .metrics(
                        { metrics in
                            guard metrics.cpu_usage.indices.contains(index) else { return nil }
                            return Double(metrics.cpu_usage[index].frequencyMHz) / 1000.0
                        },
                        formatStatusItemFrequency
                    )
                ),
            ]
        }

        descriptors += [
            StatusItemDisplayDescriptor(
                displayName: "RAM used",
                persistenceValue: "ramUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.ramUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "RAM load",
                persistenceValue: "ramLoad",
                source: .metrics(
                    { metrics in
                        guard metrics.memory.ramTotal > 0 else { return 0 }
                        return Double(metrics.memory.ramUsage) / Double(metrics.memory.ramTotal)
                    },
                    formatStatusItemUsage
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Swap used",
                persistenceValue: "swapUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.swapUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
        ]

        return descriptors
    }
}
