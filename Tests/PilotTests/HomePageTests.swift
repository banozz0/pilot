#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home, direction B (card agent-bo-95422992): which button holds Return and that only it takes Return, the Hyper
/// switch's words in the greeting and on the Pilot tile, the keyboard's names whole at one size, the last copy never cut inside a word, Now's note, the key caps, and every symbol Home draws.
/// No Vision: words are checked on the values that make them, pictures as pixels (card 962). Load-proof: fakes only,
/// no live readings, and every wait is on a condition with a generous deadline, never a fixed time.
@MainActor
@Suite("Home page")
struct HomePageTests {
    static func problem(granted: Bool = true, tiler: Bool = true, error: String? = nil) -> HomeProblems.Problem {
        HomeProblems.list(accessibilityGranted: granted, secureInput: nil, tilerRunning: tiler,
                          lastError: error)[0]
    }
    static let tiler = problem(tiler: false)
    static let access = problem(granted: false)
    static let error = problem(error: "Could not install the keyboard tap.")

    @Test("Return goes to the clicked key's button, else the first problem with a fix; none while the search holds words")
    func returnTarget() {
        #expect(HomeReturn.target(picked: false, problems: [], searching: false) == .none)
        #expect(HomeReturn.target(picked: false, problems: [Self.tiler], searching: false) == .problem(0))
        #expect(HomeReturn.target(picked: false, problems: [Self.error, Self.access], searching: false) == .problem(1))
        #expect(HomeReturn.target(picked: false, problems: [Self.error], searching: false) == .none)
        #expect(HomeReturn.target(picked: true, problems: [Self.tiler], searching: false) == .key)
        #expect(HomeReturn.target(picked: true, problems: [Self.tiler], searching: true) == .none)
        #expect(HomeReturn.target(picked: false, problems: [Self.tiler], searching: true) == .none)
    }

    /// Counts a button's runs.
    final class Ran { var count = 0 }

