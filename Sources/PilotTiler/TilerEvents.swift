import Foundation

/// What AeroSpace's socket `subscribe` sent, as values on an `AsyncStream` (code review: subscriptions become a stream).
public enum TilerEvent: Equatable, Sendable {
    case focusChanged(windowId: UInt32?, workspace: String)
    case focusedMonitorChanged(workspace: String, monitorId: Int)
    case workspaceChanged(workspace: String, prevWorkspace: String)
    case windowDetected(windowId: UInt32, workspace: String?, appBundleId: String?, appName: String?)
    /// Pilot (Window shelf, ADR 0015): a shown Stage workspace's windows or stage changed, or a shown workspace became or
    /// stopped being one, with no focus event saying so (a layout cycled, a shelved window closed, the first layout).
    case stagesChanged(workspace: String)
}

@MainActor private var subscribers: [UUID: AsyncStream<TilerEvent>.Continuation] = [:]

/// A stream of every event from now on; it ends when the caller stops iterating. `sendInitial` starts it with the current
/// state, as AeroSpace's `subscribe` does (subscriptions.swift, sendInitial).
@MainActor public func tilerEvents(sendInitial: Bool) -> AsyncStream<TilerEvent> {
    let (stream, continuation) = AsyncStream<TilerEvent>.makeStream()
    if sendInitial {
        let f = focus
        continuation.yield(.workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name))
        continuation.yield(.focusedMonitorChanged(workspace: f.workspace.name, monitorId: f.workspace.workspaceMonitor.monitorId_oneBased ?? 0))
        continuation.yield(.focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name))
    }
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { _ in Task { @MainActor in subscribers[id] = nil } }
    return stream
}

@MainActor func broadcastEvent(_ event: TilerEvent) {
    for continuation in subscribers.values { continuation.yield(event) }
}
