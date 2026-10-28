import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423220: Defocus. A mouse shake toggles it, and the look follows Look's strength and Reduce
/// Transparency.
@Suite("Defocus")
struct DefocusTests {
    /// Feeds strokes of `dx` points each, alternating direction, with `dy` points of vertical travel per stroke, as 8 ms
    /// mouse moves; a scroll event before every move with `scrolling`. True when any move fired.
    static func shake(_ detector: inout ShakeDetector, strokes: Int, dx: Double = 80, dy: Double = 0, seconds: Double = 0.1,
                      scrolling: Bool = false, from start: TimeInterval = 100) -> (fired: Bool, end: TimeInterval) {
        var t = start, fired = false
        let steps = max(1, Int(seconds / 0.008))
        for s in 0..<strokes {
            let sign: Double = s.isMultiple(of: 2) ? 1 : -1
            for _ in 0..<steps {
                t += 0.008
                if scrolling { detector.scroll(at: t) }
                if detector.move(dx: sign * dx / Double(steps), dy: dy / Double(steps), at: t) { fired = true }
            }
        }
        return (fired, t)
    }

    @Test("Six fast strokes, five swings (the default), fire once")
    func shakeFires() {
        var d = ShakeDetector()
        #expect(Self.shake(&d, strokes: 6).fired)
    }

    @Test("Four swings are not a shake by default: a step stricter than the four it took before")
    func tooFew() {
        var d = ShakeDetector()
        #expect(!Self.shake(&d, strokes: 5).fired)
    }

    @Test("Pointer drift during a scroll never fires, nor in the moment after it stops")
    func scrollDrift() {
        var d = ShakeDetector()
        let during = Self.shake(&d, strokes: 12, scrolling: true)
        #expect(!during.fired)
        #expect(!Self.shake(&d, strokes: 6, seconds: 0.04, from: during.end).fired, "a scroll's tail settles before strokes count")
    }

    @Test("A real shake still fires once the scroll has settled")
    func shakeAfterScroll() {
        var d = ShakeDetector()
        let scrolled = Self.shake(&d, strokes: 6, scrolling: true)
        #expect(Self.shake(&d, strokes: 6, from: scrolled.end + ShakeDetector.scrollQuiet + 0.05).fired)
    }

    @Test("Strokes with vertical travel near their sideways travel are not a shake; a slight tilt still is")
    func diagonal() {
        var d = ShakeDetector()
        #expect(!Self.shake(&d, strokes: 12, dx: 80, dy: 70).fired)
        d = ShakeDetector()
        #expect(Self.shake(&d, strokes: 6, dx: 80, dy: 20).fired)
    }

    @Test("Swings needed and Within set the thresholds")
    func tuning() {
        var d = ShakeDetector(swings: 3)
        #expect(Self.shake(&d, strokes: 4).fired)
        d = ShakeDetector(swings: 8)
        #expect(!Self.shake(&d, strokes: 6).fired)
        d = ShakeDetector(swings: 8)
        #expect(Self.shake(&d, strokes: 9).fired)
        // Five swings 0.15 s apart span 0.6 s: inside a 0.7 s window, outside 0.4 s.
        d = ShakeDetector(swings: 5, within: 0.4)
        #expect(!Self.shake(&d, strokes: 6, seconds: 0.15).fired)
        d = ShakeDetector(swings: 5, within: 0.7)
        #expect(Self.shake(&d, strokes: 6, seconds: 0.15).fired)
    }

    @Test("A slow sweep back and forth is reading, not shaking")
    func slowSweep() {
        var d = ShakeDetector()
        #expect(!Self.shake(&d, strokes: 8, dx: 400, seconds: 0.4).fired)
    }

    @Test("Short jitter, strokes under the minimum, never fires")
    func jitter() {
        var d = ShakeDetector()
        #expect(!Self.shake(&d, strokes: 20, dx: ShakeDetector.minStroke - 10, seconds: 0.05).fired)
    }

    @Test("One long move in one direction never fires")
    func longMove() {
        var d = ShakeDetector()
        #expect(!Self.shake(&d, strokes: 1, dx: 3000, seconds: 1).fired)
    }

    @Test("A pause between strokes starts over")
    func pauseResets() {
        var d = ShakeDetector()
        let first = Self.shake(&d, strokes: 3)
        #expect(!first.fired)
        #expect(!Self.shake(&d, strokes: 3, from: first.end + ShakeDetector.pause + 0.05).fired)
    }

    @Test("Shaking on after a fire waits out the cooldown, so one shake is one toggle")
    func cooldown() {
        var d = ShakeDetector()
        let first = Self.shake(&d, strokes: 6)
        #expect(first.fired)
        #expect(!Self.shake(&d, strokes: 6, from: first.end).fired)
        #expect(Self.shake(&d, strokes: 6, from: first.end + ShakeDetector.cooldown + 0.3).fired)
    }

    @Test("Vertical moves alone are not strokes")
    func vertical() {
        var d = ShakeDetector()
        var t: TimeInterval = 0
        var fired = false
        for _ in 0..<200 { t += 0.008; fired = d.move(dx: 0, dy: 6, at: t) || fired }
        #expect(!fired)
    }

