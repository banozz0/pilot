import Foundation
import PilotCore

extension ControlVerbs {
    /// The dock (spec pilot-dock): `pilot dock` reads its switch, size, room and icons (the pins read from the macOS Dock,
    /// never written, then the running apps); `pilot dock widgets` what each widget shows now, from its real reader;
    /// `dock-widgets` lists, adds (at a place) and removes its widgets, any of round 3's eleven (DockWidget) or an installed
    /// extension's top bar item (`extension:<id>`, round 4); `pilot dock stats` picks what System stats shows.
    func registerDock(_ dock: @escaping @Sendable @MainActor () -> DockController? = { Engine.shared?.dock },
                      windows: @escaping @Sendable @MainActor () -> [AeroWindow] = { Engine.shared?.observers.tiler.windows ?? [] }) {
        func rows(_ widgets: [DockSlot]) -> JSONValue {
            // An extension's title from its manifest, read once, as the bar may not have listed it yet.
            let titles = widgets.contains { $0.widget == nil } ? Dictionary(DockWidgetSources.barExtensions().map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) : [:]
            return .array(widgets.map { slot in
                .object(["item": .string(slot.name), "title": .string(slot.extensionID.flatMap { titles[$0] } ?? DockWidgetView.title(slot)),
                         "reads": .string(slot.reads)])
            })
        }
        /// A built-in widget, or an installed extension with a top bar item that none of them reads.
        func widget(_ name: String) throws(ControlError) -> DockSlot {
            guard let found = DockSlot(name: name) else { throw ControlError(.badValue, DockWidgetError.unknown(name).description) }
            if case .extensionItem(let id) = found, !DockWidgetSources.barExtensions().contains(where: { $0.id == id }) {
                throw ControlError(.badValue, "no installed extension \(id) with a top bar item; pilot dock widgets lists the ones there are")
            }
            return found
        }
        let up = { () throws(ControlError) -> DockController in
            guard let dock = dock() else { throw ControlError(.notReady, "Pilot's dock is not up yet; ask again in a moment") }
            return dock
        }
        register(ControlVerb("dock", help: "Pilot's dock: its switch (dock.on), size (dock.size), the auto-hide and reveal delay it saved from the macOS Dock, the room the tiler keeps for it, its widgets, and its icons: the macOS Dock's pins (read, never written) less the ones taken out of Pilot's dock, then the ones kept in it, then the running apps, each with its windows and what a click does. menu lists an app's right-click menu; keep and unpin are its Keep in Dock and Remove from Dock, on Pilot's own pins alone. widgets says what each widget shows now (its faces, its timeline, or Set up and why), read from its own reader: the extensions' bar answers, Pilot's timer, CPU and memory, the battery, Calendar (read, never asked).",
                             usage: "pilot dock | pilot dock widgets | pilot dock menu <app> | pilot dock keep <app> | pilot dock unpin <app>   (<app>: a bundle id or a name)") { call throws(ControlError) in
            // Read for the answer alone: the pill keeps what it shows.
            let dock = try up(), args = call.arguments(), dockPins = dock.readPins(), byApp = Dictionary(grouping: windows(), by: \.bundleId)
            // While on, the running apps the pill draws (the ones it follows); off, read now.
            let apps = DockController.apps(pins: dock.settings.pinned(dockPins), running: dock.isOn ? dock.running : DockController.runningApps(), byApp: byApp, front: nil)
            if args.positional.first == "widgets" {
                // And what else could go in: each installed extension with a top bar item no widget reads, not in the dock yet.
                let more = DockWidgetSources.barExtensions().map { DockSlot.extensionItem($0.id) }.filter { !dock.settings.widgets.contains($0) }
                return .object(["widgets": await Self.widgetFaces(dock.settings.widgets, stats: dock.settings.options.stats),
                                "fromExtensions": .array(more.map { .string($0.name) })])
            }
            if args.positional.first == "stats" {
                // pilot dock stats [stat…]: System stats' readings, picked (none given: read).
                let picked = try args.positional.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }.map { word throws(ControlError) -> MenuBarStats.Stat in
                    guard let stat = MenuBarStats.Stat(rawValue: word.trimmingCharacters(in: .whitespaces).lowercased()) else {
                        throw ControlError(.badValue, "\(word) is no stat: " + MenuBarStats.Stat.allCases.map(\.rawValue).joined(separator: ", "))
                    }
                    return stat
                }
                dock.settings.options.pick(picked)
                return .object(["stats": .array(dock.settings.options.stats.map { .string($0.rawValue) }),
                                "choices": .array(MenuBarStats.Stat.allCases.map { .string($0.rawValue) })])
            }
            if let sub = args.positional.first {
                let name = try args.word(1, "app")
                // A pin taken out of Pilot's dock is still the macOS Dock's, so keep finds it.
                let taken = dockPins.map { DockApp(bundleID: $0.bundleID, url: $0.url, name: $0.name, pinned: false, pid: nil, windows: 0, front: false) }
                guard let app = (apps + taken).first(where: { $0.bundleID == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw ControlError(.badValue, "no app \(name) in the dock: a pin or a running app, by bundle id or name")
                }
                switch sub {
                case "menu":
                    let sections = DockMenuItem.menu(app, windows: app.bundleID.flatMap { byApp[$0] } ?? [])
                    return .array(sections.map { .array($0.map { .string($0.title) }) })
                case "keep": dock.keep(app, dock: dockPins)
                case "unpin": dock.unpin(app, dock: dockPins)
                default: throw ControlError(.badRequest, "pilot dock menu|keep|unpin <app>")
                }
                return .object(["kept": .array(dock.settings.kept.map { .string($0.key) }), "removed": .array(dock.settings.removed.map(JSONValue.string)),
                                "pins": .array(dock.settings.pinned(dockPins).map { .string($0.name) })])
            }
            return .object([
                "on": .bool(dock.isOn), "size": .string(dock.settings.size.rawValue), "style": .string(dock.settings.style.rawValue),
                "magnify": .string(dock.settings.magnify.rawValue), "stats": .array(dock.settings.options.stats.map { .string($0.rawValue) }),
                "savedAutohide": dock.state.savedAutohide.map(JSONValue.bool) ?? .null,
                "savedDelay": dock.state.delaySaved == true ? dock.state.savedDelay.map(JSONValue.number) ?? .string("absent") : .null,
                "room": .array(dock.room.map { .object(["screen": .string($0.monitor), "height": .number(Double($0.height))]) }),
                "widgets": .array(dock.settings.widgets.map { .string($0.name) }),
                "problem": dock.problem.map(JSONValue.string) ?? .null,
                "apps": .array(apps.map { app in
                    .object(["name": .string(app.name), "bundleID": app.bundleID.map(JSONValue.string) ?? .null, "pinned": .bool(app.pinned),
                             "running": .bool(app.running), "windows": .number(Double(app.windows)), "dots": .number(Double(app.dots)),
                             "click": .string(app.click.rawValue)])
                }),
            ])
        })
        register(ControlCollection(
            "dock-widgets", help: "The dock's widgets in order (design round 3): " + DockWidget.allCases.map(\.rawValue).joined(separator: ", ") + ", or extension:<id>, an installed extension's top bar item (pilot dock widgets lists them under fromExtensions). Each draws a glyph, a small label over a value; one whose source is not set up shows Set up. add takes --at, its place from 0 (the end without it); remove then add moves one.",
            fields: [.init("item", help: "a widget: " + DockWidget.allCases.map(\.rawValue).joined(separator: ", ") + ", or extension:<id>"),
                     .init("at", help: "its place in the order, from 0; the end without it", required: false)],
            rowKey: "item",
            list: { rows(dock()?.settings.widgets ?? []) },
            add: { args throws(ControlError) in
                let dock = try up(), item = try widget(args.value("item") ?? "")
                let at = try args.value("at").map { word throws(ControlError) -> Int in
                    guard let n = Int(word), n >= 0 else { throw ControlError(.badValue, "--at takes a place from 0") }
                    return n
                }
                do throws(DockWidgetError) { try dock.settings.add(item, at: at) } catch { throw ControlError(.badValue, error.description) }
                return rows(dock.settings.widgets)
            },
            remove: { args throws(ControlError) in
                let dock = try up(), item = try widget(try args.word(0, "item"))
                do throws(DockWidgetError) { try dock.settings.remove(item) } catch { throw ControlError(.badValue, error.description) }
                return rows(dock.settings.widgets)
            }))
    }

