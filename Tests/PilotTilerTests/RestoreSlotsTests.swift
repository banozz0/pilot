import Foundation
@testable import PilotTiler
import Testing

/// Card agent-bo-95423036: a quitting app's tiled windows are remembered by app, title, workspace, place in the tree and
/// share of its parent, and its relaunched windows go back there. TestApp is the fake app; its quit is `appQuit(pid:)`, as the engine
/// calls it on NSWorkspace's terminate notification.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct RestoreSlotsTests {
        let app = TestApp.shared.rawAppBundleId!
        let day: TimeInterval = 24 * 60 * 60
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        /// Workspace 2, focused, as a slot goes back only to a workspace on screen: [1 "a.txt" weight 2, v[2, 3 "c.txt"
        /// weight 3]], floating 4, and 9 which stays.
        func quitTree() throws -> (Workspace, [Window]) {
            let workspace = Workspace.get(byName: "2")
            #expect(workspace.focusWorkspace())
            var windows: [Window] = []
            try workspace.rootTilingContainer.with { root in
                windows.append(try TestWindow.new(id: 1, parent: root, adaptiveWeight: 2))
                try TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).with {
                    windows.append(try TestWindow.new(id: 2, parent: $0))
                    windows.append(try TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3))
                }
                try TestWindow.new(id: 9, parent: root)
            }
            windows.append(try TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer))
            windowTitles = [1: "a.txt", 3: "c.txt", 4: "float"]
            return (workspace, windows)
        }

        func slot(_ title: String, _ path: [Int], _ share: CGFloat) -> WindowSlot {
            WindowSlot(appBundleId: app, title: title, workspace: "2", path: path, share: share, saved: t0)
        }

        /// The app's windows leave the tree, as the refresh after its quit garbage-collects them.
        func close(_ windows: [Window]) throws {
            for window in windows { try window.unbindFromParent() }
            try Workspace.get(byName: "2").normalizeContainers()
        }

        /// A new window of the app, bound where the slots put it, else left on workspace 9 (off the focused workspace, so
        /// it is no sibling there while the slot's share is worked out).
        func open(_ id: UInt32, title: String, in slots: WindowSlots) async throws -> TestWindow {
            let window = try TestWindow.new(id: id, parent: Workspace.get(byName: "9").rootTilingContainer)
            if let title = await slots.title(for: app, read: { title }), let data = slots.placement(appBundleId: app, title: title) {
                try window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            }
            return window
        }

        @Test func aQuitSavesEachTiledWindow() throws {
            let slots = WindowSlots(now: { t0 })
            _ = try quitTree()
            slots.appQuit(pid: TestApp.shared.pid)
            // Each one's part of its parent: 2 of the root's 4, 1 and 3 of the v-split's 4, 1 of the root's 4.
            #expect(slots.slots == [slot("a.txt", [0], 0.5), slot("", [1, 0], 0.25), slot("c.txt", [1, 1], 0.75), slot("", [2], 0.25)])
        }

        @Test func windowsThatLeftJustBeforeTheQuitAreSaved() throws {
            var now = t0
            let slots = WindowSlots(now: { now })
            let (_, windows) = try quitTree()
            slots.windowsLeaving([windows[0]])
            try close([windows[0]])
            now += 2
            slots.windowsLeaving([windows[1], windows[2]])
            try close([windows[1], windows[2]])
            slots.appQuit(pid: TestApp.shared.pid)
            #expect(slots.slots.map(\.path) == [[0], [1, 0], [1, 1], [2]])
            #expect(slots.slots.map(\.title) == ["a.txt", "", "c.txt", ""])
        }

        @Test func windowsThatLeftLongBeforeTheQuitAreNot() throws {
            var now = t0
            let slots = WindowSlots(now: { now })
            let (_, windows) = try quitTree()
            slots.windowsLeaving([windows[0]])
            try close([windows[0]])
            now += 60
            slots.appQuit(pid: TestApp.shared.pid)
            #expect(slots.slots.map(\.title) == ["", "c.txt", ""])
        }

        @Test func aMatchingTitleGoesBackToItsSlot() async throws {
            let slots = WindowSlots(now: { t0 })
            let (workspace, windows) = try quitTree()
            slots.appQuit(pid: TestApp.shared.pid)
            try close(windows.filter { $0.windowId != 9 })
            let c = try await open(13, title: "c.txt", in: slots)
            #expect(c.nodeWorkspace == workspace)
            let root = try workspace.rootTilingContainer
            #expect(c.parent === root, "its v-split is gone, so it sits where it was")
            #expect(try c.ownIndex == 1)
            #expect(try c.getWeight(.h) == 0.75 * 1 * 2, "three quarters beside 9 at 1, once the layout spreads the rest")
            let a = try await open(11, title: "a.txt", in: slots)
            #expect(a.parent === root)
            #expect(try a.ownIndex == 0)
            #expect(try a.getWeight(.h) == 0.5 * 2.5 * 3 / 2, "half beside 9 and c, 2.5 in all")
            #expect(slots.slots.map(\.title) == ["", ""])
        }

        @Test func noMatchingTitleTakesTheNextSlotInOrder() async throws {
            let slots = WindowSlots(now: { t0 })
            let (workspace, windows) = try quitTree()
            slots.appQuit(pid: TestApp.shared.pid)
            try close(windows.filter { $0.windowId != 9 })
            let first = try await open(11, title: "Untitled", in: slots)
            #expect(first.nodeWorkspace == workspace)
            #expect(try first.ownIndex == 0)
            #expect(slots.slots.map(\.title) == ["", "c.txt", ""])
        }

        @Test func aSurvivingContainerTakesItsWindowBack() async throws {
            let slots = WindowSlots(now: { t0 })
            let (workspace, windows) = try quitTree()
            slots.appQuit(pid: TestApp.shared.pid)
            try close([windows[2]]) // only 3 quit with the app; 2 keeps the v-split alive
            let split = try #require(windows[1].parent as? TilingContainer)
            slots.slots = slots.slots.filter { $0.title == "c.txt" }
            let c = try await open(13, title: "c.txt", in: slots)
            #expect(c.parent === split)
            #expect(try c.ownIndex == 1)
            #expect(c.nodeWorkspace == workspace)
        }

        @Test func aGoneWorkspaceOrNoSlotLandsAsToday() async throws {
            let slots = WindowSlots(now: { t0 })
            slots.slots = [WindowSlot(appBundleId: app, title: "a.txt", workspace: "gone", path: [0], share: 0.5, saved: t0)]
            var read = false
            #expect(await slots.title(for: app, read: { read = true; return "a.txt" }) == "a.txt")
            #expect(read)
            #expect(slots.placement(appBundleId: app, title: "a.txt") == nil, "its workspace is gone")
            // Sven, 2026-10-24 (build 88): GitHub opened on workspace 2 went back to its slot on 1, and Pilot followed it there
            #expect(Workspace.get(byName: "1").focusWorkspace())
            slots.slots = [slot("a.txt", [0], 0.5)]
            #expect(!Workspace.get(byName: "2").isVisible)
            #expect(slots.placement(appBundleId: app, title: "a.txt") == nil, "its workspace is not on screen")
            read = false
            #expect(await slots.title(for: "other.app", read: { read = true; return "" }) == nil)
            #expect(slots.placement(appBundleId: "other.app", title: "") == nil)
            #expect(!read, "an app with no slots costs no title read")
        }

        @Test func slotsPersistAndAWeekOldOneIsDropped() throws {
            let dir = FileManager.default.temporaryDirectory.appending(path: "RestoreSlotsTests-\(UUID().uuidString)")
            let file = dir.appending(path: "Pilot/window-slots.json")
            let saved = WindowSlots(file: file, now: { t0 })
            _ = try quitTree()
            saved.appQuit(pid: TestApp.shared.pid)
            #expect(WindowSlots(file: file, now: { t0 + 6 * day }).slots == saved.slots)
            #expect(WindowSlots(file: file, now: { t0 + 8 * day }).slots == [])
        }

        /// The engine's added cost: a window leaving walks the tree for its app, a new window of an app with slots takes one
        /// (the drag path is untouched).
        @Test func slotsCostLittle() async throws {
            let slots = WindowSlots(now: { t0 })
            let root = try Workspace.get(byName: "2").rootTilingContainer
            let windows = try (1...20).map { try TestWindow.new(id: UInt32($0), parent: root) }
            let clock = ContinuousClock()
            let leaving = clock.measure { for _ in 0..<100 { slots.windowsLeaving([windows[0]]) } }
            slots.appQuit(pid: TestApp.shared.pid)
            try close(windows)
            let placing = clock.measure { for i in 0..<20 { _ = slots.placement(appBundleId: app, title: "\(i)") } }
            print("restore slots: \(leaving / 100) per window leaving, \(placing / 20) per placement (20 windows)")
            #expect(leaving / 100 < .milliseconds(2) && placing / 20 < .milliseconds(2))
        }

        /// Sven, 2026-10-15 (build 45): Telegram reopened on a main + stack workspace ran off the right edge as if it were
        /// scrolling. Its slot held weight 1, saved where no layout had turned weights into points yet (a balance, an
        /// arrange, a scrolling strip), while its new neighbours held about 1686 points each: the tiles gave it almost
        /// nothing and macOS's minimum width pushed it past the edge. Each reopen shrank it by a third again (0.444).
        @Test func aSlotSavedAtAnotherScaleStillGetsItsShare() async throws {
            let workspace = Workspace.get(byName: "2")
            #expect(workspace.focusWorkspace())
            let root = try workspace.rootTilingContainer
            try TestWindow.new(id: 1, parent: root)
            try TestWindow.new(id: 2, parent: root)
            try await workspace.layoutWorkspace() // the two tiles' weights are points now
            let usable = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width
            let slots = WindowSlots(now: { t0 })
            slots.slots = [slot("chat", [2], 1.0 / 3)] // as Telegram's was saved, beside two windows at weight 1
            let window = try TestWindow.new(id: 3, parent: Workspace.get(byName: "9").rootTilingContainer)
            let data = try #require(slots.placement(appBundleId: app, title: "chat"))
            try window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            try await workspace.layoutWorkspace()
            let widths = try [1, 2, 3].map { try #require(Window.get(byId: $0)?.lastAppliedLayoutPhysicalRect).width }
            #expect(widths.allSatisfy { abs($0 - usable / 3) < 2 }, "three equal tiles, got \(widths) of \(usable)")
        }

        /// A file saved before shares (Sven's Telegram at weight 0.444) still loads; its slots go back at an even share.
        @Test func aSlotSavedAsAWeightTakesAnEvenShare() throws {
            let json = #"[{"appBundleId":"\#(app)","title":"chat","workspace":"2","path":[0],"weight":0.444,"saved":0}]"#
            let old = try JSONDecoder().decode([WindowSlot].self, from: Data(json.utf8))
            #expect(old.map(\.share) == [nil])
            #expect(Workspace.get(byName: "2").focusWorkspace())
            try TestWindow.new(id: 1, parent: Workspace.get(byName: "2").rootTilingContainer)
            #expect(old[0].bindingData?.adaptiveWeight == WEIGHT_AUTO)
        }

        @Test func aWeekOldSlotPlacesNothing() async throws {
            var now = t0
            let slots = WindowSlots(now: { now })
            slots.slots = [slot("a.txt", [0], 0.5)]
            now += 8 * day
            var read = false
            #expect(await slots.title(for: app, read: { read = true; return "a.txt" }) == nil)
            #expect(!read)
            #expect(slots.placement(appBundleId: app, title: "a.txt") == nil)
        }
    }
}
