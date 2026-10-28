import Foundation
@testable import PilotTiler
import Testing

/// Parity AC6 (card agent-bo-95422997): an app that never answers no longer holds the engine. Its AX thread is faked
/// by a thread whose job never returns in time; the wait gives up at its deadline, and the refresh keeps that app's
/// windows as they were instead of dropping them.
@Suite struct AxDeadlineTests {
    /// A run-loop thread like each app's AX thread (MacApp.getOrRegister).
    private static func appThread() -> Thread {
        let thread = Thread {
            RunLoop.current.add(Port(), forMode: .default)
            RunLoop.current.run()
        }
        thread.start()
        return thread
    }

    @Test func aHungAppsWaitEndsAtTheDeadline() async throws {
        let thread = Self.appThread()
        let start = ContinuousClock.now
        await #expect(throws: AxTimeout.self) {
            try await thread.runInLoop(.cancellable, deadline: .milliseconds(300)) { _ in Thread.sleep(forTimeInterval: 3) }
        }
        #expect(ContinuousClock.now - start < .milliseconds(300) + .milliseconds(500))
    }

    @Test func anAnsweringAppIsUnaffected() async throws {
        let thread = Self.appThread()
        #expect(try await thread.runInLoop(.cancellable, deadline: .seconds(1)) { _ in 7 } == 7)
    }

    /// Every cancellable AX wait carries the deadline: the messaging timeout AX calls get, plus room for the thread.
    @Test func theDeadlineCoversTheMessagingTimeout() {
        #expect(axMessagingTimeout == .seconds(1))
        #expect(axWaitDeadline > axMessagingTimeout)
        #expect(axWaitDeadline <= axMessagingTimeout + .milliseconds(500))
    }

    /// Lane 1 (card agent-bo-95423031, 2026-10-08): with TextEdit stopped, a window bind took 3.4 s. Registering the newly
    /// front app subscribes to its AX notifications, each waiting out the messaging timeout, and the session waited for
    /// that without a deadline. Now a registration still going at the deadline leaves the app out of this session.
    @Test @MainActor func aRegistrationStillGoingAtTheDeadlineLeavesTheAppOut() async throws {
        let never = AwaitableOneTimeBroadcastLatch()
        let start = ContinuousClock.now
        #expect(try await !MacApp.registered(never, since: start, deadline: .milliseconds(200)))
        #expect(ContinuousClock.now - start < .milliseconds(200) + .milliseconds(300))
    }

    @Test @MainActor func aRegistrationThatEndsInTimeIsAwaited() async throws {
        let quick = AwaitableOneTimeBroadcastLatch()
        Task { try await Task.sleep(for: .milliseconds(50)); await quick.signalToAll() }
        #expect(try await MacApp.registered(quick, since: .now, deadline: .seconds(1)))
    }

    /// A later session finds the same registration past its deadline and does not wait for it again.
    @Test @MainActor func aRegistrationPastItsDeadlineIsNotAwaitedAgain() async throws {
        let start = ContinuousClock.now
        #expect(try await !MacApp.registered(AwaitableOneTimeBroadcastLatch(), since: start - .seconds(2), deadline: .seconds(1)))
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }
}

