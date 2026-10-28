// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/WorkspaceCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `workspace <name>` is focusWorkspace(named:), `workspace --wrap-around next|prev` is focusNextWorkspace(_:),
// `workspace-back-and-forth` (what `--auto-back-and-forth` ran) is focusPreviousWorkspace().
extension TilerTreeTests {
    @MainActor
    @Suite
    struct WorkspaceCommandTest {
        @Test func direct_focusDifferentWorkspace() async throws {
            #expect(Workspace.get(byName: "a").focusWorkspace())

            #expect(try await run { focusWorkspace(named: "b") })
            #expect(focus.workspace.name == "b")
        }

        @Test func direct_alreadyFocused() async throws {
            #expect(Workspace.get(byName: "a").focusWorkspace())

            #expect(try await run { focusWorkspace(named: "a") } == false)
            #expect(focus.workspace.name == "a")
        }

        @Test func backAndForth_focusesPrev() async throws {
            // Make "b" alive so it can be focused as the back-and-forth target.
            _ = Workspace.get(byName: "b")
            #expect(Workspace.get(byName: "a").focusWorkspace())
            _prevFocusedWorkspaceName = "b"

            #expect(try await run { focusPreviousWorkspace() })
            #expect(focus.workspace.name == "b")
        }

        @Test func backAndForth_noPrev_fails() async throws {
            #expect(Workspace.get(byName: "a").focusWorkspace())
            // _prevFocusedWorkspaceName is nil from setUp: nothing to go back to.

            #expect(try await run { focusPreviousWorkspace() } == false)
            #expect(focus.workspace.name == "a")
        }

        // AeroSpace's `--stdin` cases ran next/prev over a list read from stdin; Pilot's next/prev runs over the
        // monitor's workspaces, so these keep a, b and c alive as persistent workspaces instead.

        @Test func relativePrev() async throws {
            try keepAlive(["a", "b", "c"], focused: "b")

            #expect(try await run { focusNextWorkspace(false) })
            #expect(focus.workspace.name == "a")
        }

        @Test func relativeNext_wrapAround() async throws {
            try keepAlive(["a", "b", "c"], focused: "c")

            #expect(try await run { focusNextWorkspace(true) })
            #expect(focus.workspace.name == "a")
        }

        @Test func relativePrev_wrapAround() async throws {
            try keepAlive(["a", "b", "c"], focused: "a")

            #expect(try await run { focusNextWorkspace(false) })
            #expect(focus.workspace.name == "c")
        }

        @Test func relativeNext_noStdin_picksFromAllWorkspaces() async throws {
            // Without --stdin, getNextPrevWorkspace pulls from Workspace.all on the focused monitor.
            _ = Workspace.get(byName: "b") // keep "b" alive in the registry
            _ = Workspace.get(byName: "c")
            #expect(Workspace.get(byName: "a").focusWorkspace())

            #expect(try await run { focusNextWorkspace(true) })
            #expect(focus.workspace.name == "b")
        }

        private func keepAlive(_ names: [String], focused: String) throws {
            config.persistentWorkspaces = names
            try #require(Workspace.get(byName: focused).focusWorkspace())
            Workspace.garbageCollectUnusedWorkspaces()
            try #require(Workspace.all.map(\.name) == names)
        }
    }
}
