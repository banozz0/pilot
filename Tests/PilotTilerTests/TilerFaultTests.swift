import Foundation
@testable import PilotTiler
import Synchronization
import Testing

// Nested in TilerTreeTests: it binds and drops tree nodes, so it must not meet a tree test at an `await`.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct TilerFaultTests {
        /// AeroSpace crash #1311's shape: a node unbound twice. In AeroSpace `dieT` ends the process; here the fault
        /// reaches Pilot's handler, the boundary rethrows it and the test process is still running to check.
        @Test func anInternalErrorReachesPilotsHandlerAndTheProcessLives() async throws {
            let seen = FaultLog()
            let previous = tilerFaultHandler
            tilerFaultHandler = { fault in seen.faults.withLock { $0.append(fault) } }
            defer { tilerFaultHandler = previous }

            let node = try Workspace.get(byName: "fault-test").rootTilingContainer
            try node.unbindFromParent()
            await #expect(throws: TilerFault.self) {
                try await withFaultBoundary { _ = try node.unbindFromParent() }
            }

            let faults = seen.faults.withLock { $0 }
            #expect(faults.count == 1)
            #expect(faults.first?.message.contains("is already unbound") == true)
        }

        /// After a fault the tree is dropped so the next refresh rebuilds it from AX; a later session runs normally.
        @Test func theEngineWorksAgainAfterAFault() async throws {
            let previous = tilerFaultHandler
            tilerFaultHandler = { _ in }
            defer { tilerFaultHandler = previous }

            await #expect(throws: TilerFault.self) {
                try await withFaultBoundary { try raiseFault("boom") }
            }
            #expect(MacWindow.allWindowsMap.isEmpty)
            let name = try await withFaultBoundary { Workspace.get(byName: "after-fault").name }
            #expect(name == "after-fault")
        }

        /// Moody fbYAVj96Ats: the rebuild after a fault put every window on the focused workspace. Each window's
        /// workspace and floating state are remembered when the tree is dropped, and a re-registered window goes back
        /// there instead of to focus.workspace.
        @Test func aFaultRemembersWhereEachWindowSat() throws {
            let one = Workspace.get(byName: "recover-1"), two = Workspace.get(byName: "recover-2")
            try TestWindow.new(id: 1, parent: one.rootTilingContainer)
            try TestWindow.new(id: 2, parent: two.floatingWindowsContainer)
            let placements = recoveryPlacements(of: one.allLeafWindowsRecursive + two.allLeafWindowsRecursive)
            #expect(placements == [
                1: RecoveredPlacement(workspace: "recover-1", isFloating: false),
                2: RecoveredPlacement(workspace: "recover-2", isFloating: true),
            ])

            recoveredPlacements = placements
            defer { recoveredPlacements = [:] }
            #expect(registrationWorkspace(windowId: 2, rect: nil).workspace.name == "recover-2")
            #expect(recoveredPlacements[2] == nil, "a placement is used once")
            #expect(registrationWorkspace(windowId: 9, rect: nil).workspace == focus.workspace)
        }

        /// Moody fbYAVj96Ats: unparking waited forever on a window its app no longer listed. A termination wait now
        /// gives up after its deadline.
        @Test func aTerminationWaitEndsAtItsDeadline() {
            let start = ContinuousClock.now
            #expect(CompletableFuture<Int>().blockingGet(timeout: .milliseconds(50)) == nil)
            #expect(ContinuousClock.now - start < .seconds(1))
            let done = CompletableFuture<Int>()
            done.complete(7)
            #expect(done.blockingGet(timeout: .milliseconds(50)) == 7)
        }
    }
}

private final class FaultLog: Sendable {
    let faults = Mutex<[TilerFault]>([])
}
