import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds in Instrument (card agent-bo-95423181, mockup A binds.html): every name whole on its key at every page width
/// from the least window to past the widest, the 75 % board while it holds them; an app's key its icon alone; the table's
/// columns giving way route first; the shared core helpers Toybox's board draws with too.
@MainActor
@Suite("Instrument Binds")
struct InstrumentBindsTests {
    static let role = tokens.type.keyName

    static let tokens = StyleTokens.of(.instrument, theme: .designed[0])

    @Test("Every bound key's name fits its key whole, two lines at most (one on the function row), a name too long for its key never under 0.9 of its size on a window 1000 pt or wider (the least window's board alone shrinks a one-word name it cannot hold, to no less than 0.7), ANSI and ISO; the 75 % board beside the inspector at 1440, two halves where it cannot hold them")
    func namesFit() throws {
        DisplayFaces.directory = LookThemeTests.fonts
        let measure = InstrumentBoardFit.measure(Self.role)
        for shape in [BindsKeyboard.Shape.ansi, .iso] {
            let boards = KeyboardCaptions.Boards(full: .init(shape), compact: .init(shape, compact: true))
            let marks = InstrumentBoardFit.Marks(names: BindsKeyboardPageTests.names, glyphs: [:], compact: boards.compact)
            // From the least window's page (760 less the 209 pt sidebar) to past the widest.
            for page in stride(from: CGFloat(551), through: 1600, by: 10) {
                let width = InstrumentBindsPage.arrangement(page, marks: marks, boards: boards, style: Self.tokens).board
                let fit = InstrumentBoardFit.best(marks, boards: boards, width: width, measure: measure)
                // Only the least window's board (a page under 767 pt, the 1000 pt window's) shrinks a name.
                #expect(fit.scale >= InstrumentBoardFit.gentle || page < 767, "\(shape) at \(page) shrinks names to \(fit.scale)")
                let rooms = InstrumentBoardFit.rooms(marks, on: fit.board, width: width)
                #expect(rooms.count == BindsKeyboardPageTests.names.keys.filter(boards.compact.codes.contains).count, "a named key is off the board at \(page)")
                let scale = fit.scale
                let over = rooms.filter { !InstrumentBoardFit.fits([$0], measure: measure, scale: scale) }.map { "\($0.name) in \(Int($0.room))" }
                #expect(over.isEmpty, "\(shape) at \(page): \(over)")
            }
            // These names, an app's among them with no icon, are too long for the board beside the inspector at 1440: it
            // goes across the page, whole, the inspector beside the table under it.
            let wide = InstrumentBindsPage.arrangement(1207, marks: marks, boards: boards, style: Self.tokens)
            #expect(wide.0 == .under && InstrumentBoardFit.best(marks, boards: boards, width: wide.board, measure: measure).board == boards.compact)
            for page in [CGFloat(767), 551] {
                let width = InstrumentBindsPage.arrangement(page, marks: marks, boards: boards, style: Self.tokens).board
                #expect(InstrumentBoardFit.best(marks, boards: boards, width: width, measure: measure).board.halves == 2, "\(page)")
            }
            // The mockup's board, its apps as their icons, stands beside the inspector at 1440.
            let icon = BoardKey.Glyph.image(NSImage(size: NSSize(width: 8, height: 8)))
            let mockup: [String: String] = ["`": "Last", "1": "1", "2": "2", "W": "Close", "E": "Emoji", "R": "Reload", "[": "¾ left",
                                            "]": "¼ right", "A": "Screen", "S": "Area", "D": "Scroll", "H": "Left", "J": "Down", "K": "Up", "L": "Right",
                                            "X": "Text", "C": "Keys", "V": "Clips", ",": "← Display", ".": "Display →", "/": "Flip split",
                                            "-": "Narrow", "=": "Widen", "T": "Telegram", "B": "Zen", "Return": "Terminal"]
            let names = Dictionary(uniqueKeysWithValues: mockup.map { (KeyNames.code(for: $0.key)!, $0.value) })
            let apps: Set<String> = ["T", "B", "Return"]
            let glyphs = Dictionary(uniqueKeysWithValues: mockup.keys.filter(apps.contains).map { (KeyNames.code(for: $0)!, icon) })
            #expect(InstrumentBindsPage.arrangement(1207, marks: .init(names: names, glyphs: glyphs, compact: boards.compact), boards: boards,
                                                    style: Self.tokens).0 == .beside, "the mockup's board beside the inspector")
        }
    }

    @Test("A name wraps word by word into the lines its room holds; a word wider than the room alone does not fit at all")
    func lines() {
        let measure = { (text: String) in CGFloat(text.count) * 6 }
        #expect(InstrumentBoardFit.lines("Display", room: 44, measure: measure) == 1)
        #expect(InstrumentBoardFit.lines("Display left", room: 44, measure: measure) == 2)
        #expect(InstrumentBoardFit.lines("Display left", room: 200, measure: measure) == 1)
        #expect(InstrumentBoardFit.lines("Passwords", room: 20, measure: measure) == nil)
    }

    @Test("An app's key a key and a half wide or less shows its icon alone, centred; a wider one its icon and its name; the function row its glyph, or its name where it has none")
    func marks() throws {
        let board = BindsKeyboard.Board(.ansi, compact: true)
        let icon = BoardKey.Glyph.image(NSImage(size: NSSize(width: 8, height: 8)))
        let b = try #require(KeyNames.code(for: "B")), ret: Int64 = 36, f8: Int64 = 100, f10: Int64 = 109, h = try #require(KeyNames.code(for: "H"))
        let marks = InstrumentBoardFit.Marks(names: [b: "Zen", ret: "Terminal", f8: "Play", f10: "Mute", h: "Left"],
                                             glyphs: [b: icon, ret: icon, f8: .symbol("playpause"), h: .symbol("arrow.left")], compact: board)
        func shows(_ code: Int64) throws -> (name: String?, glyph: BoardKey.Glyph?, centred: Bool) {
            marks.shows(try #require(board.spots.first { $0.code == code }))
        }
        #expect(try shows(b).name == nil && shows(b).centred)
        #expect(try shows(ret).name == "Terminal" && !shows(ret).centred && shows(ret).glyph != nil)
        #expect(try shows(f8).name == nil && shows(f8).glyph != nil)
        #expect(try shows(f10).name == "Mute" && shows(f10).glyph == nil)
        #expect(try shows(h).name == "Left" && shows(h).glyph != nil)
        #expect(try shows(KeyNames.code(for: "Q")!).name == nil, "a free key says nothing")
    }

    @Test("The table drops the route under 640 pt and the share under 460 pt, so the keys, the action and today's count stay whole")
    func columns() {
        let wide = TableColumns(width: 860), mid = TableColumns(width: 600), narrow = TableColumns(width: 420)
        #expect(wide.route && wide.share && !mid.route && mid.share && !narrow.route && !narrow.share)
        #expect(wide.widths(860).count == 5 && mid.widths(600).count == 4 && narrow.widths(420).count == 3)
        #expect(abs(wide.widths(860).reduce(0, +) + 4 * TableColumns.gap - 860) < 0.001, "the columns fill the row")
    }

    @Test("The shared board helpers: the layer key is Caps Lock, right Option or right Command as picked, never on Plain; a legend prints words in lower case, letters, signs and F-keys as they are; a key's caption is the layout's")
    func shared() throws {
        let board = BindsKeyboard.Board(.ansi, compact: true)
        let caps = try #require(board.spots.first { $0.modifier == .caps })
        let rightAlt = try #require(board.spots.first { $0.modifier == .alt && $0.side == .right })
        #expect(BindsKeyboard.isLayerKey(caps, layerKeys: [.capsLock], layer: .hyper))
        #expect(!BindsKeyboard.isLayerKey(caps, layerKeys: [.capsLock], layer: .plain))
        #expect(BindsKeyboard.isLayerKey(rightAlt, layerKeys: [.rightOption], layer: .shift) && !BindsKeyboard.isLayerKey(caps, layerKeys: [.rightOption], layer: .hyper))
        // Two layer keys: both drawn held.
        let rightCmd = try #require(board.spots.first { $0.modifier == .cmd && $0.side == .right })
        let leftCmd = try #require(board.spots.first { $0.modifier == .cmd && $0.side == .left })
        #expect([caps, rightCmd].allSatisfy { BindsKeyboard.isLayerKey($0, layerKeys: [.capsLock, .rightCommand], layer: .hyper) })
        #expect(!BindsKeyboard.isLayerKey(leftCmd, layerKeys: [.capsLock, .rightCommand], layer: .hyper))
        // P68: a left Control or left Option picked is drawn held; its right side is not.
        let leftCtrl = try #require(board.spots.first { $0.modifier == .ctrl && $0.side == .left })
        let leftAlt = try #require(board.spots.first { $0.modifier == .alt && $0.side == .left })
        #expect([leftCtrl, leftAlt].allSatisfy { BindsKeyboard.isLayerKey($0, layerKeys: [.leftControl, .leftOption], layer: .hyper) })
        #expect(!BindsKeyboard.isLayerKey(rightAlt, layerKeys: [.leftOption], layer: .hyper))
        #expect(BindsKeyboard.printed(caps) == "caps")
        #expect(board.caption(11) == "B" && board.caption(36) == "Return" && board.caption(105) == KeyNames.name(for: 105))
    }

    @Test("The inspector beside the long table stays in sight as the page scrolls: at its place until its column's top passes the page's top inset, then held there, never past the column's foot (Moody, batch 3: the column under it showed a dead band)")
    func pinned() {
        // The column's top 300 pt down the page: the inspector stays where it stands.
        #expect(InstrumentBindsPage.pin(columnTop: 300, column: 1900, inspector: 640, inset: 20) == 0)
        // Scrolled 700 pt past it: it rides 720 pt down its column, 20 pt under the page's top.
        #expect(InstrumentBindsPage.pin(columnTop: -700, column: 1900, inspector: 640, inset: 20) == 720)
        // At the foot: no further than the column's end.
        #expect(InstrumentBindsPage.pin(columnTop: -1800, column: 1900, inspector: 640, inset: 20) == 1260)
        // A column no taller than the inspector never moves it.
        #expect(InstrumentBindsPage.pin(columnTop: -400, column: 600, inspector: 640, inset: 20) == 0)
    }

    @Test("A double-click opens what Return opens (Bind editor T3): a bound key's bind, a free key a new bind on it with the tab's sublayer, a free Plain key a new bind with no keys preset")
    func opens() throws {
        var opened: [BindEditing] = []
        let acts = BindsKeyboardPage.Acts(pick: { _ in }, show: { _, _ in }, edit: { opened.append($0) }, clear: { _ in }, reset: { _ in },
                                          switchTo: { _ in }, resetAll: {}, showList: {}, go: { _ in })
        let t = try #require(KeyNames.code(for: "T")), b = try #require(KeyNames.code(for: "B"))
        let bound: [Int64: [String]] = [b: ["apps.zen"]]
        acts.open(b, bound: bound, layer: .hyper)
        acts.open(t, bound: bound, layer: .hyper)
        acts.open(t, bound: bound, layer: .shift)
        acts.open(t, bound: bound, layer: .plain)
        let hyper = try #require(BindsKeyboard.Layer.hyper.sublayer), shift = try #require(BindsKeyboard.Layer.shift.sublayer)
        #expect(opened == [.init(action: "apps.zen"), .init(action: nil, startKey: Key(keyCode: t, modifiers: hyper.modifiers)),
                           .init(action: nil, startKey: Key(keyCode: t, modifiers: shift.modifiers)), .init(action: nil)])
    }

    @Test("One click on a key picks it at once and opens nothing; a double-click picks it and opens it, real mouse events in a window never shown")
    func doubleClick() throws {
        var picks = 0, opens = 0
        let key = Button { picks += 1 } label: { Color.gray.frame(width: 120, height: 80) }
            .buttonStyle(.plain)
            .opensOnDoubleClick { opens += 1 }
        testApp()
        let host = NSHostingView(rootView: key)
        host.frame.size = CGSize(width: 120, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // On the window list but far off every screen, so SwiftUI takes the clicks and nothing shows.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        PanelTestSupport.pump()
        let point = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        func click(_ count: Int) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)))
                PanelTestSupport.pump(0.02)
            }
        }
        try click(1)
        // At once: no wait for a second click.
        #expect(picks == 1 && opens == 0)
        PanelTestSupport.pump(0.6)
        #expect(opens == 0, "a lone click never opens")
        try click(1)
        try click(2)
        PanelTestSupport.pump(0.2)
        #expect(opens == 1 && picks >= 2)
    }
}
