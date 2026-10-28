import Foundation
@testable import PilotCore
@testable import PilotTiler
import Testing

/// Parity AC1 (card agent-bo-95422997): the engine's settings come from Pilot's own: the Pilot block's gaps, rules and
/// floats, the workspaces kept and their monitor pins, carried once from the old config file (ADR 0011).
@Suite struct PilotSettingsTests {
    static let block = PilotBlock(
        rules: [.init(appId: "com.mitchellh.ghostty", workspace: "1"), .init(appId: "app.zen-browser.zen", workspace: "2")],
        floatApps: ["Vicinae", "System Settings", "Finder"], floatTitles: ["Preferences", "Settings"],
        gaps: .init(inner: 100, outer: 67), topBar: [.init(monitor: "CU34G4Z", height: 40)],
    )
    static let file = """
        persistent-workspaces = ["1", "2", "3", "4"]
        [workspace-to-monitor-force-assignment]
            1 = 'CU34G4Z'
            2 = 'CU34G4Z'
            3 = 'CU34G4Z'
            4 = '24G1WG4'
        [mode.main.binding]
        """

    @Test func gapsAreTheBlocks() {
        let gaps = TilerSettings(block: Self.block, pins: [:]).gaps
        #expect(gaps.inner.horizontal == .constant(100) && gaps.inner.vertical == .constant(100))
        #expect(gaps.outer.left == .constant(67) && gaps.outer.bottom == .constant(67) && gaps.outer.right == .constant(67))
        // The top bar's screen keeps the outer gap plus the bar clear; every other screen the outer gap.
        #expect(gaps.outer.top == .perMonitor([PerMonitorValue(description: .pattern("^(CU34G4Z)$")!, value: 107)], default: 67))
        // The bar alone is the edge floating windows keep under (Sven on build 21).
        #expect(TilerSettings(block: Self.block, pins: [:]).topBar == .perMonitor([PerMonitorValue(description: .pattern("^(CU34G4Z)$")!, value: 40)], default: 0))
    }

    /// Gaps off writes zero gaps, the bar's room kept on its screen; no bar writes one plain top gap.
    @Test func gapsOffAndNoBar() {
        var block = Self.block
        block.gapsOn = false
        let off = TilerSettings(block: block, pins: [:]).gaps
        #expect(off.inner == .zero)
        #expect(off.outer.left == .constant(0))
        #expect(off.outer.top == .perMonitor([PerMonitorValue(description: .pattern("^(CU34G4Z)$")!, value: 40)], default: 0))
        block.gapsOn = true
        block.topBar = []
        #expect(TilerSettings(block: block, pins: [:]).gaps.outer.top == .constant(67))
    }

    /// The app rules, then the float lists as one regex each, in the block's order: the first match wins. App names match
    /// whole, titles anywhere in the title.
    @Test func rulesAreTheBlocks() {
        let rules = TilerSettings(block: Self.block, pins: [:]).windowRules
        #expect(rules.map(\.appId) == ["com.mitchellh.ghostty", "app.zen-browser.zen", nil, nil])
        #expect(rules.prefix(2).map(\.actions) == [[.moveToWorkspace("1")], [.moveToWorkspace("2")]])
        #expect(rules[2].appNameRegexSubstring?.origin == "^(Vicinae|System Settings|Finder)$" && rules[2].actions == [.float])
        #expect(rules[3].windowTitleRegexSubstring?.origin == "(Preferences|Settings)" && rules[3].actions == [.float])
    }

