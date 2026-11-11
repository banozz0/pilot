#if DEBUG
import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The drop zone's look (card agent-bo-95423032), before and after, over a mock tiled desktop: a browser on the left
/// half, a terminal bottom right, and an editor dragged off the top right, its landing zone splitting the browser's lower
/// half or, as a swap, the terminal's tile, in Tokyo Night, Dusk and Folio, plus each zone's corner at 4x. All layers,
/// drawn once. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-3032 PILOT_RENDER_DIR=/tmp/pilot-renders/dropzone-<run> swift test --filter DropZoneRenders`
@MainActor
@Suite("Drop zone renders")
struct DropZoneRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: 1200, height: 750)

    /// The look before this card: the accent at 0.18 with a 2 pt edge at 0.7, inside the landing frame.
    static func before(_ layer: CALayer, _ theme: PilotTheme, _ landing: CGRect) {
        layer.frame = landing
        layer.backgroundColor = cg(theme.accent, 0.18)
        layer.borderColor = cg(theme.accent, 0.7)
        layer.borderWidth = 2
        layer.cornerRadius = WindowBorderPanel.windowRadius
    }

    /// The panel's look, at the default border width.
    static func after(_ layer: CALayer, _ theme: PilotTheme, _ landing: CGRect) {
        layer.frame = DropZonePanel.frame(around: landing, edge: 2)
        DropZonePanel.paint(layer, theme, edge: 2)
    }

    @Test("Before and after in a dark, a warm and a light theme", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try SharedLook.ClockRenders.dir("dropzone")
        for id in ["tokyo-night", "void", "folio"] {
            let theme = try #require(PilotTheme.named(id))
            for (name, paint) in [("before", Self.before), ("after", Self.after)] {
                for swap in [false, true] {
                    let desktop = Self.desktop(theme, swap: swap, zone: paint)
                    try Self.png(desktop).write(to: dir.appendingPathComponent("\(id)-\(swap ? "swap" : "split")-\(name).png"))
                    // The zone's lower corner and the dragged window's edge beside it, at 4x.
                    try Self.png(desktop, region: CGRect(x: swap ? 900 : 300, y: 0, width: 300, height: 160), scale: 4)
                        .write(to: dir.appendingPathComponent("\(id)-\(swap ? "swap" : "split")-\(name)-detail.png"))
                }
            }
        }
    }

    // MARK: The mock desktop

    static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        let c = Contrast.rgb(hex).map { CGFloat($0 / 255) }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha)
    }

    /// `rect` given from the top left, as the layer's bottom-left frame inside `height`.
    static func flip(_ rect: CGRect, in height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func box(_ rect: CGRect, in parent: CALayer, _ color: CGColor, radius: CGFloat = 0) -> CALayer {
        let layer = CALayer()
        layer.frame = flip(rect, in: parent.bounds.height)
        layer.backgroundColor = color
        layer.cornerRadius = radius
        parent.addSublayer(layer)
        return layer
    }

    /// Skeleton lines from the top left of `origin`, `widths` long, in `color`.
    static func lines(_ widths: [CGFloat], at origin: CGPoint, in parent: CALayer, _ color: CGColor, step: CGFloat = 18) {
        for (i, width) in widths.enumerated() where width > 0 {
            _ = box(CGRect(x: origin.x, y: origin.y + CGFloat(i) * step, width: width, height: 7), in: parent, color, radius: 3.5)
        }
    }

    /// A macOS 26 window: corner 16, the hairline round it, a title bar with its three lights; returns its body.
    static func window(_ rect: CGRect, in parent: CALayer, dark: Bool, shadow: Bool = false) -> CALayer {
        let frame = box(rect, in: parent, cg(dark ? 0x1E1F24 : 0xFFFFFF), radius: 16)
        frame.masksToBounds = true
        frame.borderWidth = 1
        frame.borderColor = dark ? cg(0xFFFFFF, 0.09) : cg(0x000000, 0.12)
        if shadow {
            // A window's lift, drawn by Core Graphics into the layer under it: render(in:) draws no layer shadows.
            let pad: CGFloat = 80
            if let ctx = bitmap(CGSize(width: rect.width + pad * 2, height: rect.height + pad * 2), scale: 2) {
                ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 48, color: cg(0x000000, 0.5))
                ctx.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad, width: rect.width, height: rect.height), cornerWidth: 16, cornerHeight: 16, transform: nil))
                ctx.setFillColor(.black)
                ctx.fillPath()
                let lift = CALayer()
                lift.frame = frame.frame.insetBy(dx: -pad, dy: -pad)
                lift.contents = ctx.makeImage()
                parent.insertSublayer(lift, below: frame)
            }
        }
        _ = box(CGRect(x: 0, y: 0, width: rect.width, height: 34), in: frame, cg(dark ? 0x26272D : 0xF3F3F3))
        for (i, light) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            _ = box(CGRect(x: 14 + CGFloat(i) * 20, y: 11, width: 12, height: 12), in: frame, cg(UInt32(light)), radius: 6)
        }
        return frame
    }

    /// The desktop mid-drag, the zone painted by `zone` splitting the browser's lower half, or on the terminal for a
    /// `swap`; the dragged editor and its focus border on top.
    static func desktop(_ theme: PilotTheme, swap: Bool, zone paint: (CALayer, PilotTheme, CGRect) -> Void) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let wallpaper = CAGradientLayer()
        wallpaper.frame = root.bounds
        wallpaper.colors = [cg(Contrast.hex(theme.wallpaper.colour)), cg(theme.ground)]
        wallpaper.startPoint = CGPoint(x: 0, y: 1)
        wallpaper.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(wallpaper)

        let gap: CGFloat = 12, half = (size.width - gap * 3) / 2, row = (size.height - gap * 3) / 2
        // The browser on the left half: a page of text and a photo.
        let browser = window(CGRect(x: gap, y: gap, width: half, height: size.height - gap * 2), in: root, dark: false)
        _ = box(CGRect(x: 120, y: 7, width: half - 240, height: 20), in: browser, cg(0xE4E4E7), radius: 6)
        lines([260, 0, 470, 500, 440, 480, 300], at: CGPoint(x: 36, y: 72), in: browser, cg(0x18181B, 0.22), step: 20)
        let photo = CAGradientLayer()
        photo.frame = flip(CGRect(x: 36, y: 240, width: half - 72, height: 250), in: browser.bounds.height)
        photo.colors = [cg(0x2B5876), cg(0xE07A5F)]
        photo.cornerRadius = 10
        photo.masksToBounds = true
        browser.addSublayer(photo)
        lines([480, 510, 420, 490, 360, 0, 450, 400], at: CGPoint(x: 36, y: 520), in: browser, cg(0x18181B, 0.22), step: 20)

        // The terminal bottom right.
        let terminal = window(CGRect(x: gap * 2 + half, y: gap * 2 + row, width: half, height: row), in: root, dark: true)
        let ink: [(CGFloat, UInt32)] = [(180, 0x9ECE6A), (320, 0xC0CAF5), (260, 0xC0CAF5), (140, 0x7DCFFF), (380, 0xC0CAF5),
                                        (220, 0xE0AF68), (300, 0xC0CAF5), (90, 0x9ECE6A), (340, 0xC0CAF5), (200, 0xC0CAF5),
                                        (120, 0x9ECE6A), (16, 0xC0CAF5)]
        for (i, (width, color)) in ink.enumerated() {
            _ = box(CGRect(x: 24, y: 56 + CGFloat(i) * 22, width: width, height: 8), in: terminal, cg(color, 0.55), radius: 2)
        }

        // The zone, where the editor lands: the browser's lower half, or the terminal's tile.
        let landing = CGRect(x: swap ? gap * 2 + half : gap, y: gap * 2 + row, width: half, height: row)
        let zone = CALayer()
        paint(zone, theme, flip(landing, in: size.height))
        root.addSublayer(zone)

        // The editor, dragged off the top right, held by the mouse over part of the zone, its focus border on top.
        let dragged = CGRect(x: swap ? 470 : 360, y: swap ? 250 : 300, width: half, height: row)
        let editor = window(dragged, in: root, dark: true, shadow: true)
        let code: [(CGFloat, CGFloat, UInt32)] = [(0, 140, 0xBB9AF7), (0, 260, 0xC0CAF5), (24, 300, 0x7AA2F7), (24, 180, 0xC0CAF5),
                                                  (48, 240, 0x9ECE6A), (48, 330, 0xC0CAF5), (24, 60, 0xC0CAF5), (0, 30, 0xC0CAF5),
                                                  (0, 0, 0), (0, 200, 0x565F89), (0, 280, 0xBB9AF7), (24, 220, 0xC0CAF5)]
        for (i, (indent, width, color)) in code.enumerated() where width > 0 {
            _ = box(CGRect(x: 56 + indent, y: 56 + CGFloat(i) * 22, width: width, height: 8), in: editor, cg(color, 0.6), radius: 2)
            _ = box(CGRect(x: 20, y: 56 + CGFloat(i) * 22, width: 14, height: 8), in: editor, cg(0x565F89, 0.6), radius: 2)
        }
        let border = box(dragged.insetBy(dx: -2, dy: -2), in: root, .clear, radius: WindowBorderPanel.windowRadius + 2)
        border.borderWidth = 2
        border.borderColor = cg(theme.accent)
        return root
    }

    /// An sRGB bitmap of `size` points at `scale`, drawn in points.
    static func bitmap(_ size: CGSize, scale: CGFloat) -> CGContext? {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: scale, y: scale)
        return ctx
    }

    /// `region` of `layer` (bottom-left points, all of it by default) drawn at `scale` as PNG bytes.
    static func png(_ layer: CALayer, region: CGRect? = nil, scale: CGFloat = 2) throws -> Data {
        let region = region ?? layer.bounds
        let ctx = try #require(bitmap(region.size, scale: scale))
        ctx.translateBy(x: -region.minX, y: -region.minY)
        layer.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        rep.size = region.size
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
#endif
