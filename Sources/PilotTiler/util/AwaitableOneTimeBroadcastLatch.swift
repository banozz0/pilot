// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/AwaitableOneTimeBroadcastLatch.swift
import Foundation

actor AwaitableOneTimeBroadcastLatch {
    private var done = false
    private var awaiters: [UniqueToken: Nullable<CheckedContinuation<(), any Error>>] = [:]

    func await() async throws {
        try checkCancellation()
        if done { return }

        let id = UniqueToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(), any Error>) in
                switch awaiters.removeValue(forKey: id) {
                    case let awaiter?:
                        checkSoft(awaiter.isNull)
                        cont.resume(throwing: CancellationError())
                    case nil where done: cont.resume()
                    case nil: awaiters[id] = .just(cont)
                }
            }
        } onCancel: {
            Task.startUnstructured { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UniqueToken) {
        switch awaiters.removeValue(forKey: id) {
            case let awaiter?: (try? awaiter.valueOrNil.orFault())?.resume(throwing: CancellationError())
            case nil where !done:
                // Indicate to 'await' that the client should be cancelled right away when it suspends
                awaiters[id] = .null
            case nil: break
        }
    }

    func signalToAll() {
        done = true
        for (_, awaiter) in awaiters {
            awaiter.valueOrNil?.resume()
        }
        awaiters = [:]
    }
}
