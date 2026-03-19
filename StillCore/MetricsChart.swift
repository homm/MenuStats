import AppKit
import SwiftUI
import DGCharts
import MacmonSwift

private enum MetricsChartPalette {
    static let board = Color(red: 0.12, green: 0.8, blue: 0.2)
    static let package = Color(red: 0.13, green: 0.48, blue: 0.97)
    static let cpu = Color(red: 0.32, green: 0.74, blue: 0.98)
    static let gpu = Color(red: 1, green: 0.22, blue: 0.02)
    static let ane = Color(red: 0.98, green: 0.58, blue: 0.02)

    static let cpuFrequencyPalette: [Color] = [
        board, package, cpu,
        Color(red: 0.18, green: 0.60, blue: 0.84),
        Color(red: 0.10, green: 0.42, blue: 0.70),
    ]

    static let gpuFrequencyPalette: [Color] = [
        gpu, ane,
        Color(red: 0.92, green: 0.36, blue: 0.18),
        Color(red: 0.86, green: 0.14, blue: 0.34),
    ]
}

func normalizedGPUClusterName(_ rawName: String) -> String {
    rawName.isEmpty ? "" : rawName.uppercased()
}

struct MetricsSeriesDescriptor {
    let title: String
    let color: Color
    let value: (Metrics) -> Double
    var usageValue: ((Metrics) -> Double)?
}

struct MetricsSample: Identifiable {
    let sampleID: Int
    let metrics: Metrics

    var id: Int { sampleID }
}

@MainActor
struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    let helpMarkdown: String?
    private let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]

    init(title: String, unitLabel: String, helpMarkdown: String? = nil, series: [MetricsSeriesDescriptor]) {
        self.title = title
        self.unitLabel = unitLabel
        self.helpMarkdown = helpMarkdown
        self.seriesBuilder = { _ in series }
    }

    init(
        title: String,
        unitLabel: String,
        helpMarkdown: String? = nil,
        seriesBuilder: @escaping (Metrics?) -> [MetricsSeriesDescriptor]
    ) {
        self.title = title
        self.unitLabel = unitLabel
        self.helpMarkdown = helpMarkdown
        self.seriesBuilder = seriesBuilder
    }

    func resolvedSeries(from metrics: Metrics?) -> [MetricsSeriesDescriptor] {
        seriesBuilder(metrics)
    }
}

@MainActor
enum MetricsChartDefinitions {
    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "WATT",
        helpMarkdown:
"""
**Power draw by components**

• `SYS` is the total system power draw.
• `CHIP` is the power reported for the whole SoC, including all compute units and memory.
• `CPU`, `GPU`, and `ANE` are individual parts of `CHIP`.
""",
        series: [
            MetricsSeriesDescriptor(
                title: "SYS",
                color: MetricsChartPalette.board,
                value: { Double($0.power.board) }
            ),
            MetricsSeriesDescriptor(
                title: "CHIP",
                color: MetricsChartPalette.package,
                value: { Double($0.power.package) }
            ),
            MetricsSeriesDescriptor(
                title: "CPU",
                color: MetricsChartPalette.cpu,
                value: { Double($0.power.cpu) }
            ),
            MetricsSeriesDescriptor(
                title: "ANE",
                color: MetricsChartPalette.ane,
                value: { Double($0.power.ane) }
            ),
            MetricsSeriesDescriptor(
                title: "GPU",
                color: MetricsChartPalette.gpu,
                value: { Double($0.power.gpu) }
            ),
        ]
    )

    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage",
        unitLabel: "GHz",
        helpMarkdown:
"""
Current frequency and usage of all CPU and GPU clusters.

**How to read this mess**
Each cluster is shown with a solid line for frequency \
and a semi-transparent area underneath for current usage. \
The area shows the fraction of that frequency that is being used. \
When usage is at 100%, the area reaches the line.
""",
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        series: [
            MetricsSeriesDescriptor(
                title: "CPU",
                color: MetricsChartPalette.cpu,
                value: { Double($0.temperature.cpuAverage) }
            ),
            MetricsSeriesDescriptor(
                title: "GPU",
                color: MetricsChartPalette.gpu,
                value: { Double($0.temperature.gpuAverage) }
            ),
        ]
    )

    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu_usage.enumerated().map { index, cluster in
            MetricsSeriesDescriptor(
                title: cluster.name,
                color: MetricsChartPalette.cpuFrequencyPalette[
                    index % MetricsChartPalette.cpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.cpu_usage[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.cpu_usage[index].usage)
                }
            )
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu_usage.enumerated().map { index, cluster in
            MetricsSeriesDescriptor(
                title: cluster.name,
                color: MetricsChartPalette.gpuFrequencyPalette[
                    index % MetricsChartPalette.gpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.gpu_usage[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.gpu_usage[index].usage)
                }
            )
        }
    }
}

