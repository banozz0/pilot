import Foundation
import CoreGraphics
import PilotCore
@testable import PilotTiler
import Testing
@testable import Pilot

/// `pilot get|set|settings` part 2 (AI helper T5): workspaces, tiling, the bars and the rest of Pilot's own settings,
/// each round-tripped through the store its page binds to, as part 1's are. Every store is the test's own, on throwaway
/// defaults, a fake tiler, a fake menu bar and a fake Pilot switch: no tiler, System Events, launch agent or notes folder
/// of Sven's is touched, nor the running Pilot.
@MainActor
@Suite("Settings schema, part 2")
struct SettingsSchemaPart2Tests {
    /// Pilot's switch as the keys see it; the real one arms and disarms the binds.
    final class FakeSwitch: PilotSwitching {
        var isOn = true
        var flips: [Bool] = []
        func set(_ on: Bool) { flips.append(on); isOn = on }
    }

    /// System Events refusing, as when Pilot is not allowed to automate it.
    final class RefusingAutohide: MenuBarAutohide {
        struct Refused: Error, CustomStringConvertible { var description: String { "not allowed" } }
        func isHidden() async throws -> Bool { throw Refused() }
        func setHidden(_ hidden: Bool) async throws { throw Refused() }
    }

    /// Screen Recording granted, nothing captured: the shelf's pictures never ask or capture in a test.
    struct NoCapture: ShelfCapturing {
        func allowed() -> Bool { true }
        func stills(_ ids: [Int], width: Int) async -> (images: [Int: ShelfStill], refused: Bool) { ([:], false) }
        @MainActor func live(_ id: Int, width: Int, frame: @escaping @MainActor (CGImage) -> Void,
                             ended: @escaping @MainActor () -> Void) async -> ShelfLiveStart { .failed }
    }

    @MainActor final class Rig {
        let defaults = UserDefaults(suiteName: testSuite())!
        let settings: PilotSettings
        let engine = WorkspaceListTests.FakeTiler()
        let block: PilotBlockStore
        let list: WorkspaceList
        let snapshots: WorkspaceSnapshots
        let bar: BarItemsStore
        let topBar: TopBarController
        let wallpaper: WallpaperSettings
        let recommendations: Recommendations
        let pilotSwitch = FakeSwitch()
        let views: StatsViewsStore
        let schema = SettingsSchema()
        let verbs = ControlVerbs()
        var asked: [String] = []
        /// Notes the old folder holds, as the command would find them.
        var notesLeft = 0

        init(allow: Bool = true, autohide: any MenuBarAutohide = TopBarControllerTests.FakeAutohide()) {
            // A saved block, so nothing is carried over from ~/.aerospace.toml.
            defaults.set(try! JSONEncoder().encode(PilotBlock()), forKey: "pilotBlock")
            settings = PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
            let tiler = TilerService(engine: engine, tip: { _ in })
            block = PilotBlockStore(tiler: tiler, defaults: defaults, bundles: { _ in [:] })
            let monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
            list = WorkspaceList(tiler: tiler, block: block, monitors: monitors, defaults: defaults)
            snapshots = WorkspaceSnapshots(observers: EngineObservers(tiler: tiler), defaults: defaults)
            bar = BarItemsStore(defaults: defaults) { [:] }
            topBar = TopBarController(defaults: defaults, autohide: autohide, writeBars: { _ in },
                                      screens: { TopBarControllerTests.screens }, panels: TopBarControllerTests.FakePanels())
            wallpaper = WallpaperSettings(defaults: defaults)
            wallpaper.tick = {}
            recommendations = Recommendations(defaults: defaults)
            views = StatsViewsStore(defaults: defaults)
            schema.registerPart2(settings: settings, list: list, snapshots: snapshots, block: block, bar: bar, topBar: topBar,
                                 wallpaper: wallpaper, recommendations: recommendations, pilotSwitch: pilotSwitch,
                                 dictation: PilotDictationTests.Rig().pilot,
                                 pictures: ShelfPictures(defaults: defaults, capture: NoCapture()),
                                 notesIn: { [unowned self] _ in notesLeft },
                                 changeNotes: { [settings] in settings.notesFolder = NotesFolder.setting($0) })
            schema.registerStats(views: views, bar: bar)
            let schema = schema
            verbs.registerSettings(schema) { [unowned self] key, value, _ in
                asked.append("\(key)=\(value)")
                return allow
            }
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        func value(_ key: String) async throws -> JSONValue {
            let answer = await ask("get", key)
            #expect(answer.ok, "get \(key): \(answer.error?.message ?? "")")
            return try #require(answer.result)
        }
    }

