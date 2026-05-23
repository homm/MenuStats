import AppKit

enum BatteryIndicatorImage {
    private static let bodyWidth: CGFloat = 26
    private static let bodyHeight: CGFloat = 12
    private static let bodyInset: CGFloat = 2
    private static let strokeWidth: CGFloat = 1
    private static let capVisibleWidth: CGFloat = 1.5
    private static let capDiameter: CGFloat = 4.5
    private static let spacing: CGFloat = 1
    private static let chargeStatusSymbolSize: CGFloat = 12
    private static let powerSaveModeSymbolSize: CGFloat = 10
    private static let verticalExtension: CGFloat = 8
    private static let leftBase: CGFloat = 2

    static let size = CGSize(
        width: bodyWidth + spacing + capVisibleWidth + leftBase,
        height: bodyHeight + verticalExtension
    )

    static func make(
        state: BatteryTrackerState,
        usesSecondaryMask: Bool,
        energySave: Bool
    ) -> NSImage? {
        guard let percent = state.lastComputedStatus?.currentPercent else {
            return nil
        }

        let clampedPercent = min(max(percent, 0), 100)

        let image = NSImage(size: size)
        image.lockFocus()
        let batteryOriginY = (size.height - bodyHeight) / 2

        if usesSecondaryMask {
            NSColor.black.withAlphaComponent(0.5).setStroke()
        }
        let strokeRect = NSRect(x: leftBase, y: batteryOriginY, width: bodyWidth, height: bodyHeight)
            .insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let strokeRadius = 3 - strokeWidth / 4
        let strokePath = NSBezierPath(roundedRect: strokeRect, xRadius: strokeRadius, yRadius: strokeRadius)
        strokePath.lineWidth = strokeWidth
        strokePath.stroke()

        if usesSecondaryMask {
            NSColor.black.setFill()
        }
        let fillWidth = max(bodyWidth - bodyInset * 2, 0) * CGFloat(clampedPercent) / 100
        let fillRect = NSRect(
            x: leftBase + bodyInset, y: batteryOriginY + bodyInset,
            width: fillWidth, height: bodyHeight - bodyInset * 2
        )
        NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()

        if usesSecondaryMask {
            NSColor.black.withAlphaComponent(0.6).setFill()
        }
        let clipRect = NSRect(
            x: leftBase + bodyWidth + spacing,
            y: batteryOriginY + (bodyHeight - capDiameter) / 2,
            width: capVisibleWidth, height: capDiameter
        )
        let capRect = NSRect(
            x: clipRect.minX - capDiameter + capVisibleWidth, y: clipRect.minY,
            width: capDiameter, height: capDiameter
        )
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: clipRect).addClip()
        NSBezierPath(ovalIn: capRect).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let chargeRect = NSRect(
            x: leftBase + (bodyWidth - chargeStatusSymbolSize) / 2,
            y: batteryOriginY + (bodyHeight - chargeStatusSymbolSize) / 2,
            width: chargeStatusSymbolSize,
            height: chargeStatusSymbolSize
        )
        switch state.chargeStatus {
        case .charging:
            let chargePath = BatteryOverlaySymbol.bolt.path(in: chargeRect)
            drawOverlayMask(chargePath, strokeWidth: 2)
        case .onHold:
            let chargePath = BatteryOverlaySymbol.powerPlug.path(in: chargeRect)
            drawOverlayMask(chargePath, strokeWidth: 2)
        default:
            break
        }

