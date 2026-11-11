#if DEBUG
import AppKit
import Foundation
import Testing
import ImageScale
@testable import Pilot

/// Cursor trails and halos (P84), drawn offscreen through `CursorEffectPainter` onto a fixed sample path, never in an
/// overlay: each trail, the Ring (still and mid-squeeze), a left and a right ripple, and the Spotlight, on a dark and a
/// light ground in Tokyo Night's and Porcelain's colours, so the 1.5 pt edge shows on both:
/// `PILOT_RENDER_DIR=<tmp> swift test --filter CursorEffectsRenders`.
@MainActor
@Suite("Cursor effects renders")
struct CursorEffectsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let panel = CGSize(width: 260, height: 150), scale = 2
    static let grounds: [(name: String, grey: CGFloat, theme: String)] = [("dark", 0.12, "tokyo-night"), ("light", 0.96, "porcelain")]

    /// A sweep left to right with one wave, sampled every 8 ms over `length` and ending now (t = 1), at the pointer.
    static func path(_ length: TimeInterval, now: TimeInterval = 1) -> [CursorEffectState.Sample] {
        let n = 25
        return (0..<n).map { i in
            let k = CGFloat(i) / CGFloat(n - 1)
            return CursorEffectState.Sample(point: CGPoint(x: 40 + 170 * k, y: 75 + 34 * sin(k * 2 * .pi)), time: now - length * (1 - Double(k)))
        }
    }

    /// The panels, named, each a state at t = 1.
    static func panels() -> [(String, CursorEffectState)] {
        var out: [(String, CursorEffectState)] = []
        for trail in [CursorTrail.thread, .comet] {
            var s = CursorEffectState(); s.trail = trail; s.samples = path(trail.length); s.pointer = s.samples.last!.point
            out.append((trail.rawValue, s))
        }
        var dots = CursorEffectState(); dots.trail = .dots; dots.pointer = path(CursorTrail.dots.length)[0].point
        for sample in path(CursorTrail.dots.length) { dots.move(to: sample.point, at: sample.time) }
        out.append(("dots", dots))
        var ring = CursorEffectState(); ring.ring = true; ring.pointer = CGPoint(x: 90, y: 75); ring.ringFade.go(1, 0, instant: true)
        out.append(("ring", ring))
        var squeezed = ring; squeezed.pointer = CGPoint(x: 170, y: 75); squeezed.squeeze = 1 - 0.11   // the squeeze's middle
        out.append(("ring-click", squeezed))
        var ripple = CursorEffectState(); ripple.ripple = true
        ripple.ripples = [.init(point: CGPoint(x: 80, y: 75), time: 1 - 0.15, right: false), .init(point: CGPoint(x: 180, y: 75), time: 1 - 0.15, right: true)]
        out.append(("ripple-left-right", ripple))
        var still = ripple; still.reduceMotion = true
        out.append(("ripple-reduce-motion", still))
        return out
    }

    /// Sven's two screens, the 3440 × 1440 main and the 1080 × 1920 portrait at its left (global points).
    static let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: -1080, y: -240, width: 1080, height: 1920)]
    /// The part of them a jump panel shows, at a quarter scale: both sides of the screens' seam at x = 0.
    static let jumpView = CGRect(x: -520, y: 400, width: 1040, height: 600)
    /// Where a spike would cross, which must stay untouched (T45): for the jump panels the seam between the portrait's run
    /// and the main screen's, and the middle of the 692 pt jump after it; for the pause panel the middle of the 424 pt step.
    static func corridors(_ name: String) -> [CGRect] {
        name == "pause-dots" ? [CGRect(x: 220, y: 720, width: 60, height: 60)]
            : [CGRect(x: -25, y: 750, width: 50, height: 20), CGRect(x: 250, y: 665, width: 80, height: 80)]
    }

    /// Each trail fed through `move(to:at:)`, an event every 5 ms ending at t = 1: a run on the portrait screen, a step
    /// across the seam onto the main screen, a run there, then a 692 pt jump (a warp, or moves the monitors missed).
    static func jumpPanels() -> [(String, CursorEffectState)] {
        func run(_ a: CGPoint, _ b: CGPoint, _ n: Int) -> [CGPoint] {
            (0..<n).map { i in let k = CGFloat(i) / CGFloat(n - 1); return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }
        }
        let points = run(CGPoint(x: -460, y: 700), CGPoint(x: -40, y: 760), 8) + run(CGPoint(x: 40, y: 760), CGPoint(x: 80, y: 980), 5)
            + run(CGPoint(x: 500, y: 430), CGPoint(x: 560, y: 380), 5)
        return [CursorTrail.thread, .comet, .dots].map { trail in
            var s = CursorEffectState(); s.trail = trail; s.screens = screens
            let start = 1 - 0.005 * Double(points.count - 1)
            s.pointer = points[0]; s.lastMove = start
            for (i, p) in points.enumerated() { s.move(to: p, at: start + 0.005 * Double(i)) }
            return ("jump-\(trail.rawValue)", s)
        } + [pauseDots()]
    }

    /// Dots after the pointer sat still 0.4 s at (400, 600), then moved from 424 pt away on the same screen (a stale
    /// pointer): no dots along that step. Thread and Comet need no panel, their step that old has faded out.
    static func pauseDots() -> (String, CursorEffectState) {
        var s = CursorEffectState(); s.trail = .dots; s.screens = screens
        s.pointer = CGPoint(x: 400, y: 600); s.lastMove = 1 - 0.02 - 0.4
        for i in 0...4 { s.move(to: CGPoint(x: 100 + 15 * CGFloat(i), y: 900 + 15 * CGFloat(i)), at: 1 - 0.02 + 0.005 * Double(i)) }
        return ("pause-dots", s)
    }

    @Test("Each trail and halo draws on a fixed path, edged on dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func renders() throws {
        let dir = URL(filePath: try #require(Self.env["PILOT_RENDER_DIR"])).appending(path: "cursor-effects")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let themes = CursorEffectColours.load(CursorRenders.packaging)
        #expect(themes.count == 10, "effects.json lists ten themes: \(themes.keys.sorted())")
        let panels = Self.panels() + Self.jumpPanels()
        let w = Int(Self.panel.width) * Self.grounds.count, h = Int(Self.panel.height) * (panels.count + 1)
        let ctx = try #require(CGContext(data: nil, width: w * Self.scale, height: h * Self.scale, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
        for (g, ground) in Self.grounds.enumerated() {
            let colours = try #require(themes[ground.theme])
            for (row, (name, state)) in (panels + [("spotlight", CursorEffectState())]).enumerated() {
                let origin = CGPoint(x: CGFloat(g) * Self.panel.width, y: CGFloat(h) - CGFloat(row + 1) * Self.panel.height)
                let box = CGRect(origin: origin, size: Self.panel)
                ctx.setFillColor(CGColor(gray: ground.grey, alpha: 1)); ctx.fill(box)
                ctx.saveGState()
                ctx.clip(to: box)
                ctx.translateBy(x: origin.x, y: origin.y)
                // A stripe of the other ground, so each effect crosses both.
                ctx.setFillColor(CGColor(gray: 1.08 - ground.grey, alpha: 1)); ctx.fill(CGRect(x: 130, y: 0, width: 40, height: Self.panel.height))
                let jump = name.hasPrefix("jump-") || name == "pause-dots"
                if jump {
                    ctx.scaleBy(x: Self.panel.width / Self.jumpView.width, y: Self.panel.width / Self.jumpView.width)
                    ctx.translateBy(x: -Self.jumpView.minX, y: -Self.jumpView.minY)
                }
                let before = try #require(ctx.makeImage())
                if name == "spotlight" {
                    CursorEffectPainter.spotlight(at: CGPoint(x: 130, y: 75), level: 1, screen: CGRect(origin: .zero, size: Self.panel), in: ctx)
                } else {
                    CursorEffectPainter.draw(state, colours, now: 1, in: ctx)
                }
                ctx.restoreGState()
                let after = try #require(ctx.makeImage())
                let changed = Self.changed(before, after, in: box)
                #expect(changed > 40, "\(name) on \(ground.name) drew nothing")
                if jump {
                    let k = Self.panel.width / Self.jumpView.width
                    for corridor in Self.corridors(name) {
                        let local = CGRect(x: (corridor.minX - Self.jumpView.minX) * k, y: (corridor.minY - Self.jumpView.minY) * k,
                                           width: corridor.width * k, height: corridor.height * k)
                        let spike = Self.changed(before, after, in: local.offsetBy(dx: origin.x, dy: origin.y))
                        #expect(spike == 0, "\(name) on \(ground.name) drew \(spike) px across \(corridor)")
                        print("cursor effects render: \(name) on \(ground.name), \(spike) px in the corridor at \(corridor)")
                    }
                }
                print("cursor effects render: \(name) on \(ground.name) (\(ground.theme)), \(changed) px changed")
            }
        }
        let out = dir.appending(path: "trails-and-halos.png")
        try #require(ctx.makeImage().flatMap(ImageFormat.png.encode)).write(to: out)
        print("cursor effects render: \(out.path)")
    }

    @Test("Look › Cursor shows Trail and the three halos, Spotlight with its Set key", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func page() throws {
        let (look, dir) = try SharedLook.LookRenders.setUp()
        let effects = CursorEffects.of(look)
        effects.trail = .thread
        effects.ring = true
        effects.spotlight = true
        let out = dir.deletingLastPathComponent().appending(path: "cursor-effects/look-cursor.png")
        try SharedLook.LookRenders.shot(look, to: out, width: 1000, height: 2300)
        SharedLook.LookRenders.resetShared()
        print("cursor effects render: \(out.path)")
    }

    /// Pixels of `box` (points) that differ between two frames of the sheet.
    static func changed(_ a: CGImage, _ b: CGImage, in box: CGRect) -> Int {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data? else { return 0 }
        let row = a.bytesPerRow, s = CGFloat(scale), top = CGFloat(a.height) - box.maxY * s
        var count = 0
        for y in Int(top)..<Int(top + box.height * s) {
            for x in Int(box.minX * s)..<Int(box.maxX * s) where da[y * row + x * 4] != db[y * row + x * 4] { count += 1 }
        }
        return count
    }
}
#endif
