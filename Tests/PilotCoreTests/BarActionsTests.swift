import Foundation
@testable import PilotCore
import Testing

/// Every bar item answers right-click, hover and scroll, and a reading turns amber past its threshold (card
/// agent-bo-95423010, design JJPiA9o30SA version 1, the right-click shot): the menu, the tooltip and the scroll as a pure
/// model, from seeded readings and fakes.
@MainActor
@Suite("Bar actions")
struct BarActionsTests {
    static func menu(_ kind: BarKind, _ i: BarInputs = BarPartsTests.inputs, in place: BarPlace = .topBar) -> [BarMenuRow] {
        BarSettings.defaults.entry(kind).menu(i, in: place)
    }

    /// Every action row, submenus opened, by title.
    static func actions(_ rows: [BarMenuRow]) -> [String: (action: BarAction, checked: Bool)] {
        var found: [String: (action: BarAction, checked: Bool)] = [:]
        for row in rows {
            switch row {
            case .action(let title, let action, let checked, _): found[title] = (action, checked)
            case .submenu(_, let rows): found.merge(actions(rows)) { a, _ in a }
            case .header, .separator: break
            }
        }
        return found
    }

    static func submenu(_ title: String, in rows: [BarMenuRow]) -> [BarMenuRow]? {
        rows.lazy.compactMap { if case .submenu(title, let rows) = $0 { rows } else { nil } }.first
    }

    @Test("Every item's right-click menu has Move to (Left, Centre, Right; not Pilot), Remove from bar and Edit bar, and each of its styles when it has more than one")
    func everyMenu() throws {
        for kind in BarKind.allCases where !kind.pinned {
            let rows = Self.menu(kind)
            let moves = try #require(Self.submenu("Move to", in: rows), "\(kind)")
            #expect(Self.actions(moves).mapValues(\.action) == ["Left": .edit(.move(.left)), "Centre": .edit(.move(.centre)), "Right": .edit(.move(.right))], "\(kind)")
            #expect(Self.actions(moves).filter(\.value.checked).map(\.key) == [BarSettings.defaults.entry(kind).side.rawValue.capitalized], "\(kind)")
            let actions = Self.actions(rows)
            #expect(actions["Edit bar…"]?.action == .page(.menuBar), "\(kind)")
            #expect((actions["Remove from bar"]?.action == .edit(.remove)) == !kind.pinned, "\(kind)")
            if kind.styles.count > 1 {
                #expect(rows.contains(.header("Style")), "\(kind)")
                for style in kind.styles {
                    let row = actions[style.menuTitle]
                    #expect(row?.action == .edit(.style(style)) && row?.checked == (style == BarSettings.defaults.entry(kind).style), "\(kind) \(style)")
                }
            } else {
                #expect(!rows.contains(.header("Style")), "\(kind)")
            }
            // Sections apart, never two lines in a row or one at either end.
            #expect(rows.first != .separator && rows.last != .separator, "\(kind)")
            #expect(!zip(rows, rows.dropFirst()).contains { $0 == .separator && $1 == .separator }, "\(kind)")
        }
    }

