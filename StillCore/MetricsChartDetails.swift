import AppKit
import DGCharts

final class MetricsCurrentValuesRenderer: LineChartRenderer {
    override func drawExtras(context: CGContext) {
        super.drawExtras(context: context)
        guard let chartView = dataProvider as? MetricsLineChartView else { return }
        let rows = MainActor.assumeIsolated {
            MetricsDetailsBuilder.buildRows(
                from: chartView.getMaterializedPointsSlice(),
                series: chartView.series
            )
        }
        let attributedText = MetricsDetailsTextBuilder.buildCurrentValuesText(
            from: rows
        )
        drawLatestValues(context: context, attributedText: attributedText)
    }

    private func drawLatestValues(context: CGContext, attributedText: NSAttributedString) {
        guard attributedText.length > 0 else { return }
        let textBounds = attributedText.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let textRect = CGRect(
            x: viewPortHandler.contentRight,
            y: viewPortHandler.contentBottom - textBounds.height,
            width: 40,
            height: textBounds.height
        )
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

enum MetricsDetailsBuilder {
    struct Row {
        struct Item {
            let text: String
            let color: NSColor
        }

        let items: [Item]
    }

    @MainActor
    static func buildRows(
        from slice: [MaterializedChartPoint],
        series: [MetricsSeriesDescriptor]
    ) -> [Row] {
        let sortedSlice = slice.sorted { lhs, rhs in
            lhs.descriptorIndex < rhs.descriptorIndex
        }

        var rows: [Row] = []
        var currentGroup: String?
        var currentItems: [Row.Item] = []

        func flushCurrentRow() {
            guard !currentItems.isEmpty else { return }
            rows.append(.init(items: currentItems))
            currentItems = []
        }

        for point in sortedSlice {
            guard series.indices.contains(point.descriptorIndex) else { continue }
            let descriptor = series[point.descriptorIndex]
            guard descriptor.showsDetails else { continue }

            let group = descriptor.detailsGroup ?? "__details_\(point.descriptorIndex)"
            if currentGroup != group {
                flushCurrentRow()
                currentGroup = group
            }

            let itemColor: NSColor = switch descriptor.kind {
            case .line:
                NSColor(descriptor.color)
            case .fill:
                .secondaryLabelColor
            }

            currentItems.append(
                .init(
                    text: descriptor.detailsFormatter(point.detailsValue),
                    color: itemColor
                )
            )
        }

        flushCurrentRow()
        return rows
    }
}

enum MetricsDetailsTextBuilder {
    private static var font: NSFont { NSFont.monospacedSystemFont(ofSize: 10, weight: .bold) }
    private static let rowSpacing: CGFloat = 4

    static func buildMarkerText(from rows: [MetricsDetailsBuilder.Row]) -> NSAttributedString {
        let columnWidths = rows.reduce(into: [Int]()) { widths, row in
            for (index, item) in row.items.enumerated() {
                if widths.count == index {
                    widths.append(item.text.count)
                } else {
                    widths[index] = max(widths[index], item.text.count)
                }
            }
        }
        let text = NSMutableAttributedString()

        for row in rows {
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n"))
            }

            for (itemIndex, item) in row.items.enumerated() {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .right
                let paddedText = item.text.leftPadding(
                    toLength: columnWidths[itemIndex],
                    withPad: " "
                )

                text.append(
                    NSAttributedString(
                        string: (itemIndex == 0 ? "" : " ") + paddedText,
                        attributes: [
                            .font: font,
                            .foregroundColor: item.color,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
            }
        }

        return text
    }

    static func buildCurrentValuesText(from rows: [MetricsDetailsBuilder.Row]) -> NSAttributedString {
        let text = NSMutableAttributedString()

        for (rowIndex, row) in rows.enumerated() {
            for (itemIndex, item) in row.items.enumerated() {
                if text.length > 0 {
                    text.append(NSAttributedString(string: "\n"))
                }

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .right

                if itemIndex == row.items.indices.last,
                   rowIndex < rows.indices.last ?? 0 {
                    paragraphStyle.paragraphSpacing = rowSpacing
                }

                text.append(
                    NSAttributedString(
                        string: item.text,
                        attributes: [
                            .font: font,
                            .foregroundColor: item.color,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
            }
        }

        return text
    }
}

private extension String {
    func leftPadding(toLength length: Int, withPad pad: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}

class FormattedTextMarkerView: MarkerView {
    var attributedText = NSAttributedString() {
        didSet {
            updateLayout()
        }
    }

    private let contentInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    private let cornerRadius: CGFloat = 4
    private let markerSpacing: CGFloat = 4

    private func updateLayout() {
        guard attributedText.length > 0 else {
            frame.size = .zero
            return
        }

        let textBounds = attributedText.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let size = CGSize(
            width: contentInsets.left + textBounds.width + contentInsets.right,
            height: contentInsets.top + textBounds.height + contentInsets.bottom
        )

        frame.size = size
        offset = CGPoint(x: -size.width - markerSpacing, y: -size.height / 2)
    }

    override func draw(context: CGContext, point: CGPoint) {
        guard attributedText.length > 0 else { return }

        let offset = offsetForDrawing(atPoint: point)
        let rect = CGRect(
            x: point.x + offset.x,
            y: point.y + offset.y,
            width: bounds.width,
            height: bounds.height
        )

        context.saveGState()

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let textRect = CGRect(
            x: rect.minX + contentInsets.left,
            y: rect.minY + contentInsets.top,
            width: rect.width - contentInsets.left - contentInsets.right,
            height: rect.height - contentInsets.top - contentInsets.bottom
        )
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        context.restoreGState()
    }
}

final class MetricsDetailsMarkerView: FormattedTextMarkerView {
    @MainActor
    override func refreshContent(entry: ChartDataEntry, highlight: Highlight) {
        guard let chartView = chartView as? MetricsLineChartView else {
            attributedText = NSAttributedString()
            return
        }

        let rows = MetricsDetailsBuilder.buildRows(
            from: chartView.getMaterializedPointsSlice(x: entry.x),
            series: chartView.series
        )
        attributedText = MetricsDetailsTextBuilder.buildMarkerText(from: rows)
    }
}
