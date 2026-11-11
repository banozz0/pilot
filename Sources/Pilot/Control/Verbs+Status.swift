import AppKit
import PilotCore

/// What `pilot status` reads besides the engine (CLI W2): the reads Home, General and onboarding make that touch the Mac
/// (a folder listing, child processes, TCC, SMAppService, the sampler). The tests hand in their own, so nothing of Sven's
/// is read, spawned or written.
@MainActor
final class ControlStatus {
    var engine: @MainActor () -> Engine? = { Engine.shared }
    /// Lists a folder, so it runs off the main thread.
    var fullDiskAccess: @Sendable () async -> Bool = { await Task.detached { FileIndex.hasFullDiskAccess() }.value }
    /// nil while Show exact menu bar items is off: nothing asks Screen Recording's state before (ADR 0012).
    var screenRecording: @MainActor (Engine) -> Bool? = { engine in
        BarItemsStore.shared.settings.exactMenuItems ? !engine.barSources.readings.menuApps.pictures.lacksPermission : nil
    }
    var loginItem: @MainActor () -> (status: LaunchAtLogin.Status, problem: String?) = { (LoginItem.shared.status, LoginItem.shared.problem) }
    var link = CommandLineLink.shared
    /// Reads the login shell's PATH into `link.onPath`.
    var readPath: @MainActor (CommandLineLink) async -> Void = { await $0.readPath() }
    var updates = PilotUpdates.shared
    var folder = PilotFolder.support
    var systemEvents: @Sendable () async -> Int32 = { await Task.detached { ControlStatus.mayControlSystemEvents() }.value }
    var clashes: @MainActor (Engine) -> Int = { ShortcutConflicts.shared.clashes(binds: $0.binds.store.binds).count }
    /// Permissions' other grants as onboarding reads them, each without a prompt; nil outside Pilot.
    var grants: @MainActor () async -> OnboardingGrants.Reading? = { await OnboardingGrants.shared.read() }
    /// This Mac's last reading and its values, held until one with a CPU share is newer than the ask (the second tick
    /// makes the rate).
    var sample: @MainActor () async -> (raw: SystemStats.Raw, values: SystemStats.Values?)? = ControlStatus.sampleThisMac
    var refreshOccupied: @MainActor (Engine) async -> Void = { await $0.observers.tiler.refreshOccupied() }
    /// The last answer onboarding's System Events row kept: the probe says procNotFound whenever System Events is idle.
    private var systemEventsAllowed = false
    /// Whether the login shell's PATH was asked this run.
    private var pathRead = false

    func running() throws(ControlError) -> Engine {
        guard let engine = engine() else { throw ControlError(.notReady, "Pilot's key engine is not running") }
        return engine
    }

    /// A part `pilot status` answers, by its name, with what it holds; a bare `pilot status` reads the `shown` ones (the rest
    /// read the Mac or wait on a reading, so only `--part` asks them).
    enum Part: String, CaseIterable {
        case line, hyper, `switch`, permissions, engine, problems, today, loginItem, commandLink, update, folder
        case workspaces, onboarding, presses, mac, widgets, shelf, notifications

        var shown: Bool { ![.workspaces, .onboarding, .presses, .mac, .widgets, .shelf, .notifications].contains(self) }

        var help: String {
            switch self {
            case .line: "Home's line beside the Hyper switch"
            case .hyper: "the Hyper key's switch (on again at every launch) and the layer key"
            case .switch: "Pilot's on/off switch: on"
            case .permissions: "Accessibility, Full Disk Access, and Screen Recording (null while Show exact menu bar items is off)"
            case .engine: "the key engine, secure input, Pilot's tiler and its tiling switch, the last error"
            case .problems: "Home's Needs you, each with the command that fixes it"
            case .today: "today's presses: total, most used, by hour"
            case .loginItem: "Launch at login: the wish, the login item's state, its problem"
            case .commandLink: "~/.local/bin/pilot: linked or not, on the PATH (read once, from the login shell)"
            case .update: "how this build updates (sparkle, none, or a debug build's checkout), Sparkle's feed and last check, the commit and checkout, the last count; --check counts"
            case .folder: "Pilot's folder"
            case .workspaces: "the focused workspace and the apps on each occupied one, read from the tiler"
            case .onboarding: "onboarding's Permissions, each row done or not (runs pgrep and TCC checks)"
            case .presses: "the 20 most run actions of all time, from the counts behind the overlay's most used"
            case .mac: "Home's This Mac: chip, CPU, memory, disk, temperature (waits up to 5 s for a reading)"
            case .widgets: "the desktop's widgets: each installed one with its trust, each placement shown or hidden and why, each screen's workspace and Show desktop"
            case .shelf: "the Window shelf on each screen showing a Stage workspace, its pictures, and Pilot's memory and CPU over 2 s"
            case .notifications: "other apps' notifications in Pilot: on, observing, counts and whether macOS's banner is hidden, never a word of a notification"
            }
        }
    }

