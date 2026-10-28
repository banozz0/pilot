import Foundation
import os
import Synchronization

/// An internal engine error: a broken tree invariant, a failed cast, a missing value. AeroSpace ended the process
/// here (its `dieT`, now `raiseFaultT` in commonUtil.swift); inside Pilot that would take down the Hyper tap, menu and top bar too, so the
/// engine throws it instead and the session boundary recovers (code review, 2026-10-07, improvement 4).
public struct TilerFault: Error, CustomStringConvertible, Sendable {
    /// The bare message the engine gave, such as "… is already unbound".
    public let message: String
    /// AeroSpace's bug report: message, refresh event, thread, coordinate and stack trace.
    public let report: String

    public var description: String { report }
}

let tilerLog = Logger(subsystem: "dev.banozz.pilot", category: "tiler")
private let handler = Mutex<@Sendable (TilerFault) -> Void>({ tilerLog.fault("\($0.report, privacy: .public)") })

/// Pilot's hook for engine faults. It runs on the thread that hit the fault, once per fault, before the throw, so a
/// fault that a `try?` inside the engine swallows is still seen. Default: an os_log fault in `dev.banozz.pilot`.
public var tilerFaultHandler: @Sendable (TilerFault) -> Void {
    get { handler.withLock { $0 } }
    set { handler.withLock { $0 = newValue } }
}

/// The session boundary. A fault inside `body` leaves the engine as it would after a crash and a restart: every
/// window is unparked and the tree is dropped, so the next refresh rebuilds it from AX. The fault is rethrown so a
/// typed call tells its caller it failed; cancellation and other errors pass through untouched.
@MainActor
func withFaultBoundary<T>(_ body: @MainActor () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let fault as TilerFault {
        recoverFromFault()
        throw fault
    }
}

@MainActor
func recoverFromFault() {
    unparkAllWindows()
    MacWindow.dropAllForRebuild()
}
