import Foundation
import Observation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// This Mac's menu-bar items (card agent-bo-95422833): the choices import Stats' once and persist; the items follow the
/// choices; the sampler is watched while any item is on and not at all with every item off. A fake host stands in for
/// the menu bar, so no test puts an item in Sven's.
@MainActor
@Suite("Menu-bar status items")
struct MenuBarStatusItemsTests {
    /// Sven's eu.exelban.Stats on 2026-10-05 (as in PilotCoreTests' MenuBarStatsTests).
    nonisolated(unsafe) static let svensStats: [String: Any] = [
        "Battery_state": 0, "Bluetooth_position": 6, "CPU_position": 0, "CPU_state": 1, "CombinedModules": 1, "Disk_position": 3,
        "Disk_state": 0, "GPU_position": 1, "GPU_state": 0, "Network_position": 5, "Network_state": 0, "RAM_position": 2,
        "Sensors_position": 4, "Sensors_state": 0, "Sensors_widget": "mini", "RAM_combinedProcesses": 1,
    ]

    /// Sven's menuBar.stats as saved on his Mac on 2026-10-06 (as in PilotCoreTests' BarItemsTests).
    static let svensSaved = #"{"items":[{"stat":"cpu","on":true,"style":"text"},{"stat":"gpu","on":false,"style":"text"},{"stat":"ram","on":true,"style":"text"},{"stat":"disk","on":false,"style":"text"},{"stat":"sensors","on":false,"style":"text"},{"stat":"network","on":false,"style":"text"},{"stat":"battery","on":false,"style":"text"},{"stat":"bluetooth","on":false,"style":"text"}],"combined":true,"combineProcesses":true}"#

