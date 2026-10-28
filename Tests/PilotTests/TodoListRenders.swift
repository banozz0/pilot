#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// To-do B drawn (ADR 0010 amended 2026-10-17): its list in Hyper+Space with due days (sections, the day at each row's
/// right, the foot naming Return and Undo) and without (one tidy list), in each Instrument layout and Toybox; its Cmd+K
/// with every key; and its popover both ways. To-do 2.0's answers, as it prints them. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter TodoListRenders`
extension SharedLook {
@MainActor
@Suite("To-do list renders")
struct TodoListRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func actions(_ id: String, _ text: String, undo: Bool = false, move: Bool = true) -> String {
        let moves = move ? #"""
        {"type":"run","command":"move","title":"Move up","key":"opt+up","stay":true,"context":{"id":"\#(id)","by":-1}},
        {"type":"run","command":"move","title":"Move down","key":"opt+down","stay":true,"context":{"id":"\#(id)","by":1}},
        """# : ""
        let undone = undo ? #"{"type":"run","command":"undo","title":"Undo delete","key":"cmd+z","stay":true},"# : ""
        return #"""
        [{"type":"run","command":"done","title":"Mark done","stay":true,"context":{"id":"\#(id)"}},\#(undone)
         {"type":"run","command":"edit","title":"Edit","key":"cmd+e","stay":true,"ask":{"text":"\#(text)"},"context":{"id":"\#(id)"}},
         {"type":"run","command":"due","title":"Set due date","key":"cmd+d","stay":true,"ask":{"choices":[{"title":"Today","value":"2026-10-17"}]},"context":{"id":"\#(id)"}},
         \#(moves)
         {"type":"copy","text":"\#(text)","title":"Copy text","key":"cmd+shift+c"},
         {"type":"run","command":"delete","title":"Delete","key":"cmd+delete","stay":true,"destructive":true,"context":{"id":"\#(id)"}}]
        """#
    }

    static func row(_ id: String, _ text: String, section: String? = nil, due: String? = nil, tone: String? = nil, undo: Bool = false,
                    move: Bool = true, done: Bool = false) -> String {
        let tag = due.map { d in tone.map { #","accessory":{"text":"\#(d)","tone":"\#($0)"}"# } ?? #","accessory":{"text":"\#(d)"}"# } ?? ""
        let head = section.map { #","section":"\#($0)""# } ?? ""
        let acts = done ? #"[{"type":"run","command":"undone","title":"Mark not done","stay":true,"context":{"id":"\#(id)"}}]"# : actions(id, text, undo: undo, move: move)
        return #"{"id":"\#(id)","title":"\#(text)","icon":"\#(done ? "✅" : "⚪")"\#(head)\#(tag),"actions":\#(acts)}"#
    }

    /// Hyper+Space › To-do with days set: Overdue, Today, Upcoming, No date, Done; Undo offered after a delete.
    static let dated = [row("o", "Renew Malta ID card", section: "Overdue", due: "Thu 15", tone: "alert", undo: true, move: false),
                        row("t", "Reply to Harry about the launch", section: "Today", due: "Today", tone: "warn", undo: true),
                        row("u", "Call mum", section: "Upcoming", due: "Fri", undo: true, move: false),
                        row("v", "Dentist", section: "Upcoming", due: "28 Oct", undo: true, move: false),
                        row("n", "Buy milk", section: "No date", undo: true),
                        row("d", "Book flights", section: "Done", done: true)]
    /// The same with no day set: one tidy list, Done under its heading.
    static let tidy = [row("t", "Reply to Harry about the launch"), row("n", "Buy milk"), row("r", "Renew Malta ID card"),
                       row("d", "Book flights", section: "Done", done: true)]

    static func model(_ rows: [String], query: String = "", layout: MenuLayoutStyle) throws -> MenuModel {
        let line = #"{"type":"list","items":[\#(rows.joined(separator: ","))]}"#.replacingOccurrences(of: "\n", with: " ")
        guard case .items(let items) = ExtensionRun.answer(line) else {
            throw CancellationError()
        }
        let command = try ExtensionAskSourceFixture.ext().commands[0]
        var nav = MenuNavigator(list: [], title: "To-do", live: true)
        nav.query = query
        nav.replaceList(ExtensionList.entries(items, of: command))
        let model = MenuModel(nav: nav)
        model.layout = layout
        return model
    }

    static func blocks(_ answer: String) throws -> [Extension.Block] {
        guard case .blocks(let blocks, _) = ExtensionRun.surfaceAnswer(answer.replacingOccurrences(of: "\n", with: " "), kind: .popover) else {
            throw CancellationError()
        }
        return blocks
    }

    static func surfaceRow(_ id: String, _ text: String, due: String? = nil, tone: String? = nil) -> String {
        let tag = due.map { d in tone.map { #","accessory":{"text":"\#(d)","tone":"\#($0)"}"# } ?? #","accessory":{"text":"\#(d)"}"# } ?? ""
        return #"""
        {"id":"\#(id)","title":"\#(text)"\#(tag),"actions":[{"type":"run","command":"edit","title":"Edit","ask":{"text":"\#(text)"},"context":{"id":"\#(id)"}}],
         "inline":[{"type":"run","command":"done","title":"Mark done","icon":"circle","context":{"id":"\#(id)"}},
                   {"type":"run","command":"delete","title":"Delete","icon":"xmark","destructive":true,"context":{"id":"\#(id)"}}]}
        """#
    }

    static let input = #"{"type":"input","placeholder":"Add a to-do, a day at the end: call mum fri","action":{"type":"run","command":"add","context":{"quiet":true}}}"#
    static let folded = #"{"type":"list","items":[{"title":"1 done ›","icon":"✅","actions":[{"type":"push","command":"done-list","title":"Show done to-dos"}]}]}"#
    static let datedPopover = #"""
    {"type":"blocks","blocks":[\#(input),
     {"type":"list","title":"Overdue","items":[\#(surfaceRow("o", "Renew Malta ID card", due: "Thu 15", tone: "alert"))]},
     {"type":"list","title":"Today","items":[\#(surfaceRow("t", "Reply to Harry about the launch", due: "Today", tone: "warn"))]},
     {"type":"list","title":"Upcoming","items":[\#(surfaceRow("u", "Call mum", due: "Fri")),\#(surfaceRow("v", "Dentist", due: "28 Oct"))]},
     {"type":"list","title":"No date","items":[\#(surfaceRow("n", "Buy milk"))]},\#(folded)]}
    """#
    static let tidyPopover = #"""
    {"type":"blocks","blocks":[\#(input),
     {"type":"list","items":[\#(surfaceRow("t", "Reply to Harry about the launch")),\#(surfaceRow("n", "Buy milk")),\#(surfaceRow("r", "Renew Malta ID card"))]},\#(folded)]}
    """#

    @Test("To-do in Hyper+Space with and without days, its Cmd+K, and its popover render",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("todo")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (style, theme) in [(PilotStyle.instrument, "nightwatch"), (.toybox, "toybox")] {
            (look.themeID, look.style) = (theme, style)
            let layouts: [MenuLayoutStyle] = style == .instrument ? [.classic, .rail, .line] : [.classic]
            for layout in layouts {
                let name = style == .instrument ? layout.rawValue : "toybox"
                try InstrumentMenuRenders.render(MenuView(model: try Self.model(Self.dated, layout: layout)), "menu-dated-\(name)", in: out)
                try InstrumentMenuRenders.render(MenuView(model: try Self.model(Self.tidy, layout: layout)), "menu-tidy-\(name)", in: out)
            }
            let keys = try Self.model(Self.dated, layout: .classic)
            _ = keys.nav.handle(.down)
            _ = keys.nav.handle(.commandK)
            try InstrumentMenuRenders.render(MenuView(model: keys), "menu-actions-\(style == .instrument ? "classic" : "toybox")", in: out)

            let tokens = StyleTokens.of(style, theme: look.theme)
            for (name, answer) in [("dated", Self.datedPopover), ("tidy", Self.tidyPopover)] {
                let view = ExtensionBlocksView(blocks: try Self.blocks(answer), compact: true, act: { _ in })
                    .frame(width: 320).padding(14)
                    .styled(.barPopovers, look: look).pilotTheme(look: look)
                    .background(Color(tokens.colors.canvas))
                try writeRender(view, to: out.appendingPathComponent("popover-\(name)-\(style.rawValue).png"), wait: 0.4)
            }
        }
    }
}
}
#endif
