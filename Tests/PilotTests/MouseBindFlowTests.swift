import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Binds › Mouse's one flow (Q257): the rows both views read from binds.json as it is, and where a caught press is bound.
@MainActor
@Suite("Mouse bind flow")
struct MouseBindFlowTests {
    static let core = MouseKeys.Device(vendor: 1008, product: 3471, name: "HyperX Pulsefire Core")
    static let defaults: [String: Key] = ["media.next": Key("F9"), "media.playPause": Key("F8")]
    static let labels = ["media.playPause": "Play or pause", "media.next": "Next track", "media.previous": "Previous track"]
    static let pulsefire = MouseButtons.Found(mice: [core], buttons: (2...4).map { MouseKeys.button($0) })

    @Test("The user's binds.json (Mouse 3 on Play or pause) and a media key tied to a button show on their rows, the file unchanged")
    func svensFile() throws {
        // binds.json's mouse rows as Sven's file has them (2026-10-17), plus a5f9c7c4's button field and a Learn-era media key.
        let mouse = #"[{"action": "media.playPause", "trigger": {"hyper": false, "key": "Mouse 3", "modifiers": []}}, "#
            + #"{"action": "media.next", "button": 4, "device": {"name": "HyperX Pulsefire Core", "product": 3471, "vendor": 1008}, "trigger": {"hyper": false, "key": "Mouse Play", "modifiers": []}}, "#
            + #"{"action": "media.previous", "device": {"name": "HyperX Pulsefire Core", "product": 3471, "vendor": 1008}, "trigger": {"hyper": false, "key": "Mouse Next", "modifiers": []}}]"#
        let json = Data(#"{"version": 3, "preset": "myBinds", "binds": [], "mouse": \#(mouse)}"#.utf8)
        let store = try BindStore(json: json, presets: [.myBinds: Self.defaults])
        let rows = MouseButtonsBlocks.rows(store.mouseBinds, found: Self.pulsefire, labels: Self.labels)

        #expect(rows.map(\.button) == [3, 4, 5, nil])
        #expect(rows[0] == .init(button: 3, trigger: MouseKeys.button(2), device: nil, label: "Play or pause"))
        #expect(rows[1].trigger == MouseKeys.media(16) && rows[1].device == Self.core && rows[1].label == "Next track")
        #expect(rows[2].trigger == nil && rows[2].name == "Forward", "unbound: Click, then press it")
        #expect(rows[3].trigger == MouseKeys.media(17) && rows[3].name == "Next key", "a media key on no button: its own row")
        let drawn = MouseButtonsBlocks.labels(rows)
        #expect(drawn[3] == .init(action: "Play or pause", sends: nil) && drawn[4] == .init(action: "Next track", sends: "Play key")
                && drawn[5] == .init(action: nil, sends: nil))

        // Reading the page changes nothing: the file writes its mouse rows back as they came.
        func mouseRows(_ data: Data) throws -> [[String: AnyHashable]] {
            try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["mouse"] as? [[String: AnyHashable]])
        }
        #expect(try mouseRows(store.json()) == mouseRows(json))
    }

    @Test("A further button the mouse has gets a row; a bound button of a mouse not connected keeps one")
    func further() {
        let seven = MouseButtons.Found(mice: [Self.core], buttons: (2...6).map { MouseKeys.button($0) })
        let binds: [(trigger: Key, bind: BindStore.MouseBind)] = [(MouseKeys.button(8), .init(action: "media.next", device: nil))]
        let rows = MouseButtonsBlocks.rows(binds, found: seven, labels: Self.labels)
        #expect(rows.map(\.button) == [3, 4, 5, 6, 7, 9] && rows.last?.label == "Next track" && rows.last?.name == "Button 9")
    }

    @Test("A press caught for a button is bound there: a media key on the button clicked, a plain button on its own")
    func bindsWhereClicked() {
        #expect(MouseButtonsBlocks.button(of: MouseKeys.media(16), target: 4) == 4)
        #expect(MouseButtonsBlocks.button(of: MouseKeys.button(4), target: 4) == 5, "clicked Back, pressed Forward: bound on Forward")
        #expect(MouseButtonsBlocks.button(of: MouseKeys.media(16), target: nil) == nil, "Other button…: a row of its own")
    }

    @Test("Each state the box shows: waiting lights the button, a press from another mouse is told apart, a pick lights its button")
    func states() {
        #expect(MouseButtonsBlocks.lit(.listening, target: 4, selected: 3) == 4)
        #expect(MouseButtonsBlocks.lit(.quiet, target: 4, selected: nil) == 4)
        #expect(MouseButtonsBlocks.lit(.got(MouseKeys.media(16), device: Self.core), target: 4, selected: nil) == 4)
        #expect(MouseButtonsBlocks.lit(.got(MouseKeys.button(2), device: nil), target: 4, selected: nil) == 3)
        #expect(MouseButtonsBlocks.lit(.idle, target: nil, selected: 5) == 5)
        let logitech = MouseKeys.Device(vendor: 1133, product: 45108, name: "Logitech MX Master 3S")
        #expect(MouseButtonsBlocks.isOtherMouse(logitech, found: Self.pulsefire))
        #expect(!MouseButtonsBlocks.isOtherMouse(Self.core, found: Self.pulsefire))
        #expect(!MouseButtonsBlocks.isOtherMouse(logitech, found: MouseButtons.Found()), "no mouse found: nothing to compare with")
        #expect(!MouseButtonsBlocks.isOtherMouse(nil, found: Self.pulsefire), "a plain button names no device")
    }
}
