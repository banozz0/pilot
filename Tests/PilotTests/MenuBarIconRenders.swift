#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pilot's own menu-bar item as the mark alone (Q643, spec pilot-1-1 T5, the designer's drawing on `pilot-1.1-t5.html`), in
/// every theme: the macOS menu bar's picture (StatusItemImage) on a dark and a light bar, drawn while the theme is Look's
/// and the drawing appearance is the bar's, beside the top bar's mark with its accent (`InstrumentMark(accent: true)`) on
/// the theme's own surface. Opt-in like the other renders. The filled top-left box is measured on each bar: it reaches 3:1,
/// whether it is the accent, the accent moved toward the bar's ink, or today's template ink.
/// `CFFIXED_USER_HOME=/tmp/<fresh> PILOT_RENDER_DIR=/tmp/<fresh> swift test --filter MenuBarIconRenders`
extension SharedLook {
@MainActor
@Suite("Menu bar icon renders")
struct MenuBarIconRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The bars the picture is measured on: the macOS menu bar's appearance is all the item can know, so one reference
    /// ground and ink each (the drawing's BAR).
    static let bars: [(name: String, appearance: NSAppearance.Name, ground: UInt32, ink: NSColor)] = [
        ("dark", .darkAqua, 0x1E1E1E, .white), ("light", .aqua, 0xEBEBEB, .black)]
    static let scale: CGFloat = 4, height: CGFloat = 24, inset: CGFloat = 8

    @Test("The Pilot item's mark in all ten themes, on the top bar and on a dark and a light macOS menu bar",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu-bar-icon")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        (look.style, look.glass) = (.instrument, false)
        defer { (look.style, look.themeID, look.glass) = saved }

        // The default bar's Pilot item in the style Sven picked: the mark, no workspace number.
        var entry = try #require(BarSettings.defaults.entries.first { $0.kind == .pilot })
        entry.style = .icon
        var inputs = BarInputs()
        inputs.pilotTitle = "2"
        let parts = try #require(BarParts.parts(entry, inputs))
        #expect(parts == [.mark])

        var rows: [Row] = []
        for theme in PilotTheme.designed {
            look.themeID = theme.id
            var cells: [Cell] = []
            for bar in Self.bars {
                // Made and drawn in the bar's appearance, as macOS draws a status item: a picture that picks its ink when it
                // is drawn (a drawing handler, as ExtensionGaugeIcon's) and one drawn once when made both read right.
                var image: NSImage?, drawn: NSBitmapImageRep?
                try #require(NSAppearance(named: bar.appearance)).performAsCurrentDrawingAppearance {
                    image = StatusItemImage.image([parts])
                    drawn = image.flatMap { try? Self.onBar($0, ground: bar.ground, ink: bar.ink) }
                }
                let picture = try #require(image), rep = try #require(drawn)
                let fill = Self.hex(rep, x: Int((Self.inset + Self.boxCentre.x) * Self.scale),
                                    y: Int((Self.height - Self.offsetY(picture) - Self.boxCentre.y) * Self.scale))
                let ratio = Contrast.ratio(fill, bar.ground)
                #expect(ratio >= 3, "\(theme.name) on a \(bar.name) menu bar: the mark's filled box is \(String(format: "%.2f", ratio)):1")
                cells.append(Cell(rep: rep, fill: fill, ratio: ratio, accent: fill == theme.accent))
            }
            rows.append(Row(theme: theme, cells: cells))
        }
        try writeRender(Sheet(rows: rows), to: dir.appendingPathComponent("menu-bar-icon.png"), wait: 0.3)
    }

    /// The filled box's centre from the picture's bottom left: the mark sits `padding` 2 in and centred in 18 points, its
    /// boxes 7 points with a 1 point gap at 15 (PilotMarkShape).
    static let boxCentre = CGPoint(x: 2 + 3.5, y: 11.5)
    static func offsetY(_ image: NSImage) -> CGFloat { ((height - image.size.height) / 2).rounded() + ((image.size.height - 15) / 2).rounded() }

    /// The picture on a bar's ground at 4x, as macOS shows it: a template takes the bar's ink, anything else keeps its colours.
    static func onBar(_ image: NSImage, ground: UInt32, ink: NSColor) throws -> NSBitmapImageRep {
        let size = NSSize(width: image.size.width + inset * 2, height: height)
        // In sRGB, as the themes' hex colours are, so the box reads back as drawn.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        Self.colour(ground).setFill()
        NSRect(origin: .zero, size: size).fill()
        let rect = NSRect(x: inset, y: ((height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
        if image.isTemplate {
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        } else {
            image.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func colour(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The pixel at `x`, `y` (from the top) as drawn, its sRGB bytes: `colorAt` hands back a converted colour.
    static func hex(_ rep: NSBitmapImageRep, x: Int, y: Int) -> UInt32 {
        guard let data = rep.bitmapData else { return 0 }
        let p = data + y * rep.bytesPerRow + x * rep.bitsPerPixel / 8
        return UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
    }

    struct Cell { let rep: NSBitmapImageRep; let fill: UInt32; let ratio: Double; let accent: Bool }
    struct Row { let theme: PilotTheme; let cells: [Cell] }

    /// One row per theme: its name, the top bar's mark on the theme's surface, then the picture on each bar with what the
    /// filled box measured.
    struct Sheet: View {
        let rows: [Row]
        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    ForEach(["Theme", "Top bar", "macOS bar, dark", "macOS bar, light"], id: \.self) {
                        Text($0.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color(white: 0.6))
                    }
                }
                ForEach(rows, id: \.theme.id) { row in
                    GridRow {
                        Text(row.theme.name).font(.system(size: 12, weight: .semibold))
                        InstrumentMark(size: 14, accent: true).foregroundStyle(Color(hex: row.theme.text2))
                            .padding(.horizontal, 12).frame(height: 24).background(Color(hex: row.theme.surface))
                            .environment(\.style, StyleTokens.of(.instrument, theme: row.theme))
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            HStack(spacing: 10) {
                                Image(nsImage: NSImage(cgImage: cell.rep.cgImage!, size: cell.rep.size)).interpolation(.none)
                                Text(String(format: "#%06X · %.1f:1%@", cell.fill, cell.ratio, cell.accent ? " · accent" : ""))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(cell.ratio >= 3 ? Color.white : Color.red)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .foregroundStyle(.white)
            .background(Color(white: 0.14))
        }
    }
}
}
#endif