        if energySave {
            let leafRect = NSRect(x: 0, y: -1, width: powerSaveModeSymbolSize, height: powerSaveModeSymbolSize)
            let leafPath = BatteryOverlaySymbol.leaf.path(in: leafRect)
            drawOverlayMask(leafPath, strokeWidth: 3)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawOverlayMask(_ path: NSBezierPath, strokeWidth: CGFloat) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private struct BatteryOverlaySymbol {
    let viewBox: CGSize
    let path: NSBezierPath

    func path(in rect: NSRect) -> NSBezierPath {
        let transformedPath = self.path.copy() as? NSBezierPath ?? NSBezierPath()
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let fittedSize = CGSize(width: viewBox.width * scale, height: viewBox.height * scale)
        let fittedOrigin = CGPoint(
            x: rect.minX + (rect.width - fittedSize.width) / 2,
            y: rect.minY + (rect.height - fittedSize.height) / 2
        )
        var transform = AffineTransform()
        transform.translate(x: fittedOrigin.x, y: fittedOrigin.y + fittedSize.height)
        transform.scale(x: scale, y: -scale)
        transformedPath.transform(using: transform)
        return transformedPath
    }

    nonisolated(unsafe) static let leaf: BatteryOverlaySymbol = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.290234, y: 1.19219))
        path.curve(to: NSPoint(x: 0, y: 4.3914), controlPoint1: NSPoint(x: 0.0798827, y: 2.1918), controlPoint2: NSPoint(x: 0, y: 3.50644))
        path.curve(to: NSPoint(x: 11.1533, y: 16.6644), controlPoint1: NSPoint(x: 0, y: 11.784), controlPoint2: NSPoint(x: 4.41426, y: 16.6644))
        path.curve(to: NSPoint(x: 18.0576, y: 13.2307), controlPoint1: NSPoint(x: 15.566, y: 16.6644), controlPoint2: NSPoint(x: 17.5777, y: 14.0465))
        path.line(to: NSPoint(x: 16.6102, y: 13.1557))
        path.curve(to: NSPoint(x: 19.1574, y: 18.0523), controlPoint1: NSPoint(x: 17.9605, y: 14.5752), controlPoint2: NSPoint(x: 18.5023, y: 15.9904))
        path.curve(to: NSPoint(x: 20.026, y: 18.7293), controlPoint1: NSPoint(x: 19.3092, y: 18.5369), controlPoint2: NSPoint(x: 19.649, y: 18.7293))
        path.curve(to: NSPoint(x: 21.3951, y: 17.1764), controlPoint1: NSPoint(x: 20.7873, y: 18.7293), controlPoint2: NSPoint(x: 21.3951, y: 18.0691))
        path.curve(to: NSPoint(x: 18.3994, y: 12.4727), controlPoint1: NSPoint(x: 21.3951, y: 15.8094), controlPoint2: NSPoint(x: 19.4193, y: 13.4305))
        path.curve(to: NSPoint(x: 5.80039, y: 6.48652), controlPoint1: NSPoint(x: 14.0482, y: 8.45176), controlPoint2: NSPoint(x: 7.44668, y: 10.8631))
        path.curve(to: NSPoint(x: 6.29629, y: 6.2164), controlPoint1: NSPoint(x: 5.68222, y: 6.17383), controlPoint2: NSPoint(x: 6.01093, y: 5.92128))
        path.curve(to: NSPoint(x: 18.3185, y: 10.6516), controlPoint1: NSPoint(x: 9.68125, y: 9.69452), controlPoint2: NSPoint(x: 14.1156, y: 6.78945))
        path.curve(to: NSPoint(x: 19.2176, y: 10.4156), controlPoint1: NSPoint(x: 18.6963, y: 10.9867), controlPoint2: NSPoint(x: 19.1484, y: 10.8182))
        path.curve(to: NSPoint(x: 19.2974, y: 9.24472), controlPoint1: NSPoint(x: 19.2664, y: 10.1342), controlPoint2: NSPoint(x: 19.2974, y: 9.68847))
        path.curve(to: NSPoint(x: 11.1844, y: 2.05586), controlPoint1: NSPoint(x: 19.2974, y: 4.45801), controlPoint2: NSPoint(x: 15.9807, y: 2.05586))
        path.curve(to: NSPoint(x: 6.29863, y: 2.45254), controlPoint1: NSPoint(x: 9.59902, y: 2.05586), controlPoint2: NSPoint(x: 7.74121, y: 2.45254))
        path.curve(to: NSPoint(x: 1.57363, y: 0.841017), controlPoint1: NSPoint(x: 4.74042, y: 2.45254), controlPoint2: NSPoint(x: 2.98867, y: 2.33789))
        path.curve(to: NSPoint(x: 0.290234, y: 1.19219), controlPoint1: NSPoint(x: 1.12226, y: 0.383402), controlPoint2: NSPoint(x: 0.458788, y: 0.47715))
        path.close()
        return BatteryOverlaySymbol(viewBox: CGSize(width: 22, height: 19), path: path)
    }()

    nonisolated(unsafe) static let bolt: BatteryOverlaySymbol = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 12.3639))
        path.curve(to: NSPoint(x: 0.747069, y: 13.0702), controlPoint1: NSPoint(x: 0, y: 12.7712), controlPoint2: NSPoint(x: 0.314062, y: 13.0702))
        path.line(to: NSPoint(x: 6.40527, y: 13.0702))
        path.line(to: NSPoint(x: 3.43183, y: 21.0717))
        path.curve(to: NSPoint(x: 4.83105, y: 21.8383), controlPoint1: NSPoint(x: 3.02812, y: 22.1356), controlPoint2: NSPoint(x: 4.13281, y: 22.7026))
        path.line(to: NSPoint(x: 13.9523, y: 10.5512))
        path.curve(to: NSPoint(x: 14.2185, y: 9.89459), controlPoint1: NSPoint(x: 14.1289, y: 10.3356), controlPoint2: NSPoint(x: 14.2185, y: 10.1297))
        path.curve(to: NSPoint(x: 13.4715, y: 9.18658), controlPoint1: NSPoint(x: 14.2185, y: 9.49362), controlPoint2: NSPoint(x: 13.9045, y: 9.18658))
        path.line(to: NSPoint(x: 7.81327, y: 9.18658))
        path.line(to: NSPoint(x: 10.7867, y: 1.18503))
        path.curve(to: NSPoint(x: 9.38749, y: 0.426434), controlPoint1: NSPoint(x: 11.1922, y: 0.122919), controlPoint2: NSPoint(x: 10.0857, y: -0.444072))
        path.line(to: NSPoint(x: 0.26621, y: 11.7073))
        path.curve(to: NSPoint(x: 0, y: 12.3639), controlPoint1: NSPoint(x: 0.0896484, y: 11.9292), controlPoint2: NSPoint(x: 0, y: 12.1368))
        path.close()
        return BatteryOverlaySymbol(viewBox: CGSize(width: 14.5799, height: 22.4228), path: path)
    }()

    nonisolated(unsafe) static let pause: BatteryOverlaySymbol = {
        let path = NSBezierPath()
        path.append(NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 4, height: 12), xRadius: 1, yRadius: 1))
        path.append(NSBezierPath(roundedRect: NSRect(x: 10, y: 4, width: 4, height: 12), xRadius: 1, yRadius: 1))
        return BatteryOverlaySymbol(viewBox: CGSize(width: 18, height: 20), path: path)
    }()

    nonisolated(unsafe) static let powerPlug: BatteryOverlaySymbol = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5.75507, y: 22.715))
        path.line(to: NSPoint(x: 8.10585, y: 22.715))
        path.curve(to: NSPoint(x: 9.87713, y: 20.9225), controlPoint1: NSPoint(x: 9.27401, y: 22.715), controlPoint2: NSPoint(x: 9.87713, y: 22.0986))
        path.line(to: NSPoint(x: 9.87713, y: 17.2004))
        path.curve(to: NSPoint(x: 11.3301, y: 14.8301), controlPoint1: NSPoint(x: 9.87713, y: 16.1076), controlPoint2: NSPoint(x: 10.4041, y: 15.526))
        path.curve(to: NSPoint(x: 13.8609, y: 9.71093), controlPoint1: NSPoint(x: 12.9728, y: 13.5834), controlPoint2: NSPoint(x: 13.8609, y: 11.6994))
        path.line(to: NSPoint(x: 13.8609, y: 7.13027))
        path.curve(to: NSPoint(x: 12.2972, y: 5.55331), controlPoint1: NSPoint(x: 13.8609, y: 6.11699), controlPoint2: NSPoint(x: 13.307, y: 5.56933))
        path.line(to: NSPoint(x: 11.2793, y: 5.54531))
        path.line(to: NSPoint(x: 11.2793, y: 1.3291))
        path.curve(to: NSPoint(x: 9.96796, y: 0), controlPoint1: NSPoint(x: 11.2793, y: 0.593553), controlPoint2: NSPoint(x: 10.6937, y: 0))
        path.curve(to: NSPoint(x: 8.64237, y: 1.3291), controlPoint1: NSPoint(x: 9.23593, y: 0), controlPoint2: NSPoint(x: 8.64237, y: 0.593553))
        path.line(to: NSPoint(x: 8.64237, y: 5.54531))
        path.line(to: NSPoint(x: 5.22558, y: 5.54531))
        path.line(to: NSPoint(x: 5.22558, y: 1.3291))
        path.curve(to: NSPoint(x: 3.92402, y: 0), controlPoint1: NSPoint(x: 5.22558, y: 0.593553), controlPoint2: NSPoint(x: 4.64804, y: 0))
        path.curve(to: NSPoint(x: 2.59668, y: 1.3291), controlPoint1: NSPoint(x: 3.19023, y: 0), controlPoint2: NSPoint(x: 2.59668, y: 0.593553))
        path.line(to: NSPoint(x: 2.59668, y: 5.54531))
        path.line(to: NSPoint(x: 1.55567, y: 5.55331))
        path.curve(to: NSPoint(x: 0, y: 7.13027), controlPoint1: NSPoint(x: 0.53789, y: 5.56933), controlPoint2: NSPoint(x: 0, y: 6.11699))
        path.line(to: NSPoint(x: 0, y: 9.71093))
        path.curve(to: NSPoint(x: 2.53886, y: 14.8301), controlPoint1: NSPoint(x: 0, y: 11.6994), controlPoint2: NSPoint(x: 0.888084, y: 13.5834))
        path.curve(to: NSPoint(x: 3.99355, y: 17.2004), controlPoint1: NSPoint(x: 3.46484, y: 15.526), controlPoint2: NSPoint(x: 3.99355, y: 16.1076))
        path.line(to: NSPoint(x: 3.99355, y: 20.9225))
        path.curve(to: NSPoint(x: 5.75507, y: 22.715), controlPoint1: NSPoint(x: 3.99355, y: 22.0986), controlPoint2: NSPoint(x: 4.5789, y: 22.715))
        path.close()
        return BatteryOverlaySymbol(viewBox: CGSize(width: 14.2222, height: 22.7293), path: path)
    }()
}
