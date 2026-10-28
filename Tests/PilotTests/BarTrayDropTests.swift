import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Menu bar page's drop targets as the page wires them (Sven on build 54): the tray's takes any piece on the strip
/// off, the top bar strip's places a tray item where BarDrop says. Each delegate's own target and change, without a
/// drag session (DropInfo has no public maker).
@MainActor
@Suite("Bar tray drops")
struct BarTrayDropTests {
    static func store() throws -> BarItemsStore {
        let store = BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }
        store.settings.set(extension: "weather", on: true, placement: .both)
        return store
    }

    /// Every piece the strip for `placement` draws, as the page draws them one by one.
    static func pieces(_ s: BarSettings, _ placement: BarPlacement, extensions: [String]) -> [BarTrayItem] {
        let preview = s.preview(placement)
        let slots = (preview.top.map { sides in TopBarSide.allCases.flatMap { sides[$0] ?? [] } } ?? []) + (preview.menu ?? [])
        let kinds = slots.flatMap { $0.isGroup ? [.group] + $0.kinds : $0.kinds }.filter { !$0.pinned && $0 != .extensions }
        return kinds.map(BarTrayItem.kind) + extensions.filter { s.onStrip(extension: $0, placement: placement) }.map(BarTrayItem.extension)
    }

    /// The top bar strip's slots as the page reports them: 40 wide, 6 apart, the left from 6, the centre from 500, the
    /// right from 800, on a strip 1080 by 30.
    static func drawn(_ s: BarSettings) -> BarDrop {
        let sides = TopBarSide.allCases.map { side in
            let start: Double = [.left: 6, .centre: 500, .right: 800][side]!
            return (side, s.slots(in: .topBar, topBarOn: true, side: side).enumerated().map { i, slot in
                BarDrop.Slot(kind: slot.kind, minX: start + Double(i) * 46, maxX: start + Double(i) * 46 + 40)
            })
        }
        return BarDrop(sides: Dictionary(uniqueKeysWithValues: sides), width: 1080, height: 30)
    }

    @Test("A drop on the tray takes each piece of the Top bar strip off it, one at a time; one not on the strip is refused")
    func trayTakesOff() throws {
        for placement in BarPlacement.allCases {
            let pieces = Self.pieces(try Self.store().settings, placement, extensions: ["weather"])
            #expect(!pieces.isEmpty)
            for piece in pieces {
                let store = try Self.store()
                let drop = BarTray.removal(store: store, placement: placement, dragged: piece, animation: nil, over: { _ in }, finish: {})
                let target = try #require(drop.target(piece, .zero), "\(piece) on \(placement)")
                drop.apply(piece, target)
                #expect(!store.settings.onStrip(piece, placement: placement), "\(piece) on \(placement)")
            }
        }
        let store = try Self.store()
        let drop = BarTray.removal(store: store, placement: .topBar, dragged: .kind(.wifi), animation: nil, over: { _ in }, finish: {})
        #expect(drop.target(.kind(.wifi), .zero) == nil)
    }

    @Test("A tray item dropped on the top bar strip lands where the strip's frames say; dragged back to the tray it comes off")
    func stripPlacesThenTrayTakesOff() throws {
        let store = try Self.store()
        let drop = Self.drawn(store.settings)
        let onto = MenuBarPage.topDrop(drop, store: store, placement: .topBar, dragged: .kind(.wifi), animation: nil, over: { _ in }, finish: {})
        let target = try #require(onto.target(.kind(.wifi), CGPoint(x: 95, y: 15)))
        #expect(target == BarStripDrop.top(.left, index: 2))
        onto.apply(.kind(.wifi), target)
        #expect(store.settings.slots(in: .topBar, topBarOn: true, side: .left)[2].kind == .wifi)
        let off = BarTray.removal(store: store, placement: .topBar, dragged: .kind(.wifi), animation: nil, over: { _ in }, finish: {})
        off.apply(.kind(.wifi), try #require(off.target(.kind(.wifi), .zero)))
        #expect(!store.settings.onStrip(.wifi, placement: .topBar))
    }

    /// Sven on build 55: Ghostex and To-do showed twice on the strip, their emoji before an answer that leads with it
    /// ("👻 👻 5"). The strip's piece is the face the bar draws, the answer alone; the emoji only while there is no answer.
    @Test func extensionPieceDrawsTheBarsFaceOnce() {
        let answered = ExtensionBar.Item(id: "ghostex", title: "Ghostex", icon: "👻", hasPage: true, answer: Extension.BarAnswer(text: "👻 5"))
        guard case .face(let face) = ExtensionStripFace.shows(answered) else { Issue.record("no face"); return }
        #expect(face == answered.face)
        #expect(face.text == "👻 5")
        let gauges = ExtensionBar.Item(id: "ai", title: "AI usage", icon: "🤖", hasPage: false,
                                       answer: Extension.BarAnswer(text: "", gauges: [Extension.Gauge(label: "C", meters: [40])]))
        #expect(ExtensionStripFace.shows(gauges) == .face(gauges.face!))
        let silent = ExtensionBar.Item(id: "todo", title: "To-do", icon: "☑️", hasPage: true, answer: Extension.BarAnswer(text: ""))
        #expect(ExtensionStripFace.shows(silent) == .icon("☑️"))
        let unasked = ExtensionBar.Item(id: "x", title: "X", icon: nil, hasPage: false)
        #expect(ExtensionStripFace.shows(unasked) == .icon("🧩"))
    }
}