    /// The parts `--part` names, comma-separated; every shown part when nil.
    static func parts(_ list: String?) throws(ControlError) -> [Part] {
        guard let list else { return Part.allCases.filter(\.shown) }
        let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw ControlError(.badRequest, "--part needs a part") }
        return try names.map { name throws(ControlError) in
            guard let part = Part(rawValue: name) else {
                throw ControlError(.badValue, "no part \(name); parts: \(Part.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return part
        }
    }

    /// The answer: one key per part asked, read side by side, so the slow ones' waits overlap.
    func status(_ parts: [Part], check: Bool) async throws(ControlError) -> JSONValue {
        let engine = try running()
        if check {
            if let why = updates.checkRefusal { throw ControlError(.badValue, why) }
            updates.check()
            for _ in 0..<120 where updates.state == .checking { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let reads = parts.map { part in (part, Task { await read(part, engine) }) }
        var out: [String: JSONValue] = [:]
        for (part, read) in reads { out[part.rawValue] = await read.value }
        return .object(out)
    }

    private func read(_ part: Part, _ engine: Engine) async -> JSONValue {
        let tiler = engine.observers.tiler
        switch part {
        case .line:
            return .string(HomeGreeting.line(hyperOn: engine.hyperSwitch.isOn, problems: engine.homeProblems, layerKey: engine.settings.layerKeys.label,
                                             workspace: tiler.focused, tiler: tiler.tilerName))
        case .hyper:
            let keys = engine.settings.layerKeys
            return .object(["on": .bool(engine.hyperSwitch.isOn), "layerKeys": .array(keys.map { .string($0.rawValue) }),
                            "layerKeyLabel": .string(keys.label)])
        case .switch:
            return .object(["on": .bool(engine.pilotSwitch.isOn)])
        case .permissions:
            engine.gate.check()
            return .object(["accessibility": .bool(engine.gate.isTrusted), "fullDiskAccess": .bool(await fullDiskAccess()),
                            "screenRecording": screenRecording(engine).map(JSONValue.bool) ?? .null])
        case .engine:
            return .object(["keyEngine": .bool(engine.bindsArmed), "secureInput": .bool(engine.secureInput.isActive),
                            "tiler": .object(["name": .string(tiler.tilerName), "running": .bool(tiler.isAnswering),
                                              "tiling": .bool(engine.tilingSwitch.isOn)]),
                            "lastError": Self.json(engine.lastError)])
        case .problems:
            return .array(engine.homeProblems.map(Self.problem))
        case .today:
            let today = engine.today, now = Date()
            return .object(["total": .number(Double(today.total(now: now))), "top": Self.counts(today.top(10, now: now)),
                            "byHour": .array(today.hours(now: now).map { .number(Double($0)) })])
        case .loginItem:
            let item = loginItem()
            return .object(["wanted": .bool(engine.settings.launchAtLogin), "status": .string(String(describing: item.status)),
                            "problem": Self.json(item.problem)])
        case .commandLink:
            link.refresh()
            // Once a run: a shell that would not say leaves onPath nil, and is not asked again on every status.
            if !pathRead { pathRead = true; await readPath(link) }
            return .object(["state": .string(String(describing: link.state)), "link": .string(link.link.path(percentEncoded: false)),
                            "onPath": link.onPath.map(JSONValue.bool) ?? .null, "problem": Self.json(link.problem)])
        case .update:
            var entry: [String: JSONValue] = ["route": .string(updates.route.rawValue), "feed": Self.json(updates.feed),
                                              "automaticChecks": updates.automaticChecks.map(JSONValue.bool) ?? .null,
                                              "lastChecked": updates.lastChecked.map { .string($0.ISO8601Format()) } ?? .null,
                                              "commit": Self.json(updates.commit), "source": Self.json(updates.source),
                                              "canCheck": .bool(updates.canCheck), "label": .string(updates.label)]
            switch updates.state {
            case .behind(let n): entry["state"] = .string("behind"); entry["behind"] = .number(Double(n))
            case let state: entry["state"] = .string(String(describing: state))
            }
            return .object(entry)
        case .folder:
            return .string(folder.path(percentEncoded: false))
        case .workspaces:
            await refreshOccupied(engine)
            return .object(["focused": Self.json(tiler.focused),
                            "occupied": .array(tiler.occupied.map { .object(["name": .string($0.name), "apps": .array($0.apps.map(JSONValue.string))]) })])
        case .onboarding:
            return await onboarding(engine)
        case .presses:
            return Self.counts(engine.topPresses(20))
        case .mac:
            return Self.thisMac(await sample())
        case .widgets:
            return WidgetDesk.shared.status()
        case .shelf:
            return await engine.shelf.status()
        case .notifications:
            return PilotNotifications.shared.status()
        }
    }

    private static func json(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }

    private static func counts(_ rows: [(action: String, count: Int)]) -> JSONValue {
        .array(rows.map { .object(["action": .string($0.action), "count": .number(Double($0.count))]) })
    }

    /// A problem with its fix as a command: Home's Restart for the tiler (HomeFix), else the page it opens.
    static func problem(_ p: HomeProblems.Problem) -> JSONValue {
        let fix: String? = switch (p.kind, p.place) {
        case (.tiler, _): "pilot run engine.restartTiler"
        case (_, let place?): "pilot open \(place.section?.rawValue ?? place.page.rawValue)"
        case (_, nil): nil
        }
        return .object(["kind": .string(String(describing: p.kind)), "title": .string(p.title), "detail": json(p.detail),
                        "fix": json(fix)])
    }

    /// Onboarding's Permissions as its window fills it, each row with whether it is done.
    private func onboarding(_ engine: Engine) async -> JSONValue {
        engine.gate.check()
        async let disk = fullDiskAccess(), events = systemEvents()
        var s = Onboarding.Status(accessibility: engine.gate.isTrusted, clashes: clashes(engine))
        s.fullDiskAccess = await disk
        await grants()?.apply(to: &s)
        systemEventsAllowed = Onboarding.systemEvents(answer: await events, last: systemEventsAllowed)
        s.systemEvents = systemEventsAllowed
        return .array(Onboarding.Row.allCases.map { row in
            .object(["row": .string(String(describing: row)), "title": .string(row.title), "detail": .string(row.detail(s)),
                     "done": .bool(Onboarding.isDone(row, s))])
        })
    }

    /// Home's This Mac block's four readings and the chip, as numbers; null fields when not read.
    static func thisMac(_ reading: (raw: SystemStats.Raw, values: SystemStats.Values?)?) -> JSONValue {
        guard let (raw, values) = reading else { return .null }
        return .object(["chip": raw.slow.machine.map { .string($0.chip) } ?? .null,
                        "cpuPercent": values?.cpu.map { .number(($0 * 100).rounded()) } ?? .null,
                        "memoryUsed": .number(Double(raw.memory.used)), "memoryTotal": .number(Double(raw.memory.total)),
                        "diskAvailable": raw.slow.disk.map { .number(Double($0.available)) } ?? .null,
                        "diskTotal": raw.slow.disk.map { .number(Double($0.total)) } ?? .null,
                        "temperature": values?.heat.map { .number(($0 * 10).rounded() / 10) } ?? .null])
    }

    /// Holds Home's watch until a reading newer than the ask has its CPU share, at most 5 s; the reading in hand then.
    static func sampleThisMac() async -> (raw: SystemStats.Raw, values: SystemStats.Values?)? {
        let sampler = SystemSampler.shared, asked = ProcessInfo.processInfo.systemUptime   // Raw.time's clock
        let watch = Task { await sampler.watch(stats: HomePage.readings) }
        defer { watch.cancel() }
        for _ in 0..<50 {
            if let raw = sampler.latest, raw.time >= asked, sampler.latestValues?.cpu != nil { return (raw, sampler.latestValues) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return sampler.latest.map { ($0, sampler.latestValues) }
    }

    /// The System Events probe onboarding's Permissions step ran before 1.1 (T54): TCC asked without a prompt.
    nonisolated static func mayControlSystemEvents() -> Int32 {
        var target = AEAddressDesc()
        let id = "com.apple.systemevents"
        _ = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &target) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }
}

extension ControlVerbs {
    /// `status` and `link`: what Home and General show about Pilot itself.
    func registerStatus(_ app: ControlStatus) {
        let names = ControlStatus.Part.allCases.map(\.rawValue)
        register(ControlVerb("status", help: "Pilot's live state as Home and General show it: Hyper, permissions, engine, problems, today; --part reads more.",
                             usage: "pilot status [--part <part>[,<part>…]] [--check]",
                             flags: [.init("part", help: "the parts to read, comma-separated: \(names.joined(separator: ", "))"),
                                     .init("check", help: "counts main's commits since this build first (a debug checkout build) and answers the update part", takesValue: false)],
                             schema: { .object(["parts": .array(ControlStatus.Part.allCases.map { .object(["name": .string($0.rawValue), "help": .string($0.help),
                                                                                                            "default": .bool($0.shown)]) })]) },
                             index: { .object(["parts": .array(names.map(JSONValue.string))]) },
                             detail: { word in ControlStatus.Part(rawValue: word).map { "pilot status --part \($0.rawValue): \($0.help)" } }) { call throws(ControlError) in
            let args = call.arguments()
            let check = args.has("check")
            var parts = try ControlStatus.parts(args.value("part"))
            if check, !parts.contains(.update) { parts.append(.update) }
            return try await app.status(parts, check: check)
        })
        register(ControlVerb("link", help: "Links ~/.local/bin/pilot to this Pilot's command, as General's Link button does, and answers the link's state.",
                             flags: []) { _ throws(ControlError) in
            app.link.makeLink()
            return try await app.status([.commandLink], check: false)
        })
    }
}
