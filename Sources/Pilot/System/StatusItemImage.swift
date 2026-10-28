import AppKit
import PilotCore

/// A menu-bar item as one small template picture (cards agent-bo-95422837 and 911). macOS redraws a status item once per
/// menu bar (one per display) whenever it changes; a SwiftUI view there cost a full layout and render each time, which
/// made the CPU and RAM item cost more than the Stats app's. The picture is drawn from the item's BarParts, the same
/// parts the top bar draws in SwiftUI; it is a template, so macOS colours it for the menu bar, and it is redrawn only
/// when its parts change.
@MainActor
enum StatusItemImage {
    static let height: CGFloat = 18
    /// Between the parts of one item, between the items of the group, around the group's capsule.
    private static let gap: CGFloat = 4, itemGap: CGFloat = 8, capsulePad: CGFloat = 5, padding: CGFloat = 2
    private static let graphWidth: CGFloat = 30, barWidth: CGFloat = 22, symbolSize: CGFloat = 13, markSize: CGFloat = 15

    nonisolated(unsafe) private static let value: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black]
    nonisolated(unsafe) private static let text: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black]
    nonisolated(unsafe) private static let label: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.black]
    nonisolated(unsafe) private static let badge: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.black]

    /// The picture, or nil with nothing to draw. `items` are the slot's items, the group's readings each their own, in a
    /// capsule when `capsule`. Drawn once into a bitmap at twice the point size, so each menu bar's redraw copies pixels.
    static func image(_ items: [[BarPart]], capsule: Bool = false) -> NSImage? {
        let items = items.map { $0.filter { switch $0 { case .app, .warn, .level: false; default: true } } }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        let partWidths = items.map { $0.map(width) }
        let widths = partWidths.map { $0.reduce(0, +) + gap * CGFloat($0.count - 1) }
        let inner = widths.reduce(0, +) + itemGap * CGFloat(widths.count - 1)
        let size = NSSize(width: (inner + (capsule ? capsulePad * 2 : 0) + padding * 2).rounded(.up), height: height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        if capsule {
            NSColor.black.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: NSRect(x: padding, y: 1, width: size.width - padding * 2, height: height - 2), xRadius: 5, yRadius: 5).fill()
        }
        var x = padding + (capsule ? capsulePad : 0)
        for (index, item) in items.enumerated() {
            var partX = x
            for (part, w) in zip(item, partWidths[index]) {
                draw(part, at: partX, width: w)
                partX += w + gap
            }
            x += widths[index] + itemGap
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    /// A part's width: a value the width of its widest reading, so the item never jumps as numbers change.
    static func width(_ part: BarPart) -> CGFloat {
        switch part {
        case .label(let s): measure(s, label)
        case .reading(let stat): measure(stat.short, label)
        case .value(let s, let widest): max(measure(s, value), widest.map(widestWidth) ?? 0)
        case .text(let s), .date(let s), .time(let s): measure(s, text)
        case .graph: graphWidth
        case .bar: barWidth
        case .symbol: symbolSize + 2
        case .mark: markSize
        case .ring: symbolSize
        case .badge(let s): measure(s, badge) + 8
        case .workspaces(let names, let current, let app):
            names.map { name in workspaceWidth(name, current: name == current, app: name == current ? app : nil) }.reduce(0, +)
                + 2 * CGFloat(max(names.count - 1, 0))
        case .dots(let count, _): CGFloat(count) * 6 + CGFloat(max(count - 1, 0)) * 3
        case .app, .warn, .level: 0
        case .strength: 4 * 3 + 3 * 1.5
        case .space(let points): points
        case .divider: 1
        case .extensionItem(let face): ExtensionGaugeIcon.width(face)
        }
    }

    private static func workspaceWidth(_ name: String, current: Bool, app: String?) -> CGFloat {
        max(measure(BarParts.workspaceLabel(name, app: app), badge) + 8, 16)
    }

    /// A value's widest text, measured once per text.
    private static var widests: [String: CGFloat] = [:]
    private static func widestWidth(_ s: String) -> CGFloat {
        if let known = widests[s] { return known }
        let measured = measure(s, value)
        widests[s] = measured
        return measured
    }

    private static func measure(_ s: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        NSAttributedString(string: s, attributes: attributes).size().width.rounded(.up)
    }

    private static func draw(_ part: BarPart, at x: CGFloat, width w: CGFloat) {
        switch part {
        case .label(let s): centred(s, label, x: x)
        case .reading(let stat): centred(stat.short, label, x: x)
        case .value(let s, _): centred(s, value, x: x)
        case .text(let s), .date(let s), .time(let s): centred(s, text, x: x)
        case .graph(let points):
            let path = NSBezierPath(), step = graphWidth / CGFloat(max(points.count - 1, 1)), bottom: CGFloat = 3, top = height - 3
            for (i, point) in points.enumerated() {
                let p = NSPoint(x: x + CGFloat(i) * step, y: bottom + (top - bottom) * CGFloat(min(max(point, 0), 1)))
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = 1.2
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
        case .bar(let share):
            let track = NSRect(x: x, y: (height - 5) / 2, width: barWidth, height: 5)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: barWidth * CGFloat(min(max(share, 0), 1)), height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = image.size
                image.draw(in: NSRect(x: x + (w - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height))
            }
        case .mark:
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.translateBy(x: x.rounded(), y: ((height - markSize) / 2).rounded())
            context.addPath(PilotMarkShape.path(markSize, flipped: false))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        case .ring(let left):
            let rect = NSRect(x: x + 1, y: (height - symbolSize) / 2 + 1, width: symbolSize - 2, height: symbolSize - 2)
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(max(left, 0), 1)), clockwise: true)
            arc.lineWidth = 2
            NSColor.black.setStroke()
            arc.stroke()
        case .badge(let s): knockout(s, rect: NSRect(x: x, y: 2, width: w, height: height - 4))
        case .workspaces(let names, let current, let app):
            var nx = x
            for name in names {
                let isCurrent = name == current, label = BarParts.workspaceLabel(name, app: isCurrent ? app : nil)
                let nw = workspaceWidth(name, current: isCurrent, app: isCurrent ? app : nil)
                if isCurrent {
                    knockout(label, rect: NSRect(x: nx, y: 2, width: nw, height: height - 4))
                } else {
                    let drawn = NSAttributedString(string: label, attributes: badge)
                    drawn.draw(at: NSPoint(x: nx + (nw - drawn.size().width) / 2, y: (height - drawn.size().height) / 2))
                }
                nx += nw + 2
            }
        case .dots(let count, let current):
            for i in 0..<count {
                NSColor.black.withAlphaComponent(i == current ? 1 : 0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + CGFloat(i) * 9, y: (height - 6) / 2, width: 6, height: 6)).fill()
            }
        case .strength(let bars):
            for (i, h) in BarParts.strengthHeights.enumerated() {
                NSColor.black.withAlphaComponent(i < bars ? 1 : 0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + CGFloat(i) * 4.5, y: (height - 12) / 2, width: 3, height: h), xRadius: 1, yRadius: 1).fill()
            }
        case .divider:
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: x, y: 2, width: 1, height: height - 4).fill()
        case .extensionItem(let face): ExtensionGaugeIcon.draw(face, at: x) { _ in .black }
        case .app, .space, .warn, .level: break
        }
    }

    private static func centred(_ s: String, _ attributes: [NSAttributedString.Key: Any], x: CGFloat) {
        let drawn = NSAttributedString(string: s, attributes: attributes)
        drawn.draw(at: NSPoint(x: x, y: (height - drawn.size().height) / 2))
    }

    /// A filled rounded box with its text cut out of it, so the menu bar's colour shows through the letters.
    private static func knockout(_ s: String, rect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let context = NSGraphicsContext.current
        let previous = context?.compositingOperation
        context?.compositingOperation = .destinationOut
        let drawn = NSAttributedString(string: s, attributes: badge)
        drawn.draw(at: NSPoint(x: rect.midX - drawn.size().width / 2, y: rect.midY - drawn.size().height / 2))
        if let previous { context?.compositingOperation = previous }
    }
}
