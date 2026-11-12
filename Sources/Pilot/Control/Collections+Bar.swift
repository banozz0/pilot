import Foundation
import PilotCore

/// What the bar's lists reach besides the items' store (CLI W18), looked up on each request: the app's by default, a
/// test's fakes. Nothing here asks Screen Recording or captures the screen (ADR 0012).
struct BarReach: Sendable {
    /// The top bar's switch and screens; nil until the engine is up.
    var topBar: @Sendable @MainActor () -> TopBarController? = { Engine.shared?.topBar }
    /// The extensions' bar items, as the Menu bar page lists them under Extensions.
    var extensions: @Sendable @MainActor () -> [ExtensionBar.Item] = { ExtensionBar.shared.items }
    /// An extension's item was just placed: asked at once, as the page's switch does.
    var nudge: @Sendable @MainActor () -> Void = { ExtensionBar.shared.nudge() }
    /// The readings this Mac lacks ("none here" on the page).
    var lacking: @Sendable @MainActor () -> Set<BarKind> = { Engine.shared?.barSources.lacking ?? [] }
    /// Show exact menu bar items is on and Screen Recording is not granted; asks macOS nothing while it is off.
    var lacksScreenRecording: @Sendable @MainActor () -> Bool = { Engine.shared?.barSources.readings.menuApps.pictures.lacksPermission ?? false }
    /// The Menu bar page, where the bar is dragged (Q185); false when the app window cannot open.
    var openEditor: @Sendable @MainActor () -> Bool = { AppWindowController.shared.open(.menuBar); return true }
    /// Show exact menu bar items was switched: on asks macOS's Screen Recording prompt unless granted, off drops the
    /// pictures, as the page's switch does.
    var exactToggled: @Sendable @MainActor () -> Void = { Engine.shared?.barSources.readings.menuApps.pictures.toggled() }
    /// The Allow gate turning Show exact menu bar items on waits on.
    var gate: @Sendable @MainActor () -> ControlGate = { AllowPrompt.gate }
}

