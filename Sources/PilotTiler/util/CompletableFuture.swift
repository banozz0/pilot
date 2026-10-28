// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/CompletableFuture.swift
import Dispatch

final class CompletableFuture<T>: Sendable {
    nonisolated(unsafe) private var value: T?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ t: T) {
        unsafe value = t
        semaphore.signal()
    }

    /// Nil when `complete` did not run within `timeout`: a termination wait on an app that stopped answering, or on a
    /// window its app no longer lists, gives up instead of holding Pilot's main thread (Moody fbYAVj96Ats).
    func blockingGet(timeout: Duration) -> T? {
        guard semaphore.wait(timeout: .now() + .nanoseconds(Int(timeout / .nanoseconds(1)))) == .success else { return nil }
        return unsafe value
    }
}
