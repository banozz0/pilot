import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The Menu bar page through the pilot command (CLI W18): items per bar, the order and styles, the extensions' items,
/// the top bar's screens, the readings' look and the clock, and Show exact menu bar items behind Allow. Every store is
/// the test's own on throwaway defaults, with a fake top bar, extensions, gate and pictures hook: nothing asks Screen
/// Recording, captures the screen or touches the running Pilot.
@MainActor
@Suite("Control: the bars")
struct ControlBarTests {
    @MainActor final class Rig {
        let defaults = UserDefaults(suiteName: testSuite())!
        let bar: BarItemsStore
        let topBar: TopBarController
        let verbs = ControlVerbs()
        let schema = SettingsSchema()
        var items = [ExtensionBar.Item(id: "todo", title: "To-do", icon: "✅", hasPage: false)]
        var lacking: Set<BarKind> = [.battery]
        var editorOpens = false
        var nudges = 0, toggles = 0
        var asked: [ControlGate.Ask] = []
        var allow = true
        var topBarUp = true

        init() {
            bar = BarItemsStore(defaults: defaults) { [:] }
            topBar = TopBarController(defaults: defaults, autohide: TopBarControllerTests.FakeAutohide(), writeBars: { _ in },
                                      screens: { TopBarControllerTests.screens }, panels: TopBarControllerTests.FakePanels())
            let gate = ControlGate { [unowned self] ask, _ in
                asked.append(ask)
                return allow
            }
            let reach = BarReach(topBar: { [unowned self] in topBarUp ? topBar : nil }, extensions: { [unowned self] in items },
                                 nudge: { [unowned self] in nudges += 1 }, lacking: { [unowned self] in lacking },
                                 lacksScreenRecording: { [unowned self] in bar.settings.exactMenuItems },
                                 openEditor: { [unowned self] in editorOpens }, exactToggled: { [unowned self] in toggles += 1 },
                                 gate: { gate })
            verbs.registerBar({ [bar] in bar }, reach: reach)
            schema.registerBar(bar, topBar: topBar)
            let schema = schema
            verbs.registerSettings(schema) { _, _, _ in false }
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        /// The answer's result; a failure is recorded with its message.
        func ok(_ verb: String, _ args: String..., sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue? {
            let answer = await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
            #expect(answer.ok, "\(verb) \(args.joined(separator: " ")): \(answer.error?.message ?? "")", sourceLocation: sourceLocation)
            return answer.result
        }

        func rows(_ collection: String) async -> [JSONValue] {
            guard case .array(let rows)? = await ok("list", collection) else { return [] }
            return rows
        }

        func entry(_ kind: BarKind) -> BarEntry { bar.settings.entry(kind) }
    }

    static func field(_ value: JSONValue?, _ name: String) -> JSONValue? {
        guard case .object(let fields)? = value else { return nil }
        return fields[name]
    }

    @Test("The three lists name their row key; add takes --placement, help says so")
    func registered() async throws {
        let rig = Rig()
        for (name, key) in [("bar-items", "item"), ("bar-extensions", "id"), ("top-bar-screens", "screen")] {
            #expect(Self.field(try rig.verbs.schema(collection: name), "rowKey") == .string(key), "\(name)")
        }
        #expect(try rig.verbs.verbs["add"]?.detail?("bar-items")?.contains("[--placement <…>]") == true)
    }

    @Test("bar-items: --placement joins or leaves one bar and keeps the other, as the page's switch; no --placement keeps the drag's rules")
    func placement() async throws {
        let rig = Rig()
        if rig.entry(.heat).on { _ = await rig.ok("remove", "bar-items", "heat") }
        let added = await rig.ok("add", "bar-items", "--item", "heat", "--placement", "menuBar")
        #expect(rig.entry(.heat).on && rig.entry(.heat).placement == .menuBar)
        #expect(Self.field(added, "placement") == .string("menuBar") && Self.field(added, "lacking") == .bool(false))
        _ = await rig.ok("add", "bar-items", "--item", "heat", "--placement", "topBar", "--side", "left", "--index", "1")
        #expect(rig.entry(.heat).placement == .both && rig.entry(.heat).side == .left)
        _ = await rig.ok("remove", "bar-items", "heat", "--placement", "menuBar")
        #expect(rig.entry(.heat).on && rig.entry(.heat).placement == .topBar)
        _ = await rig.ok("remove", "bar-items", "heat")
        #expect(!rig.entry(.heat).on)
        // A menu-bar-only item dragged on joins both bars, as before.
        _ = await rig.ok("add", "bar-items", "--item", "heat", "--placement", "menuBar")
        _ = await rig.ok("add", "bar-items", "--item", "heat")
        #expect(rig.entry(.heat).placement == .both)

        #expect(await rig.ask("add", "bar-items", "--item", "otherApps", "--placement", "menuBar").error?.message.contains("top bar only") == true)
        #expect(await rig.ask("add", "bar-items", "--item", "heat", "--placement", "menuBar", "--side", "left").error?.code == .badValue)
        #expect(await rig.ask("add", "bar-items", "--item", "heat", "--placement", "dock").error?.code == .badValue)
        #expect(await rig.ask("remove", "bar-items", "heat", "--bar", "top").error?.code == .unknownFlag)

        if !rig.entry(.battery).on { _ = await rig.ok("add", "bar-items", "--item", "battery") }
        let battery = await rig.rows("bar-items").first { Self.field($0, "item") == .string("battery") }
        #expect(Self.field(battery, "lacking") == .bool(true) && Self.field(battery, "styles") == .array([.string("iconPercent"), .string("icon")]))
    }

    @Test("bar move --onto takes the item's place in the order, as a drag on the preview; bar style picks one of the item's own")
    func moveAndStyle() async throws {
        let rig = Rig()
        _ = await rig.ok("bar", "move", "network", "--onto", "cpu")
        let kinds = rig.bar.settings.entries.map(\.kind)
        #expect(kinds.firstIndex(of: .network)! < kinds.firstIndex(of: .cpu)!)
        #expect(await rig.ask("bar", "move", "network", "--onto", "cpu", "--side", "left").error?.code == .badValue)
        #expect(await rig.ask("bar", "move", "network", "--to", "cpu").error?.code == .unknownFlag)

        let styled = await rig.ok("bar", "style", "memory", "graph")
        #expect(rig.entry(.memory).style == .graph && Self.field(styled, "style") == .string("graph"))
        _ = await rig.ok("bar", "style", "pilot", "number")
        #expect(rig.entry(.pilot).style == .number)
        let refused = await rig.ask("bar", "style", "storage", "graph")
        #expect(refused.error?.code == .badValue && refused.error?.message.contains("text, bar") == true)
    }

    @Test("pilot bar reads what the page says; edit opens the Menu bar page, and says so when the window cannot open")
    func stateAndEdit() async throws {
        let rig = Rig()
        _ = await rig.ok("add", "bar-items", "--item", "keepAwake", "--placement", "topBar")
        let state = await rig.ok("bar")
        #expect(Self.field(state, "lacking") == .array([.string("battery")]))
        #expect(Self.field(state, "onlyInTopBar").map { "\($0)" }?.contains("keepAwake") == true)
        #expect(Self.field(state, "topBarOn") == .bool(false))
        #expect(Self.field(state, "readingsLook") == .string(rig.bar.settings.readingsLook.rawValue))

        #expect(await rig.ask("bar", "edit").error?.code == .notReady)
        rig.editorOpens = true
        #expect(Self.field(await rig.ok("bar", "edit"), "editing") == .bool(true))
    }

    @Test("bar exact on asks Allow and tells the pictures as the page's switch does; deny changes nothing, off asks nothing")
    func exactItems() async throws {
        let rig = Rig()
        rig.allow = false
        #expect(await rig.ask("bar", "exact", "on").error?.code == .denied)
        #expect(!rig.bar.settings.exactMenuItems && rig.toggles == 0 && rig.asked == [ControlVerbs.exactAsk])

        rig.allow = true
        let on = await rig.ok("bar", "exact", "on")
        #expect(rig.bar.settings.exactMenuItems && rig.toggles == 1)
        #expect(Self.field(on, "exactMenuItems") == .bool(true) && Self.field(on, "needsScreenRecording") == .bool(true))
        // Already on: nothing to ask.
        _ = await rig.ok("bar", "exact", "on")
        _ = await rig.ok("bar", "exact", "off")
        #expect(!rig.bar.settings.exactMenuItems && rig.toggles == 2 && rig.asked.count == 2)
        #expect(await rig.ask("bar", "exact", "maybe").error?.code == .badValue)
    }

    @Test("bar-extensions: placed per bar as the page's rows are, asked at once; no answer text in the rows")
    func extensions() async throws {
        let rig = Rig()
        let row = await rig.rows("bar-extensions").first
        #expect(row == .object(["id": .string("todo"), "title": .string("To-do"), "on": .bool(true), "placement": .string("menuBar")]))
        _ = await rig.ok("add", "bar-extensions", "--id", "todo", "--placement", "topBar")
        #expect(rig.bar.settings.extensionEntry("todo").placement == .both && rig.entry(.extensions).on && rig.nudges == 1)
        _ = await rig.ok("remove", "bar-extensions", "todo", "--placement", "menuBar")
        #expect(rig.bar.settings.extensionEntry("todo").placement == .topBar)
        _ = await rig.ok("remove", "bar-extensions", "todo")
        #expect(!rig.bar.settings.extensionEntry("todo").on && rig.nudges == 3)
        // Already off: nothing written, nothing asked.
        _ = await rig.ok("remove", "bar-extensions", "todo")
        #expect(rig.nudges == 3)
        #expect(await rig.ask("add", "bar-extensions", "--id", "weather").error?.code == .badValue)
    }

    @Test("top-bar-screens: the connected screens, each on until left out; remove leaves one out, add shows it again")
    func screens() async throws {
        let rig = Rig()
        #expect(await rig.rows("top-bar-screens").count == 2)
        let out = await rig.ok("remove", "top-bar-screens", "CU34G4Z")
        #expect(rig.topBar.leftOut == ["CU34G4Z"] && Self.field(out, "on") == .bool(false) && Self.field(out, "height") == .number(30))
        #expect(rig.defaults.stringArray(forKey: "topBar.leftOut") == ["CU34G4Z"])
        _ = await rig.ok("add", "top-bar-screens", "--screen", "CU34G4Z")
        #expect(rig.topBar.leftOut.isEmpty)
        #expect(await rig.ask("remove", "top-bar-screens", "Projector").error?.code == .badValue)
        rig.topBarUp = false
        #expect(await rig.ask("list", "top-bar-screens").error?.code == .notReady)
    }

    @Test("Settings: the readings' look and the clock's pattern, second zone and events, on the store the page binds to")
    func settings() async throws {
        let rig = Rig()
        #expect(await rig.ask("set", "bar.readingsLook", "graph").result == .string("graph"))
        #expect(!rig.bar.settings.isOn(.group, in: .menuBar) && rig.entry(.cpu).style == .graph)
        #expect(await rig.ask("set", "bar.clock", "12 h").result == .string(TopBarClockFormat.time12.rawValue))
        #expect(await rig.ask("set", "bar.clock", "EEE HH:mm").result == .string("EEE HH:mm") && rig.bar.settings.clock.rawValue == "EEE HH:mm")
        #expect(await rig.ask("set", "bar.clock", " ").error?.code == .badValue)
        #expect(await rig.ask("set", "bar.clockZone", "Europe/Malta").result == .string("Europe/Malta") && rig.bar.settings.clockZone == "Europe/Malta")
        #expect(await rig.ask("set", "bar.clockZone", "none").result == .string("none") && rig.bar.settings.clockZone == nil)
        #expect(await rig.ask("set", "bar.clockZone", "Mars/Olympus").error?.code == .badValue)
        #expect(await rig.ask("set", "bar.clockEvents", "on").result == .bool(true) && rig.bar.settings.clockEvents)
    }
}