    /// A float title matches part of the title, case ignored, its text taken literally (Sven, 2026-10-10): Google's sign-in
    /// popup floats in any browser; Settings now floats Settings – Wi-Fi too; a dot is a dot.
    @MainActor @Test func floatTitlesMatchPartOfTheTitle() throws {
        var block = Self.block
        block.floatTitles = ["Google Accounts", "Settings", "a.b (beta)"]
        let regex = try #require(TilerSettings(block: block, pins: [:]).windowRules.last?.windowTitleRegexSubstring)
        for title in ["Sign in - Google Accounts — Zen Browser", "sign in – google accounts", "Settings – Wi-Fi", "a.b (beta) – Editor"] {
            #expect(title.contains(caseInsensitiveRegex: regex), "\(title)")
        }
        for title in ["Google Account", "Gmail — Zen Browser", "axb (beta)", "a.b beta", ""] {
            #expect(!title.contains(caseInsensitiveRegex: regex), "\(title)")
        }
    }

    /// The import's title regex, `^(A|B)$`, still carries over as entries, which now match as part of a title.
    @MainActor @Test func importedTitleRegexCarriesOver() throws {
        let file = """
            [[on-window-detected]]
                if.window-title-regex-substring = '^(Preferences|Settings|MiniPlayer)$'
                run = 'layout floating'
            """
        let carried = try #require(try PilotBlock.carryOver(from: file))
        #expect(carried.floatTitles == ["Preferences", "Settings", "MiniPlayer"])
        let regex = try #require(TilerSettings(block: carried, pins: [:]).windowRules.last?.windowTitleRegexSubstring)
        #expect(["Settings", "MiniPlayer", "Ghostty Preferences"].allSatisfy { $0.contains(caseInsensitiveRegex: regex) })
        #expect(!"Spotify".contains(caseInsensitiveRegex: regex))
    }

    /// C8: an app floated by bundle id is its own float rule after the app rules and before the float names, so it floats
    /// by the app itself whatever name macOS gives it.
    @Test func floatIdsAreRules() {
        var block = Self.block
        block.floatAppIds = ["com.microsoft.VSCode", "com.apple.finder"]
        let rules = TilerSettings(block: block, pins: [:]).windowRules
        #expect(rules.map(\.appId) == ["com.mitchellh.ghostty", "app.zen-browser.zen", "com.microsoft.VSCode", "com.apple.finder", nil, nil])
        #expect(rules[2...3].allSatisfy { $0.actions == [.float] && $0.appNameRegexSubstring == nil && $0.windowTitleRegexSubstring == nil })
        #expect(rules[4].appNameRegexSubstring?.origin == "^(Vicinae|System Settings|Finder)$")
    }

    /// Spec scrolling-layout T4 and T8: the block's widths (as fractions of the usable width) and sliver are the tiler's; a
    /// new column is half and the strip glides 180 ms whatever the hidden new width and speed say (Sven's Q42, Q43).
    @Test func scrollingIsTheBlocks() {
        var block = Self.block
        block.scrolling = .init(widths: [.quarter, .half, .full], newWidth: .threeQuarters, sliver: 12, speed: .fast)
        let settings = TilerSettings(block: block, pins: [:])
        #expect(settings.scrollingWidths == [0.25, 0.5, 1])
        #expect(settings.scrollingNewWidth == 0.5 && settings.scrollingSliver == 12)
        for speed in PilotBlock.ScrollSpeed.allCases {
            block.scrolling.speed = speed
            #expect(TilerSettings(block: block, pins: [:]).scrollingGlide == .milliseconds(180), "\(speed)")
        }
    }

    /// Glide windows (Sven's Q147): on by default, and off reaches the tiler.
    @Test func glideIsTheBlocks() {
        var block = Self.block
        #expect(TilerSettings(block: block, pins: [:]).glide)
        block.glide = false
        #expect(!TilerSettings(block: block, pins: [:]).glide)
    }

