#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// What Home's parts share with the rest of Pilot (Home's board went in pilot-ui-redesign T6): a problem's fix, the Hyper
/// switch's words in the greeting line (`pilot status`), the split board's keys, the key caps, and every symbol the
/// binds' boards draw.
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

    /// The mockup's names on their keys, the longest ones the boards draw among them (Binds' tests read them).
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

    @Test("A key cap shows Return and Space as signs, Escape short, a sublayer's modifiers before its key, a plain combo whole")
    func caps() {
        #expect(HomeKeys.cap(Key("return")) == "↵")
        #expect(HomeKeys.cap(Key("space")) == "␣")
        #expect(HomeKeys.cap(Key("b")) == "B")
        #expect(HomeKeys.cap(Key("escape")) == "Esc")
        #expect(HomeKeys.cap(Key("n", shift: true)) == "⇧N")
        #expect(HomeKeys.cap(Key("v", .leftAlt, hyper: false)) == "Left Alt+V")
    }

    @Test("Every symbol the binds' boards draw is one macOS has")
    func symbols() {
        let used = Array(HomeBinds.symbols.values) + HomeBinds.moduleSymbols
        let missing = used.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "\(missing)")
    }
}
#endif
