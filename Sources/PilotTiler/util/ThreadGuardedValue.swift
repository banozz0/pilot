// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/ThreadGuardedValue.swift

/// Pilot: a wrong-thread access is reported (`checkSoft`), a use after `destroy` throws; writes go through
/// `modify` because a throwing getter cannot have a setter.
final class ThreadGuardedValue<Value>: Sendable {
    nonisolated(unsafe) private var _threadGuarded: Value?
    private let owningThread: AxAppThreadToken?
    init(_ value: Value) {
        owningThread = axTaskLocalAppThreadToken
        checkSoft(owningThread != nil, "axTaskLocalAppThreadToken is not initialized")
        unsafe self._threadGuarded = value
    }
    var threadGuarded: Value {
        get throws {
            checkThread()
            return try unsafe _threadGuarded.orFault("Value is already destroyed")
        }
    }
    func modify<R>(_ body: (inout Value) throws -> R) throws -> R {
        var value = try threadGuarded
        defer { unsafe _threadGuarded = value }
        return try body(&value)
    }
    func destroy() {
        checkThread()
        unsafe _threadGuarded = nil
    }
    private func checkThread() {
        checkSoft(owningThread == axTaskLocalAppThreadToken, "\(owningThread.prettyDescription) != \(axTaskLocalAppThreadToken.prettyDescription)")
    }
    deinit {
        unsafe checkSoft(_threadGuarded == nil, "The Value must be explicitly destroyed on the appropriate thread before deinit")
    }
}
