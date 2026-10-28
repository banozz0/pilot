import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Story 122: setting a key from the bind hint, by the bind editor's rules, and the tip that waits for it. In the shared
/// look's suites: the tip is HUD's one panel, which TipTests also shows.
extension SharedLook {
@MainActor
@Suite("BindNudger")
struct BindNudgerTests {
    static let textEdit = "apps.open:com.apple.TextEdit"

    /// Terminal on Hyper+Return, Files on Hyper+F, TextEdit on none.
    static func store() -> BindStore {
        BindStore(defaults: ["apps.terminal": Key("return"), "apps.files": Key("f")], actions: ["apps.terminal", "apps.files"])
    }

    static func assign(_ key: Key, in store: inout BindStore) -> BindNudger.Assigned {
        BindNudger.assign(key, to: textEdit, store: store, in: &store) { $0 == "apps.files" ? "Files" : $0 }
    }

    @Test("A free Hyper key binds the app; a held one is refused with its holder named, never taken; a plain combo is refused")
    func assign() {
        var store = Self.store()
        #expect(Self.assign(Key("e"), in: &store) == .bound)
        #expect(store.trigger(for: Self.textEdit) == Key("e") && store.action(for: Key("e")) == Self.textEdit)

        store = Self.store()
        let before = store.json()
        #expect(Self.assign(Key("f"), in: &store) == .taken(by: "Files"))
        #expect(store.json() == before, "a refused key changed the binds")

        #expect(Self.assign(Key("v", [.cmd], hyper: false), in: &store) == .plain)
        #expect(store.json() == before, "a plain combo was bound")
    }

    final class Captured { var keys: [Key] = []; var ran: [Key] = [] }

    /// A tap waiting as the hint waits (onlyHyper) or as the editor's Record does, with Option+V as a Pilot plain bind.
    static func waitingTap(onlyHyper: Bool) -> (HyperTap, Captured) {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let got = Captured()
        let optionV = Key(keyCode: KeyCode.v, modifiers: [.alt], hyper: false)
        tap.isBound = { $0 == optionV }
        tap.onRun = { key, _ in got.ran.append(key) }
        tap.captureNext = { got.keys.append($0) }
        tap.captureOnlyHyper = onlyHyper
        return (tap, got)
    }

    @Test("While the hint waits, Cmd+C and a plain key reach the front app untouched and a Pilot plain bind still runs; a Hyper key is taken")
    func waitTakesOnlyHyper() {
        let (tap, got) = Self.waitingTap(onlyHyper: true)
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 8, flags: KeyEvent.cmdMask)), "Cmd+C was swallowed")
        #expect(!tap.route(KeyEvent(kind: .keyUp, keyCode: 8, flags: KeyEvent.cmdMask)))
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 0)), "a plain key was swallowed")
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: KeyCode.v, flags: KeyEvent.altMask)))
        #expect(got.keys.isEmpty && got.ran == [Key(keyCode: KeyCode.v, modifiers: [.alt], hyper: false)])
        _ = tap.route(KeyEvent(kind: .keyDown, keyCode: LayerKey.capsLock.keyCode))
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 14)))
        #expect(got.keys == [Key("e")] && tap.captureNext == nil)
    }

    @Test("The editor's Record still takes a plain combo")
    func recordTakesPlain() {
        let (tap, got) = Self.waitingTap(onlyHyper: false)
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 8, flags: KeyEvent.cmdMask)))
        #expect(got.keys.count == 1 && got.keys.first?.hyper == false)
    }

    @Test("The hint waits from Set a key until its tip closes", .pilotFocus)
    func waiting() {
        testApp()
        let engine = Engine()
        let nudger = engine.nudger
        #expect(!nudger.waiting)
        nudger.capture("TextEdit", target: Self.textEdit)
        #expect(nudger.waiting)
        HUD.dismissTip()
        #expect(!nudger.waiting, "the wait outlived its tip")
        withExtendedLifetime(engine) {}
    }

    final class Closes { var count = 0 }

    @Test("A tip's onClose runs once however it goes: closed, or replaced by the next tip")
    func onClose() {
        testApp()
        let closes = Closes()
        _ = PanelTestSupport.hide(HUD.prepareTip("Press a Hyper key for TextEdit · Esc stops", seconds: 10, action: nil) { closes.count += 1 })
        HUD.dismissTip()
        HUD.dismissTip()
        #expect(closes.count == 1)
        _ = PanelTestSupport.hide(HUD.prepareTip("Press a Hyper key for TextEdit · Esc stops", seconds: 10, action: nil) { closes.count += 1 })
        _ = PanelTestSupport.hide(HUD.prepareTip("TextEdit is on Hyper+E", seconds: 3, action: nil))
        HUD.dismissTip()
        #expect(closes.count == 2)
    }
}
}