    @Test("Blur runs from Off to a heavy blur and leaves the dim alone; a saved strength keeps the dim it gave")
    func look() throws {
        let looks = try (1...5).map { try #require(Defocus.look(strength: $0, dim: 18, reduceTransparency: false)) }
        #expect(looks.map(\.blurRadius) == looks.map(\.blurRadius).sorted() && looks.allSatisfy { $0.blurRadius > 0 })
        #expect(looks.allSatisfy { $0.dim == 0.18 }, "the dim is its own setting now")
        #expect(Defocus.look(strength: 99, dim: 18, reduceTransparency: false) == looks.last)
        #expect(Defocus.look(strength: -1, dim: 18, reduceTransparency: false) == Defocus.Look(blurRadius: 0, dim: 0.18))
        #expect(Defocus.look(strength: 3, dim: 200, reduceTransparency: false)?.dim == 0.8)
        // Nothing changes until the dim is moved: strength 3's look as it was, and every strength's old dim to seed from.
        #expect(Defocus.defaultStrength == 3 && Defocus.defaultDim == 18)
        #expect(Defocus.look(strength: 3, dim: Defocus.defaultDim, reduceTransparency: false) == Defocus.Look(blurRadius: 20, dim: 0.18))
        #expect((1...5).map(Defocus.dim(strength:)) == [10, 14, 18, 22, 26])
    }

    @Test("Blur alone, dim alone, both; both off is nothing to do")
    func blurAndDim() {
        #expect(Defocus.look(strength: 4, dim: 0, reduceTransparency: false) == Defocus.Look(blurRadius: 28, dim: 0))
        #expect(Defocus.look(strength: 0, dim: 50, reduceTransparency: false) == Defocus.Look(blurRadius: 0, dim: 0.5))
        #expect(Defocus.look(strength: 2, dim: 40, reduceTransparency: false) == Defocus.Look(blurRadius: 14, dim: 0.4))
        #expect(Defocus.look(strength: 0, dim: 0, reduceTransparency: false) == nil)
        #expect(Defocus.summary(strength: 2, dim: 40) == "Blurs and dims every other window.")
        #expect(Defocus.summary(strength: 2, dim: 0) == "Blurs every other window.")
        #expect(Defocus.summary(strength: 0, dim: 40) == "Dims every other window.")
        #expect(Defocus.summary(strength: 0, dim: 0).contains("nothing to do"))
    }

    @Test("Reduce Transparency trades a picked blur for a step more dim; with the blur off it changes nothing")
    func reduceTransparency() {
        #expect(Defocus.look(strength: 3, dim: 18, reduceTransparency: true) == Defocus.Look(blurRadius: 0, dim: 0.28))
        #expect(Defocus.look(strength: 3, dim: 0, reduceTransparency: true) == Defocus.Look(blurRadius: 0, dim: 0.1))
        #expect(Defocus.look(strength: 0, dim: 30, reduceTransparency: true) == Defocus.Look(blurRadius: 0, dim: 0.3))
        #expect(Defocus.look(strength: 0, dim: 0, reduceTransparency: true) == nil, "both off is still nothing, not a 10 % dim")
    }

    @Test("Only a standard window on screen stays sharp: none, minimised, fullscreen or a dialog hides the blur")
    func sharpWindow() {
        let f = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(Defocus.keepsSharp(WindowBorder.Window(frame: f, subrole: "AXStandardWindow", fullScreen: false, minimised: false)))
        #expect(!Defocus.keepsSharp(nil))
        #expect(!Defocus.keepsSharp(WindowBorder.Window(frame: f, subrole: "AXStandardWindow", fullScreen: true, minimised: false)))
        #expect(!Defocus.keepsSharp(WindowBorder.Window(frame: f, subrole: "AXStandardWindow", fullScreen: false, minimised: true)))
        #expect(!Defocus.keepsSharp(WindowBorder.Window(frame: f, subrole: "AXDialog", fullScreen: false, minimised: false)))
    }

    @Test("The bind's default key is Hyper+Alt+D")
    func key() {
        #expect(Defocus.defaultKey == Key("d", .alt))
        #expect(Defocus.actionID == "windows.defocus")
    }

    @Test("Hyper+Alt+D is free in My binds, which carries it")
    func presets() {
        let myBinds = MyBinds.preset(registry: [Defocus.actionID: Defocus.defaultKey])
        #expect(myBinds[Defocus.actionID] == Defocus.defaultKey)
        #expect(myBinds.filter { $0.value == Defocus.defaultKey }.count == 1)
    }

    @Test("Look's hint names windows.defocus's bind as it is now, bound, rebound or unbound, and the shake only while it is on")
    func hint() throws {
        var store = BindStore(defaults: [Defocus.actionID: Defocus.defaultKey], actions: [Defocus.actionID])
        let bound = Defocus.defaultKey.label
        #expect(Defocus.hint(key: store.trigger(for: Defocus.actionID), shake: true) == "Shake the mouse or press \(bound)")
        #expect(Defocus.hint(key: store.trigger(for: Defocus.actionID), shake: false) == "Press \(bound)")
        try store.set(Defocus.actionID, to: Key("x", .alt))
        let rebound = Key("x", .alt).label
        #expect(Defocus.hint(key: store.trigger(for: Defocus.actionID), shake: true) == "Shake the mouse or press \(rebound)")
        try store.set(Defocus.actionID, to: nil)
        #expect(store.trigger(for: Defocus.actionID) == nil)
        #expect(Defocus.hint(key: nil, shake: true) == "Shake the mouse, or bind a key in Binds")
        #expect(Defocus.hint(key: nil, shake: false) == "Bind a key in Binds to turn it on")
    }
}
