import Foundation
import OSLog
import PilotCore

/// One line of Pilot's log as `pilot log` answers it.
struct LogLine: Equatable, Sendable {
    let date: Date
    let category: String
    /// "error" (Logger's error and warning, one level in the store) or "fault".
    let level: String
    let message: String
}

extension ControlVerbs {
    /// The most lines `log` answers, the newest kept.
    static let logLines = 50

    /// `pilot log --last <span>` (Ask Pilot G7): Pilot's own errors and warnings, for troubleshooting. Read from this
    /// process's log store off the main actor; a private value reads back as <private> there (probe, 2026-10-16), and every
    /// line goes through LinkToken.redact besides. `read` hands back the lines since a date; a test hands in its own.
    func registerLog(read: @escaping @Sendable (Date) throws -> [LogLine] = ControlVerbs.pilotLog, now: @escaping @Sendable () -> Date = { Date() }) {
        register(ControlVerb("log", help: "Pilot's own errors and warnings from the last while, the newest first.",
                             usage: "pilot log [--last <30s|10m|2h>]",
                             flags: [.init("last", help: "how far back: 30s, 10m or 2h; 10m when left out, a day at most")]) { call throws(ControlError) in
            let since = now().addingTimeInterval(-(try Self.span(call.arguments().value("last") ?? "10m")))
            let read = await Task.detached { Result { try read(since) } }.value
            guard case .success(let lines) = read else { throw ControlError(.notReady, "Pilot's log did not read") }
            let newest = lines.filter { $0.date >= since }.sorted { $0.date > $1.date }
            return .object(["since": .string(since.ISO8601Format()), "count": .number(Double(newest.count)),
                            "lines": .array(newest.prefix(Self.logLines).map { line in
                                .object(["time": .string(line.date.ISO8601Format()), "category": .string(line.category),
                                         "level": .string(line.level), "message": .string(LinkToken.redact(line.message))])
                            })])
        })
    }

    /// "30s", "10m", "1h30m" in seconds, as a reminder's time reads; a day at most.
    static func span(_ text: String) throws(ControlError) -> TimeInterval {
        guard let seconds = Reminders.duration(text), seconds > 0 else {
            throw ControlError(.badValue, "--last takes a span as 30s, 10m, 2h or 1h30m")
        }
        guard seconds <= Reminders.longest else { throw ControlError(.outOfRange, "--last reaches a day back at most: 24h") }
        return seconds
    }

    /// Pilot's errors and faults since `since`, from this process's log store.
    nonisolated static func pilotLog(since: Date) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let errors = NSPredicate(format: "subsystem == %@ AND (messageType == error OR messageType == fault)", "dev.banozz.pilot")
        let entries = try store.getEntries(at: store.position(date: since), matching: errors)
        return entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level == .error || $0.level == .fault }.map {
            LogLine(date: $0.date, category: $0.category, level: $0.level == .fault ? "fault" : "error", message: $0.composedMessage)
        }
    }
}
