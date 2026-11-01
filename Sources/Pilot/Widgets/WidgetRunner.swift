import EventKit
import Foundation
import OSLog
import PilotCore

private let runLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// The one place a widget's command runs (ADR 0016). Trust is read from the widget's record on every run, never kept
/// from an earlier one: a locked widget runs nothing (Q680). The command runs from argv as a direct child, in the
/// widget's folder, with a fixed environment and its settings on stdin; it is stopped after 5 s with every process it
/// started, and so is a run whose task is cancelled (its widget hidden).
enum WidgetRunner {
    /// Who allowed a run. `.record`: the widget's trust record, the only grant for a widget in the Widgets folder.
    /// `.allowed`: Sven pressed Allow on `pilot widget check` for a folder outside it, one run; it never reaches a widget
    /// inside the Widgets folder, whose record alone decides.
    enum Grant: Sendable { case record, allowed }

    /// The run's answer, the trust it was read with (locked: nothing ran) and how long it took.
    struct Run: Sendable {
        let answer: Widget.Answer
        let trust: Widget.Trust
        let duration: Duration
    }

    /// `placement`'s own settings, over the widget's, go on its stdin (Edit widget).
    @concurrent static func run(_ widget: Widget, store: WidgetStore, grant: Grant = .record, size: Widget.Size? = nil,
                                placement: Widget.Placement? = nil,
                                environment pilot: [String: String] = ProcessInfo.processInfo.environment) async -> Run {
        let start = ContinuousClock.now
        // Allow stands for a folder outside the Widgets folder only; inside it the record decides, and trust(of:) reads
        // anything outside as locked.
        let trust: Widget.Trust = grant == .allowed && !store.holds(widget.folder) ? .madeHere : store.trust(of: widget)
        func done(_ answer: Widget.Answer) -> Run { Run(answer: answer, trust: trust, duration: ContinuousClock.now - start) }
        guard trust.runs else { return done(.error("locked: Trust this widget on the Widgets page to run its command")) }
        guard case .command(let argv, _) = widget.data else { return done(.error("it has no command")) }
        let environment = Widget.environment(id: widget.id, folder: widget.folder, from: pilot)
        guard let program = Widget.program(argv[0], folder: widget.folder, path: environment["PATH"] ?? "") else {
            return done(.error("\(argv[0]) is not an executable file in the widget's folder or on its PATH"))
        }
        let input = Widget.message(settings: await store.runSettings(of: widget, placement: placement), size: size ?? widget.size)
        do {
            let printed = try await ChildProcess.run(program.path, Array(argv.dropFirst()), environment: environment, input: input,
                                                     directory: widget.folder, timeout: Widget.timeout, limit: Widget.outputLimit)
            let answer = Widget.answer(printed)
            if case .error(let reason, let said?) = answer { runLog.notice("widget \(widget.id, privacy: .public): \(reason, privacy: .public): \(said, privacy: .private)") }
            return done(answer)
        } catch is ChildProcess.TooLarge {
            return done(.error("printed more than \(Widget.outputLimit / 1_000_000) MB, so it was stopped"))
        } catch is ChildProcess.TimedOut {
            return done(.error("stopped after \(Int(Widget.timeout.inSeconds)) s"))
        } catch is CancellationError {
            return done(.error("stopped: hidden"))
        } catch let failure as ChildProcess.Failure {
            runLog.notice("widget \(widget.id, privacy: .public) exited \(failure.status, privacy: .public): \(failure.message, privacy: .private)")
            return done(.error("exited \(failure.status)", said: String(failure.message.prefix(200))))
        } catch {
            return done(.error(String(error.localizedDescription.prefix(200))))
        }
    }
}

/// A reading feeds a widget the way a command does, as data, and Pilot draws a blocks widget from it itself, so a
/// locked blocks widget fed by readings renders (Q680). This Mac's readings hold the sampler's watch only while a widget
/// that shows them does; the calendar reads EventKit only when access was already given, never asking.
@MainActor
enum WidgetReadings {
    /// Holds what every reading of a widget needs read until the calling task is cancelled.
    static func watch(_ readings: [Widget.Reading]) async {
        await withTaskGroup(of: Void.self) { group in
            for reading in readings { group.addTask { await watch(reading) } }
        }
    }

    /// The readings now: one reading's data as it is, a few keyed by name.
    static func data(_ readings: [Widget.Reading], now: Date = .now) async -> JSONValue {
        if readings.count == 1 { return await data(readings[0], now: now) }
        var all: [String: JSONValue] = [:]
        for reading in readings { all[reading.rawValue] = await data(reading, now: now) }
        return .object(all)
    }

