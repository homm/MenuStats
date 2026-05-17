import AppKit
import Benchmark
import CoreText
import Foundation
import SwiftUI


private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

BenchmarkColumn.register(
    BenchmarkColumn(
        name: "throughput",
        value: { 1 / median($0.measurements) },
        unit: .inverseTime,
    )
)

private enum BenchmarkFonts {
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
}

private struct DetailsFonts: @unchecked Sendable {
    let valueFont: NSFont
    let percentFont: NSFont?
}

private final class OffscreenSurface: @unchecked Sendable {
    let rect: CGRect
    private let scale: CGFloat
    private let pixelRect: CGRect
    private let bitmap: NSBitmapImageRep
    private let graphicsContext: NSGraphicsContext

    init?(pixelSize: CGSize, scale: CGFloat) {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bitmapGraphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let graphicsContext = NSGraphicsContext(
            cgContext: bitmapGraphicsContext.cgContext,
            flipped: true
        )
        let pointSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        bitmap.size = pointSize

        self.rect = CGRect(origin: .zero, size: pointSize)
        self.scale = scale
        self.pixelRect = CGRect(origin: .zero, size: pixelSize)
        self.bitmap = bitmap
        self.graphicsContext = graphicsContext
    }

    func draw(_ text: NSAttributedString) {
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.setFillColor(NSColor.white.cgColor)
        graphicsContext.cgContext.fill(pixelRect)
        graphicsContext.cgContext.saveGState()
        graphicsContext.cgContext.scaleBy(x: scale, y: scale)
        graphicsContext.cgContext.translateBy(x: 0, y: rect.height)
        graphicsContext.cgContext.scaleBy(x: 1, y: -1)
        text.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        graphicsContext.cgContext.restoreGState()
        NSGraphicsContext.current = previousContext
    }

    func draw(lines: [(text: NSAttributedString, height: CGFloat)]) {
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.setFillColor(NSColor.white.cgColor)
        graphicsContext.cgContext.fill(pixelRect)
        graphicsContext.cgContext.saveGState()
        graphicsContext.cgContext.scaleBy(x: scale, y: scale)
        graphicsContext.cgContext.translateBy(x: 0, y: rect.height)
        graphicsContext.cgContext.scaleBy(x: 1, y: -1)
        var y: CGFloat = 0
        for line in lines {
            line.text.removingTrailingNewline.draw(
                with: CGRect(x: 0, y: y, width: rect.width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            y += line.height
        }
        graphicsContext.cgContext.restoreGState()
        NSGraphicsContext.current = previousContext
    }

    func writePNG(to url: URL) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try data.write(to: url)
    }
}

private let fontSize: CGFloat = 12
private let lines = [
    "1.41",
    "35.1%",
    "2.03",
    "1.3%",
    "0.34",
    "15.8%",
]
private let lineColors = [
    NSColor.systemGreen,
    NSColor.systemGreen.withAlphaComponent(0.65),
    NSColor.systemBlue,
    NSColor.systemBlue.withAlphaComponent(0.65),
    NSColor.systemRed,
    NSColor.systemRed.withAlphaComponent(0.65),
]
private let surface = OffscreenSurface(pixelSize: CGSize(width: 112, height: 220), scale: 2)

private extension NSAttributedString {
    var removingTrailingNewline: NSAttributedString {
        guard string.hasSuffix("\n"), length > 0 else { return self }
        return attributedSubstring(from: NSRange(location: 0, length: length - 1))
    }
}

private func makeDetailsText(fonts: DetailsFonts, usesColors: Bool) -> NSAttributedString {
    let text = NSMutableAttributedString()

    for (index, lineText) in lines.enumerated() {
        if index > 0 {
            text.append(NSAttributedString(string: "\n"))
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        if index == 1 || index == 3 {
            paragraphStyle.paragraphSpacing = 4
        }

        let line = NSMutableAttributedString(
            string: lineText,
            attributes: [
                .font: fonts.valueFont,
                .foregroundColor: usesColors ? lineColors[index] : NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )

        if let percentFont = fonts.percentFont {
            let nsLineText = lineText as NSString
            if nsLineText.hasSuffix("%") {
                line.addAttribute(
                    .font,
                    value: percentFont,
                    range: NSRange(location: nsLineText.length - 1, length: 1)
                )
            }
        }

        text.append(line)
    }

    return text
}

private func drawDetailsText(fonts: DetailsFonts, usesColors: Bool) {
    surface?.draw(makeDetailsText(fonts: fonts, usesColors: usesColors))
}

private func makeDetailsLineTexts(
    fonts: DetailsFonts,
    usesColors: Bool
) -> [(text: NSAttributedString, height: CGFloat)] {
    var result: [(text: NSAttributedString, height: CGFloat)] = []

    for (index, lineText) in lines.enumerated() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        if index == 1 || index == 3 {
            paragraphStyle.paragraphSpacing = 4
        }

        let line = NSMutableAttributedString(
            string: "\(lineText)\n",
            attributes: [
                NSAttributedString.Key.font: fonts.valueFont,
                NSAttributedString.Key.foregroundColor: usesColors ? lineColors[index] : NSColor.labelColor,
                NSAttributedString.Key.paragraphStyle: paragraphStyle,
            ]
        )

        if let percentFont = fonts.percentFont {
            let nsLineText = lineText as NSString
            if nsLineText.hasSuffix("%") {
                line.addAttribute(
                    NSAttributedString.Key.font,
                    value: percentFont,
                    range: NSRange(location: nsLineText.length - 1, length: 1)
                )
            }
        }

        let height: CGFloat = 15 + paragraphStyle.paragraphSpacing
        result.append((line, height))
    }

    return result
}

private func drawDetailsLines(fonts: DetailsFonts, usesColors: Bool) {
    surface?.draw(lines: makeDetailsLineTexts(fonts: fonts, usesColors: usesColors))
}

benchmark("Fonts.TabularNSFont") {
    autoreleasepool {
        _ = BenchmarkFonts.tabularSystemFont(ofSize: fontSize, weight: .bold)
    }
}

benchmark("Fonts.TabularSwiftUIFontFromNSFont") {
    autoreleasepool {
        _ = Font(BenchmarkFonts.tabularSystemFont(ofSize: fontSize, weight: .bold))
    }
}


private let singleFont = DetailsFonts(
    valueFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy),
    percentFont: nil
)

benchmark("makeDetailsText.SingleFont.CachedFonts") {
    autoreleasepool {
        _ = makeDetailsText(fonts: singleFont, usesColors: false)
    }
}

benchmark("makeDetailsText.SingleFont.UncachedFonts") {
    autoreleasepool {
        _ = makeDetailsText(
            fonts: DetailsFonts(
                valueFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy),
                percentFont: nil
            ),
            usesColors: false
        )
    }
}

