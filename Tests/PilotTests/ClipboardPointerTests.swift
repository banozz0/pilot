import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The clipboard panel by mouse (card agent-bo-95422994, G6), on a throwaway store; nothing touches the real clipboard.
/// The panel's own tests run the real panel and view, hidden (alpha 0, no mouse), on the test's pointer.
@MainActor
@Suite("Clipboard panel pointer", .serialized)
final class ClipboardPointerTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-pointer-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    func model(_ texts: [String], pinned: String? = nil) throws -> PanelModel {
        let store = try ClipboardStore(path: database)
        for (i, text) in texts.reversed().enumerated() {
            let id = try store.add(ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil),
                                   at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
            if text == pinned { try store.setPinned(id, true) }
        }
        return PanelModel(store: store)
    }

    @Test("A click is Return: paste, or copy when Settings › Clipboard says Return copies")
    func clickIsReturn() {
        #expect(PanelCommand.click(returnCopies: false) == PanelCommand(key: .return, searchEmpty: true))
        #expect(PanelCommand.click(returnCopies: false) == .paste(plain: false))
        #expect(PanelCommand.click(returnCopies: true) == .copy)
    }

    @Test("A hover moves the cursor; with rows picked it leaves the picks alone; a click runs Return on that row alone")
    func hoverAndClick() throws {
        let model = try model(["a", "b", "c"])
        var ran: [PanelCommand] = []
        model.run = { ran.append($0) }
        model.hover(at: 2)
        #expect(model.cursor == 2)
        model.extend(-1)
        model.hover(at: 0)
        #expect(model.targets.map(\.text) == ["c", "b"])
        model.click(at: 0, returnCopies: false)
        #expect(model.targets.map(\.text) == ["a"])
        #expect(ran == [.paste(plain: false)])
        model.click(at: 7, returnCopies: true)
        model.hover(at: 7)
        #expect(model.cursor == 0)
        #expect(ran.count == 1)
    }

    @Test("A click on a tab opens it, as Tab reaching it does")
    func tabClick() throws {
        let model = try model(["a"])
        model.tab = .kind(.link)
        #expect(model.tab == .kind(.link))
        #expect(model.rows.isEmpty)
    }

    @Test("In Cmd+K's list a hover moves the choice and a click runs it, as Return on it does")
    func choiceClick() throws {
        let model = try model(["a"])
        model.open(.actions)
        let pin = try #require(model.actionChoices.firstIndex(of: .pin))
        model.hoverChoice(at: pin)
        #expect(model.promptCursor == pin)
        model.run = { if $0 == .confirm { _ = model.confirm() } }
        model.clickChoice(at: pin)
        #expect(model.prompt == nil)
        #expect(model.rows.first?.pinned == true)
    }

    // MARK: - In the panel

    let pointer = TestPointer()
    /// What the clicks ran, noted and never done.
    var ran: [PanelCommand] = []

    /// Five texts, alpha pinned (so Pinned and Recent head the rows), in the real panel.
    func panel() throws -> (PanelModel, NSPanel) {
        let model = try model(["alpha", "bravo", "charlie", "delta", "echo"], pinned: "alpha")
        model.run = { [unowned self] in ran.append($0) }
        return (model, PanelTestSupport.open(ClipboardPanelView(model: model, returnCopies: false, pointer: pointer.track)))
    }

    /// The panel's scroll views, in window coordinates: the rows' (tallest at the left), the tabs' strip (one line
    /// high), the preview's.
    func scrolls(_ panel: NSPanel) -> (list: CGRect, tabs: CGRect, preview: CGRect?) {
        let scrolls = SharedLook.MenuScrollTests.scrollViews(in: panel.contentView).map(PanelTestSupport.shown)
        let tall = scrolls.filter { $0.height >= 44 }.sorted { $0.minX < $1.minX }
        return (tall.first ?? .zero, scrolls.first { $0.height < 44 } ?? .zero, tall.dropFirst().first)
    }

    @Test("In the panel the pointer selects each row it moves onto, Pinned and Recent are no rows, a still pointer keeps the keys' row, a click anywhere across a row is Return on it alone", .pilotFocus)
    func panelRows() throws {
        let (model, panel) = try panel()
        defer { panel.orderOut(nil) }
        let list = scrolls(panel).list
        // From the last row, so the first one's top edge shows as a change.
        model.hover(at: model.rows.count - 1)
        PanelTestSupport.pump(0.1)
        let tops = pointer.sweep(panel, x: list.midX, from: list.maxY - 1, to: list.minY + 1) { model.cursor }
        #expect(tops.map(\.index) == Array(model.rows.indices), "rows met top to bottom: \(tops.map(\.index)) of \(model.rows.count)")
        let top = Dictionary(uniqueKeysWithValues: tops.map { ($0.index, $0.y) })
        let third = CGPoint(x: list.midX, y: try #require(top[3]) - 8)

        // Recent's heading over row 1, under the pinned row: the pointer rests there, a click there does nothing.
        let recent = CGPoint(x: list.midX, y: try #require(top[1]) + 9)
        pointer.move(panel, to: third)
        #expect(model.cursor == 3)
        pointer.move(panel, to: recent)
        PanelTestSupport.click(panel, at: recent)
        #expect(model.cursor == 3)
        #expect(ran.isEmpty)

        // The keys move on; the rows under the still pointer do not take it back until it moves.
        model.move(1)
        PanelTestSupport.hover(panel, at: CGPoint(x: third.x + 1, y: third.y))
        #expect(model.cursor == 4)
        pointer.move(panel, to: CGPoint(x: third.x + 2, y: third.y))
        #expect(model.cursor == 3)

        PanelTestSupport.click(panel, at: CGPoint(x: list.minX + 14, y: try #require(top[4]) - 8))
        #expect(model.cursor == 4)
        PanelTestSupport.click(panel, at: CGPoint(x: list.maxX - 14, y: try #require(top[2]) - 8))
        #expect(model.targets.map(\.text) == ["charlie"])
        #expect(ran == [.paste(plain: false), .paste(plain: false)])
        #expect(HUD.focusSearch(in: panel) == .had)
    }

    @Test("In the panel a click on a kind or tag tab opens it, left to right in the strip's order, and the search keeps the keyboard", .pilotFocus)
    func panelTabs() throws {
        let (model, panel) = try panel()
        defer { panel.orderOut(nil) }
        let strip = scrolls(panel).tabs
        #expect(strip.width > 200)
        var opened: [PanelTab] = [model.tab]
        // 12 pt apart, under the narrowest tab's width.
        for x in stride(from: strip.minX + 2, to: strip.maxX - 2, by: 12) {
            PanelTestSupport.click(panel, at: CGPoint(x: x, y: strip.midY))
            if model.tab != opened.last { opened.append(model.tab) }
        }
        let order = opened.compactMap { model.tabs.firstIndex(of: $0) }
        #expect(opened.count >= 4 && order == order.sorted() && Set(order).count == order.count, "tabs opened: \(opened)")
        #expect(HUD.focusSearch(in: panel) == .had)
    }

    @Test("In the panel Cmd+K's choices take the pointer in order, and a click confirms one as Return does", .pilotFocus)
    func panelChoices() throws {
        let (model, panel) = try panel()
        defer { panel.orderOut(nil) }
        model.open(.actions)
        PanelTestSupport.pump()
        let choices = try #require(scrolls(panel).preview)
        // From the first choice, where Cmd+K starts: each next one's top edge shows as a change.
        let tops = pointer.sweep(panel, x: choices.midX, from: choices.maxY - 1, to: choices.minY + 1) { model.promptCursor }
        #expect(tops.count >= 3 && tops.map(\.index) == Array(1...tops.count), "choices met: \(tops.map(\.index)) of \(model.actionChoices.count)")
        pointer.move(panel, to: CGPoint(x: choices.midX, y: try #require(tops.first).y + 8))
        #expect(model.promptCursor == 0)
        PanelTestSupport.click(panel, at: CGPoint(x: choices.midX, y: try #require(tops.first { $0.index == 2 }).y - 8))
        #expect(model.promptCursor == 2)
        #expect(ran == [.confirm])
    }
}