    /// Each widget as it shows now. While the dock draws, its readers are held and this only reads; otherwise (the dock
    /// off, the sandbox) they are held for this answer alone: the extensions asked once, the sampler's CPU reading
    /// and network readings waited for up to 7 s. Calendar is read, never asked.
    @MainActor
    static func widgetFaces(_ widgets: [DockSlot], stats: [MenuBarStats.Stat] = DockWidgetOptions.defaultStats, sources: BarSources? = Engine.shared?.barSources,
                            extensionBar: ExtensionBar = .shared, calendar: DockCalendar = .shared) async -> JSONValue {
        guard let sources else { return .array([]) }
        let kinds = DockWidgetSources.kinds(widgets, stats: stats).subtracting([.extensions]), asked = DockWidgetSources.extensions(widgets)
        let live = extensionBar.isRunning && extensionBar.held.isSuperset(of: asked)
        if !live {
            kinds.forEach(sources.readings.hold)
            extensionBar.hold(asked, for: "pilot dock widgets")
            // A loop running (the top bar's) is nudged by the hold and answers on its own round: a second round run
            // beside it would write its older list over the answers. With none, one round here.
            if extensionBar.isRunning {
                for _ in 0..<20 where extensionBar.items.contains(where: { asked.contains($0.id) && $0.answer == nil && $0.problem == nil }) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } else if !asked.isEmpty {
                await extensionBar.round()
            }
            if !kinds.isDisjoint(with: [.cpu, .memory, .network, .graphics, .storage, .heat, .battery, .bluetoothBatteries]) {
                // CPU's share and the network's rates need a second sample, the sampler's 5 s after the first.
                for _ in 0..<35 where sources.sampler.latestValues?.cpu == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        defer {
            if !live {
                kinds.forEach(sources.readings.release)
                extensionBar.hold([], for: "pilot dock widgets")
            }
        }
        if widgets.contains(.widget(.nextEvent)) || widgets.contains(.widget(.timeline)) { calendar.follow(now: sources.readings.now) }
        let reader = DockWidgetSources(sources: sources, extensionBar: extensionBar, calendar: calendar, stats: stats)
        return .array(widgets.map { widget in
            var row: [String: JSONValue] = ["widget": .string(widget.name), "reads": .string(widget.reads)]
            switch reader.body(widget) {
            case .faces(let faces):
                row["shows"] = .string("faces")
                row["faces"] = .array(faces.map { face in
                    var one: [String: JSONValue] = ["face": .string(face.words)]
                    if let tone = face.tone { one["tone"] = .string(tone.rawValue) }
                    if case .image(let data) = face.glyph { one["artwork"] = .string("\(data.count) bytes") }
                    return .object(one)
                })
            case .timeline(let timeline):
                row["shows"] = .string("timeline")
                row["faces"] = .array([.object(["face": .string(timeline.label.uppercased()),
                                                "events": .array(timeline.spans.map { .string($0.title) })])])
            case .setUp(let why):
                row["shows"] = .string("set up")
                row["why"] = .string(DockWidgetBodyView.setUpWords(why))
            }
            return .object(row)
        })
    }
}
