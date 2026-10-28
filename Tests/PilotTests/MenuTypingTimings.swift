#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// What one keystroke in the Hyper+Space menu's root search costs (Build 83's typing lag): the real catalogue (this Mac's
/// apps, every action, the drive catalogue's commands, Install's entries), thirty windows and a big app's 300 menu items,
/// then each prefix of a few typed lines set as the search field sets it, with the providers the panel runs on each change
/// (emoji, settings, answers, Translate's, snippets). Prints milliseconds per key; a debug build's, so compare runs, not
/// against the eye. Opt-in, never in the full run (SWIFT_DETERMINISTIC_HASHING=1 keeps the actions' order between runs):
/// `CFFIXED_USER_HOME=/tmp/<fresh dir> PILOT_TIMINGS=1 swift test --filter MenuTypingTimings` (under /tmp, not /private/tmp)
/// `PILOT_TIMINGS_DUMP=<file>` also writes every step's rows, selection and kind counts, to diff a ranking change by.
extension SharedLook {
@MainActor
@Suite("Menu typing timings")
struct MenuTypingTimings {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let opted = env["PILOT_TIMINGS"] != nil && env["CFFIXED_USER_HOME"] != nil
    static let lines = ["visual studio code", "ghostty", "dark mode", "screenshot", "sytem settings", "calendar", "mial", "toggle sidebar",
                        "fidner", "12*7"]

