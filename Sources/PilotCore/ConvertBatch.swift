import Foundation

/// Convert's ways in (card agent-bo-95423211): Finder's Convert with Pilot… and a file row's Convert to… both open the
/// menu's picker on these rows.
public extension Convert {
    /// A row per format, a row waiting for a tool saying so: picking that row offers Install.
    static func rows(_ options: [ConvertOption]) -> [MenuEntry] {
        options.map { MenuEntry(title: $0.format.title, target: .action("convert.\($0.format.rawValue)"), detail: $0.needs.map { ConvertError.needs($0).description }) }
    }
}

/// Files converted to one format one after another: those already in it are skipped, a failure is noted and the rest
/// go on, a cancel stops the file in hand and keeps the ones finished. Its lines are the tips' text.
public struct ConvertBatch: Sendable {
    public let urls: [URL]
    public let skipped: [URL]
    public let format: ConvertFormat

    public init(_ urls: [URL], to format: ConvertFormat) {
        (skipped, self.urls) = (urls.filter { ConvertFormat(of: $0) == format }, urls.filter { ConvertFormat(of: $0) != format })
        self.format = format
    }

    public struct Outcome: Sendable {
        public var written: [URL] = []
        public var failed: [(URL, String)] = []
        public var cancelled = false

        public init() {}
    }

    /// Converts each file in turn; `progress` hears, before each file after the first, how many are done. A cancel ends
    /// it early, `cancelled` set and the files finished kept.
    public func run(with converter: Converter, progress: @MainActor @Sendable (Int) async -> Void) async -> Outcome {
        var outcome = Outcome()
        for (i, url) in urls.enumerated() {
            if i > 0 { await progress(i) }
            do {
                try Task.checkCancellation()
                outcome.written.append(try await converter.convert(url, to: format))
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failed.append((url, String(describing: error)))
            }
        }
        return outcome
    }

    /// The progress tip with `done` files finished.
    public func progress(_ done: Int) -> String {
        urls.count == 1 ? "Converting \(urls[0].lastPathComponent) to \(format.title)…" : "Converting \(done + 1) of \(urls.count) to \(format.title)…"
    }

    /// The finished tip: a cancel, what was written, then what failed and what was already in the format.
    public func summary(_ outcome: Outcome) -> String {
        let written = outcome.written.count
        var parts = outcome.cancelled ? ["Conversion cancelled"] : []
        if written > 0 || (parts.isEmpty && outcome.failed.isEmpty && skipped.isEmpty) {
            parts.append(written == 1 && urls.count == 1 ? "\(outcome.written[0].lastPathComponent) is ready"
                         : "\(written) \(written == 1 ? "file" : "files") converted to \(format.title)")
        }
        parts += outcome.failed.map { "\($0.0.lastPathComponent) failed: \($0.1)" }
        parts += skipped.map { "\($0.lastPathComponent) was already \(format.title)" }
        return parts.joined(separator: "; ")
    }
}
