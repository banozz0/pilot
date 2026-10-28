// Pilot's own tests for the typed calls AeroSpace 74a1bf17 had no test for: close-all-windows-but-current, enable,
// focus --window-id, eval (calls in one session), the scrolling toggle, and version/subscribe as tilerEvents().
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct PilotCallsTest {
        /// `close-all-windows-but-current`: every other window of the workspace closes, floating ones too; other
        /// workspaces keep theirs.
        @Test func closeAllButCurrent() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                    #expect(focused)
                    try TestWindow.new(id: 2, parent: $0)
                    try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 3, parent: $0)
                    }
                }
                try TestWindow.new(id: 4, parent: $0.floatingWindowsContainer)
            }
            try TestWindow.new(id: 5, parent: Workspace.get(byName: "b").rootTilingContainer)

            try await run { try focus.workspace.closeAll(but: focusedWindow()) }
            #expect(workspace.allLeafWindowsRecursive.map(\.windowId) == [1])
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(Workspace.get(byName: "b").allLeafWindowsRecursive.map(\.windowId) == [5])
        }

        /// `enable on|off`: on keeps each floating window's size for later (EnableCommand.swift), off leaves it.
        @Test func enableOnAndOff() async throws {
            let workspace = Workspace.get(byName: name)
            let floating = try TestWindow.new(
                id: 1,
                parent: workspace.floatingWindowsContainer,
                rect: Rect(topLeftX: 10, topLeftY: 10, width: 300, height: 200),
            )
            let tiled = try TestWindow.new(id: 2, parent: workspace.rootTilingContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 50, height: 50))
            #expect(!isTilerEnabled)

            await setTilerEnabled(true)
            #expect(isTilerEnabled)
            #expect(floating.lastFloatingSize == CGSize(width: 300, height: 200))
            #expect(tiled.lastFloatingSize == nil)

            await setTilerEnabled(false)
            #expect(!isTilerEnabled)
            #expect(floating.lastFloatingSize == CGSize(width: 300, height: 200))
        }

        /// `focus --window-id N` (FocusCommand.swift's window-id branch, `Window.get(byId:)` then `focusWindow()`): the
        /// window and its workspace take the focus; an unknown id changes nothing.
        @Test func focusWindowById() async throws {
            try Workspace.get(byName: "a").rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }
            try TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)

            #expect(try await run { try Window.get(byId: 2)?.focusWindow() == true })
            #expect(focus.windowOrNil?.windowId == 2)
            #expect(focus.workspace.name == "b")

            #expect(try await run { try Window.get(byId: 99)?.focusWindow() == true } == false)
            #expect(focus.windowOrNil?.windowId == 2)
        }

        /// `eval 'move-node-to-workspace --window-id 2 b; focus --window-id 2'` (LayoutPreset's drop): the calls run in
        /// order inside one session.
        @Test func evalIsCallsInOneSession() async throws {
            try Workspace.get(byName: "a").rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
                try TestWindow.new(id: 2, parent: $0)
            }

            try await run {
                let window = try #require(Window.get(byId: 2))
                try window.moveToWorkspace(Workspace.get(byName: "b"))
                _ = try window.focusWindow()
            }
            #expect(try Workspace.get(byName: "b").layoutDescription == .workspace([.h_tiles([.window(2)])]))
            #expect(focus.windowOrNil?.windowId == 2)
            #expect(focus.workspace.name == "b")
        }

        /// `layout --workspace W --root tiles scrolling`: each call toggles the root.
        @Test func toggleScrolling() async throws {
            let workspace = Workspace.get(byName: name)
            try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

            #expect(try await run { try workspace.setRootLayout(toggling: [.tiles, .scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            #expect(try await run { try workspace.setRootLayout(toggling: [.tiles, .scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .tiles)
        }

        /// `--version` and `subscribe focused-workspace-changed focus-changed window-detected`: in-process there is no
        /// server to ask, so the subscription is tilerEvents(), and a listener hears the focus and a detected window.
        @Test func tilerEventsCarryFocusAndDetectedWindows() async throws {
            try TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
            try await refreshModel_nonCancellable() // settle the last known focus before listening
            let events = tilerEvents(sendInitial: false)
            var iterator = events.makeAsyncIterator()

            try await run { try Window.get(byId: 2)?.focusWindow() == true }
            #expect(await iterator.next() == .focusChanged(windowId: 2, workspace: "b"))
            #expect(await iterator.next() == .workspaceChanged(workspace: "b", prevWorkspace: "setUpWorkspacesForTests"))

            let detected = try TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
            try await runOnWindowDetected(ifConventional: detected)
            #expect(await iterator.next() == .windowDetected(
                windowId: 3,
                workspace: "b",
                appBundleId: "bobko.AeroSpace.test-app",
                appName: "bobko.AeroSpace.test-app",
            ))
        }
    }
}