    static let notesFolder = FileManager.default.temporaryDirectory.appending(path: "pilot-notes-\(UUID().uuidString.prefix(8))")

    /// Keys whose store reads UserDefaults on each get, so a value written behind its back is what get reads.
    static let computedOverDefaults: Set = ["update.selfUpdatingCasks"]

    static func sample(_ setting: SettingKey) -> (word: String, value: JSONValue)? {
        if setting.key == "notes.folder" {
            let path = notesFolder.path(percentEncoded: false)
            return (path, .string(path))
        }
        return SettingsSchemaTests.sample(setting)
    }

    @Test("Every part 2 key: set to a valid non-default value, get reads it back from the store, not from UserDefaults")
    func roundTrip() async throws {
        try FileManager.default.createDirectory(at: Self.notesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Self.notesFolder) }
        let rig = Rig()
        // The pill's four settings wait for it to ship (PillFeature).
        #expect(rig.schema.keys.count == 52)
        for setting in rig.schema.sorted {
            let sample = try #require(Self.sample(setting), "no non-default sample for \(setting.key)")
            #expect(try await rig.value(setting.key) != sample.value, "\(setting.key) already holds its sample")
            let set = await rig.ask("set", setting.key, sample.word)
            #expect(set.ok && set.result == sample.value, "set \(setting.key) \(sample.word): \(set.error?.message ?? "\(String(describing: set.result))")")
            if !Self.computedOverDefaults.contains(setting.key) {
                rig.defaults.set("written behind the store's back", forKey: setting.key)
            }
            #expect(try await rig.value(setting.key) == sample.value, "\(setting.key) did not read back")
        }
    }

    @Test("A change lands on the very store objects the pages bind to, the gaps once the tiler took them")
    func sameStores() async {
        let rig = Rig()
        _ = await rig.ask("set", "workspaces.count", "4")
        _ = await rig.ask("set", "tiling.gaps.inner", "12")
        _ = await rig.ask("set", "tiling.gaps.on", "off")
        _ = await rig.ask("set", "windows.dragModifier", "cmd")
        _ = await rig.ask("set", "topBar.on", "on")
        _ = await rig.ask("set", "wallpaper.interval", "60")
        _ = await rig.ask("set", "wallpaper.ownFolders", "eachScreen")
        #expect(rig.list.count == 4 && rig.list.names == ["1", "2", "3", "4"])
        #expect(rig.block.block.gaps.inner == 12 && !rig.block.block.gapsOn)
        // The tiler was handed the gap changes, as the page's slider hands them.
        #expect(rig.engine.applied.count >= 2)
        #expect(rig.settings.dragModifier == .cmd && rig.topBar.isOn)
        #expect(rig.wallpaper.interval == 60 && rig.wallpaper.isScheduled && rig.wallpaper.folders == .perScreen)
        rig.wallpaper.interval = 0
    }

    /// The scrolling layout's keys go while its block stays hidden (Q43; page map, Sven 2026-10-17): unknown, as any other.
    @Test("No scrolling key while Tiling's Scrolling block is hidden")
    func noScrollingKeys() async {
        let rig = Rig()
        for key in ["tiling.scrolling.widths", "tiling.scrolling.newWidth", "tiling.scrolling.sliver", "tiling.scrolling.speed"] {
            #expect(await rig.ask("get", key).error?.code == .unknownKey, "\(key) is still a key")
        }
    }