    static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: testSuite()))
    }

    @Test("The first start carries the user's saved readings and pomodoro switch over once, never asking Stats, and keeps the old keys; later starts read bar.items")
    func carriesOver() throws {
        let defaults = try Self.defaults()
        defaults.set(Data(Self.svensSaved.utf8), forKey: "menuBar.stats")
        defaults.set(false, forKey: "pomodoro.countdown")
        var asked = 0
        let first = BarItemsStore(defaults: defaults) { asked += 1; return Self.svensStats }
        #expect(asked == 0)
        #expect(first.settings == BarSettings.migrated(stats: try JSONDecoder().decode(MenuBarStats.Choices.self, from: Data(Self.svensSaved.utf8)), topBar: nil, pomodoroCountdown: false))
        #expect(defaults.data(forKey: "menuBar.stats") != nil && defaults.object(forKey: "pomodoro.countdown") as? Bool == false)
        first.settings.set(.heat, on: true)
        first.settings.move(.heat, to: 0)
        let second = BarItemsStore(defaults: defaults) { asked += 1; return [:] }
        #expect(second.settings == first.settings && second.settings.entries.first?.kind == .heat && asked == 0)
    }

    @Test("A Mac that never saved readings takes the Stats app's choices once; one without Stats starts from round 4's defaults")
    func firstStart() throws {
        var asked = 0
        let withStats = BarItemsStore(defaults: try Self.defaults()) { asked += 1; return Self.svensStats }
        #expect(asked == 1)
        #expect(withStats.settings == BarSettings.migrated(stats: MenuBarStats.fromStats(Self.svensStats), topBar: nil, pomodoroCountdown: nil))
        #expect(BarItemsStore(defaults: try Self.defaults()) { [:] }.settings == .defaults)
    }

    @Test("A change notifies what observes the items")
    func observed() throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { [:] }
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = store.settings } onChange: { fired += 1 }
        store.settings.set(.storage, on: true)
        #expect(fired == 1)
    }

    final class Host: StatusItemHosting {
        var shown: [[StatusItemContent]] = []
        var presented: [[BarKind]] = []
        var menus: [(kinds: [BarKind], rows: [BarMenuRow], perform: (BarAction) -> Void)] = []
        var clicked: (StatusItemContent, _ right: Bool) -> Void = { _, _ in }
        func show(_ items: [StatusItemContent]) { shown.append(items) }
        func menu(_ rows: [BarMenuRow], for kinds: [BarKind], perform: @escaping (BarAction) -> Void) { menus.append((kinds, rows, perform)) }
        func present(_ popover: AnyView, for kinds: [BarKind]) { presented.append(kinds) }
        var presentedExtensions: [String] = []
        func present(_ popover: AnyView, extension id: String) { presentedExtensions.append(id) }
        var kinds: [[BarKind]]? { shown.last?.map(\.kinds) }
    }

    /// The items' sources on fakes: the readers' sampler watch on the test's sampler, a fake power assertion, fake
    /// layouts, a timer of its own; nothing real is read or changed.
    static func sources(_ sampler: SystemSampler, power: SetupKeepAwakeTests.FakePower = .init(),
                        layouts: BarReadingsTests.Sources = .init(), audio: SetupSoundTests.FakeAudio = .init(),
                        timer: ExtensionTimer = ExtensionTimer(),
                        observers: EngineObservers = EngineObservers(), clock: @escaping () -> Date = Date.init,
                        calendar: ClockCalendar = ClockCalendar { ClockPopoverTests.FakeStore() },
                        appMenus: AppMenus = AppMenus(), menuApps: MenuApps = MenuApps(), statusLights: StatusLights = .shared,
                        extensionBar: ExtensionBar = ExtensionBar(folder: FileManager.default.temporaryDirectory.appending(path: "pilot-no-extensions-\(UUID().uuidString)"))) -> BarSources {
        // The macOS menu bar always holds the extensions' bar items (Surfaces v2): on an empty folder here, never Sven's.
        let readings = BarReadings(sound: SetupSound(audio: audio), look: Look(inputSources: layouts), menuApps: menuApps, appMenus: appMenus,
                                   readBattery: { nil }, readWiFi: { nil }, clock: clock,
                                   watchStats: { stats in Task { await sampler.watch(every: .milliseconds(10), needs: [], stats: stats) } },
                                   calendar: calendar, extensionBar: extensionBar, statusLights: statusLights)
        return BarSources(readings: readings, observers: observers, sampler: sampler, keepAwake: KeepAwake(power: power),
                          timer: timer, extensionBar: extensionBar, pilotTitle: { "2" })
    }

    @Test("An open popover keeps the process list read every second; closing it ends that, and only that")
    func popoverWatch() async throws {
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        let watch = PopoverWatch(sampler: sampler, interval: .milliseconds(10))
        watch.opened([.gpu])
        #expect(try await SystemSamplerTests.wait { counter.reads >= 3 })
        #expect(counter.processReads == 0)
        watch.closed()
        watch.opened([.cpu])
        // The list is read at once, then every process interval (10 s), while the popover shows it.
        #expect(try await SystemSamplerTests.wait { counter.processReads >= 1 && !sampler.busiestCPU.isEmpty })
        watch.closed()
        #expect(try await SystemSamplerTests.stopsReading(sampler) { counter.reads })
        #expect(sampler.busiestCPU.isEmpty)
    }

    @Test("A reading popover's watch ends when the popover's view goes, even with no onDisappear")
    func popoverWatchReleased() async throws {
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        var watch: PopoverWatch? = PopoverWatch(sampler: sampler, interval: .milliseconds(10))
        watch?.opened([.cpu])
        #expect(try await SystemSamplerTests.wait { counter.reads >= 3 })
        watch = nil
        #expect(try await SystemSamplerTests.stopsReading(sampler) { counter.reads })
        #expect(watch == nil)
    }

    @Test("Stats' Combined processes comes over: the busiest by RAM count an app's helpers under the app, the CPU list does not")
    func combinedProcesses() async throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { Self.svensStats }
        let sampler = SystemSampler(processInterval: .milliseconds(10), read: { parts in
            var raw = SystemSamplerTests.raw(1, slow: false, processes: false)
            if parts.contains(.processes) {
                raw.processes = KillProcess.parse("1 10.0 100000 Google Chrome\n2 5.0 900000 Google Chrome Helper (Renderer)\n3 20.0 800000 Finder")
            }
            return raw
        }, fetchPublicIP: { nil })
        let items = MenuBarStatusItems(store: store, host: Host())
        items.start(Self.sources(sampler))
        let listing = Task { await sampler.watch(every: .milliseconds(10), needs: .processes) }
        #expect(try await SystemSamplerTests.wait { !sampler.busiestMemory.isEmpty })
        #expect(sampler.busiestMemory.first?.name == "Google Chrome" && sampler.busiestMemory.first?.value == "977 MB")
        #expect(sampler.busiestCPU.map(\.name) == ["Finder", "Google Chrome", "Google Chrome Helper (Renderer)"])
        store.settings.combineProcesses = false
        #expect(try await SystemSamplerTests.wait { sampler.busiestMemory.first?.name == "Google Chrome Helper (Renderer)" })
        listing.cancel()
        await listing.value
        items.stop()
    }

    @Test("The items follow the store: the group as one, one each without it, gone while the top bar shows them; no reading shown, nothing reads")
    func itemsFollowChoices() async throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { Self.svensStats }
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        let host = Host()
        let items = MenuBarStatusItems(store: store, host: host)
        let topBar = TopBarOn()
        store.isTopBarOn = { topBar.on }
        items.start(Self.sources(sampler))
        // Pilot's own icon first; the workspaces item waits for the tiler, which the fakes never start.
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu, .memory], [.capture], [.timer]] })
        store.settings.set(.group, on: false)
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu], [.memory], [.capture], [.timer]] })
        // Items placed in both leave the menu bar while the top bar is on; one placed in the menu bar stays.
        store.settings.set(.memory, placement: .menuBar)
        topBar.on = true
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.memory], [.capture]] })
        topBar.on = false
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu], [.memory], [.capture], [.timer]] })
        // A reading shown, the sampler reads; none, it stops.
        #expect(try await SystemSamplerTests.wait { counter.reads >= 3 })
        store.settings.set(.cpu, on: false)
        store.settings.set(.memory, on: false)
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.capture], [.timer]] })
        #expect(try await SystemSamplerTests.stopsReading(sampler) { counter.reads })
        let stopped = counter.reads
        store.settings.set(.network, on: true)
        #expect(try await SystemSamplerTests.wait { counter.reads > stopped })
        items.stop()
        #expect(host.kinds == [])
    }

    @Test("A tick that changes nothing an item shows redraws nothing; a style change redraws the same items in place")
    func redrawOnlyChanges() async throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { Self.svensStats }
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        let host = Host()
        let items = MenuBarStatusItems(store: store, host: host)
        items.start(Self.sources(sampler))
        // The fake's CPU share and RAM hold still from the second reading on.
        #expect(try await SystemSamplerTests.wait { counter.reads >= 3 })
        let settled = host.shown.count
        let reads = counter.reads
        #expect(try await SystemSamplerTests.wait { counter.reads >= reads + 5 })
        #expect(host.shown.count == settled)
        store.settings.set(.cpu, style: .bar)
        #expect(try await SystemSamplerTests.wait { host.shown.count == settled + 1 })
        // A new install has Capture's menu on in the menu bar (Q368).
        #expect(host.kinds == [[.pilot], [.cpu, .memory], [.capture], [.timer]])
        #expect(host.shown.last?[1].parts.first?.last.map { if case .bar = $0 { true } else { false } } == true)
        items.stop()
    }

    @Test("A click opens the item's popover, the group's for the group, Pilot's the dropdown; the layout cycles and Keep awake switches without one")
    func clicks() throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { [:] }
        let host = Host(), power = SetupKeepAwakeTests.FakePower(), layouts = BarReadingsTests.Sources()
        let sources = Self.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()), power: power, layouts: layouts)
        let items = MenuBarStatusItems(store: store, host: host)
        items.start(sources)
        sources.readings.look.followLayouts()
        let click = { (kinds: [BarKind], group: Bool) in host.clicked(StatusItemContent(kinds: kinds, parts: [], isGroup: group), false) }
        click([.cpu, .memory, .network], true)
        click([.memory], true)
        click([.timer], false)
        click([.heat], false)
        #expect(host.presented == [[.cpu, .memory, .network], [.memory], [.timer], [.heat]])
        // The keyboard layout opens its popover (Sven on build 36), switching nothing.
        click([.keyboardLayout], false)
        #expect(host.presented.last == [.keyboardLayout] && layouts.selected.isEmpty)
        click([.keepAwake], false)
        #expect(sources.keepAwake.isOn && power.held.count == 1)
        click([.keepAwake], false)
        #expect(!sources.keepAwake.isOn && power.held.isEmpty)
        click([.spacer], false)
        #expect(host.presented.count == 5)
        // Pilot's own item opens the dropdown.
        click([.pilot], false)
        #expect(host.presented.last == [.pilot])
        items.stop()
    }

    @Test("Capture's click hangs its own menu, never a popover; a row runs its registered action by id, and its right-click adds the bar's rows")
    func captureClick() throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { [:] }
        let host = Host()
        var sources = Self.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()))
        var ran: [String] = []
        sources.registered = { ids in Dictionary(uniqueKeysWithValues: ids.filter { $0 != "captures.editLast" }.map { ($0, $0 == "captures.area" ? "⇪ S" : nil) }) }
        sources.runAction = { ran.append($0) }
        // The registry's labels repeat ids Capture's menu names: each is asked for once.
        sources.captureLabels = { ["captures.area": "Capture area", "captures.magnifier": "Pixel magnifier"] }
        let items = MenuBarStatusItems(store: store, host: host)
        items.start(sources)
        host.clicked(StatusItemContent(kinds: [.capture], parts: [], isGroup: false), false)
        #expect(host.presented.isEmpty && host.menus.count == 1)
        let menu = try #require(host.menus.last)
        #expect(menu.rows.first == .action("Capture area", .run("captures.area"), hint: "⇪ S"))
        let titles = { (rows: [BarMenuRow]) in rows.compactMap { if case .action(let title, _, _, _) = $0 { title } else { nil } } }
        #expect(!titles(menu.rows).contains("Edit last capture") && !titles(menu.rows).contains("Remove from bar"))
        #expect(titles(menu.rows).contains("Pixel magnifier"))
        menu.perform(.run("captures.area"))
        #expect(ran == ["captures.area"])
        host.clicked(StatusItemContent(kinds: [.capture], parts: [], isGroup: false), true)
        #expect(titles(host.menus.last?.rows ?? []).contains("Remove from bar") && host.menus.last?.rows.first == menu.rows.first)
        items.stop()
    }

    @Test("The Timer item shows in the menu bar while the top bar is off, leaves it while on, and goes when switched off")
    func timerItem() throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { [:] }
        let topBar = TopBarOn()
        store.isTopBarOn = { topBar.on }
        #expect(store.shows(.timer, in: .menuBar))
        topBar.on = true
        #expect(!store.shows(.timer, in: .menuBar) && store.shows(.pilot, in: .menuBar))
        topBar.on = false
        #expect(store.shows(.timer, in: .menuBar))
        store.settings.set(.timer, on: false)
        #expect(!store.shows(.timer, in: .menuBar))
    }

    @Test("Volume: a click opens the Sound popover, an Option-click mutes or unmutes; a right-click opens its menu, whose Mute mutes (Sven on build 21; cards agent-bo-95422993 and 95423010)")
    func volumeClicks() throws {
        let store = BarItemsStore(defaults: try Self.defaults()) { [:] }
        store.settings.set(.volume, on: true)
        let host = Host(), audio = SetupSoundTests.FakeAudio()
        let items = MenuBarStatusItems(store: store, host: host)
        items.start(Self.sources(SystemSamplerTests.sampler(.init()), audio: audio))
        let volume = StatusItemContent(kinds: [.volume], parts: [], isGroup: false)
        items.click(volume, option: false)
        #expect(host.presented == [[.volume]] && audio.setMutedCalls.isEmpty)
        items.click(volume, option: true)
        #expect(audio.mutes[10] == true && host.presented.count == 1)
        items.click(volume, option: true)
        #expect(audio.mutes[10] == false && host.presented.count == 1)
        host.clicked(volume, true)
        #expect(host.presented.count == 1 && host.menus.map(\.kinds) == [[.volume]] && audio.setMutedCalls.count == 2)
        host.menus[0].perform(.click(.toggleMute))
        #expect(audio.mutes[10] == true)
        items.stop()
    }

    /// Sven's bar.items on 2026-10-07, carried over from his old top bar: these are on, placed in the top bar only.
    static let svensTopBarOnly: [BarKind] = [.group, .heat, .volume, .keyboardLayout, .timer, .clock]

    static func svensBar(_ defaults: UserDefaults) -> BarItemsStore {
        let store = BarItemsStore(defaults: defaults) { [:] }
        for kind in svensTopBarOnly + [.otherApps] {
            store.settings.set(kind, on: true)
            store.settings.set(kind, placement: .topBar)
        }
        return store
    }

    /// The test sampler with a CPU temperature, so Heat has a reading to draw.
    static func warmSampler() -> SystemSampler {
        let counter = SystemSamplerTests.Counter()
        return SystemSampler(historyLength: 60, read: { parts in
            var raw = SystemSamplerTests.raw(Double(counter.bump(slow: false, processes: false)), slow: false, processes: false)
            if parts.contains(.sensors) { raw.sensors = .init(temperatures: ["Tp01": 50], fans: [], power: nil) }
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
    }

    @Test("With the top bar off, every item on in the top bar only (Group, Heat, Volume, Keyboard layout, Timer, Clock) is named, and Show in the menu bar draws each as a menu bar item, keeping the top bar; other apps stay in the top bar, their items being the menu bar's own (card agent-bo-95422993, G1)")
    func topBarOnlyToMenuBar() async throws {
        let store = Self.svensBar(try Self.defaults())
        store.settings.set(.group, on: false)
        let host = Host(), items = MenuBarStatusItems(store: store, host: host)
        items.start(Self.sources(Self.warmSampler()))
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu], [.memory], [.network], [.capture]] })
        let hidden = store.settings.onlyInTopBar
        #expect(hidden == [.heat, .volume, .keyboardLayout, .clock, .timer])
        store.settings.showInMenuBar(hidden)
        #expect(store.settings.onlyInTopBar.isEmpty)
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu], [.memory], [.network], [.heat], [.volume], [.keyboardLayout], [.capture], [.clock], [.timer]] })
        #expect(hidden.allSatisfy { store.settings.shows($0, in: .topBar, topBarOn: true) })
        // The Group, on in the top bar only, is hidden too; shown, it gathers the menu bar's readings into one item.
        store.settings.set(.group, on: true)
        #expect(store.settings.onlyInTopBar == [.group])
        store.settings.showInMenuBar([.group])
        #expect(try await SystemSamplerTests.wait { host.kinds == [[.pilot], [.cpu, .memory, .network, .heat], [.volume], [.keyboardLayout], [.capture], [.clock], [.timer]] })
        #expect(host.shown.last?.first { $0.kinds.count > 1 }?.isGroup == true)
        #expect(!store.settings.shows(.otherApps, in: .menuBar, topBarOn: false))
        items.stop()
    }

    @Test("The Timer item in the menu bar shows a running extension timer's countdown there; it reads off while the item is in the top bar only (card agent-bo-95422993, G2)")
    func timerShowsCountdown() async throws {
        let store = Self.svensBar(try Self.defaults())
        let clock = ExtensionTimerTests.Clock()
        let timer = ExtensionTimer(now: { clock.now })
        let host = Host(), items = MenuBarStatusItems(store: store, host: host)
        items.start(Self.sources(SystemSamplerTests.sampler(.init()), timer: timer))
        #expect(!store.settings.isOn(.timer, in: .menuBar))
        store.settings.set(.timer, in: .menuBar, on: true)
        #expect(store.settings.isOn(.timer, in: .menuBar) && store.settings.shows(.timer, in: .topBar, topBarOn: true))
        let shows = { (title: String) in host.shown.last?.first { $0.kinds == [.timer] }?.parts.joined().contains(.value(title, widest: "88:88")) == true }
        timer.startFocus()
        #expect(try await SystemSamplerTests.wait { shows("25:00") })
        clock.now += 61
        timer.tick()
        #expect(try await SystemSamplerTests.wait { shows("23:59") })
        store.settings.set(.timer, in: .menuBar, on: false)
        #expect(!store.settings.shows(.timer, in: .menuBar, topBarOn: false) && store.settings.shows(.timer, in: .topBar, topBarOn: true))
        timer.stop()
        items.stop()
    }

    /// The top bar's switch, observed as TopBarController's is.
    @Observable final class TopBarOn { var on = false }
}