    /// The blocks Pilot draws for a few readings, in the widget's order.
    static func blocks(_ readings: [Widget.Reading], _ data: JSONValue) -> [Extension.Block] {
        guard readings.count > 1 else { return readings.first.map { blocks($0, data) } ?? [] }
        guard case .object(let all) = data else { return [] }
        return readings.flatMap { blocks($0, all[$0.rawValue] ?? .object([:])) }
    }

    /// Holds what `reading` needs read until the calling task is cancelled; returns at once for one read on demand.
    static func watch(_ reading: Widget.Reading) async {
        switch reading {
        case .cpu: await SystemSampler.shared.watch(stats: [.cpu])
        case .memory: await SystemSampler.shared.watch(stats: [.ram])
        case .network: await SystemSampler.shared.watch(stats: [.network])
        case .disk, .battery, .clock, .calendar: return
        }
    }

    /// The reading now, as the data a page would get.
    static func data(_ reading: Widget.Reading, now: Date = .now) async -> JSONValue {
        let values = SystemSampler.shared.latestValues
        switch reading {
        case .cpu: return .object(["percent": values?.cpu.map { .number(($0 * 100).rounded()) } ?? .null])
        case .memory: return .object(["percent": values.map { .number(($0.ram * 100).rounded()) } ?? .null])
        case .network:
            return .object(["down": values?.down.map(JSONValue.number) ?? .null, "up": values?.up.map(JSONValue.number) ?? .null])
        case .disk:
            guard let disk = await Task.detached(operation: { SystemReader.disk() }).value, disk.total > 0 else { return .object([:]) }
            return .object(["available": .number(Double(disk.available)), "total": .number(Double(disk.total)),
                            "percent": .number((100 * Double(disk.total - disk.available) / Double(disk.total)).rounded())])
        case .battery:
            guard let battery = await Task.detached(operation: { SystemReader.battery() }).value else { return .object(["present": .bool(false)]) }
            return .object(["present": .bool(true), "percent": .number(Double(battery.percent)), "charging": .bool(battery.charging),
                            "phrase": .string(battery.phrase)])
        case .clock:
            return .object(["time": .string(now.formatted(date: .omitted, time: .shortened)),
                            "date": .string(now.formatted(.dateTime.weekday(.wide).day().month(.wide))), "iso": .string(now.ISO8601Format())])
        case .calendar:
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .object(["access": .bool(false), "events": .array([])]) }
            let start = Calendar.current.startOfDay(for: now), end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
            let events = EventKitCalendar().events(in: DateInterval(start: start, end: end)).prefix(8).map { event -> JSONValue in
                .object(["title": .string(event.title), "allDay": .bool(event.allDay),
                         "start": .string(event.start.formatted(date: .omitted, time: .shortened))])
            }
            return .object(["access": .bool(true), "events": .array(Array(events))])
        }
    }

    /// The blocks Pilot draws for a reading's data.
    static func blocks(_ reading: Widget.Reading, _ data: JSONValue) -> [Extension.Block] {
        guard case .object(let d) = data else { return [] }
        func number(_ key: String) -> Double? { if case .number(let n)? = d[key] { n } else { nil } }
        func meter(_ label: String, _ note: String? = nil) -> [Extension.Block] {
            guard let percent = number("percent") else { return [.note(.init(text: "\(label): reading…"))] }
            return [.meter(.init(label: label, percent: percent, note: note, tone: percent >= 90 ? .alert : percent >= 75 ? .warn : nil))]
        }
        switch reading {
        case .cpu: return meter("CPU")
        case .memory: return meter("Memory")
        case .disk:
            let free = number("available").map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " free" }
            return meter("Disk", free)
        case .battery:
            if case .bool(false)? = d["present"] { return [.note(.init(text: "This Mac has no battery"))] }
            return meter("Battery", d["phrase"]?.string)
        case .network:
            let rate = { (key: String) in number(key).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" } ?? "–" }
            return [.stats([.init(label: "Down", value: rate("down")), .init(label: "Up", value: rate("up"))])]
        case .clock:
            return [.hero(.init(value: d["time"]?.string ?? "–", place: d["date"]?.string))]
        case .calendar:
            if case .bool(false)? = d["access"] { return [.note(.init(text: "Calendar access is off: the clock's popover asks for it"))] }
            guard case .array(let events)? = d["events"], !events.isEmpty else { return [.note(.init(text: "Nothing on today"))] }
            let rows = events.compactMap { event -> String? in
                guard case .object(let e) = event, let title = e["title"]?.string else { return nil }
                return "**\(e["allDay"] == .bool(true) ? "all day" : e["start"]?.string ?? "")** \(title)"
            }
            return [.markdown(rows.joined(separator: "\n\n"))]
        }
    }
}
