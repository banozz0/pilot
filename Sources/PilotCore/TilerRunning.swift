import Foundation

/// The pause between chained steps that race app activation (spike test 3).
public let tilerSettle: Duration = .milliseconds(300)

/// One tiler call and its answer: InProcessTiler runs it (card agent-bo-95422997), tests a fake (workspace presets).
/// `events` is the tiler's event stream.
@MainActor public protocol TilerRunning: Sendable {
    @discardableResult func run(_ command: AeroCommand) async throws -> String
    func events() -> AsyncStream<AeroEvent>
}

/// The tiler ran the call and it did nothing: no such window, no neighbour that way (TilerCallRefused).
public protocol AeroCallRefusal: Error {}

extension TilerRunning {
    public func windows(_ scope: AeroCommand.WindowScope) async throws -> [AeroWindow] {
        try AeroWindow.parse(try await run(.listWindows(scope)))
    }

    /// The workspace each monitor shows.
    public func visibleWorkspaces() async throws -> [AeroMonitorWorkspace] {
        try AeroMonitorWorkspace.parse(try await run(.listVisibleWorkspaces))
    }

    public func focusedWorkspace() async throws -> AeroWorkspace? {
        try AeroWorkspace.parse(try await run(.focusedWorkspace)).first
    }

    /// Width then height by `step` (card agent-bo-95422754), `settle` apart when the width changed. The tiler refuses an
    /// axis the window has no split along (AeroCallRefusal); that axis is skipped, not a failure. Any other error throws.
    /// Returns the axes that changed.
    public func resizeBoth(id: Int, by step: Int, settle: Duration = tilerSettle) async throws -> [AeroCommand.Axis] {
        var changed: [AeroCommand.Axis] = []
        for axis in [AeroCommand.Axis.width, .height] {
            if axis == .height, !changed.isEmpty { try await Task.sleep(for: settle) }
            do { try await run(.resize(id: id, axis, by: step)); changed.append(axis) }
            catch is AeroCallRefusal {}
        }
        return changed
    }

    /// The tiler's focused window, only once it belongs to `pid`. Chained steps race app activation (spike test 3), so a
    /// mismatch waits `settle` once and asks again; nil means focus never got there.
    public func focusedWindow(ownedBy pid: Int32, settle: Duration = tilerSettle) async throws -> AeroWindow? {
        if let window = try await windows(.focused).first, window.pid == pid { return window }
        try await Task.sleep(for: settle)
        return try await windows(.focused).first { $0.pid == pid }
    }
}

/// Splits a byte stream into complete lines; keeps a partial line until its newline arrives. The file index (FileIndex)
/// reads its pipe through it.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    public init() {}

    public func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    /// The partial line left at the end of the stream, nil when the stream ended on a newline.
    public func flush() -> String? {
        lock.withLock {
            defer { pending = Data() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}