extension ControlVerbs {
    /// The bar's items (AI helper T8, CLI W18): `bar-items` lists, adds and removes them per bar as the Menu bar page's
    /// switch does, `bar-extensions` places the extensions' items, `top-bar-screens` picks the screens the top bar shows
    /// on, and `bar` reads what the page says about the bars, moves an item, sets its style and the spacer, clears every
    /// item or restores the default ones (Q411), opens the Menu bar page, and switches Show exact menu bar items (on asks Allow: it uses Screen Recording, ADR 0012). Every change
    /// goes to the store both bars and the page draw from.
    func registerBar(_ bar: @escaping @Sendable @MainActor () -> BarItemsStore, reach: BarReach = BarReach()) {
        register(ControlCollection(
            "bar-items", help: "The items on in Pilot's top bar or the macOS menu bar, in order (Menu bar). add with --placement puts the item in that bar and keeps the other it is in, as the page's switch does; without it the item joins the top bar, as a drop on the Menu bar page's top bar strip does. remove with --placement takes it out of that bar alone; without it, off both. The top bar holds any number of dividers: add divider while one is there adds one more, listed as divider:<n>, which remove and bar move name.",
            fields: [.init("item", help: "one of \(Self.cases(BarKind.self)), or divider:<n> for one more divider"),
                     .init("placement", help: "the bar it joins: \(Self.cases(BarPlacement.self)); other apps, app menus and extensions are top bar only", required: false),
                     .init("side", help: "the top bar's side: \(Self.cases(TopBarSide.self)) (the item's own)", required: false),
                     .init("index", help: "before the item now at this place on that side, from 0 (last)", required: false)],
            rowKey: "item",
            list: { let lacking = reach.lacking(); return .array(bar().settings.entries.filter { $0.on && $0.kind != .extensions }.map { Self.row($0, lacking: lacking) }) },
            add: { args throws(ControlError) in
                try bar().requireWritable()
                let kind = try Self.movable(args.value("item") ?? "")
                let side = try Self.side(args.value("side")), index = try Self.index(args.value("index"))
                // Once a divider is on the top bar, each add is one more there (Sven on build 2363), as the page's tray does.
                if kind == .divider, args.value("placement") == nil, case let item = bar().settings.dividerToAdd(.topBar), item != .kind(.divider) {
                    return Self.change(item, in: bar(), reach) { s in s.drop(item, on: .top(side ?? s.entry(.divider).side, index: index ?? .max), placement: .topBar) }
                }
                guard let word = args.value("placement") else { return Self.apply(.add(kind, side: side, index: index), kind, to: bar(), reach) }
                let placement = try Self.placement(word, for: kind)
                try Self.refuseMenuBarPlace(placement, side: side, index: index)
                return Self.change(kind, in: bar(), reach) { s in
                    s.set(kind, in: placement, on: true)
                    if side != nil || index != nil { s.place(kind, on: side ?? s.entry(kind).side, at: index ?? .max) }
                }
            },
            remove: { args throws(ControlError) in
                try bar().requireWritable()
                if let refusal = ControlVerb.unknownFlag(args.flags, known: ["placement"], in: "pilot remove bar-items") { throw refusal }
                if let item = try Self.moreDivider(try args.word(0, "item"), on: bar()) {
                    return Self.change(item, in: bar(), reach) { $0.takeOff(item, placement: .topBar) }
                }
                let kind = try Self.movable(try args.word(0, "item"))
                guard bar().settings.entry(kind).on else { throw ControlError(.badValue, "\(kind.rawValue) is not on the bar") }
                guard let word = args.value("placement") else { return Self.apply(.remove(kind), kind, to: bar(), reach) }
                let placement: BarPlacement = try Self.choice(word, "--placement")
                return Self.change(kind, in: bar(), reach) { $0.set(kind, in: placement, on: false) }
            }))
        registerBarExtensions(bar, reach)
        registerTopBarScreens(reach)
        register(ControlVerb("bar", help: "What the Menu bar page says about the bars (readings this Mac lacks, items in the top bar alone, Show exact menu bar items and its Screen Recording); moves an item, puts it in the Group or takes it out (ungroup alone splits the whole Group), sets its style or the spacer's width (reset gives it back its style's), clears every item off a bar or both (Pilot's own icon stays) or restores the default items there, the bar the page shows unless --placement names one, opens the Menu bar page to drag the bar, or switches Show exact menu bar items (on asks Allow: it uses Screen Recording).",
                             usage: "pilot bar | pilot bar preset legacy|floatingStrip|threeIslands|pills|pillFirst (legacy is the Full bar) | pilot bar geometry <field> <points> | pilot bar geometry <JSON> | pilot bar move <item> [--side left|centre|right] [--index n] | pilot bar move <item> --onto <item> | pilot bar style <item> <style> | pilot bar group <item> | pilot bar ungroup [<item>] | pilot bar spacer <points>|reset | pilot bar clear|restore [--placement menuBar|topBar|both] | pilot bar edit | pilot bar exact on|off",
                             flags: [.init("side", help: "move: the top bar's side it goes to"),
                                     .init("index", help: "move: before the item now at this place on that side, from 0"),
                                     .init("onto", help: "move: where this item is in the bars' order, as a drag on the page's preview"),
                                     .init("placement", help: "clear, restore: the bar it acts on, \(Self.cases(BarPlacement.self)) (the one the Menu bar page shows)")],
                             schema: { .object([
                                                "styles": .object(Dictionary(uniqueKeysWithValues: BarKind.allCases.map {
                                                    ($0.rawValue, JSONValue.array($0.styles.map { .string($0.rawValue) }))
                                                }))]) }) { call throws(ControlError) in
            let args = call.arguments()
            guard let sub = args.positional.first else { return Self.state(bar(), reach) }
            try bar().requireWritable()
            switch sub {
            case "preset":
                guard args.positional.count == 2, args.flags.isEmpty else { throw ControlError(.badRequest, "bar preset <legacy|floatingStrip|threeIslands|pills|pillFirst>: legacy is the Full bar") }
                try bar().choosePreset(try args.word(1, "preset"))
                return Self.state(bar(), reach)
            case "geometry":
                guard args.flags.isEmpty else { throw ControlError(.badRequest, "bar geometry <field> <points>, or bar geometry <JSON>") }
                if args.positional.count == 2 { try bar().applyGeometry(try args.word(1, "JSON")) }
                else if args.positional.count == 3, let value = Double(try args.word(2, "points")) { try bar().setGeometry(try args.word(1, "field"), value: value) }
                else { throw ControlError(.badValue, "bar geometry <field> <points>, or bar geometry <JSON>") }
                return Self.state(bar(), reach)
            case "move":
                if let item = try Self.moreDivider(try args.word(1, "item"), on: bar()) {
                    guard args.value("onto") == nil else { throw ControlError(.badValue, "move a divider with --side and --index") }
                    let side = try Self.side(args.value("side")), index = try Self.index(args.value("index"))
                    return Self.change(item, in: bar(), reach) { s in
                        s.place(item, on: side ?? s.topBarPlace(item)?.side ?? .right, at: index ?? .max)
                    }
                }
                let kind = try Self.movable(try args.word(1, "item"))
                if let onto = args.value("onto") {
                    guard args.value("side") == nil, args.value("index") == nil else {
                        throw ControlError(.badValue, "move takes --onto or --side and --index, not both")
                    }
                    let target: BarKind = try Self.choice(onto, "--onto")
                    return Self.change(kind, in: bar(), reach) { $0.move(kind, onto: target) }
                }
                return Self.apply(.move(kind, side: try Self.side(args.value("side")), index: try Self.index(args.value("index"))), kind, to: bar(), reach)
            case "style":
                let kind: BarKind = try Self.choice(try args.word(1, "item"), "item")
                let word = try args.word(2, "style")
                guard let style = BarStyle(rawValue: word), kind.styles.contains(style) else {
                    throw ControlError(.badValue, "\(kind.rawValue)'s style is one of \(kind.styles.map(\.rawValue).joined(separator: ", ")), not \(word)")
                }
                return Self.change(kind, in: bar(), reach) { $0.set(kind, style: style) }
            case "group":
                let kind: BarKind = try Self.choice(try args.word(1, "item"), "item")
                var joined = bar().settings
                guard joined.group(kind) else {
                    throw ControlError(.badValue, "\(kind.rawValue) cannot join the Group: it takes \(BarKind.allCases.filter(\.groupable).map(\.rawValue).joined(separator: ", ")), while the Group is on")
                }
                return Self.change(kind, in: bar(), reach) { $0 = joined }
            case "ungroup":
                guard args.positional.count > 1 else {
                    Self.write(bar()) { $0.ungroup() }
                    return Self.state(bar(), reach)
                }
                let kind: BarKind = try Self.choice(try args.word(1, "item"), "item")
                guard bar().settings.entry(kind).inGroup else { throw ControlError(.badValue, "\(kind.rawValue) is not in the Group") }
                return Self.change(kind, in: bar(), reach) { $0.ungroup(kind) }
            case "spacer":
                let word = try args.word(1, "points or reset")
                let points = word == "reset" ? nil : Double(word)
                guard word == "reset" || points != nil else { throw ControlError(.badValue, "the spacer is a width in points or reset, not \(word)") }
                if let points, !BarSpacer.widths.contains(points) {
                    throw ControlError(.outOfRange, "the spacer is \(Int(BarSpacer.widths.lowerBound)) to \(Int(BarSpacer.widths.upperBound)) points, not \(word)")
                }
                return Self.apply(.spacer(points), .spacer, to: bar(), reach)
            case "clear", "restore":
                // The bar the page shows unless --placement names one, as the page's buttons act on it.
                let store = bar()
                let placement = try args.value("placement").map { word throws(ControlError) -> BarPlacement in try Self.choice(word, "--placement") }
                    ?? store.pagePlacement
                if sub == "clear" { Self.write(store) { $0.clearAll(in: placement, extensions: reach.extensions().map(\.id)) } }
                else if Self.write(store, { $0.restoreDefaultItems(in: placement) }) { reach.nudge() }
                return Self.state(store, reach, placement: placement)
            case "edit":
                guard reach.openEditor() else { throw ControlError(.notReady, "the app window could not open the Menu bar page") }
                return .object(["editing": .bool(true)])
            case "exact":
                let on = try Self.onOff(try args.word(1, "on or off"), "exact")
                let store = bar()
                guard on, !store.settings.exactMenuItems else { return Self.exact(on, store, reach) }
                return try await reach.gate().allow(Self.exactAsk, peer: call.peer) { Self.exact(on, store, reach) }
            case let other: throw ControlError(.badRequest, "pilot bar, or bar move, style, group, ungroup, spacer, clear, restore, edit or exact, not \(other)")
            }
        })
    }

