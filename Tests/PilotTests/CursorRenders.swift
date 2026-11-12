#if DEBUG
import AppKit
import Foundation
import Testing
import ImageScale
import PilotCore
@testable import Pilot

/// Cursor sets (P84), proved without touching the system cursor: nothing here registers, removes or applies a cursor.
/// The probe only looks the private calls up (`PILOT_CURSOR_PROBE=1 swift test --filter CursorRenders`); the renders draw
/// each set through `CursorArt` from `Packaging/Cursors`, in its own colours and two themes, and compare every cell with
/// the designer's QA sheets (vault `Projects/Pilot/Cursors 1.1/qa/<set>-all-palettes.png`, or PILOT_CURSOR_QA):
/// `PILOT_RENDER_DIR=<tmp> swift test --filter CursorRenders`.
@MainActor
@Suite("Cursor renders")
struct CursorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let packaging = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Cursors")
    static let qa = URL(filePath: env["PILOT_CURSOR_QA"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "hermes-vault/obsidian-vault/Projects/Pilot/Cursors 1.1/qa").path)
    /// The QA sheets' rows, top to bottom (the designer's sheets.py), and the three drawn here.
    static let qaRows = ["own", "dracula", "tokyo-night", "void", "ayu-dark", "garnet", "matte-black", "porcelain", "folio", "toybox-night", "toybox"]
    static let drawn = ["own", "tokyo-night", "porcelain"]
    /// sheets.py's flex rows: 10 px in, a 110 px label, 6 px gaps, 64 px cells (2x), 6 px above and below.
    static let cell = 64, firstX = 126, step = 70, rowHeight = 76, rowTop = 6
    /// The most one cell may be off the QA sheet on average, per channel.
    static let cellLimit = 1.5
    static let cellSamples = Double(cell * cell * 3)

    @Test("Every private cursor call resolves", .enabled(if: env["PILOT_CURSOR_PROBE"] != nil))
    func probe() {
        let found = CursorCalls.probe()
        for (name, ok) in found { print("cursor probe on \(CursorBackup.osBuild): \(name) \(ok ? "found" : "MISSING")") }
        #expect(found.count == 7 && found.allSatisfy(\.found), "\(found.filter { !$0.found }.map(\.name))")
        #expect(CursorCalls.loaded != nil)
    }

    @Test("Each set draws in its own colours and two themes, matching the designer's QA sheets", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func renders() throws {
        let dir = URL(filePath: try #require(Self.env["PILOT_RENDER_DIR"])).appending(path: "cursors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalogue = try #require(CursorCatalogue.load(Self.packaging))
        for id in ["quiet", "toybox", "duo"] {
            let set = try #require(catalogue.sets[id])
            let sheet = try #require(CursorArt.sheet(Self.packaging, set: id, scale: 2))
            let qa = try #require(Self.pixels(Self.qa.appending(path: "\(id)-all-palettes.png")))
            let cursors = set.cursors.values.sorted { $0.row < $1.row }
            #expect(cursors.count == 30)
            let ours = Bitmap(width: Self.firstX + Self.step * cursors.count, height: Self.rowHeight * Self.drawn.count)
            var total = 0.0, worst = (d: 0, at: "")
            var worstCell = (mean: 0.0, at: "")
            for (r, palette) in Self.drawn.enumerated() {
                let row = try #require(Self.qaRows.firstIndex(of: palette))
                let ground = qa.pixel(2, row * Self.rowHeight + 2)
                let colours = palette == "own" ? (set.palettes["own"] ?? [:]) : set.palette(.theme, theme: palette)
                ours.fill(y: r * Self.rowHeight, height: Self.rowHeight, ground)
                for (i, cursor) in cursors.enumerated() {
                    let image = try #require(CursorCatalogue.strip(sheet, cursor: cursor, palette: colours, px: Self.cell))
                    let frame = image.height > Self.cell ? try #require(image.cropping(to: CGRect(x: 0, y: 0, width: Self.cell, height: Self.cell))) : image
                    let x = Self.firstX + i * Self.step, y = r * Self.rowHeight + Self.rowTop
                    ours.draw(frame, x: x, y: y)
                    var cellTotal = 0.0
                    for py in 0..<Self.cell {
                        for px in 0..<Self.cell {
                            let a = ours.pixel(x + px, y + py), b = qa.pixel(x + px, row * Self.rowHeight + Self.rowTop + py)
                            for c in 0..<3 {
                                let d = abs(Int(a[c]) - Int(b[c]))
                                cellTotal += Double(d)
                                if d > worst.d { worst = (d, "\(palette) cell \(i) (\(px),\(py)) ours \(a.prefix(3)) qa \(b.prefix(3))") }
                            }
                        }
                    }
                    total += cellTotal
                    // Per cell, so one wrong cursor among 30 cannot hide in the sheet's average.
                    let cellMean = cellTotal / Self.cellSamples
                    if cellMean > worstCell.mean { worstCell = (cellMean, "\(palette) cell \(i)") }
                    #expect(cellMean < Self.cellLimit, "\(id) \(palette) cell \(i) is \(cellMean)/255 off the QA sheet")
                }
            }
            try #require(ours.png()).write(to: dir.appending(path: "\(id)-own-lagoon-porcelain.png"))
            let mean = total / (Self.cellSamples * Double(cursors.count * Self.drawn.count))
            print("cursor renders: \(id) against qa/\(id)-all-palettes.png, \(Self.drawn.joined(separator: ", ")): mean \(String(format: "%.3f", mean))/255, "
                  + "worst cell \(String(format: "%.3f", worstCell.mean))/255 (\(worstCell.at)), worst pixel \(worst.d)/255 (\(worst.at))")
        }
    }

    /// The designer's sample pairs (cursor-designs.notes.md › Proof): Sun, and Low, picked to be weak (1.8:1), each on
    /// the light and the dark ground the weak-pair check was drawn for.
    static let pairs: [(name: String, fill: UInt32, outline: UInt32)] = [("sun", 0xFFC933, 0x6B2FA8), ("low", 0x8E96A3, 0xC3C8D0)]
    static let grounds: [UInt32] = [0xEEF1F5, 0x0B0E14]

    @Test("Each design draws in two custom pairs on light and dark; Classic's masks are pixel-true; every role has a colour",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func customPairs() throws {
        let dir = URL(filePath: try #require(Self.env["PILOT_RENDER_DIR"])).appending(path: "cursors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalogue = try #require(CursorCatalogue.load(Self.packaging))
        // Kept as the theme draws them, by the designer's mapping: shadows, Toybox's cream glass and poof and white shine.
        let kept: [CursorSetID: Set<String>] = [.quiet: ["shadow"], .duo: ["shadow", "edge"], .toybox: ["glass", "poof", "shine"]]
        let derived: [CursorSetID: Set<String>] = [.duo: CursorCustom.duoShade, .toybox: CursorCustom.toyboxCandies]
        for set in [CursorSetID.quiet, .toybox, .duo, .classic] {
            let id = set.rawValue
            let art = try #require(catalogue.sets[id])
            let cursors = art.cursors.values.sorted { $0.row < $1.row }
            #expect(cursors.count == 30)
            // Every role the art paints is the fill's, the outline's, worked out from them, or kept as the theme draws it.
            let roles = try #require(CursorCustom.roles[set])
            let covered = roles.fill.union(roles.outline).union(derived[set] ?? []).union(kept[set] ?? [])
            #expect(Set(cursors.flatMap(\.layers)).filter { !covered.contains($0) && !CursorCustom.isGlyph($0) }.isEmpty, "\(id) roles left over")
            let sheet = try #require(CursorArt.sheet(Self.packaging, set: id, scale: 2))
            let rows = Self.pairs.count * Self.grounds.count
            let ours = Bitmap(width: Self.firstX + Self.step * cursors.count, height: Self.rowHeight * rows)
            for (p, pair) in Self.pairs.enumerated() {
                let custom = CursorCustom(set: set, fill: .custom(pair.fill), outline: .custom(pair.outline))
                let palette = art.palette(.custom, theme: "tokyo-night", custom: custom)
                for (g, ground) in Self.grounds.enumerated() {
                    let y = (p * Self.grounds.count + g) * Self.rowHeight
                    ours.fill(y: y, height: Self.rowHeight, Contrast.rgb(ground).map { UInt8($0) })
                    for (i, cursor) in cursors.enumerated() {
                        let image = try #require(CursorCatalogue.strip(sheet, cursor: cursor, palette: palette, px: Self.cell))
                        let frame = image.height > Self.cell ? try #require(image.cropping(to: CGRect(x: 0, y: 0, width: Self.cell, height: Self.cell))) : image
                        ours.draw(frame, x: Self.firstX + i * Self.step, y: y + Self.rowTop)
                    }
                }
                print("cursor renders: \(id) custom \(pair.name): fill/outline \(String(format: "%.1f", Contrast.ratio(pair.fill, pair.outline))):1, "
                      + "palette \(palette.filter { ["body", "fill", "rim", "outline", "shade", "edge", "sky"].contains($0.key) }.sorted { $0.key < $1.key })")
            }
            try #require(ours.png()).write(to: dir.appending(path: "\(id)-custom-sun-low.png"))
        }
        // Classic's two masks: hard pixels, outline and fill never on one pixel, and each scale the 1x grid in n x n blocks.
        let classic = try #require(catalogue.sets["classic"])
        #expect(classic.cursors.values.allSatisfy { $0.layers == ["outline", "fill"] })
        let one = try #require(CursorArt.sheet(Self.packaging, set: "classic", scale: 1))
        #expect(one.grey.allSatisfy { $0 == 0 || $0 == 255 })
        for y in 0..<one.height { for x in 0..<32 { #expect(!(one.grey[y * one.bytesPerRow + x] > 0 && one.grey[y * one.bytesPerRow + 32 + x] > 0)) } }
        for n in [2, 5] {
            let big = try #require(CursorArt.sheet(Self.packaging, set: "classic", scale: n))
            #expect(big.width == one.width * n && big.height == one.height * n)
            var off = 0
            for y in 0..<big.height { for x in 0..<big.width where big.grey[y * big.bytesPerRow + x] != one.grey[(y / n) * one.bytesPerRow + x / n] { off += 1 } }
            #expect(off == 0, "classic@\(n)x differs from 1x in \(off) px")
        }
        // The designs' own rules, as gen.py computes them: Duo's shade from its own fill, Toybox's candies read at 4.5:1.
        let duo = try #require(catalogue.sets["duo"]).palette(.custom, theme: "tokyo-night", custom: CursorCustom(set: .duo, fill: .custom(0x2BC4F0)))
        #expect(duo["shade"] == "#1B7A95" && duo["b_copy"] == "#1B7A95")
        let toy = try #require(catalogue.sets["toybox"]).palette(.custom, theme: "tokyo-night", custom: CursorCustom(set: .toybox, outline: .custom(0x6B2FA8)))
        #expect(["lilac", "mint", "coral", "sky"].allSatisfy { Contrast.ratio(Contrast.hex(toy[$0]!), 0x6B2FA8) >= 4.5 })
        print("cursor renders: classic masks pixel-true at 1x, 2x, 5x; duo shade \(duo["shade"]!); toybox candies \(["lilac", "mint", "coral", "sky"].map { toy[$0]! })")
    }

    @Test("Look › Cursor shows the preview, Shape, Size, Custom's wells and contrast, Effects and the halos with their colour (Q112)",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func page() throws {
        for (name, fill, outline) in Self.pairs {
            let (look, dir) = try SharedLook.LookRenders.setUp()
            let cursors = CursorSets.of(look), effects = CursorEffects.of(look)
            cursors.set = .quiet       // a render's store never applies (`mayApply`)
            cursors.size = .medium
            cursors.colours = .custom
            (cursors.fill, cursors.outline) = (.custom(fill), .custom(outline))
            effects.trail = .thread
            (effects.ring, effects.ripple) = (true, true)
            effects.colour = .custom(0xFF5C8A)
            let out = dir.deletingLastPathComponent().appending(path: "cursors/look-cursor-\(name).png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SharedLook.LookRenders.shot(look, to: out, width: 1000, height: 2300)
            SharedLook.LookRenders.resetShared()
            print("cursor renders: \(out.path)")
        }
    }

    // MARK: Pixels

    /// An sRGB RGBA bitmap, top row first.
    final class Bitmap {
        let width, height: Int
        let context: CGContext

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self), i = (y * width + x) * 4
            return [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]
        }

        func fill(y: Int, height h: Int, _ colour: [UInt8]) {
            context.setFillColor(CGColor(srgbRed: CGFloat(colour[0]) / 255, green: CGFloat(colour[1]) / 255, blue: CGFloat(colour[2]) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: height - y - h, width: width, height: h))
        }

        func draw(_ image: CGImage, x: Int, y: Int) {
            context.draw(image, in: CGRect(x: x, y: height - y - image.height, width: image.width, height: image.height))
        }

        func png() -> Data? { context.makeImage().flatMap(ImageFormat.png.encode) }
    }

    static func pixels(_ url: URL) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let bitmap = Bitmap(width: image.width, height: image.height)
        bitmap.draw(image, x: 0, y: 0)
        return bitmap
    }
}
#endif
