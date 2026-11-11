import AppKit
import Foundation
import Darwin
import Synchronization
import PilotCore

/// Early, explicit recording composition. Never constructs Engine, Look, a live bar controller or the desktop registry.
struct BarFixture: Decodable {
    let root, home, suite, state, packs, socket, control, nativeState: String
    let binding: ThemeBinding
    let baseline: ThemeNativeAppearance
    let screens: [Screen]
    let loadProbe: Bool?
    struct Screen: Decodable {
        let name: String
        let x, y, width, height, strip, notch: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    @MainActor static func serve(_ manifest: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard !env.keys.contains(where: { $0.hasPrefix("PILOT_SANDBOX") || $0 == "PILOT_THEME_FIXTURE" }),
              env["PILOT_LIVE"] == nil, env["PILOT_FOCUS"] == nil else { throw ThemeFailure("incompatible bar fixture environment") }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let paths = [manifest, config.root, config.home, config.state, config.packs, config.socket, config.control, config.nativeState, config.binding.root]
        guard paths.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == $0 }),
              paths.filter({ $0 != config.root }).allSatisfy({ $0.hasPrefix(config.root + "/") }),
              config.home == config.root + "/home", env["CFFIXED_USER_HOME"] == config.home, NSHomeDirectory() == config.home,
              config.suite.hasPrefix("dev.banozz.pilot.strip-"), config.suite.allSatisfy({ $0.isLetter || $0.isNumber || ".-".contains($0) }),
              Set(paths).count == paths.count, config.socket.utf8.count < 100,
              [config.state, config.packs, config.binding.root, config.home].allSatisfy({ !config.socket.hasPrefix($0 + "/") }),
              !config.screens.isEmpty, Set(config.screens.map(\.name)).count == config.screens.count,
              config.screens.allSatisfy({ [$0.x, $0.y, $0.width, $0.height, $0.strip, $0.notch].allSatisfy(\.isFinite) && $0.width >= 1 && $0.height >= 1 && $0.notch >= 0 }) else { throw ThemeFailure("explicit canonical bar fixture roots/home/suite/screens/socket required") }
        for path in [config.home, config.state, config.packs, config.binding.root] {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw ThemeFailure("missing isolated fixture directory") }
        }
        let defaults = try BarFixtureDefaults(root: config.home, suite: config.suite)
        let discovery = Mutex((stats: 0, extensions: 0))
        let store = BarItemsStore(defaults: defaults, statsPrefs: {
            discovery.withLock { $0.stats += 1 }; return [:]
        }, extensionOrder: {
            discovery.withLock { $0.extensions += 1 }; return ["fixture"]
        })
        if config.loadProbe != true {
            try store.requireWritable()
            // This fixture requires explicit extension places. Production migration uses the injected order above.
            if let bytes = defaults.data(forKey: BarItemsStore.key) {
                let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                let entries = raw?["entries"] as? [[String: Any]] ?? []
                let placed = Set(entries.filter { $0["kind"] as? String == "extension" }.compactMap { $0["extension"] as? String })
                guard store.settings.extensionItems.allSatisfy({ !($0.on && $0.placement != .menuBar) || placed.contains($0.id) }) else { throw ThemeFailure("fixture requires explicit extension order") }
            }
        }
        func control() throws -> [String: String] {
            let relative = String(config.control.dropFirst(config.root.count + 1))
            guard let bytes = try ThemeFiles.read(root: config.root, path: relative).bytes else { throw ThemeFailure("missing fixture control") }
            return try JSONDecoder().decode([String: String].self, from: bytes)
        }
        func record(_ text: String) throws {
            let file = try ThemeFiles.read(root: config.state, path: "effects.jsonl")
            _ = try ThemeFiles.write((file.bytes ?? Data()) + Data((text + "\n").utf8), over: file)
        }
        let gate = ControlGate { ask, _ in
            guard ["Apply theme", "Restore default appearance"].contains(ask.title) else { return false }
            do {
                let values = try control()
                print("BAR Allow: \(ask.text)"); fflush(stdout)
                if values["hold"] == "yes" {
                    try Data(ask.text.utf8).write(to: URL(fileURLWithPath: config.root + "/asked"))
                    for _ in 0..<300 {
                        if FileManager.default.fileExists(atPath: config.root + "/go") { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard FileManager.default.fileExists(atPath: config.root + "/go") else { return false }
                }
                return values["allow"] == "yes"
            } catch { return false }
        }
        let relativeNative = String(config.nativeState.dropFirst(config.root.count + 1))
        func readNative() throws -> ThemeNativeAppearance {
            try store.requireWritable()
            guard let bytes = try ThemeFiles.read(root: config.root, path: relativeNative).bytes else { throw ThemeFailure("missing recording native state") }
            var value = try JSONDecoder().decode(ThemeNativeAppearance.self, from: bytes)
            try value.validate()
            try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(value))
            guard value.bar == nil else { throw ThemeFailure("bar state must come only from the injected item store") }
            value.bar = .init(store.settings.preset)
            return value
        }
        if config.loadProbe != true { _ = try readNative() }; try config.baseline.validate()
        let owner = ThemeCoordinator(store: ThemePackStore(root: config.packs, writableRoot: config.packs), binding: config.binding,
            stateRoot: config.state, effects: .init(kind: "recording bar fixture", refresh: { try record("refresh recorded"); return "recorded only" }, appearance: { _ in }),
            native: .init(read: readNative, write: { value in
                try store.requireWritable()
                try value.validate()
                guard let bar = value.bar else { throw ThemeFailure("missing bound bar capability") }
                var paletteMaterial = value; paletteMaterial.bar = nil
                _ = try ThemeFiles.write(ThemeDigest.encoded(paletteMaterial), over: ThemeFiles.read(root: config.root, path: relativeNative))
                if store.settings.preset != bar.configuration { store.settings.preset = bar.configuration }
                guard defaults.synchronize() else { throw ThemeFailure("isolated defaults write failed") }
                try record(String(decoding: ThemeDigest.encoded(value), as: UTF8.self))
            }, baseline: { config.baseline }), gate: gate,
            style: { (try? control()["style"]) ?? "invalid" }, context: { ThemeDigest.of(try Data(contentsOf: URL(fileURLWithPath: manifest))) },
            fault: { stage in
                let values = try control()
                if values["crash"] == stage { fflush(stdout); _exit(86) }
                if values["fail"] == stage { throw ThemeFailure("injected \(stage)") }
            }, fixtureRoot: config.root)
        let pill = PillLayoutStore(defaults: defaults), dropdown = DropdownLayoutStore(defaults: defaults)
        let schema = SettingsSchema(); schema.registerBarAppearance(store); schema.registerPill(pill); schema.registerStatsBar(store); schema.registerDropdown(dropdown)
        let verbs = ControlVerbs(); verbs.registerCore(); verbs.registerSettings(schema)
        verbs.registerBar({ store }, reach: .init(topBar: { nil }, extensions: { [.init(id: "fixture", title: "Fixture", icon: "square", hasPage: false)] }, nudge: {}, lacking: { [] }, lacksScreenRecording: { false }, openEditor: { false }, exactToggled: {}, gate: { gate }))
        verbs.registerThemes { owner }
        // Native controls call these same seams directly, without the bar verb's outer guard.
        verbs.register(ControlVerb("bar-fixture-edit", help: "Call the shared native bar writer", flags: []) { call throws(ControlError) in
            let args = call.arguments()
            switch try args.word(0, "writer") {
            case "preset": try store.choosePreset(try args.word(1, "preset"))
            case "geometry": try store.applyGeometry(try args.word(1, "JSON"))
            case "field":
                guard let value = Double(try args.word(2, "points")) else { throw ControlError(.badValue, "points required") }
                try store.setGeometry(try args.word(1, "field"), value: value)
            case "binding":
                store.settings.combineProcesses.toggle()
                store.background = .glass; store.colour = .theme
                store.itemColours.toggle(); store.pagePlacement = .topBar
                return .string("binding probe completed")
            default: throw ControlError(.badValue, "unknown fixture writer")
            }
            return .string("ok")
        })
        // One round of the extensions' bar items as a surface holds them (spec desktop-controls T7, step 7): the fixture
        // root's `extensions` folder, none placed on a bar; `pill` holds the pill's asked ids (only while its Extensions view
        // shows), `menu` the Pilot menu's while open (only while its Extensions card shows), `closed` nothing. Recorded runs,
        // no Keychain. Answers which ran and what the surface lists.
        verbs.register(ControlVerb("bar-fixture-extensions", help: "One extension round as the pill, the open Pilot menu or nothing holds them", flags: []) { call throws(ControlError) in
            let surface = try call.arguments().word(0, "pill, menu or closed")
            let ran = Mutex<[String]>([])
            let bar = ExtensionBar(folder: URL(fileURLWithPath: config.root).appending(path: "extensions"),
                                   storage: ExtensionStorage(data: URL(fileURLWithPath: config.state).appending(path: "extension-data"),
                                                             cache: URL(fileURLWithPath: config.state).appending(path: "extension-cache"),
                                                             keychain: ExtensionCheck.NoKeychain()),
                                   run: { surface, _ in
                                       ran.withLock { $0.append(surface.command.id.extension) }
                                       return .bar(Extension.BarAnswer(text: "\(surface.command.id.extension) 42"))
                                   })
            bar.shows = { _, _ in false }
            switch surface {
            case "pill": bar.hold(Set(pill.layout.asked), for: "pill")
            case "menu": bar.hold(Set(dropdown.layout.asked), for: "dropdown")
            case "closed": break
            default: throw ControlError(.badValue, "pill, menu or closed, not \(surface)")
            }
            await bar.round()
            let listed: [String] = surface == "pill"
                ? PillDrop.extensions(pill.layout.extensions, bar: bar).map { "\($0.name) \($0.value)" }
                : DropdownBlocks.extensions(dropdown.layout.asked, bar: bar).map { "\($0.title) \($0.text)" }
            return .object(["view": .string(pill.layout.current.rawValue), "asked": .array(ran.withLock { $0 }.map(JSONValue.string)),
                            "extensions": .array(listed.map(JSONValue.string))])
        })
        // The drops' open set after each step, through DropKeys alone (spec desktop-controls T5: the pill goes alone).
        verbs.register(ControlVerb("bar-fixture-drops", help: "Replay drop toggles and Escapes through DropKeys", flags: []) { call throws(ControlError) in
            var keys = DropKeys()
            var steps: [JSONValue] = []
            for word in call.words {
                if word == "escape" { _ = keys.escape(at: 0) }
                else if let drop = BarDropKind(rawValue: word) { keys.toggle(drop) }
                else { throw ControlError(.badValue, "a drop (\(BarDropKind.allCases.map(\.rawValue).joined(separator: ", "))) or escape, not \(word)") }
                steps.append(.object(["step": .string(word), "open": .array(BarDropKind.allCases.filter(keys.open.contains).map { .string($0.rawValue) }),
                                      "focused": keys.focused.map { .string($0.rawValue) } ?? .null]))
            }
            return .array(steps)
        })
        verbs.register(ControlVerb("bar-fixture", help: "Read injected saved bar state and supplied-screen placement", flags: []) { _ throws(ControlError) in
            do {
                guard defaults.synchronize() else { throw ThemeFailure("isolated defaults write failed") }
                let inputs = try control()
                let frames: [JSONValue] = config.screens.map { screen in
                    let frame = BarPresetGeometry.frame(store.settings.preset, screen: screen.rect, strip: screen.strip, notch: screen.notch)
                    let sides = store.settings.preview(.topBar).top ?? [:]
                    let island = store.settings.preset?.preset == .threeIslands
                    // Fake measurements are explicit sources; the production layout and final visibility are unchanged.
                    let widths = sides.mapValues { slots in slots.map { slot -> CGFloat in
                        if inputs["hidden:" + slot.item.rawValue] == "yes" { return 0 }
                        if island, case .extension = slot.item {
                            var parts = BarInputs()
                            if inputs["extensionVisible"] == "yes" {
                                parts.extensionBars = [.init(id: "fixture", title: "Fixture", answer: .init(text: "Ready"))]
                            }
                            if BarParts.parts(slot, parts, settings: store.settings) == nil { return 0 }
                        }
                        return max(0, min(10_000, Double(inputs["width:" + slot.item.rawValue] ?? "72") ?? 72))
                    } }
                    let least: [TopBarSide: [CGFloat]] = Dictionary(uniqueKeysWithValues: sides.map { side, slots in
                        (side, slots.enumerated().map { i, slot in min(widths[side]![i], CGFloat(max(0, Double(inputs["least:" + slot.item.rawValue] ?? "10000") ?? 10000))) })
                    })
                    let row = TopBarRow(spacing: store.settings.preset?.spacing ?? 8, gap: 12, islands: island ? store.settings.preset : nil)
                    let plan = row.arrange(widths, least: least, room: max(0, frame.width - (island ? 0 : 2 * (store.settings.preset?.padding ?? 6))), more: 24, height: frame.height)
                    func rect(_ r: CGRect) -> JSONValue { .array([r.minX, r.minY, r.width, r.height].map { .number(Double($0)) }) }
                    let groups = TopBarSide.allCases.map { side -> (String, JSONValue) in
                        guard let group = plan.groups[side] else { return (side.rawValue, .null) }
                        let panel = BarPresetGeometry.islandFrame(group, in: frame)
                        let parent = NSView(frame: CGRect(origin: .zero, size: group.size))
                        let clip = TopBarIslandClip(NSView(frame: CGRect(origin: .zero, size: frame.size)))
                        clip.frame = parent.bounds; clip.canvas = frame; clip.crop = group; parent.addSubview(clip)
                        let inside = clip.hitTest(CGPoint(x: group.width / 2, y: group.height / 2)) != nil
                        let outside = clip.hitTest(CGPoint(x: -1, y: group.height / 2)) == nil
                        clip.crop = .zero
                        let empty = clip.hitTest(CGPoint(x: group.width / 2, y: group.height / 2)) == nil
                        return (side.rawValue, .object(["frame": rect(group), "panel": panel.map(rect) ?? .null,
                            "hit": .bool(plan.hit(at: CGPoint(x: group.midX, y: group.midY)) == side),
                            "clipInside": .bool(inside), "clipOutside": .bool(outside), "clipEmpty": .bool(empty)]))
                    }
                    let samples = stride(from: CGFloat(0), through: frame.width, by: max(1, frame.width / 128)).map { x -> JSONValue in
                        .object(["x": .number(x), "side": plan.hit(at: CGPoint(x: x, y: frame.height / 2)).map { .string($0.rawValue) } ?? .null])
                    }
                    let observed = BarFrames()
                    for side in TopBarSide.allCases {
                        for (i, width) in (plan.width[side] ?? []).enumerated() {
                            observed.report(CGRect(x: plan.x[side]![i] ?? -TopBarRow.offstage - width, y: 0, width: width, height: frame.height), side: side, index: i, on: screen.name)
                        }
                    }
                    // The pill's drop (spec desktop-controls T5): under its item as laid out here, inside the visible frame (the
                    // screen less its menu bar strip); with no bar, from the visible frame's top.
                    let visible = CGRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height - screen.strip)
                    let pillSide = sides.first { $0.value.contains { $0.item == .kind(.pill) } }?.key
                    let pillItem = sides.lazy.compactMap { side, slots -> CGFloat? in
                        guard let i = slots.firstIndex(where: { $0.item == .kind(.pill) }), let x = plan.x[side]?[i] ?? nil else { return nil }
                        return frame.minX + (island ? 0 : (store.settings.preset?.padding ?? 6)) + x + (plan.width[side]?[i] ?? 0) / 2
                    }.first
                    // The window the pill stands in, as TopBarWindows places it: its island, else the strip or whole bar;
                    // its flat foot is what the live drop takes from that window (BarDropLights.ground).
                    let pillWindow = island ? pillSide.flatMap { BarPresetGeometry.islandFrame(plan.groups[$0], in: frame) } : frame
                    let pillGround = pillWindow.map { PillPlacement.ground(window: $0, radius: store.settings.preset?.radius ?? 0) }
                    let pill: JSONValue = .object(["item": pillItem.map { .number(Double($0)) } ?? .null, "visible": rect(visible), "bar": rect(frame),
                        "window": pillWindow.map(rect) ?? .null, "ground": pillGround.map(rect) ?? .null,
                        "drop": pillItem.map { rect(PillPlacement.frame(item: $0, visible: visible, bar: frame, ground: pillGround)) } ?? .null,
                        "noBar": rect(PillPlacement.frame(item: nil, visible: visible, bar: nil))])
                    return .object(["screen": .string(screen.name), "frame": .array([frame.minX, frame.minY, frame.width, frame.height].map { .number($0) }), "pill": pill,
                        "placement": .object(Dictionary(uniqueKeysWithValues: plan.x.map { side, values in (side.rawValue, JSONValue.array(values.map { $0.map { .number($0) } ?? .null })) })),
                        "measuredWidths": .object(Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, .array($0.value.map { .number(Double($0)) })) })),
                        "widths": .object(Dictionary(uniqueKeysWithValues: plan.width.map { ($0.key.rawValue, .array($0.value.map { .number(Double($0)) })) })),
                        "items": .object(Dictionary(uniqueKeysWithValues: sides.map { ($0.key.rawValue, .array($0.value.map { .string($0.item.rawValue) })) })),
                        "groups": .object(Dictionary(uniqueKeysWithValues: groups)), "hitSamples": .array(samples),
                        "gone": .array(observed.gone(on: screen.name, in: sides).map { .string($0.item.rawValue) }),
                        "overflow": plan.more.map { .number($0) } ?? .null])
                }
                return .object(["saved": try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(store.settings)),
                                "loadError": store.loadError.map(JSONValue.string) ?? .null,
                                "discovery": discovery.withLock { .object(["stats": .number(Double($0.stats)), "extensions": .number(Double($0.extensions))]) },
                                "native": store.loadError == nil ? try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(readNative())) : .null, "screens": .array(frames)])
            } catch { throw ControlError(.badValue, String(describing: error)) }
        })
        let socket = ControlSocket(path: URL(fileURLWithPath: config.socket), verbs: verbs)
        // Validate recovery before accepting any command or reporting ready.
        print("BAR recovery: \(try owner.recover())")
        guard socket.start() else { throw ThemeFailure("private bar socket refused") }
        defer { socket.stop() }
        print("BAR FIXTURE ONLY: Engine=absent live=absent Keychain=absent production-registry=absent effects=recording home=explicit")
        print("BAR verbs: \(verbs.sorted.map(\.name).joined(separator: ","))"); fflush(stdout)
        let hold = URL(fileURLWithPath: config.socket + ".hold")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let start = Date()
        while FileManager.default.fileExists(atPath: hold.path), Date().timeIntervalSince(start) < 600 {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Injected UserDefaults interface with explicit local persistence; never consults CFPreferences or its daemon.
final class BarFixtureDefaults: UserDefaults, @unchecked Sendable {
    private let root: String
    private let path: String
    private var values: [String: Any]
    private var failure: Error?
    init(root: String, suite: String) throws {
        self.root = root; path = "Library/Preferences/" + suite + ".plist"
        if let bytes = try ThemeFiles.read(root: root, path: path).bytes {
            guard let value = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { throw ThemeFailure("invalid isolated defaults") }
            values = value
        } else { values = [:] }
        super.init(suiteName: suite)!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (values[key] as? NSNumber)?.floatValue ?? 0 }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
        do {
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            _ = try ThemeFiles.write(bytes, over: ThemeFiles.read(root: root, path: path))
        } catch { failure = error }
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func synchronize() -> Bool { failure == nil }
}