    /// Each extension's bar item (Surfaces v2), placed per bar as the Menu bar page's rows under Extensions do. Rows
    /// carry no answer text: an extension's output stays in the bar (W6's rule for run).
    private func registerBarExtensions(_ bar: @escaping @Sendable @MainActor () -> BarItemsStore, _ reach: BarReach) {
        register(ControlCollection(
            "bar-extensions", help: "The extensions' bar items (Menu bar › Extensions): one never placed is on in the macOS menu bar. add puts it in --placement's bar (menuBar unless given) and keeps the other; in the top bar each is its own item, first put last on the right, and --side and --index move it as bar-items' do. remove takes it out of --placement's bar alone, or off both. Rows give each one's side and index in the top bar, as pilot bar's topBar lists them.",
            fields: [.init("id", help: "the extension's id, as pilot list bar-extensions names it"),
                     .init("placement", help: "the bar it joins: \(Self.cases(BarPlacement.self)) (menuBar)", required: false),
                     .init("side", help: "the top bar's side: \(Self.cases(TopBarSide.self)) (its own)", required: false),
                     .init("index", help: "before the item now at this place on that side, from 0 (last)", required: false)],
            rowKey: "id",
            list: { let s = bar().settings; return .array(reach.extensions().map { Self.extensionRow($0, s) }) },
            add: { args throws(ControlError) in
                try bar().requireWritable()
                let item = try Self.extensionItem(args.value("id"), reach)
                let side = try Self.side(args.value("side")), index = try Self.index(args.value("index"))
                let moves = side != nil || index != nil
                let placement: BarPlacement = try args.value("placement").map { word throws(ControlError) in try Self.choice(word, "--placement") }
                    ?? (moves ? .topBar : .menuBar)
                try Self.refuseMenuBarPlace(placement, side: side, index: index)
                return Self.placeExtension(item, in: bar(), reach) { s in
                    if !s.isOn(extension: item.id, in: placement) { s.toggle(extension: item.id, in: placement) }
                    guard moves, let at = s.topBarPlace(.extension(item.id)) else { return }
                    s.place(.extension(item.id), on: side ?? at.side, at: index ?? .max)
                }
            },
            remove: { args throws(ControlError) in
                try bar().requireWritable()
                if let refusal = ControlVerb.unknownFlag(args.flags, known: ["placement"], in: "pilot remove bar-extensions") { throw refusal }
                let item = try Self.extensionItem(try args.word(0, "id"), reach)
                guard let word = args.value("placement") else {
                    return Self.placeExtension(item, in: bar(), reach) { s in
                        s.set(extension: item.id, on: false, placement: s.extensionEntry(item.id).placement)
                    }
                }
                let placement: BarPlacement = try Self.choice(word, "--placement")
                return Self.placeExtension(item, in: bar(), reach) { s in
                    if s.isOn(extension: item.id, in: placement) { s.toggle(extension: item.id, in: placement) }
                }
            }))
    }

