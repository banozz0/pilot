import Foundation
import Testing
@testable import PilotCore

/// System Events' autohide as a fake: it records every read and write and never touches the real menu bar.
final class FakeAutohide: MenuBarAutohide, @unchecked Sendable {
    var hidden: Bool
    var failWrite = false
    private(set) var writes: [Bool] = []
    private(set) var reads = 0

    init(hidden: Bool) { self.hidden = hidden }

    func isHidden() async throws -> Bool {
        reads += 1
        return hidden
    }

    func setHidden(_ hidden: Bool) async throws {
        if failWrite { throw ChildProcess.Failure(tool: "osascript", status: 1, message: "Not authorised to send Apple events to System Events.") }
        writes.append(hidden)
        self.hidden = hidden
    }
}

@Suite("Top bar")
struct TopBarTests {
    @Test("A screen's visible frame less its bar: the bar is a hard edge for the windows Pilot places (Sven on build 21)")
    func belowBar() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Autohide hides the menu bar: the visible frame starts at the top, the bar's 30.5 points (rounded up) come off.
        #expect(TopBarGeometry.belowBar(CGRect(x: 0, y: 0, width: 1920, height: 1040), screen: screen, bar: 30.5)
                == CGRect(x: 0, y: 31, width: 1920, height: 1009))
        // A visible frame already clear of it, or no bar, stays as it is.
        let clear = CGRect(x: 0, y: 40, width: 1920, height: 1000)
        #expect(TopBarGeometry.belowBar(clear, screen: screen, bar: 30) == clear)
        #expect(TopBarGeometry.belowBar(screen, screen: screen, bar: nil) == screen)
        // A second screen to the right, its own origin.
        let right = CGRect(x: 1920, y: -200, width: 1280, height: 800)
        #expect(TopBarGeometry.belowBar(right, screen: right, bar: 24).minY == -176)
    }

    static let base = PilotBlock(rules: [.init(appId: "com.mitchellh.ghostty", workspace: "1")], gaps: .init(inner: 10, outer: 24))
    static let bars = [PilotBlock.BarInset(monitor: "CU34G4Z", height: 30), .init(monitor: "24G1WG4", height: 30)]

    /// The block's bars as the switch writes them, kept in memory (PilotBlockStore hands them to the tiler).
    final class Written: @unchecked Sendable {
        var bars: [PilotBlock.BarInset] = []
        var write: @Sendable ([PilotBlock.BarInset]) async throws -> Void { { [self] in bars = $0 } }
    }

    @Test("The carry-over reads the per-monitor form back as the same bars and gaps")
    func carryOverReadsBars() throws {
        var block = Self.base
        block.topBar = Self.bars + [.init(monitor: "DELL U2720Q (1)", height: 25)]
        #expect(try PilotBlock.carryOver(from: block.toml) == block)
        // A per-monitor top Pilot did not write (a pattern, not a name, or no default) is refused, never guessed.
        #expect(throws: PilotBlockError.self) { try PilotBlock.carryOver(from: "[gaps]\nouter.top = [{ monitor.main = 30 }, 24]") }
        #expect(throws: PilotBlockError.self) { try PilotBlock.carryOver(from: "[gaps]\nouter.top = [{ monitor.\"^(A)$\" = 30 }]") }
    }

    @Test("Settings saved before the top bar existed still load, with no bars")
    func oldSettingsLoad() throws {
        let old = #"{"rules":[],"floatApps":["Finder"],"floatTitles":[],"gaps":{"inner":10,"outer":24},"gapsOn":true}"#
        let block = try JSONDecoder().decode(PilotBlock.self, from: Data(old.utf8))
        #expect(block.topBar.isEmpty)
        #expect(block.floatApps == ["Finder"])
    }

    @Test("Switching on saves the autohide it found, writes the bars into the block, then hides the menu bar")
    func switchOn() async throws {
        let written = Written()
        let autohide = FakeAutohide(hidden: false)
        let on = try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: written.write)
        #expect(on == TopBarSwitch(isOn: true, savedAutohide: false))
        #expect(autohide.writes == [true])
        #expect(written.bars == Self.bars)
    }

    @Test("Switching off puts the saved autohide back and leaves the block's bars as they were before switching on")
    func switchOffRestores() async throws {
        for found in [false, true] {
            let written = Written()
            let autohide = FakeAutohide(hidden: found)
            let on = try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: written.write)
            let off = try await on.switchedOff(bars: Self.bars, autohide: autohide, writeBars: written.write)
            #expect(off == .off)
            #expect(autohide.hidden == found)
            #expect(autohide.writes == [true, found])
            #expect(written.bars.isEmpty)
        }
    }

    @Test("Switching on when on, or off when off, touches nothing")
    func noRepeat() async throws {
        let written = Written()
        let autohide = FakeAutohide(hidden: false)
        let on = try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: written.write)
        written.bars = []
        #expect(try await on.switchedOn(Self.bars, autohide: autohide, writeBars: written.write) == on)
        #expect(try await TopBarSwitch.off.switchedOff(bars: Self.bars, autohide: autohide, writeBars: written.write) == .off)
        #expect(autohide.writes == [true])
        #expect(autohide.reads == 1)
        #expect(written.bars.isEmpty, "neither repeat wrote the bars")
    }

    @Test("A refused System Events write leaves the switch off and the block as it was")
    func failedAutohide() async throws {
        let written = Written()
        let autohide = FakeAutohide(hidden: false)
        autohide.failWrite = true
        await #expect(throws: TopBarError.self) { try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: written.write) }
        #expect(autohide.hidden == false)
        #expect(written.bars.isEmpty)
    }

    @Test("A refused block write leaves the menu bar as it was and the switch off")
    func failedBlock() async throws {
        let autohide = FakeAutohide(hidden: false)
        struct Refused: Error {}
        await #expect(throws: TopBarError.self) {
            try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: { _ in throw Refused() })
        }
        #expect(autohide.writes.isEmpty)
    }

    @Test("Switching off with autohide refused keeps the bar on and its room in the block, so a retry can finish")
    func failedOff() async throws {
        let written = Written()
        let autohide = FakeAutohide(hidden: false)
        let on = try await TopBarSwitch.off.switchedOn(Self.bars, autohide: autohide, writeBars: written.write)
        autohide.failWrite = true
        await #expect(throws: TopBarError.self) { try await on.switchedOff(bars: Self.bars, autohide: autohide, writeBars: written.write) }
        #expect(autohide.hidden == true)
        #expect(written.bars == Self.bars)
    }

    @Test("The bar's height is the menu bar's strip, else the height remembered while it showed, else the fallback")
    func height() {
        #expect(TopBarGeometry.strip(frameMaxY: 1440, visibleMaxY: 1410, remembered: nil, fallback: 22) == 30)
        #expect(TopBarGeometry.strip(frameMaxY: 1440, visibleMaxY: 1440, remembered: 30, fallback: 22) == 30)
        #expect(TopBarGeometry.strip(frameMaxY: 1440, visibleMaxY: 1440, remembered: nil, fallback: 22) == 22)
        // A notched MacBook's strip is fractional; the tiler's gap is whole points, rounded up so no tile slips under.
        #expect(TopBarGeometry.inset(37.5) == 38)
    }

    @Test("A bar's frame is its screen's top strip, on a screen left of or above the main one too (card agent-bo-95423038)")
    func frame() {
        #expect(TopBarGeometry.frame(screen: CGRect(x: 0, y: 0, width: 3440, height: 1440), strip: 30) == CGRect(x: 0, y: 1410, width: 3440, height: 30))
        #expect(TopBarGeometry.frame(screen: CGRect(x: -1080, y: 0, width: 1080, height: 1920), strip: 30)
            == CGRect(x: -1080, y: 1890, width: 1080, height: 30))
    }

    @Test("Each screen's bar takes its strip, rounded up, by its name")
    func screens() {
        let screens = [TopBarGeometry.Screen(name: "CU34G4Z", strip: 30), .init(name: "24G1WG4", strip: 29.5)]
        #expect(TopBarGeometry.bars(screens) == Self.bars)
    }

    @Test("System Events' autohide is read and set by its dictionary name, through osascript")
    func systemEventsScript() {
        #expect(SystemEventsAutohide.readScript == #"tell application "System Events" to get autohide menu bar of dock preferences"#)
        #expect(SystemEventsAutohide.writeScript(true) == #"tell application "System Events" to set autohide menu bar of dock preferences to true"#)
        #expect(SystemEventsAutohide.parse("true\n") == true)
        #expect(SystemEventsAutohide.parse("false\n") == false)
        #expect(SystemEventsAutohide.parse("missing value") == nil)
    }

    @Test("The workspaces module shows the occupied ones and this screen's, in the tiler's order, marking shown and focused")
    func workspaces() {
        let items = TopBarWorkspaces.items(occupied: ["1", "3", "web"], focused: "3", visibleHere: "7")
        #expect(items.map(\.name) == ["1", "3", "7", "web"])
        #expect(items.filter(\.isFocused).map(\.name) == ["3"])
        #expect(items.filter(\.isShownHere).map(\.name) == ["7"])
        // The tiler not answering: nothing to show.
        #expect(TopBarWorkspaces.items(occupied: [], focused: nil, visibleHere: nil).isEmpty)
    }

    @Test("The bar starts with workspaces on the left and the clock on the right")
    func standardLayout() {
        #expect(TopBarLayout.standard == TopBarLayout(left: [TopBarItem(.workspaces)], centre: [], right: [TopBarItem(.clock)]))
    }
}
