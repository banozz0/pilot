// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/runLoop.swift
import ApplicationServices
import Foundation
import os
import Synchronization

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob,
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    /// Pilot: a cancellable wait gives up at `deadline` (default axWaitDeadline) with AxTimeout and cancels the job, so an
    /// app that stops answering cannot hold the session (card agent-bo-95422997, AC6). A non-cancellable job has no
    /// deadline; the termination waits bound themselves (MacApp.terminationWait).
    func runInLoop<T: Sendable>(
        _ cm: CancellationMode,
        deadline: Duration? = nil,
        _ body: @Sendable @escaping (RunLoopJob) throws -> T,
    ) async throws -> T { // todo try to convert to typed throws
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        let deadline = cm == .cancellable ? deadline ?? axWaitDeadline : nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                // cont.resume must run exactly once: the job and the deadline race for it
                let once = Mutex<CheckedContinuation<T, any Error>?>(cont)
                let timer = deadline.map { deadline in
                    Task.detached {
                        guard (try? await Task.sleep(for: deadline)) != nil else { return } // the job answered first
                        job.cancel()
                        once.withLock { $0.take() }?.resume(throwing: AxTimeout())
                    }
                }
                let resume: @Sendable (Result<T, any Error>) -> Void = { result in
                    timer?.cancel()
                    once.withLock { $0.take() }?.resume(with: result)
                }
                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    do {
                        try job.checkCancellation()
                        resume(.success(try body(job)))
                    } catch {
                        let nonCancellableFailed = cm == .nonCancellable && !(error is TilerFault)
                        resume(.failure(nonCancellableFailed ? fault("Non-cancellable job failed: \(error)") : error))
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
        _refreshSessionEvent = refreshSessionEvent
    }
    @objc func action() {
        if autoCheckCancelled && job.isCancelled { return }
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            _action(job)
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    // Alternative 1. In macOS 15, it's possible to use `Atomic<Bool>` from `Synchronization` module
    // Alternative 2. https://github.com/apple/swift-atomics/tree/main but I don't want to add one more dependency just for
    //                AtomicBool
    nonisolated(unsafe) private var _isCancelled: Int32 = 0
    var isCancelled: Bool { unsafe _isCancelled == 1 }
    func cancel() {
        if cm == .nonCancellable { return }
        while !isCancelled {
            unsafe OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    let cm: CancellationMode
    public init(_ cm: CancellationMode) { self.cm = cm }

    static let cancelled: RunLoopJob = RunLoopJob(.cancellable).also { $0.cancel() }

    func checkCancellation() throws {
        if cm == .cancellable && isCancelled {
            throw CancellationError()
        }
    }
}

/// An app's AX thread did not answer by the deadline: the app is hung or busy.
struct AxTimeout: Error {}

/// Pilot (card agent-bo-95423039): `body` for one window; an app that misses its AX deadline is skipped until the next
/// session, so the rest of the refresh and layout goes on. MacApp.answering logs the stall once.
@MainActor
func skippingSlowApp(_ body: @MainActor () async throws -> Void) async throws {
    do { try await body() } catch is AxTimeout {}
}

private let stallLog = Mutex<@Sendable (String) -> Void>({ tilerLog.notice("\($0, privacy: .public)") })

/// Where a stalled app is told: once per stall, when it first misses its deadline. Tests swap it.
var axStallLog: @Sendable (String) -> Void {
    get { stallLog.withLock { $0 } }
    set { stallLog.withLock { $0 = newValue } }
}

/// How long one AX call on an app may take (AXUIElementSetMessagingTimeout on every app and window element; the default is
/// about 6 s).
let axMessagingTimeout: Duration = .seconds(1)

/// After an app missed its deadline, how long the engine stops waiting on it before asking again (MacApp.answering).
let axUnansweredPause: Duration = .seconds(5)

extension AXUIElement {
    /// This element's AX calls give up after axMessagingTimeout. Apple sets it per object ("sets it only for that
    /// object", AXUIElement.h), so the app element and each window element get it; the system-wide one would change
    /// every AX call Pilot makes.
    func withMessagingTimeout() -> AXUIElement {
        AXUIElementSetMessagingTimeout(self, Float(axMessagingTimeout / .milliseconds(1)) / 1000)
        return self
    }
}

/// How long the engine waits for an app's AX thread: one timed-out AX call plus room for the thread to get to the job.
let axWaitDeadline: Duration = axMessagingTimeout + .milliseconds(250)