    /// The screens connected now and whether the top bar shows on each (Menu bar › Screens); a screen never seen
    /// before gets one, and one on a fullscreen Space keeps it out of sight.
    private func registerTopBarScreens(_ reach: BarReach) {
        let topBar = { () throws(ControlError) -> TopBarController in
            guard let topBar = reach.topBar() else { throw ControlError(.notReady, "Pilot's top bar is not up yet; ask again in a moment") }
            return topBar
        }
        let screenRow = { (topBar: TopBarController, name: String) -> JSONValue in
            let screen = topBar.connected.first { $0.name == name }
            return .object(["screen": .string(name), "on": .bool(!topBar.leftOut.contains(name)),
                            "height": screen.map { .number(Double(TopBarGeometry.inset($0.strip))) } ?? .null,
                            "fullscreen": .bool(topBar.fullscreen.contains(name))])
        }
        /// A connected screen's name: the page lists only those.
        let connected = { (topBar: TopBarController, name: String) throws(ControlError) -> String in
            guard topBar.connected.contains(where: { $0.name == name }) else {
                throw ControlError(.badValue, "no screen \(name) connected; there are \(topBar.connected.map(\.name).joined(separator: ", "))")
            }
            return name
        }
        register(ControlCollection(
            "top-bar-screens", help: "The screens connected now and whether Pilot's top bar shows on each (Menu bar › Screens); fullscreen is true while that screen's current Space is a fullscreen app's, where its bar stays out of sight. add shows it on a screen, remove leaves that screen out.",
            fields: [.init("screen", help: "a connected screen's name, as pilot list top-bar-screens names it")],
            rowKey: "screen",
            list: { () throws(ControlError) in let t = try topBar(); return .array(t.connected.map { screenRow(t, $0.name) }) },
            add: { args throws(ControlError) in
                let t = try topBar(), name = try connected(t, args.value("screen") ?? "")
                if t.leftOut.contains(name) { t.leftOut.remove(name) }
                return screenRow(t, name)
            },
            remove: { args throws(ControlError) in
                if let refusal = ControlVerb.unknownFlag(args.flags, known: [], in: "pilot remove top-bar-screens") { throw refusal }
                let t = try topBar(), name = try connected(t, try args.word(0, "screen"))
                if !t.leftOut.contains(name) { t.leftOut.insert(name) }
                return screenRow(t, name)
            }))
    }