private struct MetricsChartRenderSeries {
    let descriptor: MetricsSeriesDescriptor
    let lineEntries: [ChartDataEntry]
    let fillEntries: [ChartDataEntry]?
}

private struct MetricsChartRenderModel {
    let series: [MetricsChartRenderSeries]

    init(samples: [MetricsSample], series descriptors: [MetricsSeriesDescriptor]) {
        self.series = descriptors.map { descriptor in
            let lineEntries = samples.map { sample in
                ChartDataEntry(
                    x: Double(sample.sampleID),
                    y: descriptor.value(sample.metrics)
                )
            }

            let fillEntries = descriptor.usageValue.map { usageValue in
                samples.map { sample in
                    ChartDataEntry(
                        x: Double(sample.sampleID),
                        y: usageValue(sample.metrics) * descriptor.value(sample.metrics)
                    )
                }
            }

            return MetricsChartRenderSeries(
                descriptor: descriptor,
                lineEntries: lineEntries,
                fillEntries: fillEntries
            )
        }
    }
}

final class UpperBoundStabilizer {
    private(set) var current: Double = -.infinity

    /// If the new quantized value is sufficiently below the current bound,
    /// the upper bound is allowed to shrink.
    let shrinkThreshold: Double

    /// Allowed significand steps in the [1, 10] decade.
    /// Example: with [1, 1.5, 2, 3, 5, 10],
    /// 112 -> 150, 0.112 -> 0.15, -112 -> -100, -0.112 -> -0.1.
    let steps: [Double]

    let spaceTop: Double

    init(shrinkThreshold: Double, steps: [Double], spaceTop: Double = 0.0) {
        self.shrinkThreshold = shrinkThreshold
        self.steps = steps
        self.spaceTop = spaceTop
    }

    func update(height: Double) -> Double {
        guard height > 0 else { return 0 }

        let newHeight = quantizeUp(height * (1 + spaceTop))

        if newHeight > current || newHeight < current * shrinkThreshold {
            current = newHeight
        }

        return current
    }

    private func quantizeUp(_ value: Double) -> Double {
        guard value > 0 else { return 0 }

        let exponent = floor(log10(value))
        let scale = pow(10.0, exponent)
        let significand = value / scale
        let quantizedSignificand = steps.first(where: { $0 >= significand }) ?? 10

        return quantizedSignificand * scale
    }
}


final class MetricsLineChartView: LineChartView {
    let yMaxStabilizer = UpperBoundStabilizer(
        shrinkThreshold: 0.6,
        steps: [1, 1.5, 2.5, 4, 6, 10],
        spaceTop: 0.1
    )
}

private struct MetricsDGChartView: NSViewRepresentable {
    let renderModel: MetricsChartRenderModel
    let xDomain: ClosedRange<Int>
    let yStart: Double
    let desiredCount: Int
    let lineWidth: Double

    func makeNSView(context: Context) -> MetricsLineChartView {
        let chartView = MetricsLineChartView()
        chartView.drawBordersEnabled = false
        chartView.drawGridBackgroundEnabled = false
        chartView.chartDescription.enabled = false
        chartView.scaleXEnabled = false
        chartView.scaleYEnabled = false
        chartView.minOffset = 0
        chartView.extraTopOffset = 8

        let xAxis = chartView.xAxis
        xAxis.enabled = true
        xAxis.drawLabelsEnabled = false
        xAxis.drawAxisLineEnabled = false
        xAxis.drawGridLinesEnabled = false

        let rightAxis = chartView.rightAxis
        rightAxis.enabled = false
        return chartView
    }

    func updateNSView(_ chartView: MetricsLineChartView, context: Context) {
        configureAxes(chartView)
        configureLegend(chartView)
        chartView.data = makeChartData()
    }

    private func configureAxes(_ chartView: MetricsLineChartView) {
        let xAxis = chartView.xAxis
        xAxis.axisMinimum = Double(xDomain.lowerBound)
        xAxis.axisMaximum = Double(xDomain.upperBound)

        let leftAxis = chartView.leftAxis
        leftAxis.enabled = true
        leftAxis.axisMinimum = yStart
        leftAxis.axisMaximum = getYMax(chartView)

        leftAxis.drawLabelsEnabled = true
        leftAxis.setLabelCount(desiredCount, force: false)
        leftAxis.drawAxisLineEnabled = false
        leftAxis.drawGridLinesEnabled = true
        leftAxis.gridLineWidth = 0.5
        leftAxis.gridLineDashLengths = [3, 2]
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 1
        leftAxis.zeroLineDashLengths = nil
    }

