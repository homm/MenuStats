import AppKit
import SwiftUI
import Charts
import MacmonSwift

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    private static let metricsIntervalKey = "metricsIntervalMs"

    static var metricsIntervalMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: metricsIntervalKey)
            return value == 0 ? defaultMetricsIntervalMs : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: metricsIntervalKey)
        }
    }
}

enum AppPresentation {
    static let windowMinSize = CGSize(width: 420, height: 320)
    static let statusItemSystemImageName = "chart.bar.xaxis"
    static let statusItemFallbackTitle = "MS"
    static let statusItemToolTip = "MenuStats"
    static let pinnedWindowTitle = "MenuStats"
}

private struct PowerSeriesDescriptor: Identifiable {
    let id: String
    let title: String
    let color: Color
    let metricKeyPath: KeyPath<PowerMetrics, Float>

    func watts(from metrics: Metrics) -> Double {
        Double(metrics.power[keyPath: metricKeyPath])
    }
}

private struct PowerChartSample: Identifiable {
    let sampleID: Int
    let metrics: Metrics

    var id: Int { sampleID }
}

@MainActor
private enum PowerChartDefinition {
    static let series: [PowerSeriesDescriptor] = [
        PowerSeriesDescriptor(
            id: "board",
            title: "BOARD",
            color: Color(red: 0.12, green: 0.72, blue: 0.40),
            metricKeyPath: \.board
        ),
        PowerSeriesDescriptor(
            id: "package",
            title: "PKG",
            color: Color(red: 0.13, green: 0.48, blue: 0.97),
            metricKeyPath: \.package
        ),
        PowerSeriesDescriptor(
            id: "cpu",
            title: "CPU",
            color: Color(red: 0.32, green: 0.74, blue: 0.98),
            metricKeyPath: \.cpu
        ),
        PowerSeriesDescriptor(
            id: "ane",
            title: "ANE",
            color: Color(red: 0.98, green: 0.58, blue: 0.02),
            metricKeyPath: \.ane
        ),
        PowerSeriesDescriptor(
            id: "gpu",
            title: "GPU",
            color: Color(red: 0.98, green: 0.22, blue: 0.44),
            metricKeyPath: \.gpu
        ),
    ]
}


// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var latestMetrics: Metrics?
    @Published var metricsError: String = ""
    fileprivate private(set) var powerChartBuffer = RingBuffer<PowerChartSample>(capacity: 180)
    private var metricsTask: Task<Void, Never>?
    private var latestCollectedMetrics: Metrics?
    private var latestCollectedMetricsError: String = ""
    private var isContentVisible: Bool = false

    private init() {
        startMetricsLoop()
        loadSocInfo()
    }

    func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsError = ""

        metricsTask = Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            var lastUpdateStarted = clock.now

            do {
                let sampler = try Sampler()
                defer { sampler.close() }

                while !Task.isCancelled {
                    let intervalMs = await MainActor.run { AppDependencies.shared.metricsIntervalMs }
                    let sampleInterval = Swift.Duration.milliseconds(intervalMs)
                    let elapsed = lastUpdateStarted.duration(to: clock.now)

                    if elapsed < sampleInterval {
                        do {
                            try await Task.sleep(for: sampleInterval - elapsed)
                        } catch {
                            break
                        }
                    }

                    guard !Task.isCancelled else { break }
                    lastUpdateStarted = clock.now

                    let metrics = try sampler.metrics()
                    await MainActor.run {
                        let sampleID = AppDependencies.shared.powerChartBuffer.appendedCount
                        let sample = PowerChartSample(sampleID: sampleID, metrics: metrics)
                        AppDependencies.shared.powerChartBuffer.append(sample)
                        AppDependencies.shared.latestCollectedMetrics = metrics
                        AppDependencies.shared.latestCollectedMetricsError = ""
                        AppDependencies.shared.publishMetricsStateIfVisible()
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.latestCollectedMetrics = nil
                    AppDependencies.shared.latestCollectedMetricsError = "Macmon metrics error: \(error)"
                    AppDependencies.shared.publishMetricsStateIfVisible()
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }

    func setContentVisible(_ isVisible: Bool) {
        guard isContentVisible != isVisible else { return }
        isContentVisible = isVisible

        if isVisible {
            latestMetrics = latestCollectedMetrics
            metricsError = latestCollectedMetricsError
        }
    }

    private func publishMetricsStateIfVisible() {
        guard isContentVisible else { return }
        latestMetrics = latestCollectedMetrics
        metricsError = latestCollectedMetricsError
    }

    private func loadSocInfo() {
        do {
            let info = try Macmon.socInfo()
            chipName = info.chipName
            socSummary = formatSocSummary(info)
        } catch {
            chipName = nil
            socSummary = ""
        }
    }

    private func formatSocSummary(_ info: SocInfo) -> String {
        var parts = info.cpuDomains.compactMap { domain -> String? in
            let name = cpuDomainLabel(for: domain.name)
            guard !name.isEmpty else { return nil }
            return "\(domain.units) \(name)"
        }
        parts.append("\(info.gpuCores) GPU cores")
        return parts.joined(separator: ", ")
    }

    private func cpuDomainLabel(for rawName: String) -> String {
        let lower = rawName.lowercased()
        if lower == "ecpu" {
            return "E-cores"
        }
        if lower == "pcpu" {
            return "P-cores"
        }
        return rawName;
    }

    @Published var metricsIntervalMs: Int = AppSettings.metricsIntervalMs {
        didSet {
            AppSettings.metricsIntervalMs = metricsIntervalMs
        }
    }

    func increaseMetricsInterval() {
        let current = metricsIntervalMs
        let step =
            current >= Self.largeIntervalThresholdMs
            ? Self.largeIntervalStepMs : Self.intervalStepMs
        metricsIntervalMs = min(
            ((metricsIntervalMs + step) / step) * step, Self.maxMetricsIntervalMs)
    }

    func decreaseMetricsInterval() {
        let step =
            metricsIntervalMs > Self.largeIntervalThresholdMs
            ? Self.largeIntervalStepMs : Self.intervalStepMs
        metricsIntervalMs = max(
            (max(metricsIntervalMs - step, 0) + step - 1) / step * step, Self.minMetricsIntervalMs)
    }

    private static let minMetricsIntervalMs = 1
    private static let maxMetricsIntervalMs = 10_000
    private static let intervalStepMs = 250
    private static let largeIntervalStepMs = 1_000
    private static let largeIntervalThresholdMs = 5_000
}


// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var lastBatteryStatus: String = ""

    var body: some View {
        let powerChartSamples = dependencies.powerChartBuffer.snapshot()

        VStack(spacing: 8) {
            HStack {
                Text(dependencies.chipName ?? "MenuStats")
                    .font(.headline)
                Text(dependencies.socSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    isOn: Binding(
                        get: { presentationState.mode == .pinned },
                        set: { isPinned in
                            presentationState.setPresentationMode(isPinned ? .pinned : .attached)
                        }
                    )
                ) {
                    Image(systemName: "pin")
                }
                    .toggleStyle(.button)
                    .help(presentationState.mode == .pinned ? "Attach to menu bar" : "Keep window open")
                Button("⏼") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 4)

            Divider()
                .background(Color(nsColor: .textColor))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Power")
                        .font(.headline)
                    Spacer()
                    Text("WATT")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }

                if !powerChartSamples.isEmpty {
                    HStack(alignment: .top) {
                        Chart {
                            ForEach(powerChartSamples) { sample in
                                ForEach(PowerChartDefinition.series) { series in
                                    LineMark(
                                        x: .value("Sample", sample.sampleID),
                                        y: .value("Watts", series.watts(from: sample.metrics)),
                                    )
                                        .foregroundStyle(by: .value("Series", series.title))
                                        .interpolationMethod(.monotone)
                                        .lineStyle(StrokeStyle(lineWidth: 1))
                                }
                            }
                        }
                            .chartForegroundStyleScale(
                                domain: PowerChartDefinition.series.map(\.title),
                                range: PowerChartDefinition.series.map(\.color)
                            )
                            .chartLegend(position: .top, alignment: .trailing, spacing: 10)
                            .chartXScale(domain: powerChartXDomain)
                            .chartYAxis { AxisMarks(position: .leading) }
                            .chartXAxis(.hidden)
                            .frame(maxWidth: .infinity)
                            .padding(.top, -22)

                        if let metrics = dependencies.latestMetrics {
                            VStack(alignment: .leading, spacing: 0) {
                                Spacer()
                                ForEach(PowerChartDefinition.series) { series in
                                    Text(formattedWatts(series.watts(from: metrics)))
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.bold)
                                        .foregroundStyle(series.color)
                                }
                            }
                        }
                    }
                }

                if dependencies.latestMetrics == nil && !dependencies.metricsError.isEmpty {
                    Text(dependencies.metricsError)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if dependencies.latestMetrics == nil {
                    Text("Waiting for metrics...")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
                .background {
                    Color(.textBackgroundColor)
                        .padding(.horizontal, -12)
                        .padding(.vertical, -8)
                }

            Divider()

            HStack(spacing: 4) {
                Text("Interval:")
                Text(intervalLabel)
                Button("–") {
                    dependencies.decreaseMetricsInterval()
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("-", modifiers: [])
                Text("/")
                    .foregroundStyle(.secondary)
                Button("+") {
                    dependencies.increaseMetricsInterval()
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("=", modifiers: [])
                Spacer()
            }

            if !lastBatteryStatus.isEmpty {
                Divider()
                Text(lastBatteryStatus)
                    .textSelection(.enabled)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
                    let exe = exeDir.appendingPathComponent("battery_tracker").path
                    let status = run_once(exe, ["status"]) ?? "(no output)"
                    DispatchQueue.main.async {
                        self.lastBatteryStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        .onChange(of: presentationState.isWindowVisible, initial: true) { _, isVisible in
            dependencies.setContentVisible(isVisible)
        }
    }

    private func formattedWatts(_ value: Double) -> String {
        String(format: "%6.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private var intervalLabel: String {
        let interval = dependencies.metricsIntervalMs
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", Double(interval) / 1000.0)
    }

    private var powerChartXDomain: ClosedRange<Int> {
        let buffer = dependencies.powerChartBuffer
        let lowerBound = buffer.appendedCount - buffer.capacity
        return lowerBound...buffer.appendedCount
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationController: MenuPresentationController<ContentView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentationController = MenuPresentationController(
            content: { presentationState in
                ContentView(presentationState: presentationState)
            },
            configureStatusItem: { statusItem in
                guard let button = statusItem.button else { return }

                if let image = NSImage(
                    systemSymbolName: AppPresentation.statusItemSystemImageName,
                    accessibilityDescription: AppPresentation.statusItemToolTip
                ) {
                    image.isTemplate = true
                    button.image = image
                    button.title = ""
                } else {
                    button.title = AppPresentation.statusItemFallbackTitle
                }

                button.toolTip = AppPresentation.statusItemToolTip
            },
            configureWindow: { window in
                window.title = AppPresentation.pinnedWindowTitle
                window.setContentSize(AppPresentation.windowMinSize)
                window.minSize = AppPresentation.windowMinSize
            }
        )
    }
}

@main
struct MenuStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
