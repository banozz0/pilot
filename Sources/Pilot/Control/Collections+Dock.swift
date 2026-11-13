import Foundation
import PilotCore

extension ControlVerbs {
    /// The dock (spec pilot-dock): `pilot dock` reads its switch, size, room and icons (the pins read from the macOS Dock,
    /// never written, then the running apps); `pilot dock widgets` what each widget shows now, from its real reader;
    /// `dock-widgets` lists, adds (at a place) and removes its widgets, any of round 3's eleven (DockWidget).
    func registerDock(_ dock: @escaping @Sendable @MainActor () -> DockController? = { Engine.shared?.dock },
                      windows: @escaping @Sendable @MainActor () -> [AeroWindow] = { Engine.shared?.observers.tiler.windows ?? [] }) {
        func rows(_ widgets: [DockWidget]) -> JSONValue {
            .array(widgets.map { .object(["item": .string($0.rawValue), "title": .string($0.title), "reads": .string($0.reads)]) })
        }
        func widget(_ name: String) throws(ControlError) -> DockWidget {
            guard let found = DockWidget(name: name) else { throw ControlError(.badValue, DockWidgetError.unknown(name).description) }
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
            if args.positional.first == "widgets" { return await Self.widgetFaces(dock.settings.widgets) }
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
                "on": .bool(dock.isOn), "size": .string(dock.settings.size.rawValue),
                "savedAutohide": dock.state.savedAutohide.map(JSONValue.bool) ?? .null,
                "savedDelay": dock.state.delaySaved == true ? dock.state.savedDelay.map(JSONValue.number) ?? .string("absent") : .null,
                "room": .array(dock.room.map { .object(["screen": .string($0.monitor), "height": .number(Double($0.height))]) }),
                "widgets": .array(dock.settings.widgets.map { .string($0.rawValue) }),
                "problem": dock.problem.map(JSONValue.string) ?? .null,
                "apps": .array(apps.map { app in
                    .object(["name": .string(app.name), "bundleID": app.bundleID.map(JSONValue.string) ?? .null, "pinned": .bool(app.pinned),
                             "running": .bool(app.running), "windows": .number(Double(app.windows)), "dots": .number(Double(app.dots)),
                             "click": .string(app.click.rawValue)])
                }),
            ])
        })
        register(ControlCollection(
            "dock-widgets", help: "The dock's widgets in order (design round 3): " + DockWidget.allCases.map(\.rawValue).joined(separator: ", ") + ". Each draws a glyph, a small label over a value; one whose source is not set up shows Set up. add takes --at, its place from 0 (the end without it); remove then add moves one.",
            fields: [.init("item", help: "a widget: " + DockWidget.allCases.map(\.rawValue).joined(separator: ", ")),
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
    /// waited for up to 4 s. Calendar is read, never asked.
    @MainActor
    static func widgetFaces(_ widgets: [DockWidget], sources: BarSources? = Engine.shared?.barSources, extensionBar: ExtensionBar = .shared,
                            calendar: DockCalendar = .shared) async -> JSONValue {
        guard let sources else { return .array([]) }
        let kinds = DockWidgetSources.kinds(widgets).subtracting([.extensions]), asked = DockWidgetSources.extensions(widgets)
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
            if !kinds.isDisjoint(with: [.cpu, .memory, .battery, .bluetoothBatteries]) {
                // CPU's share needs a second sample.
                for _ in 0..<20 where sources.sampler.latestValues?.cpu == nil { try? await Task.sleep(for: .milliseconds(200)) }
            }
        }
        defer {
            if !live {
                kinds.forEach(sources.readings.release)
                extensionBar.hold([], for: "pilot dock widgets")
            }
        }
        if widgets.contains(.nextEvent) || widgets.contains(.timeline) { calendar.follow(now: sources.readings.now) }
        let reader = DockWidgetSources(sources: sources, extensionBar: extensionBar, calendar: calendar)
        return .array(widgets.map { widget in
            var row: [String: JSONValue] = ["widget": .string(widget.rawValue), "reads": .string(widget.reads)]
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