    private func getYMax(_ chartView: MetricsLineChartView) -> Double {
        let rawYMax = chartView.data?.getYMax(axis: .left) ?? 0
        return chartView.yMaxStabilizer.update(height: rawYMax - yStart) + yStart
    }

    private func makeChartData() -> LineChartData {
        let fillDataSets = renderModel.series.compactMap(makeFillDataSet(for:))
        let lineDataSets = renderModel.series.reversed().map(makeLineDataSet(for:))
        return LineChartData(dataSets: fillDataSets + lineDataSets)
    }

    private func makeLineDataSet(for series: MetricsChartRenderSeries) -> LineChartDataSet {
        let dataSet = LineChartDataSet(
            entries: series.lineEntries,
            label: series.descriptor.title
        )
        dataSet.mode = .linear
        dataSet.drawValuesEnabled = false
        dataSet.drawCirclesEnabled = false
        dataSet.drawFilledEnabled = false
        dataSet.lineWidth = lineWidth
        dataSet.setColor(NSColor(series.descriptor.color))
        dataSet.highlightEnabled = false
        return dataSet
    }

    private func makeFillDataSet(for series: MetricsChartRenderSeries) -> LineChartDataSet? {
        guard let fillEntries = series.fillEntries else { return nil }

        let dataSet = LineChartDataSet(
            entries: fillEntries,
            label: series.descriptor.title
        )
        dataSet.mode = .linear
        dataSet.drawValuesEnabled = false
        dataSet.drawCirclesEnabled = false
        dataSet.lineWidth = 0
        dataSet.drawFilledEnabled = true
        dataSet.fillColor = NSColor(series.descriptor.color)
        dataSet.fillAlpha = 0.3
        dataSet.highlightEnabled = false
        return dataSet
    }

    private func configureLegend(_ chartView: LineChartView) {
        let legend = chartView.legend
        legend.enabled = true
        legend.horizontalAlignment = .right
        legend.verticalAlignment = .top
        legend.orientation = .horizontal
        legend.drawInside = false
        legend.form = .circle
        legend.formSize = 8
        legend.xEntrySpace = 10
        legend.xOffset = 0
        legend.yOffset = -1
        legend.font = .systemFont(ofSize: 12)
        legend.textColor = NSColor(Color.secondary)
        legend.setCustom(entries: renderModel.series.map { series in
            let entry = LegendEntry(label: series.descriptor.title)
            entry.formColor = NSColor(series.descriptor.color)
            return entry
        })
    }
}

struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let samples: [MetricsSample]
    let xDomain: ClosedRange<Int>
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)? = nil
    var desiredCount = 6
    var lineWidth = 1.0
    var yStart = 0.0
    @State private var isHelpPresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let lastMetrics = samples.last?.metrics {
                let series = definition.resolvedSeries(from: lastMetrics)
                MetricsDGChartView(
                    renderModel: MetricsChartRenderModel(samples: samples, series: series),
                    xDomain: xDomain,
                    yStart: yStart,
                    desiredCount: desiredCount,
                    lineWidth: lineWidth
                )
                latestValuesView(series: series, metrics: lastMetrics)
            } else {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .topLeading, content: headerView)
    }

    private func latestValuesView(series: [MetricsSeriesDescriptor], metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(series, id: \.title) { series in
                Text(valueFormatter(series.value(metrics)))
                    .font(.system(.footnote, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(series.color)
                    .padding(.top, 4)
                if let usageValueFormatter, let usageValue = series.usageValue {
                    Text(usageValueFormatter(usageValue(metrics)))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func headerView() -> some View {
        HStack(alignment: .bottom) {
            HStack(alignment: .center, spacing: 4) {
                Text(definition.title)
                    .font(.headline)
                if let helpMarkdown = definition.helpMarkdown {
                    Button {
                        isHelpPresented.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
                        ChartHelpPopover(markdown: helpMarkdown)
                    }
                }
            }
            Spacer()
            Text(definition.unitLabel)
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChartHelpPopover: View {
    let markdown: String

    private var attributedMarkdown: AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(markdown)
        }
    }

    var body: some View {
        Text(attributedMarkdown)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}
