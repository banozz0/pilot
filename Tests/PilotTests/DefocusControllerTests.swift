import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423220: Defocus's controller on a fake overlay and a fake mouse tap. The shake, the bind, the
/// focused window and Look's strength drive it; no real window is ordered or blurred.
@MainActor
@Suite("Defocus controller")
struct DefocusControllerTests {
    final class FakeSurface: DefocusSurface {
        var shown: (screens: [CGRect], below: CGWindowID, look: Defocus.Look)?
        func show(screens: [CGRect], below window: CGWindowID, look: Defocus.Look) { shown = (screens, window, look) }
        func hide() { shown = nil }
    }

    final class FakeTap: MouseMoveTap {
        var move: ((Double, Double, TimeInterval) -> Void)?
        var scroll: ((TimeInterval) -> Void)?
        func start(move: @escaping (Double, Double, TimeInterval) -> Void, scroll: @escaping (TimeInterval) -> Void) -> Bool {
            self.move = move; self.scroll = scroll; return true
        }
        func stop() { move = nil; scroll = nil }
    }

    static let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1440, height: 900)]
    static func window(_ id: CGWindowID?, subrole: String = "AXStandardWindow") -> WindowBorder.Window {
        WindowBorder.Window(frame: CGRect(x: 100, y: 50, width: 800, height: 600), subrole: subrole, fullScreen: false,
                            minimised: false, windowID: id)
    }

    final class Tips { var said: [String] = [] }

    struct Rig {
        let controller: DefocusController, surface: FakeSurface, tap: FakeTap, look: Look, tips: Tips
    }

    func rig() -> Rig {
        let surface = FakeSurface(), tap = FakeTap(), tips = Tips()
        let look = WindowBorderControllerTests.look()
        let c = DefocusController(surface: surface, tap: tap, look: look, screens: { Self.screens }) { tips.said.append($0) }
        c.start()
        return Rig(controller: c, surface: surface, tap: tap, look: look, tips: tips)
    }

    /// Lets withObservationTracking's onChange task run.
    func settle() async { for _ in 0..<3 { await Task.yield() } }

    /// Six strokes, five swings: a shake at the default Swings needed.
    func shake(_ tap: FakeTap, strokes: Int = 6, from start: TimeInterval = 100) {
        var t = start
        for s in 0..<strokes { for _ in 0..<10 { t += 0.008; tap.move?(s.isMultiple(of: 2) ? 8 : -8, 0, t) } }
    }

    @Test("Off until toggled; on, every screen is covered below the focused window at Look's strength; toggled again it hides")
    func toggle() {
        let r = rig()
        r.controller.update(Self.window(42))
        #expect(r.surface.shown == nil)
        r.controller.toggle()
        #expect(r.surface.shown?.below == 42)
        #expect(r.surface.shown?.screens == Self.screens)
        #expect(r.surface.shown?.look == Defocus.look(strength: Defocus.defaultStrength, dim: Defocus.defaultDim,
                                                     reduceTransparency: r.look.reduceTransparency))
        r.controller.toggle()
        #expect(r.surface.shown == nil)
    }

    @Test("The blur follows focus to the next window and waits, hidden, while no window can stay sharp")
    func followsFocus() {
        let r = rig()
        r.controller.toggle()
        #expect(r.surface.shown == nil, "no window yet")
        r.controller.update(Self.window(1))
        #expect(r.surface.shown?.below == 1)
        r.controller.update(Self.window(2))
        #expect(r.surface.shown?.below == 2)
        r.controller.update(Self.window(3, subrole: "AXDialog"))
        #expect(r.surface.shown == nil)
        r.controller.update(Self.window(nil))
        #expect(r.surface.shown == nil, "a window with no id cannot be ordered against")
        r.controller.update(Self.window(4))
        #expect(r.surface.shown?.below == 4)
    }

    @Test("A shake toggles it only while the shake tap is armed, with the binds")
    func shakeToggles() {
        let r = rig()
        r.controller.update(Self.window(7))
        #expect(r.tap.move == nil)
        r.controller.arm(true)
        shake(r.tap)
        #expect(r.surface.shown?.below == 7)
        r.controller.arm(false)
        #expect(r.tap.move == nil)
        #expect(r.surface.shown == nil, "binds disarmed: Defocus turns off, since nothing could turn it off")
    }

    @Test("Shake to defocus is on by default and saved; off, the shake tap stops at once and Defocus itself stays as it was")
    func shakeSwitch() async {
        let defaults = LookTests.defaults()
        let saved = WindowBorderControllerTests.look(defaults: defaults)
        #expect(saved.defocusShake)
        saved.defocusShake = false
        #expect(WindowBorderControllerTests.look(defaults: defaults).defocusShake == false)

        let r = rig()
        r.controller.update(Self.window(8))
        r.controller.arm(true)
        shake(r.tap)
        #expect(r.surface.shown?.below == 8)
        r.look.defocusShake = false
        await settle()
        #expect(r.tap.move == nil, "switched off: the tap stops")
        #expect(r.surface.shown?.below == 8, "only the trigger goes")
        r.controller.toggle()
        #expect(r.surface.shown == nil, "the bind still toggles it")
        r.controller.arm(false)
        r.controller.arm(true)
        #expect(r.tap.move == nil, "re-armed binds leave the switch off")
        r.look.defocusShake = true
        await settle()
        shake(r.tap)
        #expect(r.surface.shown?.below == 8)
        r.controller.arm(false)
    }

    @Test("Swings needed and Within are saved and clamped, and retune the shake live; a scroll silences it")
    func shakeTuning() async {
        let defaults = LookTests.defaults()
        let saved = WindowBorderControllerTests.look(defaults: defaults)
        #expect(saved.defocusShakeSwings == 5 && saved.defocusShakeWithin == 0.7)
        saved.defocusShakeSwings = 99
        saved.defocusShakeWithin = 0.1
        #expect(saved.defocusShakeSwings == 8 && saved.defocusShakeWithin == 0.4)
        let reread = WindowBorderControllerTests.look(defaults: defaults)
        #expect(reread.defocusShakeSwings == 8 && reread.defocusShakeWithin == 0.4)

        let r = rig()
        r.controller.update(Self.window(5))
        r.controller.arm(true)
        r.look.defocusShakeSwings = 8
        await settle()
        shake(r.tap)
        #expect(r.surface.shown == nil, "six strokes are not eight swings")
        r.look.defocusShakeSwings = 3
        await settle()
        shake(r.tap, strokes: 4, from: 200)
        #expect(r.surface.shown?.below == 5)
        r.tap.scroll?(300)
        shake(r.tap, strokes: 4, from: 300)
        #expect(r.surface.shown?.below == 5, "drift during a scroll does not toggle it off")
        r.controller.arm(false)
    }

    @Test("Strength is saved, clamped and redraws the overlay")
    func strength() async {
        let r = rig()
        #expect(r.look.defocusStrength == Defocus.defaultStrength)
        r.controller.update(Self.window(9))
        r.controller.toggle()
        r.look.defocusStrength = 99
        #expect(r.look.defocusStrength == Defocus.strengths.upperBound)
        await settle()
        #expect(r.surface.shown?.look == Defocus.look(strength: 5, dim: Defocus.defaultDim, reduceTransparency: r.look.reduceTransparency))
    }

    @Test("Dim is saved, clamped, seeded once from a saved strength's old dim, and redraws the overlay on its own")
    func dim() async {
        #expect(WindowBorderControllerTests.look(defaults: LookTests.defaults()).defocusDim == Defocus.defaultDim)
        let defaults = LookTests.defaults()
        defaults.set(5, forKey: "look.defocusStrength")
        let fresh = WindowBorderControllerTests.look(defaults: defaults)
        #expect(fresh.defocusDim == 26, "strength 5 kept the dim it had")
        fresh.defocusStrength = 1
        #expect(WindowBorderControllerTests.look(defaults: defaults).defocusDim == 26, "the seed is saved: a new blur leaves it")
        fresh.defocusDim = 99
        #expect(fresh.defocusDim == 80)
        #expect(WindowBorderControllerTests.look(defaults: defaults).defocusDim == 80)

        let r = rig()
        r.controller.update(Self.window(11))
        r.controller.toggle()
        r.look.defocusDim = 50
        await settle()
        #expect(r.surface.shown?.look.dim == 0.5)
        r.look.defocusStrength = 0
        await settle()
        #expect(r.surface.shown?.look == Defocus.Look(blurRadius: 0, dim: 0.5), "dim only")
        r.look.defocusDim = 0
        await settle()
        #expect(r.surface.shown == nil, "both off: nothing drawn")
        r.look.defocusStrength = 2
        await settle()
        #expect(r.surface.shown?.look.blurRadius ?? 0 > 0 && r.surface.shown?.look.dim == 0, "blur only")
    }

    @Test("With Blur and Dim both off, the bind and the shake only tip that there is nothing to do; turning off still works")
    func nothingToDo() async {
        let r = rig()
        r.controller.update(Self.window(12))
        r.look.defocusStrength = 0
        r.look.defocusDim = 0
        await settle()
        r.controller.toggle()
        #expect(r.surface.shown == nil)
        #expect(r.tips.said == [Defocus.nothingToDo])
        r.controller.arm(true)
        shake(r.tap)
        #expect(r.tips.said.count == 2)
        r.look.defocusDim = 30
        await settle()
        r.controller.toggle()
        #expect(r.surface.shown?.look.dim == 0.3)
        r.look.defocusDim = 0
        await settle()
        r.controller.toggle()
        #expect(r.surface.shown == nil && r.tips.said.count == 2, "on to off never tips")
        r.controller.arm(false)
    }

    @Test("Pilot's click-through panels at the normal level are not windows to focus, swap or rescue")
    func panelsNotWindows() {
        func info(_ id: CGWindowID) -> WindowInfo { WindowInfo(id: id, pid: 1, title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600)) }
        let list = [(info: info(1), layer: 0, alpha: 1.0), (info: info(2), layer: 0, alpha: 1.0), (info: info(3), layer: 3, alpha: 1.0)]
        #expect(EngineObservers.normal(list, skipping: [2]).map(\.id) == [1])
        #expect(EngineObservers.normal(list, skipping: []).map(\.id) == [1, 2])
    }

    /// Sven on build 58 ("menubar shouldnt be dimmed"): the overlay sits under the macOS menu bar and under Pilot's top
    /// bar at both its levels, so Defocus never dims or blurs either.
    @Test func overlayStaysUnderTheBars() {
        for bar in [NSWindow.Level.mainMenu, TopBarWindows.aboveMenuBar, TopBarWindows.underMenuBar] {
            #expect(DefocusPanels.level.rawValue < bar.rawValue)
        }
    }
}