    /// A block saved before the scrolling layout has no `scrolling`: it loads with the defaults Sven picked (1/3, 1/2, 2/3,
    /// full; 5 pt), which are the tiler's own, a new column half and one 180 ms glide (T8), and keeps everything else it held.
    @Test func oldBlockLoadsScrollingDefaults() throws {
        let old = #"{"rules": [], "floatApps": ["Finder"], "floatTitles": [], "gaps": {"inner": 8, "outer": 12}, "gapsOn": true}"#
        let block = try JSONDecoder().decode(PilotBlock.self, from: Data(old.utf8))
        #expect(block.scrolling == PilotBlock.Scrolling() && block.floatApps == ["Finder"] && block.gaps.outer == 12)
        let settings = TilerSettings(block: block, pins: [:]), engine = TilerSettings()
        #expect(settings.scrollingWidths == engine.scrollingWidths && settings.scrollingNewWidth == 0.5)
        #expect(settings.scrollingSliver == engine.scrollingSliver && settings.scrollingGlide == .milliseconds(180))
        // And a changed block survives its own save: its hidden keys still decode.
        var changed = block
        changed.scrolling = .init(widths: [.full], newWidth: .half, sliver: 1, speed: .instant)
        #expect(try JSONDecoder().decode(PilotBlock.self, from: JSONEncoder().encode(changed)) == changed)
        // A scrolling block saved before T9 has no centre mode: never, the tiler's own.
        let beforeT9 = #"{"rules": [], "floatApps": [], "floatTitles": [], "gaps": {"inner": 8, "outer": 12}, "gapsOn": true, "#
            + #""scrolling": {"widths": ["1/2"], "newWidth": "1/3", "sliver": 7, "speed": "fast"}}"#
        let t8 = try JSONDecoder().decode(PilotBlock.self, from: Data(beforeT9.utf8)).scrolling
        #expect(t8.sliver == 7 && t8.centre == .never && TilerSettings(block: block, pins: [:]).scrollingCentre == engine.scrollingCentre)
        changed.scrolling.centre = .overflow
        #expect(try JSONDecoder().decode(PilotBlock.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(TilerSettings(block: changed, pins: [:]).scrollingCentre == .overflow)
        // Column rules (T11): a width reaches the tiler by bundle id, focus off as an app that keeps focus.
        #expect(t8.apps.isEmpty)
        changed.scrolling.apps = [.init(appId: "a.term", width: .third), .init(appId: "a.chat", focus: false)]
        #expect(try JSONDecoder().decode(PilotBlock.self, from: JSONEncoder().encode(changed)) == changed)
        let rules = TilerSettings(block: changed, pins: [:])
        #expect(rules.scrollingAppWidths == ["a.term": 1.0 / 3])
        #expect(rules.windowRules.first == WindowRule(appId: "a.chat", actions: [.keepFocus], checkFurtherRules: true), "first, going on to the rest")
    }

    /// Sven's four pinned workspaces, 1 to 3 on the wide screen and 4 on the portrait one, carried over once from the
    /// force-assignment table outside Pilot's block (WorkspaceMonitors.pins), main while their screen is gone (N7); all nine
    /// persistent unless fewer are kept.
    @Test func fourWorkspacesPinnedToTheirScreens() throws {
        let defaults = try #require(UserDefaults(suiteName: NSTemporaryDirectory() + "dev.banozz.pilot.test.\(UUID().uuidString)"))
        let pins = WorkspaceMonitors.pins(in: defaults, carryingFrom: Self.file, displays: [])
        #expect(WorkspaceMonitors.carryOver(from: Self.file) == ["1": "CU34G4Z", "2": "CU34G4Z", "3": "CU34G4Z", "4": "24G1WG4"])
        let settings = TilerSettings(block: Self.block, pins: pins)
        #expect(settings.persistentWorkspaces == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(TilerSettings(block: Self.block, workspaces: Workspaces.names(2), pins: pins).persistentWorkspaces == ["1", "2"])
        #expect(settings.workspaceToMonitorForceAssignment == [
            "1": [.pattern("CU34G4Z")!, .main], "2": [.pattern("CU34G4Z")!, .main], "3": [.pattern("CU34G4Z")!, .main],
            "4": [.pattern("24G1WG4")!, .main],
        ])
    }
}