    /// The search and each provider timed apart, per key.
    @Test("Each part of a keystroke, timed", .enabled(if: opted))
    func parts() throws {
        let menu = try Catalogue()
        defer { menu.restore() }
        var parts: [String: Double] = [:], keys = 0, dump: [String] = []
        func time<T>(_ name: String, _ f: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { parts[name, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
            return f()
        }
        func note(_ step: String, _ nav: MenuNavigator) {
            dump.append("\(step) selection \(nav.selection), counts \(MenuEntry.Kind.tabOrder.map { $0.flatMap(nav.count(of:)).map(String.init) ?? "-" })")
            dump += nav.rows.map { "  \($0.id) \($0.title)" }
        }
        for line in Self.lines {
            var nav = menu.navigator()
            for n in 1...line.count {
                keys += 1
                let q = String(line.prefix(n))
                time("search") { nav.query = q }
                note("\(q): search", nav)
                let emoji = time("emoji rows") { EmojiSearch.entries(for: q, in: menu.emoji) }
                time("emoji ranked") { nav.provide(.emoji, emoji) }
                note("\(q): emoji", nav)
                let settings = time("settings rows") { SettingsSearch.entries(for: q) }
                time("settings ranked") { nav.provide(.setting, settings) }
                note("\(q): settings", nav)
                let answers = time("answers rows") { RootAnswers.entries(for: q, now: .now) }
                time("answers ranked") { nav.provide(.answer, answers) }
                time("translate ranked") { nav.provide(.answer, home: .translate, []) }
                let snippets = time("snippets rows") { MenuEntries.snippets(SnippetLibrary.shared.snippets, query: q) }
                time("snippets ranked") { nav.provide(.snippet, home: .snippets, snippets) }
                note("\(q): snippets", nav)
            }
        }
        if let path = Self.env["PILOT_TIMINGS_DUMP"] { try dump.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        for (name, ms) in parts.sorted(by: { $0.value > $1.value }) { print("menu timings: \(name) \(String(format: "%.2f", ms / Double(keys))) ms per key") }
    }

    /// The whole keystroke as the panel takes it, then the menu redrawn in a window that is never shown, in each layout.
    @Test("Each keystroke of a root search, timed", .enabled(if: opted))
    func keystrokes() throws {
        let menu = try Catalogue()
        defer { menu.restore() }
        for layout in [MenuLayoutStyle.line, .rail, .classic] {
            Look.shared.menuLayout = layout
            let host = NSHostingView(rootView: MenuView(model: menu.model(layout)))
            host.frame.size = CGSize(width: 760, height: 560)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            var search: [Double] = [], draw: [Double] = []
            for line in Self.lines {
                let model = menu.model(layout)
                host.rootView = MenuView(model: model)
                host.layoutSubtreeIfNeeded()
                host.display()
                for n in 1...line.count {
                    let start = DispatchTime.now().uptimeNanoseconds
                    model.nav.query = String(line.prefix(n))
                    let searched = DispatchTime.now().uptimeNanoseconds
                    host.layoutSubtreeIfNeeded()
                    host.display()
                    search.append(Double(searched - start) / 1e6)
                    draw.append(Double(DispatchTime.now().uptimeNanoseconds - searched) / 1e6)
                }
            }
            func spread(_ ms: [Double]) -> String {
                let s = ms.sorted()
                return String(format: "median %.2f ms, p90 %.2f ms, worst %.2f ms", s[s.count / 2], s[s.count * 9 / 10], s[s.count - 1])
            }
            print("menu timings: \(layout.rawValue) search \(spread(search)); draw \(spread(draw)); \(search.count) keys")
        }
    }

    /// The menu's rows as Pilot lists them on this Mac, in a home that is not Sven's.
    @MainActor
    struct Catalogue {
        let entries: [MenuEntry], windows: [AeroWindow], menuItems: [MenuEntry], emoji: [Emoji]
        /// The look and the faces as they were, put back after (restore), so a later suite in the run draws as it did.
        private let saved = (style: Look.shared.style, layout: Look.shared.menuLayout, faces: DisplayFaces.directory)

        init() throws {
            try #require(NSHomeDirectory() == env["CFFIXED_USER_HOME"], "the home directory did not move; refusing to touch Sven's data")
            testApp()
            Look.shared.style = .instrument
            // The faces from the repo, as Pilot.app's Resources hold them: without them each text looks for its font afresh.
            DisplayFaces.directory = LookThemeTests.fonts
            emoji = try EmojiSearch.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/emoji.json")))
            entries = PilotMenu.entries(Engine(), scripts: [], extensions: [])
            windows = try AeroWindow.parse("[" + (1...30).map { i in
                #"{"window-id": \#(i), "app-name": "App \#(i % 7)", "app-bundle-id": "com.example.app\#(i % 7)", "app-pid": \#(i % 7 + 1), "workspace": "\#(i % 5 + 1)", "monitor-id": 1, "window-layout": "h_tiles", "window-title": "Window number \#(i) of a long project title"}"#
            }.joined(separator: ",") + "]")
            let words = ["Open", "Close", "Save", "Export", "Show", "Hide", "Toggle", "Find", "Replace", "Go to", "Move", "Duplicate", "Rename",
                         "Format", "Insert", "Select", "Zoom", "Window", "Sidebar", "Tab", "Line", "Selection", "Project", "Document",
                         "Inspector", "Breakpoint", "Scheme", "Console", "Minimap", "Code"]
            menuItems = (0..<300).map { i in
                MenuEntry(title: "\(words[i % words.count]) \(words[i / 3 % words.count].lowercased()) \(words[i * 7 / 5 % words.count].lowercased())",
                          target: .action("drive.menu:test.\(i)"), ownKind: .menuItem, subtitle: "View › Item \(i)")
            }
            print("menu timings: \(entries.count) entries, \(windows.count) windows, \(menuItems.count) menu items, \(emoji.count) emoji")
        }

        func restore() { (Look.shared.style, Look.shared.menuLayout, DisplayFaces.directory) = saved }

        /// A fresh menu at the root with its windows and menu items listed, as they arrive after it opens.
        func navigator() -> MenuNavigator {
            var nav = MenuNavigator(entries: entries)
            nav.provide(.window, MenuEntries.windows(MenuEntries.byWorkspace(windows), excluding: nil))
            nav.provide(.menuItem, menuItems)
            return nav
        }

        /// That menu in `layout`, the panel's root providers hearing each search.
        func model(_ layout: MenuLayoutStyle) -> MenuModel {
            let model = MenuModel(nav: navigator())
            model.layout = layout
            model.windows = windows
            model.onQuery = { [weak model, emoji] query in
                guard let model else { return }
                model.nav.provide(.emoji, EmojiSearch.entries(for: query, in: emoji))
                model.nav.provideSettings(query)
                model.nav.provide(.answer, RootAnswers.entries(for: query, now: .now))
                model.nav.provide(.answer, home: .translate, [])
                model.nav.provide(.snippet, home: .snippets, MenuEntries.snippets(SnippetLibrary.shared.snippets, query: query))
            }
            return model
        }
    }
}
}
#endif