    @Test("A fresh store reads each part 2 key's schema default")
    func defaults() async throws {
        let rig = Rig()
        for setting in rig.schema.sorted {
            #expect(try await rig.value(setting.key) == setting.standard, "\(setting.key)'s default")
        }
    }

    @Test("Past the range out-of-range, a word the page has no pick for bad-value, and a refused switch says why")
    func refusals() async {
        let rig = Rig()
        for (args, code) in [(["workspaces.count", "10"], ControlError.Code.outOfRange), (["workspaces.count", "0"], .outOfRange),
                             (["tiling.gaps.inner", "101"], .outOfRange), (["tiling.gaps.outer", "-1"], .outOfRange),
                             (["windows.dragModifier", "shift"], .badValue), (["wallpaper.interval", "7"], .badValue),
                             (["bar.colour", "red"], .badValue), (["notes.folder", "/no/such/folder"], .badValue),
                             (["overlayMode", "some"], .badValue)] {
            let answer = await rig.verbs.answer(ControlRequest(verb: "set", args: args), peer: nil)
            #expect(!answer.ok && answer.error?.code == code, "set \(args.joined(separator: " "))")
        }
        #expect(rig.list.count == 9 && rig.block.block.gaps.inner == 0)

        // A Hyper key is never the dictation key too (Q224).
        rig.settings.setLayerKeys([.capsLock, .rightOption], from: .settings)
        let dictationKey = await rig.ask("set", "dictation.tapKey", "rightOption")
        #expect(dictationKey.error?.code == .badValue && rig.settings.dictationKey == .off)
        #expect(await rig.ask("set", "dictation.tapKey", "rightControl").ok && rig.settings.dictationKey == .rightControl)

        let refusing = Rig(autohide: RefusingAutohide())
        let topBar = await refusing.ask("set", "topBar.on", "on")
        #expect(topBar.error?.code == .badValue && topBar.error?.message.contains("Automation") == true && !refusing.topBar.isOn)
    }