    static let exactAsk = ControlGate.Ask("Show exact menu bar items", "draws other apps' menu bar items from screen captures; macOS asks Screen Recording")

    /// Show exact menu bar items switched as the page's switch does, written only when it changes; answers `pilot bar`.
    private static func exact(_ on: Bool, _ store: BarItemsStore, _ reach: BarReach) -> JSONValue {
        if write(store, { $0.exactMenuItems = on }) { reach.exactToggled() }
        return state(store, reach)
    }

    /// `pilot bar`: what the page says about the bars beside the items: the readings this Mac lacks ("none here"), the
    /// items on in the top bar alone (shown nowhere while it is off), and whether Show exact menu bar items waits on
    /// Screen Recording ("Allow Screen Recording…"). After clear or restore, `placement` names the bar it acted on.
    private static func state(_ store: BarItemsStore, _ reach: BarReach, placement: BarPlacement? = nil) -> JSONValue {
        let s = store.settings, topBarOn = reach.topBar()?.isOn
        var answer: [String: JSONValue] = ["topBarOn": topBarOn.map(JSONValue.bool) ?? .null,
                        "lacking": .array(BarSettings.readingKinds.filter(reach.lacking().contains).map { .string($0.rawValue) }),
                        "onlyInTopBar": .array(s.onlyInTopBar.map { .string($0.rawValue) }),
                        "readingsLook": .string(s.readingsLook.rawValue),
                        // The top bar's order, side by side, as it draws with the bar on: each extension's item its own.
                        "topBar": .object(Dictionary(uniqueKeysWithValues: (s.preview(.topBar).top ?? [:]).map { side, slots in
                            (side.rawValue, JSONValue.array(slots.map { .string($0.name) }))
                        })),
                        "preset": (try? ThemeDigest.encoded(s.preset)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null,
                        "exactMenuItems": .bool(s.exactMenuItems),
                        "needsScreenRecording": .bool(reach.lacksScreenRecording())]
        // The pill-first bar draws over the saved one, which `topBar` and `preset` still show as saved.
        answer["pillFirst"] = .bool(store.pillFirst.on)
        if store.pillFirst.on {
            answer["drawn"] = .object(Dictionary(uniqueKeysWithValues: store.topBarSides.map { side, slots in
                (side.rawValue, JSONValue.array(slots.map { .string($0.name) }))
            }))
        }
        if let placement { answer["placement"] = .string(placement.rawValue) }
        return .object(answer)
    }

    /// The route's change, as a pilot://bar link makes it, written only when it changes something; answers `kind`'s
    /// item as it now stands.
    private static func apply(_ route: BarRoute, _ kind: BarKind, to store: BarItemsStore, _ reach: BarReach) -> JSONValue {
        change(kind, in: store, reach) { route.apply(to: &$0) }
    }

    /// A page edit, written only when it changes something; answers `kind`'s item as it now stands.
    private static func change(_ kind: BarKind, in store: BarItemsStore, _ reach: BarReach, _ edit: (inout BarSettings) -> Void) -> JSONValue {
        change(.kind(kind), in: store, reach, edit)
    }

    /// The same for any item: one more divider taken off answers off, as it has no entry then.
    private static func change(_ item: BarTrayItem, in store: BarItemsStore, _ reach: BarReach, _ edit: (inout BarSettings) -> Void) -> JSONValue {
        write(store, edit)
        guard let entry = store.settings.entry(for: item) else { return .object(["item": .string(item.rawValue), "on": .bool(false)]) }
        return row(entry, lacking: reach.lacking())
    }

    /// The edit on a copy of the settings, saved only when it changes them; true when it did.
    @discardableResult private static func write(_ store: BarItemsStore, _ edit: (inout BarSettings) -> Void) -> Bool {
        var next = store.settings
        edit(&next)
        guard next != store.settings else { return false }
        store.settings = next
        return true
    }

    /// One more divider (divider:<n>) named on the command line, on the top bar; nil for any other word.
    private static func moreDivider(_ word: String, on store: BarItemsStore) throws(ControlError) -> BarTrayItem? {
        guard word.hasPrefix("divider:") else { return nil }
        guard let item = BarTrayItem(rawValue: word), case .divider = item, store.settings.onStrip(item, placement: .topBar) else {
            let on = store.settings.entries.filter { $0.dividerID != nil }.map(\.item.rawValue)
            throw ControlError(.badValue, "no \(word) on the top bar; \(on.isEmpty ? "there is no other divider" : "there are \(on.joined(separator: ", "))")")
        }
        return item
    }

    private static func row(_ entry: BarEntry, lacking: Set<BarKind>) -> JSONValue {
        .object(["item": .string(entry.dividerID == nil ? entry.kind.rawValue : entry.item.rawValue), "on": .bool(entry.on), "style": .string(entry.style.rawValue),
                 "styles": .array(entry.kind.styles.map { .string($0.rawValue) }),
                 "placement": .string(entry.placement.rawValue), "side": .string(entry.side.rawValue),
                 "topBarOnly": .bool(entry.kind.topBarOnly), "lacking": .bool(lacking.contains(entry.kind)), "inGroup": .bool(entry.inGroup),
                 "width": entry.width.map(JSONValue.number) ?? .null])
    }

    /// A bar the item may join: other apps, app menus and extensions live in the top bar alone (the page locks the rest).
    private static func placement(_ word: String, for kind: BarKind) throws(ControlError) -> BarPlacement {
        let placement: BarPlacement = try choice(word, "--placement")
        if kind.topBarOnly, placement != .topBar { throw ControlError(.badValue, "\(kind.rawValue) is top bar only: --placement topBar") }
        return placement
    }

    private static func extensionItem(_ id: String?, _ reach: BarReach) throws(ControlError) -> ExtensionBar.Item {
        let items = reach.extensions()
        guard let item = items.first(where: { $0.id == id }) else {
            let ids = items.isEmpty ? "none has a bar item" : "there are \(items.map(\.id).joined(separator: ", "))"
            throw ControlError(.badValue, "no extension bar item \(id ?? ""); \(ids)")
        }
        return item
    }

    /// An extension's item placed as the page's switch places it, then asked at once; answers its row.
    private static func placeExtension(_ item: ExtensionBar.Item, in store: BarItemsStore, _ reach: BarReach,
                                       _ edit: (inout BarSettings) -> Void) -> JSONValue {
        if write(store, edit) { reach.nudge() }
        return extensionRow(item, store.settings)
    }

    private static func extensionRow(_ item: ExtensionBar.Item, _ s: BarSettings) -> JSONValue {
        let entry = s.extensionEntry(item.id), at = s.topBarPlace(.extension(item.id))
        return .object(["id": .string(item.id), "title": .string(item.title), "on": .bool(entry.on), "placement": .string(entry.placement.rawValue),
                        "side": at.map { .string($0.side.rawValue) } ?? .null, "index": at.map { .number(Double($0.index)) } ?? .null])
    }


    /// --side and --index place an item on the top bar, so --placement menuBar refuses them.
    private static func refuseMenuBarPlace(_ placement: BarPlacement, side: TopBarSide?, index: Int?) throws(ControlError) {
        guard placement == .menuBar, side != nil || index != nil else { return }
        throw ControlError(.badValue, "--side and --index place an item on the top bar; --placement menuBar keeps it off it")
    }

    /// A bar item a change may move: Pilot's own icon stays first on the left.
    private static func movable(_ word: String) throws(ControlError) -> BarKind {
        let kind: BarKind = try choice(word, "--item")
        if kind.pinned { throw ControlError(.badValue, "\(kind.rawValue) is pinned: it stays first on the left") }
        if kind == .extensions { throw ControlError(.badValue, "each extension's item is its own: pilot add bar-extensions --id <id> --side <side>") }
        return kind
    }

    private static func side(_ word: String?) throws(ControlError) -> TopBarSide? {
        guard let word else { return nil }
        return try choice(word, "--side")
    }

    private static func index(_ word: String?) throws(ControlError) -> Int? {
        guard let word else { return nil }
        guard let index = Int(word), index >= 0 else { throw ControlError(.badValue, "--index is a place from 0, not \(word)") }
        return index
    }
}
