import AppKit
import Combine
import SwiftUI
import MacmonSwift

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    private static let metricsIntervalKey = "metricsIntervalMs"
    private static let statusItemDisplayModeKey = "statusItemDisplayMode"

    static var metricsIntervalMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: metricsIntervalKey)
            return value == 0 ? defaultMetricsIntervalMs : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: metricsIntervalKey)
        }
    }

    static var statusItemDisplayMode: String? {
        get {
            UserDefaults.standard.string(forKey: statusItemDisplayModeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: statusItemDisplayModeKey)
        }
    }
}

enum AppPresentation {
    static let windowMinSize = CGSize(width: 420, height: 560)
    static let statusItemSystemImageName = "chart.bar.xaxis"
    static let statusItemToolTip = "StillCore"
    static let floatingWindowTitle = "StillCore"
    static let chartHistoryCapacity = 180
}

enum FormatLocale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

enum AppFonts {
    static func tabularSystemFont(
        ofSize fontSize: CGFloat,
        weight: NSFont.Weight,
        width: NSFont.Width = NSFont.Width(-0.1)
    ) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: weight, width: width)
        let featureSettings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [
                .typeIdentifier: kNumberSpacingType,
                .selectorIdentifier: kMonospacedNumbersSelector,
            ],
        ]
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings,
        ])

        return NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
    }
    nonisolated(unsafe) static let statusItemButton = tabularSystemFont(
        ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let intervalMenuLabel = tabularSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    nonisolated(unsafe) static let batteryPercent = tabularSystemFont(
        ofSize: 12, weight: .medium)
    static let helpIcon = Font.system(size: 13, weight: .semibold)
    static let systemMessage = Font.system(size: 12, design: .monospaced)

    nonisolated(unsafe) static let chartDetailsValue = tabularSystemFont(
        ofSize: 12, weight: .bold)
    nonisolated(unsafe) static let chartDetailsMarkerValue = tabularSystemFont(
        ofSize: 10, weight: .bold)
    nonisolated(unsafe) static let chartLegend = tabularSystemFont(
        ofSize: 12, weight: .medium)
}

// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var metricsError: String = ""
    private(set) var socInfo: SocInfo?
    private var metricsTask: Task<Void, Never>?
    private let metricsSubject = PassthroughSubject<Metrics, Never>()

    var metricsPublisher: AnyPublisher<Metrics, Never> {
        metricsSubject.eraseToAnyPublisher()
    }

    private init() {
        startMetricsLoop()
        loadSocInfo()
    }

    func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsError = ""

        metricsTask = Task.detached {
            let clock = ContinuousClock()
            var lastUpdateStarted = clock.now

            do {
                let sampler = try Sampler()
                defer { sampler.close() }

                while !Task.isCancelled {
                    while true {
                        let intervalMs = await MainActor.run { AppDependencies.shared.metricsIntervalMs }
                        let sampleInterval = Swift.Duration.milliseconds(intervalMs)
                        let elapsed = lastUpdateStarted.duration(to: clock.now)
                        guard elapsed < sampleInterval else { break }

                        do {
                            try await Task.sleep(for: min(sampleInterval - elapsed, .milliseconds(500)))
                        } catch {
                            break
                        }
                    }

                    guard !Task.isCancelled else { break }
                    lastUpdateStarted = clock.now

                    let metrics = try sampler.metrics()
                    await MainActor.run {
                        AppDependencies.shared.metricsSubject.send(metrics)
                        if !AppDependencies.shared.metricsError.isEmpty {
                            AppDependencies.shared.metricsError = ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.metricsError = String(describing: error)
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }

    private func loadSocInfo() {
        do {
            let info = try Macmon.socInfo()
            socInfo = info
            chipName = info.chipName
            socSummary = formatSocSummary(info)
        } catch {
            socInfo = nil
            chipName = nil
            socSummary = ""
        }
    }

    private func formatSocSummary(_ info: SocInfo) -> String {
        var parts = info.cpuDomains.compactMap { domain -> String? in
            var name = domain.name.uppercased()
            let lower = domain.name.lowercased()
            if lower == "ecpu" {
                name = "E"
            }
            if lower == "pcpu" {
                name = "P"
            }
            return "\(domain.units)\(name)"
        }
        parts.append("\(info.gpuCores)G cores")
        return parts.joined(separator: " ")
    }

    @Published var metricsIntervalMs: Int = AppSettings.metricsIntervalMs {
        didSet {
            AppSettings.metricsIntervalMs = metricsIntervalMs
        }
    }

    func increaseMetricsInterval() {
        let current = metricsIntervalMs
        let step = Self.intervalStep(for: current)
        metricsIntervalMs = min(
            ((metricsIntervalMs + step) / step) * step, Self.maxMetricsIntervalMs)
    }

    func decreaseMetricsInterval() {
        let step = Self.intervalStep(for: metricsIntervalMs - 1)
        metricsIntervalMs = max(
            (max(metricsIntervalMs - step, 0) + step - 1) / step * step, Self.minMetricsIntervalMs)
    }

    private static func intervalStep(for intervalMs: Int) -> Int {
        if intervalMs >= largeIntervalThresholdMs {
            return largeIntervalStepMs
        }
        if intervalMs >= mediumIntervalThresholdMs {
            return mediumIntervalStepMs
        }
        return intervalStepMs
    }

    private static let minMetricsIntervalMs = 100
    private static let maxMetricsIntervalMs = 10_000
    private static let intervalStepMs = 250
    private static let mediumIntervalStepMs = 500
    private static let mediumIntervalThresholdMs = 1_000
    private static let largeIntervalStepMs = 1_000
    private static let largeIntervalThresholdMs = 3_000
}

private enum MetricsChartPalette {
    static let board = color(light: (0.06, 0.736, 0.14), dark: (0.18, 0.92, 0.28))
    static let package = color(light: (0.058, 0.406, 0.892), dark: (0.13, 0.48, 0.97))
    static let cpu = color(light: (0.246, 0.663, 0.902), dark: (0.32, 0.74, 0.98))
    static let gpu = color(light: (0.92, 0.188, 0.0), dark: (1.0, 0.30, 0.10))
    static let ane = color(light: (0.94, 0.62, 0.0), dark: (1.0, 0.66, 0.08))

    static let cpuFrequencyPalette: [NSColor] = [
        board, package, cpu,
        color(light: (0.117, 0.534, 0.773), dark: (0.26, 0.68, 0.92)),
        color(light: (0.048, 0.366, 0.644), dark: (0.18, 0.52, 0.82)),
    ]

    static let gpuFrequencyPalette: [NSColor] = [
        gpu, ane,
        color(light: (0.846, 0.29, 0.111), dark: (1.0, 0.44, 0.24)),
        color(light: (0.791, 0.076, 0.275), dark: (0.98, 0.22, 0.44)),
    ]

    private static func color(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: components.red,
                green: components.green,
                blue: components.blue,
                alpha: 1
            )
        }
    }
}

@MainActor
private enum MetricsChartDefinitions {
    private enum Formatters {
        static func watts(_ value: Double) -> String {
            String(format: "%.2f", locale: FormatLocale.posix, value)
        }

        static func frequencyGHz(_ value: Double) -> String {
            String(format: "%.2f", locale: FormatLocale.posix, value)
        }

        static func usage(_ value: Double) -> String {
            String(format: "%.1f%%", locale: FormatLocale.posix, value * 100.0)
        }

        static func temperature(_ value: Double) -> String {
            String(format: "%.1f", locale: FormatLocale.posix, value)
        }
    }

    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "Watt",
        helpMarkdown:
"""
**Power draw by components**

• `SYS` is the total system power draw.
• `CHIP` is the power reported for the whole SoC, including all compute units and memory.
• `CPU`, `GPU`, and `ANE` are individual parts of `CHIP`.
""",
        showsSampleTime: true,
        schemaBuilder: { _ in "power" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "SYS",
                    color: MetricsChartPalette.board,
                    kind: .line,
                    chartValue: { Double($0.power.board) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "CHIP",
                    color: MetricsChartPalette.package,
                    kind: .line,
                    chartValue: { Double($0.power.package) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    kind: .line,
                    chartValue: { Double($0.power.cpu) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "ANE",
                    color: MetricsChartPalette.ane,
                    kind: .line,
                    chartValue: { Double($0.power.ane) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    kind: .line,
                    chartValue: { Double($0.power.gpu) },
                    detailsFormatter: Formatters.watts
                ),
            ]
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        helpMarkdown: nil,
        schemaBuilder: { _ in "temperature" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    kind: .line,
                    lineWidth: 2.0,
                    chartValue: { Double($0.temperature.cpuAverage) },
                    detailsFormatter: Formatters.temperature
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    kind: .line,
                    lineWidth: 2.0,
                    chartValue: { Double($0.temperature.gpuAverage) },
                    detailsFormatter: Formatters.temperature
                ),
            ]
        }
    )

    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage",
        unitLabel: "GHz, %",
        helpMarkdown:
"""
Current frequency and usage of all CPU and GPU clusters.

**How to read this mess**
Each cluster is shown with a solid line for frequency \
and a semi-transparent area underneath for current usage. \
The area shows the fraction of that frequency that is being used. \
When usage is at 100%, the area reaches the line.
""",
        schemaBuilder: { metrics in
            guard let metrics else { return AnyHashable("frequency.empty") }
            return AnyHashable(
                metrics.cpu_usage.map(\.name) + ["|"] + metrics.gpu_usage.map(\.name)
            )
        },
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu_usage.enumerated().flatMap { index, cluster in
            let title = metrics.cpu_usage.count == 1 ? "CPU" : cluster.name
            let color = MetricsChartPalette.cpuFrequencyPalette[
                index % MetricsChartPalette.cpuFrequencyPalette.count
            ]
            let group = "cpu.\(index)"

            return [
                MetricsSeriesDescriptor(
                    title: title,
                    color: color,
                    kind: .line,
                    chartValue: { metrics in
                        Double(cpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.withAlphaComponent(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                            * Double(cpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                    },
                    detailsFormatter: Formatters.usage,
                    detailsGroup: group
                ),
            ]
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu_usage.enumerated().flatMap { index, cluster in
            let title = metrics.gpu_usage.count == 1 ? "GPU" : cluster.name
            let color = MetricsChartPalette.gpuFrequencyPalette[
                index % MetricsChartPalette.gpuFrequencyPalette.count
            ]
            let group = "gpu.\(index)"

            return [
                MetricsSeriesDescriptor(
                    title: title,
                    color: color,
                    kind: .line,
                    chartValue: { metrics in
                        Double(gpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.withAlphaComponent(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.gpu_usage[index].usage)
                            * Double(gpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsValue: { metrics in
                        Double(metrics.gpu_usage[index].usage)
                    },
                    detailsFormatter: Formatters.usage,
                    detailsGroup: group
                ),
            ]
        }
    }

    private static func cpuChartFrequencyMHz(_ metrics: Metrics, index: Int) -> UInt32 {
        let frequency = metrics.cpu_usage[index].frequencyMHz
        guard frequency == 0,
            let domains = AppDependencies.shared.socInfo?.cpuDomains,
            domains.indices.contains(index),
            let minimumFrequency = domains[index].frequenciesMHz.first
        else { return frequency }
        return minimumFrequency
    }

    private static func gpuChartFrequencyMHz(_ metrics: Metrics, index: Int) -> UInt32 {
        let frequency = metrics.gpu_usage[index].frequencyMHz
        guard frequency == 0,
            let minimumFrequency = AppDependencies.shared.socInfo?.gpuFrequenciesMHz.first
        else { return frequency }
        return minimumFrequency
    }
}

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject private var batteryTrackerService = BatteryTrackerService.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var highlightedChartSampleX: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(dependencies.chipName ?? AppPresentation.floatingWindowTitle)
                    .font(.headline)
                Text(dependencies.socSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Text("Update interval:")
                    ForEach(Self.intervalMenuOptions, id: \.milliseconds) { option in
                        Button(option.title) {
                            dependencies.metricsIntervalMs = option.milliseconds
                        }
                    }
                    Divider()
                    Text("Keyboard shortcuts:")
                    Button("More often") {
                        dependencies.decreaseMetricsInterval()
                    }
                        .keyboardShortcut("-", modifiers: [])
                    Button("Less often") {
                        dependencies.increaseMetricsInterval()
                    }
                        .keyboardShortcut("=", modifiers: [])
                } label: {
                    (Text(Image(systemName: "clock.arrow.circlepath"))
                    + Text(intervalLabel))
                        .font(Font(AppFonts.intervalMenuLabel))
                        .foregroundStyle(.primary)
                }
                    .menuStyle(.button)
                    .buttonStyle(.accessoryBar)
                    .help("Update interval")
                Button {
                    presentationState.setPresentationMode(
                        presentationState.mode == .attached ? .floating : .attached)
                } label: {
                    Image(presentationState.mode == .attached ? "PinFloating" : "PinAttached")
                        .resizable().frame(height: 15)
                        .fixedSize().frame(width: 15, height: 15)
                        .offset(y: -1)
                }
                    .help(presentationState.mode == .floating ? "Attach to menu bar" : "Detach from menu bar")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
            }

            if !dependencies.metricsError.isEmpty {
                Text("Macmon error: \(dependencies.metricsError)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .font(AppFonts.systemMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                let backgroundColor = Color(.textBackgroundColor)
                    .padding(EdgeInsets(top: -8, leading: -12, bottom: -4, trailing: -12))
                let chartSectionInsets = EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0)
                GeometryReader { metrics in
                    VStack(spacing: 0) {
                        MetricsChartSection(
                            definition: MetricsChartDefinitions.power,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            highlightedSampleX: $highlightedChartSampleX
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background(backgroundColor)
                            .padding(chartSectionInsets)

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.frequency,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            highlightedSampleX: $highlightedChartSampleX
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background(backgroundColor)
                            .padding(chartSectionInsets)

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.temperature,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            highlightedSampleX: $highlightedChartSampleX,
                            yAxisLabelCount: 4,
                            yStart: 30
                        )
                            .background(backgroundColor)
                            .padding(chartSectionInsets)
                    }
                }
            }

            HStack(spacing: 8) {
                if let actionTitle = batteryTrackerService.actionTitle {

                    Text("Battery tracker:")
                    if batteryTrackerService.installState != .requiresApproval {
                        Text(batteryTrackerService.runtimeLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(actionTitle) {
                        batteryTrackerService.performPrimaryAction()
                    }
                } else {
                    if let currentPercent = batteryTrackerService.runtimeState?.lastComputedStatus?.currentPercent {
                        HStack(spacing: 4) {
                            BatteryIndicatorView(percent: currentPercent)
                                .foregroundStyle(.secondary)
                            Text("\(currentPercent)%")
                                .foregroundStyle(.secondary)
                                .font(Font(AppFonts.batteryPercent))
                        }
                    }
                    Text(batteryTrackerService.statusText)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if batteryTrackerService.actionTitle == nil && !batteryTrackerService.lastErrorMessage.isEmpty {
                    Text(batteryTrackerService.lastErrorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var intervalLabel: AttributedString {
        Self.intervalLabel(for: dependencies.metricsIntervalMs)
    }

    private static func intervalLabel(for interval: Int) -> AttributedString {
        let wholeSeconds = interval >= 1_000 ? "\(interval / 1_000)" : ""
        let milliseconds = interval % 1_000
        let fraction: String
        switch milliseconds {
        case 0:
            fraction = ""
        default:
            let digits =
                milliseconds % 100 == 0 ? milliseconds / 100
                : milliseconds % 10 == 0 ? milliseconds / 10
                : milliseconds
            fraction = ".\(digits)"
        }

        return AttributedString("\u{2009}\(wholeSeconds)\(fraction)s")
    }

    private static let intervalMenuOptions = [
        (milliseconds: 250, title: "0.25\u{2006}seconds"),
        (milliseconds: 500, title: "0.5\u{2006}s"),
        (milliseconds: 1_000, title: "1\u{2006}s"),
        (milliseconds: 2_000, title: "2\u{2006}s"),
        (milliseconds: 5_000, title: "5\u{2006}s"),
    ]
}

private struct BatteryIndicatorView: View {
    let percent: Int
    private let bodyWidth: CGFloat = 24
    private let bodyHeight: CGFloat = 12
    private let bodyInset: CGFloat = 2

    var body: some View {
        let clampedPercent = min(max(percent, 0), 100)
        let fillWidth = max(bodyWidth - bodyInset * 2, 0) * CGFloat(clampedPercent) / 100

        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1))

                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: fillWidth)
                    .padding(bodyInset)
            }
            .frame(width: bodyWidth, height: bodyHeight)

            Circle()
                .frame(width: 6, height: 6)
                .frame(width: 2, height: 6, alignment: .trailing)
                .clipped()
        }
    }
}

@MainActor
private struct StatusItemDisplayDescriptor {
    let displayName: String
    let persistenceValue: String
    let source: StatusItemDisplaySource

    static let icon = StatusItemDisplayDescriptor(
        displayName: "Icon",
        persistenceValue: "icon",
        source: .icon
    )
}

private enum StatusItemDisplaySource {
    case icon
    case metrics((Metrics) -> Double?, (Double) -> String)
    case batteryStatus((BatteryTrackerState) -> String?)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationController: MenuPresentationController<ContentView>?
    private var statusMetricsSubscription: AnyCancellable?
    private var statusBatterySubscription: AnyCancellable?
    private let statusItemMenu = NSMenu()
    private var lastMetrics: Metrics?
    private var lastBatteryState: BatteryTrackerState?
    private var statusItemDisplayDescriptors: [StatusItemDisplayDescriptor] = []
    private var selectedStatusItemDescriptor = StatusItemDisplayDescriptor.icon
    private let restartHelperArgument = "--helper-restart"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(restartHelperArgument) {
            BatteryTrackerService.shared.restartHelper()
            NSApp.terminate(nil)
            return
        }

        let aboutItem = NSMenuItem(title: "About...", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        statusItemMenu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        statusItemMenu.addItem(quitItem)

        presentationController = MenuPresentationController(
            content: { presentationState in
                ContentView(presentationState: presentationState)
            },
            statusItemMenu: statusItemMenu,
            configureStatusItem: { statusItem in
                guard let button = statusItem.button else { return }
                button.image = nil
                button.font = AppFonts.statusItemButton
                button.toolTip = AppPresentation.statusItemToolTip
                self.applyStatusItemIcon(to: statusItem)
            },
            configureWindow: { window in
                window.title = AppPresentation.floatingWindowTitle
                window.setContentSize(AppPresentation.windowMinSize)
                window.minSize = AppPresentation.windowMinSize
            }
        )

        // Metrics build the dynamic menu and refresh all metric-backed status titles
        statusMetricsSubscription = AppDependencies.shared.metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.updateStatusItemMetrics(metrics)
            }

        // Battery state is produced by the helper
        statusBatterySubscription = BatteryTrackerService.shared.runtimeStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusItemBatteryState(state)
            }
    }

    private func updateStatusItemMetrics(_ metrics: Metrics) {
        guard let statusItem = presentationController?.statusItem else { return }
        lastMetrics = metrics
        if statusItemDisplayDescriptors.isEmpty {
            buildStatusItemMenu(with: metrics)
            applyStatusItemDisplayMode(AppSettings.statusItemDisplayMode ?? "icon")
        } else {
            applyStatusItemMetrics(to: statusItem)
        }
    }

    private func updateStatusItemBatteryState(_ state: BatteryTrackerState?) {
        lastBatteryState = state
        guard let statusItem = presentationController?.statusItem else { return }
        applyStatusItemBatteryState(to: statusItem)
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

    private func formatStatusItemBatteryPercent(_ state: BatteryTrackerState) -> String? {
        guard let percent = state.lastComputedStatus?.currentPercent else { return nil }
        return formatStatusItemPercent(Double(percent))
    }

    private func formatStatusItemFrequency(_ valueGHz: Double) -> String {
        String(format: "%4.2f GHz", locale: FormatLocale.posix, valueGHz)
    }

    private func formatStatusItemMemoryGb(_ valueGb: Double) -> String {
        String(format: "%4.1f Gb", locale: FormatLocale.posix, valueGb)
    }

    private func buildStatusItemMenu(with metrics: Metrics) {
        statusItemDisplayDescriptors = makeStatusItemDisplayDescriptors(metrics: metrics)
        statusItemMenu.insertItem(.separator(), at: 0)
        for descriptor in statusItemDisplayDescriptors.reversed() {
            let item = NSMenuItem(
                title: descriptor.displayName,
                action: #selector(selectStatusItemDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = descriptor.persistenceValue
            statusItemMenu.insertItem(item, at: 0)
        }
        updateStatusItemMenuSelection()
    }

    private func applyStatusItemMetrics(to statusItem: NSStatusItem) {
        guard case .metrics(let getValue, let formatValue) = selectedStatusItemDescriptor.source else {
            return
        }
        guard let lastMetrics, let value = getValue(lastMetrics) else {
            applyStatusItemIcon(to: statusItem)
            return
        }
        applyStatusItemTitle(formatValue(value), to: statusItem)
    }

    private func applyStatusItemBatteryState(to statusItem: NSStatusItem) {
        guard case .batteryStatus(let formatValue) = selectedStatusItemDescriptor.source else {
            return
        }
        guard let lastBatteryState, let title = formatValue(lastBatteryState) else {
            applyStatusItemIcon(to: statusItem)
            return
        }
        applyStatusItemTitle(title, to: statusItem)
    }

    private func applyStatusItemIcon(to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        if button.image != nil && button.title.isEmpty {
            return
        }
        let image = NSImage(
            systemSymbolName: AppPresentation.statusItemSystemImageName,
            accessibilityDescription: AppPresentation.statusItemToolTip
        )
        image?.isTemplate = true
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

    private func sanitizedPersistenceValue(_ persistenceValue: String) -> String {
        return statusItemDisplayDescriptors.contains { $0.persistenceValue == persistenceValue } ? persistenceValue : "icon"
    }

    private func updateStatusItemMenuSelection() {
        for item in statusItemMenu.items {
            guard let persistenceValue = item.representedObject as? String else { continue }
            item.state = persistenceValue == selectedStatusItemDescriptor.persistenceValue ? .on : .off
        }
    }

    private func applyStatusItemDisplayMode(_ persistenceValue: String) {
        let selectedStatusItemDisplayMode = sanitizedPersistenceValue(persistenceValue)
        selectedStatusItemDescriptor =
            statusItemDisplayDescriptors.first { $0.persistenceValue == selectedStatusItemDisplayMode }
            ?? .icon
        AppSettings.statusItemDisplayMode = selectedStatusItemDescriptor.persistenceValue
        updateStatusItemMenuSelection()

        guard let statusItem = presentationController?.statusItem else { return }
        switch selectedStatusItemDescriptor.source {
        case .metrics:
            applyStatusItemMetrics(to: statusItem)
        case .batteryStatus:
            applyStatusItemBatteryState(to: statusItem)
        case .icon:
            applyStatusItemIcon(to: statusItem)
        }
    }

    @objc private func selectStatusItemDisplayMode(_ sender: NSMenuItem) {
        guard let persistenceValue = sender.representedObject as? String else { return }
        applyStatusItemDisplayMode(persistenceValue)
    }

    private func makeStatusItemDisplayDescriptors(metrics: Metrics) -> [StatusItemDisplayDescriptor] {
        var descriptors = [
            .icon,
            StatusItemDisplayDescriptor(
                displayName: "Battery percent",
                persistenceValue: "batteryPercent",
                source: .batteryStatus(formatStatusItemBatteryPercent)
            ),
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

    @objc private func showAboutPanel() {
        NSApp.activate()
        AboutPanel.show()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

@MainActor
private enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits(),
        ])
    }

    private static func credits() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let credits = NSMutableAttributedString(try! AttributedString(
            markdown: """
[Source code](https://github.com/homm/StillCore)

Metrics core by [macmon](https://github.com/vladkens/macmon)

Special thanks to
Alyosha Gusev
""",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        credits.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }
}

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About StillCore") {
                    AboutPanel.show()
                }
            }
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Decrease Update Interval") {
                    AppDependencies.shared.decreaseMetricsInterval()
                }
                    .keyboardShortcut("-", modifiers: [])
                Button("Increase Update Interval") {
                    AppDependencies.shared.increaseMetricsInterval()
                }
                    .keyboardShortcut("=", modifiers: [])
            }
        }
    }
}