    @Test("Pilot's tiler stopped: Home's button restarts it (card agent-bo-95423025)")
    func tilerFix() throws {
        let restarted = Ran(), went = Ran()
        func fix(_ problem: HomeProblems.Problem) throws -> (title: String, run: @MainActor () -> Void) {
            let fix = HomeFix.of(problem, go: { _ in went.count += 1 }, restartTiler: { restarted.count += 1 })
            return try #require(fix)
        }
        let restart = try fix(Self.tiler)
        #expect(restart.title == "Restart Pilot's tiler")
        restart.run()
        #expect(restarted.count == 1 && went.count == 0)
        let none = HomeFix.of(Self.error, go: { _ in }, restartTiler: {})
        #expect(try fix(Self.access).title == "Grant Accessibility" && none == nil)
        #expect(HomeGreeting.line(hyperOn: true, problems: [Self.tiler], layerKey: "Caps Lock", workspace: nil, tiler: "Pilot's tiler")
                == "Hyper is on. Pilot's tiler is not running, so nothing tiles.")
    }

    /// Keys sent to `view` in a titled window that is never shown, as key equivalents, as the window sends a key before the
    /// focused view sees it. A ⌘K probe button sits beside the view: once ⌘K runs it, the window's shortcuts are known to
    /// be registered (a moment after the first layout, later on a loaded Mac), so a key it then refuses is refused for good.
    @MainActor
    final class KeyWindow {
        let window: NSWindow
        let probe: Ran

        init(_ view: some View) {
            testApp()
            let probe = Ran()
            self.probe = probe
            let host = NSHostingView(rootView: VStack {
                view
                Button("Probe") { probe.count += 1 }.keyboardShortcut("k", modifiers: .command)
            }.pilotTheme())
            host.frame.size = host.fittingSize
            window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        func key(_ characters: String, code: UInt16, command: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        /// Runs the run loop until `done` holds, 60 s at most: a deadline only a hung Mac reaches.
        @discardableResult
        func wait(until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(60)
            while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return done()
        }

        /// ⌘K, sent until the probe runs once more: the shortcuts are in, and anything a key sent before it has run.
        func ready() -> Bool {
            let runs = probe.count
            return wait {
                _ = window.performKeyEquivalent(with: key("k", code: 40, command: true))
                return probe.count > runs
            }
        }

        /// Return, once; whether the window took it.
        func pressReturn() -> Bool { window.performKeyEquivalent(with: key("\r", code: 36)) }

        func close() { window.close() }
    }

    @Test("A button holding Return runs on Return; one that does not never takes it, beside the holding one or alone")
    func hintedButtonTakesReturn() {
        let hinted = Ran(), plain = Ran()
        let both = KeyWindow(VStack {
            ReturnButton(title: "Start it", holdsReturn: false) { plain.count += 1 }
            ReturnButton(title: "Open Permissions", holdsReturn: true) { hinted.count += 1 }
        })
        defer { both.close() }
        #expect(both.ready(), "the window's shortcuts never registered")
        #expect(both.pressReturn(), "the window did not take Return")
        #expect(both.wait { hinted.count > 0 }, "the hinted button did not run on Return")
        #expect(plain.count == 0, "a button without the hint ran on Return")

        // Alone: with the shortcuts in, Return is refused and runs nothing.
        let alone = KeyWindow(ReturnButton(title: "Start it", holdsReturn: false) { plain.count += 1 })
        defer { alone.close() }
        #expect(alone.ready(), "the window's shortcuts never registered")
        #expect(!alone.pressReturn(), "the window took Return with no button holding it")
        #expect(alone.ready(), "the probe stopped running")   // so an action Return sent late has run by now
        #expect(plain.count == 0, "a button without the hint ran on Return")
    }

    @Test("The greeting's line says what the Hyper switch is first, then what needs you, else what the layer key and tiling do")
    func greetingLine() {
        func line(_ on: Bool, _ problems: [HomeProblems.Problem], _ workspace: String? = "1") -> String {
            HomeGreeting.line(hyperOn: on, problems: problems, layerKey: "Caps Lock", workspace: workspace, tiler: "Pilot's tiler")
        }
        // The line names the tiler (card agent-bo-95423010).
        #expect(line(true, []) == "Hyper is on. Caps Lock is your Hyper key; Pilot's tiler is tiling workspace 1.")
        #expect(line(false, []) == "Hyper is off. Caps Lock does what macOS says; plain combos still run.")
        #expect(line(true, [Self.tiler], nil) == "Hyper is on. Pilot's tiler is not running, so nothing tiles.")
        #expect(line(false, [Self.tiler], nil) == "Hyper is off. Pilot's tiler is not running, so nothing tiles.")
        #expect(line(true, [Self.error]) == "Hyper is on. Could not install the keyboard tap.")
        #expect(line(true, [Self.tiler, Self.access], nil) == "Hyper is on. 2 things need you.")
        // Pilot is the whole app: Home never says it is on or off.
        #expect([line(true, []), line(false, []), line(true, [Self.access])].allSatisfy { !$0.contains("Pilot is") })
    }

    @Test("The Pilot tile says Hyper is off in plain words, after anything that needs fixing")
    func tileWords() {
        #expect(PilotTile.headline(hyperOn: true, problems: 0) == "All clear")
        #expect(PilotTile.headline(hyperOn: false, problems: 0) == "Hyper is off")
        #expect(PilotTile.headline(hyperOn: false, problems: 1) == "One thing to fix")
        #expect(PilotTile.headline(hyperOn: true, problems: 2) == "2 things to fix")
        #expect(PilotTile.note(hyperOn: false, problems: [], layerKey: "Caps Lock") == "Caps Lock does what macOS says; plain combos still run.")
        #expect(PilotTile.note(hyperOn: true, problems: [], layerKey: "Caps Lock") == "Hyper is on, and every key is yours.")
        #expect(PilotTile.note(hyperOn: false, problems: [Self.tiler], layerKey: "Caps Lock") == "Tiling needs Pilot's tiler; your binds still work.")
    }

    /// The mockup's names on their keys, the longest ones Home draws today among them.
    static let names: [Int64: String] = {
        let named = ["Esc": "Lock", "1": "Work", "2": "Chat", "3": "3", "4": "Music", "-": "Narrow", "=": "Widen", "Tab": "Next",
                     "W": "Close", "E": "Emoji", "R": "Reload", "T": "Telegram", "Y": "YouTube", "I": "Shottr",
                     "P": "Passwords", "[": "¾ left", "]": "¼ right", "A": "Screen", "S": "Area", "D": "Scrolling", "F": "Files",
                     "G": "Ghostex", "H": "Left", "J": "Down", "K": "Up", "L": "Right", "Return": "Terminal", "Z": "Empryo",
                     "X": "Text", "C": "Keys", "V": "Clips", "B": "Zen", "N": "Editor", "M": "Spotifast", ",": "← Display",
                     ".": "Display →", "/": "Flip split", "Space": "Pilot menu"]
        return Dictionary(uniqueKeysWithValues: named.map { (KeyNames.code(for: $0.key)!, $0.value) })
    }()

    @Test("The split board holds every key of the whole one once, in two halves of seven units a row, then Space")
    func splitBoard() {
        let whole = BoardFit.wholeRows.joined().map(\.cap)
        let split = BoardFit.splitRows.joined().map(\.cap)
        #expect(split.count == whole.count)
        #expect(Set(split.compactMap(\.code)) == Set(whole.compactMap(\.code)))
        #expect(BoardFit.splitRows.allSatisfy { $0.reduce(0) { $0 + $1.width } == 7 })
        #expect(BoardFit.splitRows.map { $0.first?.cap.legend } == ["Esc", "Tab", "Hyper", "Shift", "6", "Y", "H", "N", "Space"])
    }

    static func windows(_ rows: [(app: String, bundle: String, layout: String)]) throws -> [AeroWindow] {
        let json = rows.enumerated().map { i, w in
            #"{"window-id": \#(i), "app-name": "\#(w.app)", "app-bundle-id": "\#(w.bundle)", "app-pid": 1, "workspace": "1", "monitor-id": 1, "window-layout": "\#(w.layout)", "window-title": "t"}"#
        }
        return try AeroWindow.parse("[" + json.joined(separator: ",") + "]")
    }

    @Test("Now's note says how the workspace's windows sit and how many: apps, or windows when an app has two")
    func nowSummary() throws {
        #expect(HomeNowBlock.summary(try Self.windows([("Ghostex", "a", "h_tiles"), ("Ghostty", "b", "h_tiles")])) == "Columns, 2 apps")
        #expect(HomeNowBlock.summary(try Self.windows([("Ghostty", "b", "v_tiles"), ("Ghostty", "b", "v_tiles")])) == "Rows, 2 windows")
        #expect(HomeNowBlock.summary(try Self.windows([("Zen", "z", "h_scrolling")])) == "Scrolling, 1 app")
        #expect(HomeNowBlock.summary(try Self.windows([("Finder", "f", "floating")])) == "Floating, 1 app")
        #expect(HomeNowBlock.summary([]) == "nothing open")
    }

    @Test("A key cap shows Return and Space as signs, Escape short, a sublayer's modifiers before its key, a plain combo whole")
    func caps() {
        #expect(HomeKeys.cap(Key("return")) == "↵")
        #expect(HomeKeys.cap(Key("space")) == "␣")
        #expect(HomeKeys.cap(Key("b")) == "B")
        #expect(HomeKeys.cap(Key("escape")) == "Esc")
        #expect(HomeKeys.cap(Key("n", shift: true)) == "⇧N")
        #expect(HomeKeys.cap(Key("v", .leftAlt, hyper: false)) == "Left Alt+V")
    }

    @Test("Every symbol Home draws is one macOS has")
    func symbols() {
        let used = Array(HomeBinds.symbols.values) + HomeBinds.moduleSymbols + QuickAction.all.map(\.symbol)
            + ["desktopcomputer", "scope", "flame", "cursorarrow.rays", "bolt", "clock", "cpu", "keyboard", "powerplug", "clipboard",
               "exclamationmark.triangle", "xmark", "macwindow"] + (0...50).map { "\($0).square" }
        let missing = used.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "\(missing)")
    }
}
#endif