benchmark("Offscreen.SingleFont.CachedFonts") {
    autoreleasepool {
        drawDetailsText(fonts: singleFont, usesColors: false)
    }
}

benchmark("Offscreen.SingleFont.UncachedFonts") {
    autoreleasepool {
        drawDetailsText(
            fonts: DetailsFonts(
                valueFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy),
                percentFont: nil
            ),
            usesColors: false
        )
    }
}

private let mixedFonts = DetailsFonts(
    valueFont: BenchmarkFonts.tabularSystemFont(ofSize: fontSize, weight: .bold),
    percentFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
)

benchmark("Offscreen.MixedFonts.CachedFonts") {
    autoreleasepool {
        drawDetailsText(fonts: mixedFonts, usesColors: false)
    }
}

benchmark("Offscreen.MixedFonts.UncachedFonts") {
    autoreleasepool {
        drawDetailsText(
            fonts: DetailsFonts(
                valueFont: BenchmarkFonts.tabularSystemFont(ofSize: fontSize, weight: .bold),
                percentFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
            ),
            usesColors: false
        )
    }
}

benchmark("Offscreen.MixedFontsAndColors.CachedFonts") {
    autoreleasepool {
        drawDetailsText(fonts: mixedFonts, usesColors: true)
    }
}

benchmark("Offscreen.MixedFontsAndColors.LineByLine.CachedFonts") {
    autoreleasepool {
        drawDetailsLines(fonts: mixedFonts, usesColors: true)
    }
}

benchmark("Offscreen.MixedFontsAndColors.UncachedFonts") {
    autoreleasepool {
        drawDetailsText(
            fonts: DetailsFonts(
                valueFont: BenchmarkFonts.tabularSystemFont(ofSize: fontSize, weight: .bold),
                percentFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
            ),
            usesColors: true
        )
    }
}

if let debugImagePath = ProcessInfo.processInfo.environment["OFFSCREEN_DEBUG_IMAGE"] {
    drawDetailsLines(fonts: mixedFonts, usesColors: true)
    // drawDetailsText(fonts: mixedFonts, usesColors: true)
    try surface?.writePNG(to: URL(fileURLWithPath: debugImagePath))
}

Benchmark.main()