    @Test("Volume's menu: Show Volume on the click, Mute on Option-click, Output, Sound settings (Sven on build 21)")
    func volumeMenu() throws {
        var i = BarPartsTests.inputs
        i.outputs = ["Speakers", "AirPods Pro"]
        let rows = Self.menu(.volume, i)
        #expect(rows.prefix(3) == [.action("Show Volume", .click(.popover), hint: "click"), .action("Mute", .click(.toggleMute), hint: "⌥ click"),
                                   .submenu("Output", [.action("Speakers", .output("Speakers"), checked: true), .action("AirPods Pro", .output("AirPods Pro"))])])
        #expect(Self.actions(rows)["Sound settings…"]?.action == .settings("com.apple.Sound-Settings.extension"))
        i.muted = true
        #expect(Self.menu(.volume, i)[1] == .action("Unmute", .click(.toggleMute), hint: "⌥ click"))
    }

    @Test("Keyboard layout's menu: Show on the click, Next layout kept from the old click, Keyboard settings (Sven on build 36)")
    func keyboardMenu() {
        let rows = Self.menu(.keyboardLayout)
        #expect(rows.prefix(3) == [.action("Show Keyboard layout", .click(.popover), hint: "click"), .action("Next layout", .click(.cycleLayout)),
                                   .action("Keyboard settings…", .settings("com.apple.Keyboard-Settings.extension"))])
    }

    @Test("Displays' menu: Show Displays on the click and Displays settings; its part is the display glyph, its tooltip what it holds")
    func displaysMenu() {
        let rows = Self.menu(.displays)
        #expect(rows.prefix(2) == [.action("Show Displays", .click(.popover), hint: "click"),
                                   .action("Displays settings…", .settings("com.apple.Displays-Settings.extension"))])
        #expect(BarParts.parts(BarSettings.defaults.entry(.displays), BarInputs()) == [.symbol("display")])
        #expect(BarTooltip.text(.displays, BarInputs()) == "Brightness, resolution and refresh rate")
        #expect(!BarSettings.defaults.entry(.displays).on && BarSettings.defaults.entry(.displays).side == .right)
    }

    @Test("Capture's menu (Sven, 2026-10-16; P69, as Snapzy's): every capture, Record screen, the tools, history and settings; while recording Stop with its time and Pause first; each row runs its registered action, its key greyed at the right, an action not registered leaves its row out, and a capture it does not name joins under its label")
    func captureMenu() {
        var i = BarInputs()
        let known = BarKind.captureActions.filter { !["captures.combineImages", "captures.editVideo", "captures.history"].contains($0) }
        i.actions = Dictionary(uniqueKeysWithValues: known.map { ($0, $0 == "captures.area" ? "⇪ S" : nil) })
        let rows = BarKind.capture.actions(i, scrolls: false)
        #expect(rows == [.action("Capture area", .run("captures.area"), hint: "⇪ S"), .action("Capture window", .run("captures.activeWindow")),
                         .action("Capture screen", .run("captures.fullscreen")), .action("Scrolling capture", .run("captures.scrolling")),
                         .action("Scrolling capture, upward", .run("captures.scrollingUp")), .action("Capture text", .run("captures.ocr")),
                         .action("Read QR on screen", .run("captures.readQRScreen")), .action("Capture a UI element", .run("captures.smartElement")), .action("Capture a subject", .run("captures.subject")),
                         .action("Capture and mark up", .run("captures.markup")), .action("Capture the last area again", .run("captures.repeatArea")),
                         .action("Capture after a delay", .run("captures.delayed")), .action("Pick a colour", .run("captures.pickColour")), .separator,
                         .action("Record screen", .run("captures.screenRecording")), .separator,
                         .action("Edit last capture", .run("captures.editLast")), .action("Pin last capture", .run("captures.pinLast")),
                         .action("Show last thumbnail again", .run("captures.restoreThumbnail")), .action("Capture history…", .page(.captures)),
                         .action("Captures settings…", .page(.captures))])
        let titles = { (i: BarInputs) in Self.actions(BarKind.capture.actions(i, scrolls: false)).filter { $0.value.action != .page(.captures) }.keys.sorted() }
        // While it records: Stop with the time and Pause lead; paused, Resume; starting or counting down, Cancel; no Record screen.
        i.recording = .recording(42)
        #expect(BarKind.capture.actions(i, scrolls: false).prefix(3) == [.action("Stop recording (0:42)", .run("captures.screenRecording")),
                                                                        .action("Pause recording", .run("captures.pauseRecording")), .separator])
        #expect(!titles(i).contains("Record screen"))
        i.recording = .paused(42)
        #expect(Self.actions(BarKind.capture.actions(i, scrolls: false))["Resume recording"]?.action == .run("captures.pauseRecording"))
        i.recording = .counting(3)
        #expect(titles(i).contains("Cancel recording") && !titles(i).contains("Pause recording"))
        i.recording = nil
        // Open history, Edit video and a new capture type show once registered; history takes the page row's place.
        i.actions["captures.history"] = .some(nil)
        i.actions["captures.editVideo"] = .some(nil)
        i.actions["captures.magnifier"] = .some("⇪ M")
        i.actionLabels = ["captures.magnifier": "Pixel magnifier", "captures.menu": "Capture menu", "captures.area": "Capture area"]
        #expect(titles(i).contains("Open history") && titles(i).contains("Edit video…") && !titles(i).contains("Capture history…"))
        let added = BarKind.capture.actions(i, scrolls: false)
        #expect(added.contains(.action("Pixel magnifier", .run("captures.magnifier"), hint: "⇪ M")))
        #expect(!titles(i).contains("Capture menu") && added.filter { if case .action(_, .run("captures.area"), _, _) = $0 { true } else { false } }.count == 1)
        i.actionLabels = [:]
        // Edit last capture's action not registered (yet): its row is left out; nothing registered leaves history and settings.
        i.actions["captures.editLast"] = nil
        #expect(!titles(i).contains("Edit last capture"))
        #expect(BarKind.capture.actions(BarInputs(), scrolls: false) == [.action("Capture history…", .page(.captures)), .action("Captures settings…", .page(.captures))])
        // The right-click menu has the same rows first, then the bar's.
        let right = BarSettings.defaults.entry(.capture).menu(BarInputs(), in: .topBar)
        #expect(right.prefix(2) == [.action("Capture history…", .page(.captures)), .action("Captures settings…", .page(.captures))])
        #expect(Self.actions(right)["Remove from bar"] != nil)
    }

    @Test("Capture draws its camera, named in icon + name; while recording its time in place of the red dot, paused its pause glyph, counting down the count")
    func captureParts() {
        let entry = BarSettings.defaults.entry(.capture)
        var i = BarInputs()
        #expect(BarParts.parts(entry, i) == [.symbol(BarParts.captureSymbol)])
        i.recording = .recording(42)
        #expect(BarParts.parts(entry, i) == [.symbol("record.circle.fill"), .value("0:42", widest: "88:88")])
        #expect(BarTooltip.text(.capture, i) == "Recording · 0:42 · click to stop or pause")
        i.recording = .paused(3_725)
        #expect(BarParts.parts(entry, i) == [.symbol("pause.circle"), .value("1:02:05", widest: "8:88:88")])
        i.recording = .counting(3)
        #expect(BarParts.parts(entry, i) == [.symbol("record.circle"), .value("3")])
        var named = BarSettings.defaults
        named.set(.capture, style: .iconName)
        #expect(BarParts.parts(named.entry(.capture), BarInputs()) == [.symbol(BarParts.captureSymbol), .text("Capture")])
        // A new install has it on in the menu bar only (Q368); new in a saved layout, it joins off. A click opens its menu.
        #expect(entry.on && entry.placement == .menuBar && entry.side == .right && !BarKind.capture.joinsOn && BarSlot.item(entry).click == .menu)
    }

    @Test("The macOS menu bar's menu has no Move to: sides are the top bar's")
    func menuBarMenu() {
        for kind in BarKind.allCases {
            let rows = Self.menu(kind, in: .menuBar)
            #expect(Self.submenu("Move to", in: rows) == nil && Self.actions(rows)["Edit bar…"] != nil, "\(kind)")
        }
        // Scroll is the top bar's: the menu bar names no scroll hint.
        #expect(Self.menu(.workspaces, in: .menuBar)[1] == .action("Next workspace", .workspace(next: true)))
        #expect(Self.menu(.workspaces)[1] == .action("Next workspace", .workspace(next: true), hint: "scroll"))
    }

    @Test("Move to Left on Volume saves side left and places it last on the left")
    func moveToSide() {
        var s = BarSettings.defaults
        s.apply(.move(.left), on: .volume)
        #expect(s.entry(.volume).side == .left)
        let left = s.entries.filter { $0.side == .left }.map(\.kind)
        #expect(left.last == .volume && left.count == 5)
        // Its new place: right after the last item already on the left, nothing else reordered.
        var expected = BarSettings.defaults.entries.map(\.kind).filter { $0 != .volume }
        expected.insert(.volume, at: expected.firstIndex(of: .appMenus)! + 1)
        #expect(s.entries.map(\.kind) == expected)
        // Saved as it is set.
        let saved = try? JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(s))
        #expect(saved == s)
    }

    @Test("Remove from bar sets the item off; a style the menu picks is set; Pilot is pinned, so its menu has no Remove")
    func removeAndStyle() {
        var s = BarSettings.defaults
        s.apply(.remove, on: .workspaces)
        #expect(!s.entry(.workspaces).on)
        s.apply(.style(.graph), on: .cpu)
        #expect(s.entry(.cpu).style == .graph)
        s.apply(.remove, on: .pilot)
        #expect(s.entry(.pilot).on)
        #expect(!Self.menu(.pilot).contains { if case .action("Remove from bar", _, _, _) = $0 { true } else { false } })
        // Pinned first on the left (card agent-bo-95423009), so it has no Move to and a move leaves it there.
        #expect(!Self.menu(.pilot).contains { if case .submenu("Move to", _) = $0 { true } else { false } })
        s.apply(.move(.right), on: .pilot)
        #expect(s.entry(.pilot).side == .left)
    }

    @Test("Every item has a one-line tooltip from seeded readings; CPU's reads CPU 9% · load 1.42")
    func tooltips() {
        var i = BarPartsTests.inputs
        i.values?.cpu = 0.09
        i.latest?.load = [1.42, 1.1, 0.9]
        for kind in BarKind.allCases {
            let text = BarTooltip.text(kind, i)
            #expect(!text.isEmpty && !text.contains("\n"), "\(kind)")
        }
        #expect(BarTooltip.text(.cpu, i) == "CPU 9% · load 1.42")
        #expect(BarTooltip.text(.storage, i) == "Storage 72% used")
        #expect(BarTooltip.text(.volume, i) == "Volume 50 % · Speakers")
        #expect(BarTooltip.text(.clock, i) == "Monday, 5 October 2026")
        #expect(BarTooltip.text(.bluetoothBatteries, i) == "AirPods Pro 72% · Mouse 40%")
        // With no readings yet every item still says what it is.
        #expect(BarKind.allCases.allSatisfy { !BarTooltip.text($0, BarInputs()).isEmpty })
        // The group's names each reading in it.
        let s = BarSettings.defaults
        #expect(BarTooltip.text(.group([s.entry(.cpu), s.entry(.memory)]), i) == "CPU 9% · load 1.42  ·  Memory 61% used")
    }

    final class FakeTarget: BarScrollTarget {
        var volume: Float? = 0.5
        var levels: [Float] = []
        var commands: [AeroCommand] = []
        func setVolume(_ level: Float) { levels.append(level); volume = level }
        func run(_ command: AeroCommand) { commands.append(command) }
    }

    @Test("Scroll on Volume moves the level 5 percent a step, held to 0 to 100; on Workspaces it asks the tiler for the previous and next workspace; the rest take none")
    func scroll() {
        let target = FakeTarget()
        BarScroll.perform(.volume, steps: 1, on: target)
        BarScroll.perform(.volume, steps: -3, on: target)
        #expect(target.levels.map { ($0 * 100).rounded() } == [55, 40])
        target.volume = 0.98
        BarScroll.perform(.volume, steps: 2, on: target)
        #expect(target.levels.last == 1)
        BarScroll.perform(.workspaces, steps: 1, on: target)
        BarScroll.perform(.workspaces, steps: -2, on: target)
        #expect(target.commands == [.workspacePrevious, .workspaceNext, .workspaceNext])
        for kind in BarKind.allCases where kind != .volume && kind != .workspaces {
            BarScroll.perform(kind, steps: 1, on: target)
            #expect(!kind.scrolls, "\(kind)")
        }
        #expect(target.levels.count == 3 && target.commands.count == 3)
        // No level to read (a device without one): nothing is set.
        target.volume = nil
        BarScroll.perform(.volume, steps: 1, on: target)
        #expect(target.levels.count == 3)
    }

    @Test("A wheel notch is one step; a trackpad's fine deltas add up to a step every 12 points")
    func scrollSteps() {
        var steps = BarScroll.Steps()
        #expect(steps.add(1, precise: false) == 1 && steps.add(-3, precise: false) == -1)
        #expect([5, 5, 5, 5, 5].map { steps.add($0, precise: true) } == [0, 0, 1, 0, 1])
        #expect(steps.add(-30, precise: true) == -2)
    }

    @Test("A reading turns amber past its threshold: Storage at 97 percent used warns, at 89 it does not")
    func warn() {
        var i = BarPartsTests.inputs
        i.latest?.slow.disk = .init(available: 30, total: 1000)
        #expect(BarPartsTests.parts(.storage, .text, i) == [.reading(.disk), .value("97%", widest: "100%"), .warn, .level(.critical)])
        #expect(BarPartsTests.parts(.storage, .bar, i)?.contains(.warn) == true)
        i.latest?.slow.disk = .init(available: 110, total: 1000)
        #expect(BarPartsTests.parts(.storage, .text, i)?.contains(.warn) == false)
        // CPU, memory and graphics at 90 percent, heat at 90°, a battery at 20 percent unplugged.
        i.values?.cpu = 0.95
        i.values?.ram = 0.9
        #expect(BarPartsTests.parts(.cpu, .graph, i)?.contains(.warn) == true && BarPartsTests.parts(.memory, .text, i)?.contains(.warn) == true)
        #expect(BarPartsTests.parts(.graphics, .text, i)?.contains(.warn) == false && BarPartsTests.parts(.heat, .text, i)?.contains(.warn) == false)
        i.battery = .init(percent: 15, charging: false, minutesLeft: 20)
        #expect(BarPartsTests.parts(.battery, .iconPercent, i)?.contains(.warn) == true)
        i.battery?.charging = true
        #expect(BarPartsTests.parts(.battery, .iconPercent, i)?.contains(.warn) == false)
    }
}