    @Test("notes.folder never moves the user's notes: with notes in the old folder it refuses and changes nothing")
    func notesStay() async throws {
        try FileManager.default.createDirectory(at: Self.notesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Self.notesFolder) }
        let rig = Rig()
        rig.notesLeft = 3
        let answer = await rig.ask("set", "notes.folder", Self.notesFolder.path(percentEncoded: false))
        #expect(answer.error?.code == .badValue && answer.error?.message.contains("Notes page") == true)
        #expect(rig.settings.notesFolder == nil)
    }

    @Test("Pilot's switch waits on the Allow gate: Deny answers denied and flips nothing; a plain key never asks")
    func gate() async {
        let denying = Rig(allow: false)
        #expect(await denying.ask("set", "switch.on", "off").error?.code == .denied, "set switch.on")
        #expect(denying.pilotSwitch.flips.isEmpty && denying.pilotSwitch.isOn)
        _ = await denying.ask("set", "topBar.on", "on")
        #expect(denying.asked == ["switch.on=off"] && denying.topBar.isOn)

        let allowing = Rig()
        #expect(await allowing.ask("set", "switch.on", "off").ok && allowing.pilotSwitch.flips == [false])
        // The keys that confirm are the ones the gate asks about, so the prompt has its question.
        let confirms = allowing.schema.sorted.filter(\.confirms).map(\.key)
        #expect(confirms == ["shelf.pictures", "switch.on"])
        #expect(confirms.allSatisfy { ControlGate.Ask.set($0, to: "on") != nil })
    }

    // MARK: the inventory

    /// Every UserDefaults key Pilot reads or writes, as the source names them (HEAD 1f39db2a, read for this task; the
    /// spec's inventory §1 was never written down). A `*` stands for a provider or role.
    static let inventory: Set = [
        "layerKey", "quickTapEscape", "general.bindNudges", "launchAtLogin", "overlayMode", "overlayPicks", "overlay.delay", "system.publicIP",
        "windows.dragModifier", "windows.swipeWorkspaces", "displays.brightnessKeys", "notes.folder", "update.selfUpdatingCasks",
        "translate.home", "translate.other",
        "look.style", "look.theme", "look.glass", "look.transparency", "look.glassBlur", "look.windowBorder", "look.windowBorderWidth",
        "look.windowBorderColour", "look.defocusStrength", "look.defocusDim", "look.defocusShake", "look.defocusShakeSwings",
        "look.defocusShakeWithin", "look.appsShowAs", "look.windowLayout", "look.strength", "look.material",
        "look.cursor", "look.cursorDrawn", "look.cursorShape", "look.cursorSize", "look.cursorColours", "look.cursorFill", "look.cursorOutline", "look.cursorEffectColour", "look.cursorApplied", "look.cursorTrail", "look.cursorRing", "look.cursorRipple",
        "look.cursorSpotlight",
        "clipboard.keepCount", "clipboard.keepDays", "clipboard.saveImages", "clipboard.returnAction", "clipboard.sort",
        "clipboard.sortReversed", "clipboard.ignoredApps",
        "files.showHidden", "files.excluded", "passwords.length", "passwords.symbols", "passwords.clearAfter",
        "folders.repos", "folders.gifs", "giphy.rating", "menu.rootOrder", "menu.rootHidden", "menu.giphyKind", "abilities.added",
        "ai.provider", "ai.fallback", "ai.chatReset", "ai.model.*", "ai.effort.*", "ai.baseURL.*", "ai.models.*",
        "workspaces.count", "workspaces.monitors", "workspaces.layouts", "workspaces.atLoginSession", "snapshots.reopenApps",
        "pilotBlock", "pilotBlock.yabaiFloatsCarried", "pilotBlock.floatNamesMoved",
        "bar.items", "bar.pagePlacement", "bar.background", "bar.colour", "bar.itemColours",
        "topBar.switch", "topBar.leftOut", "topBar.strips", "menuBar.stats", "topBar.settings", "pomodoro.countdown",
        "wallpaper.sources", "wallpaper.order", "wallpaper.seed", "wallpaper.scope", "wallpaper.interval",
        "wallpaper.ownFolders", "wallpaper.folders", "wallpaper.screenSources", "wallpaper.fitShape", "wallpaper.workspaces", "wallpaper.workspaceSources",
        "wallpaper.workspaceImages",
        "recommendations.show", "switch.on",
        "editor.pick", "apps.pick.*", "dictation.model", "dictation.whileSpeaking", "dictation.showIn", "dictation.barSide", "dictation.waveColour", "dictation.copy", "dictation.pauseMedia", "home.blocks", "stats.views", "appWindow.page", "notes.last", "notes.frameMargins", "notes.welcomed",
        "setup.wifi.shown", "setup.bluetooth.shown", "pilot.notifications.decision", "pilot.notifications.macOSOffSaid",
        "AppleInterfaceStyle",
    ]

    /// A blob whose fields are keys under other names.
    static let blobs: [String: [String]] = ["pilotBlock": ["tiling.gaps.on", "tiling.gaps.inner", "tiling.gaps.outer", "tiling.scrolling.centre"],
                                            "topBar.switch": ["topBar.on"],
                                            "stats.views": ["stats.layout", "stats.show"] + StatsCard.allCases.map { "stats.card.\($0.rawValue)" }]
    /// Lists a collection verb edits (`pilot list`, `add`, `remove`).
    static let collections: Set = ["files.excluded", "menu.rootOrder", "menu.rootHidden", "workspaces.monitors", "workspaces.layouts", "bar.items", "wallpaper.sources",
                                   "wallpaper.screenSources", "wallpaper.workspaceSources", "home.blocks"]
    /// Lists no verb reaches yet, only their page; each moves to `collections` when its collection lands.
    static let pageOnlyLists: Set = ["overlayPicks", "clipboard.ignoredApps", "abilities.added", "topBar.leftOut"]
    /// Task T9's: the apps picked for a role.
    static let appPicks: Set = ["editor.pick", "apps.pick.*"]
    /// What Pilot keeps for itself, not a choice of Sven's: the last page, flags done once, a seed, a cache, a record.
    static let internalState: Set = ["ai.models.*", "workspaces.atLoginSession", "pilotBlock.yabaiFloatsCarried", "pilotBlock.floatNamesMoved",
                                     "topBar.strips", "wallpaper.seed", "wallpaper.workspaceImages", "appWindow.page", "menu.giphyKind", "notes.last", "notes.frameMargins", "notes.welcomed",
                                     "setup.wifi.shown", "setup.bluetooth.shown", "pilot.notifications.decision",
                                     "pilot.notifications.macOSOffSaid", "look.cursorApplied"]
    /// Read once to carry a setting over, never written.
    static let carriedOver: Set = ["look.cursor", "wallpaper.folders", "wallpaper.workspaces", "look.strength", "look.material", "menuBar.stats", "topBar.settings", "pomodoro.countdown"]
    /// macOS's own, read only.
    static let macOS: Set = ["AppleInterfaceStyle"]

    @Test("Every UserDefaults key is a registered setting, a blob's keys or on a named list; none unaccounted")
    func inventoryAccounted() {
        let rig = Rig(), part1 = SettingsSchemaTests.Rig()
        let blobKeys = Set(Self.blobs.values.joined())
        #expect(blobKeys.isSubset(of: rig.schema.keys.keys), "a blob names a key no family registers")
        let registered = Set(rig.schema.keys.keys).union(part1.schema.keys.keys)
        func isRegistered(_ key: String) -> Bool {
            key.hasSuffix(".*") ? registered.contains { $0.hasPrefix(key.dropLast()) } : registered.contains(key)
        }
        let listed = Self.collections.union(Self.pageOnlyLists).union(Self.appPicks).union(Self.internalState).union(Self.carriedOver).union(Self.macOS)
        let unaccounted = Self.inventory.filter { key in
            !isRegistered(key) && !listed.contains(key) && !(Self.blobs[key]?.allSatisfy(registered.contains) ?? false)
        }
        #expect(unaccounted.isEmpty, "unaccounted: \(unaccounted.sorted())")
        // A key on a list is not also a setting, and every list names only inventory keys.
        #expect(listed.filter(isRegistered).isEmpty && listed.isSubset(of: Self.inventory))
    }

    @Test("Stats' keys follow the page: card picks and Show in the layout picked now, mixed while cards differ, helpers on Busiest's store")
    func stats() async throws {
        let rig = Rig()
        #expect(await rig.ask("set", "stats.card.storage", "bars").result == .string("bars"))
        #expect(try await rig.value("stats.show") == .string("mixed") && rig.views.views.view(.storage) == .bars)
        #expect(await rig.ask("set", "stats.layout", "compact").ok)
        // Compact keeps its own picks: storage shows its default there, and the cards differ.
        #expect(try await rig.value("stats.card.storage") == .string("number") && rig.views.views.layout == .compact)
        #expect(await rig.ask("set", "stats.show", "line").result == .string("line"))
        #expect(await rig.ask("set", "stats.show", "mixed").error?.code == .badValue)
        #expect(await rig.ask("set", "stats.layout", "comfortable").ok)
        #expect(try await rig.value("stats.card.storage") == .string("bars"))
        #expect(await rig.ask("set", "stats.combineProcesses", "on").result == .bool(true) && rig.bar.settings.combineProcesses)
        // The store saves the views as the page does, so a fresh store over the same defaults reads them.
        #expect(StatsViewsStore(defaults: rig.defaults).views.view(.storage) == .bars)
    }
}
