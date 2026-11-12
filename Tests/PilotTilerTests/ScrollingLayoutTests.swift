// Scrolling layout (spec Projects/Pilot/specs/scrolling-layout.html, acceptance checks 1 to 5): the tiler's layout
// pass on test windows over Sven's desk, a 3440 × 1440 ultrawide with a 1080 × 1920 portrait screen on its left, driven
// through the tiler's calls. Each pass writes each window once, so its frame and glide start after a pass are that
// pass's write. The writes are then replayed as AX takes them (AppWindow): a jump and each glide tick on a fake clock go
// through FrameSteps, size and position apart, and every frame the window shows between them is checked.
import AppKit
import PilotCore
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct ScrollingLayoutTests {
        static let ultrawide = Rect(topLeftX: 0, topLeftY: 0, width: 3440, height: 1440)
        static let portrait = Rect(topLeftX: -1080, topLeftY: -480, width: 1080, height: 1920)
        static let gap: CGFloat = 10
        /// The ultrawide less its outer gaps; layout takes a point off the height (layoutWorkspace).
        static let usable = Rect(topLeftX: gap, topLeftY: gap, width: 3440 - 2 * gap, height: 1440 - 2 * gap - 1)
        /// Half the usable width as a column, every column's width until Hyper+R changes one: two and their gap fill it.
        static let half = (usable.width + gap) / 2 - gap

        /// One frame a pass wrote, where it glided from (nil: it jumped), for how long, and the x it was to keep within.
        struct Write { let id: UInt32; let from: Rect?; let to: Rect; let duration: Duration; let span: ClosedRange<CGFloat>? }

        /// A window as AX takes the writes MacApp makes (FrameSteps): its size and place apart, an app's minimum width kept
        /// whatever is asked; every frame it shows, between writes too, is kept.
        final class AppWindow {
            var frame: Rect
            let minWidth: CGFloat
            var learned: CGFloat = 0
            var shown: [Rect] = []
            /// Size reads asked for: only after a shrink write, never after the last.
            var reads = 0

            init(_ frame: Rect, minWidth: CGFloat) {
                self.frame = frame
                self.minWidth = minWidth
            }

            func take(_ target: Rect, from current: Rect?, span: ClosedRange<CGFloat>?, resetSize: Bool) {
                learned = FrameSteps(current: current, target: target, span: span, minWidth: learned, resetSize: resetSize).run(
                    setSize: { size, readBack in
                        frame = Rect(topLeftX: frame.minX, topLeftY: frame.minY, width: max(size.width, minWidth), height: size.height)
                        shown.append(frame)
                        if readBack { reads += 1 }
                        return span != nil && readBack ? frame.size : nil
                    },
                    setPosition: { point in
                        frame = Rect(topLeftX: point.x, topLeftY: point.y, width: frame.width, height: frame.height)
                        shown.append(frame)
                    },
                )
            }
        }

        private var writes: [Write] = []

        /// Each window's writes as its app takes them, from `start` (an app whose windows are at least `minWidth` wide): a
        /// jump reads the frame first, as MacApp does on a strip; a glide ticks every 4 ms from where it was written last.
        private func replay(start: Rect, minWidth: CGFloat = 0) -> [UInt32: AppWindow] {
            var apps: [UInt32: AppWindow] = [:]
            let t0 = ContinuousClock.now
            for write in writes {
                let app = apps[write.id] ?? AppWindow(start, minWidth: minWidth)
                apps[write.id] = app
                guard let from = write.from else {
                    app.take(write.to, from: app.frame, span: write.span, resetSize: true)
                    continue
                }
                var set = GlideSet()
                let glides = set.retarget(write.id, from: from, to: write.to, now: t0, duration: write.duration, span: write.span)
                #expect(glides)
                var tick = 0
                while !set.isEmpty {
                    tick += 1
                    for step in set.step(t0 + .milliseconds(4 * tick)) { app.take(step.frame, from: step.from, span: step.span, resetSize: false) }
                }
            }
            return apps
        }

        private func desk(columns: Int, on screen: Rect = ultrawide) throws -> (Workspace, [TestWindow]) {
            unitTestScreen.withLock {
                $0.monitors = [
                    MonitorInfoImpl(monitorAppKitNsScreenScreensId: 1, name: "Ultrawide", rect: Self.ultrawide, visibleRect: Self.ultrawide, isMain: true),
                    MonitorInfoImpl(monitorAppKitNsScreenScreensId: 2, name: "Portrait", rect: Self.portrait, visibleRect: Self.portrait, isMain: false),
                ]
            }
            gcMonitors()
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10),
                               outer: .init(left: .constant(10), bottom: .constant(10), top: .constant(10), right: .constant(10)))
            let workspace = Workspace.get(byName: name)
            let root = try workspace.rootTilingContainer
            root.layout = .scrolling
            let windows = try (1...columns).map { try TestWindow.new(id: UInt32($0), parent: root) }
            if screen == Self.portrait { #expect(try #require(monitorInfos.first { $0.rect == screen }).setActiveWorkspace(workspace)) }
            #expect(workspace.focusWorkspace())
            #expect(workspace.workspaceMonitor.rect == screen)
            return (workspace, windows)
        }

        /// A layout pass, its writes kept.
        private mutating func pass(_ workspace: Workspace, _ windows: [TestWindow]) async throws {
            let before = windows.map(\.frameWrites)
            try await workspace.layoutWorkspace()
            #expect(windows.map(\.frameWrites) == zip(windows, before).map { $1 + ($0.isBound ? 1 : 0) }, "each window written once a pass")
            writes += try windows.filter(\.isBound).map {
                Write(id: $0.windowId, from: $0.lastGlidingFrom, to: try #require($0.axRect), duration: $0.lastGlideDuration, span: $0.lastSpan)
            }
        }

        private func focused() throws -> Rect { try #require((try focusedWindow() as? TestWindow)?.axRect) }

        /// Whether `frame` lies within the usable rect: a whole column in view.
        private static func isWhole(_ frame: Rect?) -> Bool {
            guard let frame else { return false }
            return frame.minX >= usable.minX - 0.5 && frame.maxX <= usable.maxX + 0.5
        }

        private static func close(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.5 } == true }

        /// Check 1: across a scroll to the far right and back, no frame written and no step of any glide reaches the
        /// portrait screen; the columns it would cover wait hidden in the ultrawide's corner, away from it.
        @Test mutating func nothingEverShowsOnThePortraitScreen() async throws {
            let (workspace, windows) = try desk(columns: 8)
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            for direction in [CardinalDirection.right, .left] {
                for _ in 1...7 {
                    #expect(try await focusedWindow().focusNeighbor(direction))
                    try await pass(workspace, windows)
                    #expect(Self.isWhole(try focused()), "the focused column is whole")
                }
                #expect(try await !focusedWindow().focusNeighbor(direction), "no cycling")
            }
            let hidden = writes.filter { $0.to.minX > Self.ultrawide.maxX - 2 }
            #expect(!hidden.isEmpty, "the far right hid the first columns")
            #expect(hidden.allSatisfy { $0.from == nil }, "hiding jumps")
            #expect(writes.filter { $0.from != nil }.count > 20, "the strip glided")
            #expect(writes.allSatisfy { !$0.to.overlaps(Self.portrait) })
            for (id, app) in replay(start: Rect(topLeftX: 1000, topLeftY: 100, width: 800, height: 800)) {
                #expect(app.shown.allSatisfy { !$0.overlaps(Self.portrait) }, "window \(id) showed on the portrait screen")
            }
            #expect(windows[0].lastGlideDuration == .milliseconds(350), "a strip scroll glides 350 ms")
        }

        /// Check 2: with the strip at its start, every column wholly past the ultrawide's right edge, which has no display
        /// beyond it, keeps exactly 5 px on screen; no frame lies wholly past it.
        @Test mutating func aColumnPastTheOpenEdgeKeepsAFivePixelSliver() async throws {
            let (workspace, windows) = try desk(columns: 6)
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            for (i, window) in windows[0..<2].enumerated() { #expect(Self.close(window.axRect?.minX, 10 + CGFloat(i) * (Self.half + 10))) }
            #expect(windows[2...].allSatisfy { Self.close($0.axRect?.minX, Self.ultrawide.maxX - 5) && Self.ultrawide.maxX - ($0.axRect?.minX ?? 0) == 5 })
            #expect(writes.allSatisfy { $0.to.minX < Self.ultrawide.maxX }, "nothing wholly past the open edge")
        }

        /// Check 3: Hyper+→ on the rightmost column in view focuses the next and scrolls the least, so it lands whole one
        /// gap from the edge; Hyper+← mirrors it, and moves focus without a scroll onto a column already in view.
        @Test mutating func focusScrollsTheLeastThatShowsTheColumn() async throws {
            let (workspace, windows) = try desk(columns: 6)
            #expect(try windows[1].focusWindow())
            try await pass(workspace, windows)
            #expect(Self.isWhole(windows[1].axRect), "column 2 in view")
            #expect(try await focusedWindow().focusNeighbor(.right))
            try await pass(workspace, windows)
            #expect(focus.windowOrNil == windows[2])
            let landed = try focused()
            #expect(Self.close(landed.maxX, Self.usable.maxX) && Self.close(landed.width, Self.half), "whole, one gap from the edge")
            #expect(Self.close(windows[1].axRect?.maxX, landed.minX - Self.gap), "column 2 sits a gap to its left")
            for _ in 1...3 {
                #expect(try await focusedWindow().focusNeighbor(.right))
                try await pass(workspace, windows)
            }
            // Columns 5 and 6 in view: column 4 is past the left edge, toward the portrait screen.
            let inView = windows[4].axRect
            #expect(try await focusedWindow().focusNeighbor(.left))
            try await pass(workspace, windows)
            #expect(focus.windowOrNil == windows[4])
            #expect(windows[4].axRect == inView, "column 5 was in view: no scroll")
            #expect(try await focusedWindow().focusNeighbor(.left))
            try await pass(workspace, windows)
            #expect(focus.windowOrNil == windows[3])
            #expect(Self.close(try focused().minX, Self.usable.minX))
            #expect(windows[3].lastGlidingFrom == nil, "back from hidden it jumps")
        }

        /// Check 4 (T8, Sven's Q42): a new window opens as a column right after the focused one, and the strip's widths
        /// fit the new count: every column half again, what Hyper+R set gone.
        @Test mutating func aNewWindowIsAHalfColumnRightOfTheFocusedOne() async throws {
            let (workspace, windows) = try desk(columns: 3)
            #expect(try windows[1].focusWindow())
            try await pass(workspace, windows)
            #expect(windows[0].cycleColumnWidth(forward: true) && windows[2].cycleColumnWidth(forward: false))
            try await pass(workspace, windows)
            #expect(!Self.close(windows[0].axRect?.width, Self.half) && !Self.close(windows[2].axRect?.width, Self.half))
            let opened = try TestWindow.new(id: 9, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
            try await opened.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
            try await pass(workspace, windows + [opened])
            #expect(try workspace.rootTilingContainer.children.map { ($0 as? Window)?.windowId } == [1, 2, 9, 3])
            // Every column half again; column 1, partly past the portrait edge, peeks cut back to the ultrawide (ADR 0014
            // as amended 2026-11-12), the rest show at their whole width.
            #expect((windows + [opened]).allSatisfy { $0.columnWidth == Strip.automaticWidth })
            #expect((windows + [opened]).allSatisfy { Self.close($0.axRect?.width, Self.half) || Self.close($0.axRect?.minX, Self.ultrawide.minX) })
            #expect(Self.close(opened.axRect?.minX, (windows[1].axRect?.maxX ?? 0) + Self.gap))
        }

        /// T8 (Sven's Q42): one window is full, two or more half each, refitted as windows close; Hyper+R's width holds
        /// over passes until the count changes.
        @Test mutating func widthsFollowTheWindowCount() async throws {
            let (workspace, windows) = try desk(columns: 3)
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            #expect(windows.allSatisfy { Self.close($0.axRect?.width, Self.half) })
            #expect(windows[0].cycleColumnWidth(forward: true))
            for _ in 1...2 { try await pass(workspace, windows) }
            #expect(Self.close(windows[0].axRect?.width, Self.usable.width * 2 / 3 - Self.gap / 3), "Hyper+R holds: two thirds")
            try windows[2].closeAxWindow()
            try await pass(workspace, Array(windows[0..<2]))
            #expect(windows[0..<2].allSatisfy { Self.close($0.axRect?.width, Self.half) }, "a close refits: half each")
            try windows[1].closeAxWindow()
            try await pass(workspace, [windows[0]])
            #expect(windows[0].axRect == Self.usable, "one window is full")
        }

        /// Check 5: a lone window fills the usable width, whatever its column's width.
        @Test mutating func aLoneWindowFillsTheUsableWidth() async throws {
            let (workspace, windows) = try desk(columns: 1)
            windows[0].columnWidth = 1.0 / 3
            try await pass(workspace, windows)
            #expect(windows[0].axRect == Self.usable)
        }

        /// Moody on T1 v1: on the portrait screen, whose right edge meets the ultrawide, its last column growing leftward
        /// (1/2 to 2/3) and then filling the screen once the others close never draws on the ultrawide: not at a write, not
        /// between a size write and a position write, not on a glide tick, not when instant, and not for an app that keeps
        /// a 500 px minimum, wider than a 1/3 portrait column.
        @Test(arguments: [false, true]) mutating func aPortraitColumnNeverReachesOntoTheUltrawide(instant: Bool) async throws {
            if instant { config.scrollingGlide = nil }
            let (workspace, windows) = try desk(columns: 3, on: Self.portrait)
            #expect(try windows[2].focusWindow())
            try await pass(workspace, windows)
            #expect(windows[2].cycleColumnWidth(forward: true))
            try await pass(workspace, windows)
            #expect(Self.close(windows[2].axRect?.maxX, Self.portrait.maxX - Self.gap) && windows[2].lastSpan?.upperBound == 0)
            for window in windows[0..<2] { try window.closeAxWindow() }
            try await pass(workspace, windows)
            #expect(Self.close(windows[2].axRect?.width, Self.portrait.width - 2 * Self.gap))
            #expect(writes.contains { $0.from != nil } != instant)
            for minWidth: CGFloat in [0, 500] {
                for (id, app) in replay(start: Rect(topLeftX: -800, topLeftY: 100, width: 600, height: 800), minWidth: minWidth) {
                    #expect(app.shown.allSatisfy { !$0.overlaps(Self.ultrawide) }, "window \(id), minimum \(minWidth): \(app.shown.filter { $0.overlaps(Self.ultrawide) })")
                }
            }
        }

        /// The write order itself: a column on the portrait screen growing leftward against the ultrawide. Size first, as
        /// AeroSpace wrote it (no frame known), shows a frame reaching 168 px onto the ultrawide; FrameSteps' order none.
        @Test func sizeFirstReachedOverTheEdgeTheOrderDoesNot() {
            let old = Rect(topLeftX: -356.67, topLeftY: 10, width: 346.67, height: 1899)
            let new = Rect(topLeftX: -535, topLeftY: 10, width: 525, height: 1899)
            for known in [false, true] {
                let app = AppWindow(old, minWidth: 0)
                app.take(new, from: known ? old : nil, span: -.greatestFiniteMagnitude ... 0, resetSize: true)
                #expect(app.shown.map(\.maxX).max().map { $0 > 0 } == !known, "known \(known): \(app.shown)")
                #expect(app.frame == new)
                // Known, a growing column has no shrink to read back; unknown, the first size write is where a minimum shows.
                #expect(app.reads == (known ? 0 : 1), "never after the last size write")
            }
            let narrowing = AppWindow(new, minWidth: 0)
            narrowing.take(old, from: new, span: -.greatestFiniteMagnitude ... 0, resetSize: true)
            #expect(narrowing.reads == 1 && narrowing.frame == old, "one read, after the shrink")
        }

        /// Moody on T1 v1: a join that leaves the strip one stack, or closing down to one stack, keeps the workspace a
        /// strip (normalization flattened the root into the stack), so the next window is a new column.
        @Test(arguments: [false, true]) mutating func aStripOfOneStackStaysAStrip(closing: Bool) async throws {
            config.enableNormalizationFlattenContainers = true
            let (workspace, windows) = try desk(columns: closing ? 3 : 2)
            #expect(try windows[closing ? 1 : 0].join(with: .right))
            if closing { try windows[0].closeAxWindow() }
            try await run {}
            let root = try workspace.rootTilingContainer
            #expect(root.layout == .scrolling && root.children.count == 1 && root.children.first is TilingContainer)
            #expect(try windows.last!.focusWindow())
            let opened = try TestWindow.new(id: 9, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
            try await opened.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
            try await run {}
            #expect(try workspace.rootTilingContainer === root && root.children.count == 2 && root.children.last === opened)
        }

        /// The calls behind Hyper+R, Hyper+Shift+R and Hyper+Alt+C (T2 binds them): a column steps through the widths,
        /// round, and the strip centres it as far as its ends allow. The strip's speed set to instant jumps.
        @Test mutating func widthsStepRoundAndCentreCentres() async throws {
            let (workspace, windows) = try desk(columns: 5)
            #expect(try windows[2].focusWindow())
            try await pass(workspace, windows)
            var steps: [CGFloat?] = []
            for _ in 1...4 { #expect(windows[2].cycleColumnWidth(forward: true)); steps.append(windows[2].columnWidth) }
            let expected: [CGFloat?] = [2.0 / 3, 1, 1.0 / 3, 1.0 / 2]
            #expect(steps == expected)
            #expect(windows[2].cycleColumnWidth(forward: false) && windows[2].columnWidth == 1.0 / 3)
            try await pass(workspace, windows)
            #expect(windows[2].centreColumn())
            config.scrollingGlide = nil
            try await pass(workspace, windows)
            #expect(Self.close(try focused().center.x, Self.usable.center.x) && windows[2].lastGlidingFrom == nil)
            let tiled = try TestWindow.new(id: 9, parent: Workspace.get(byName: "tiles").rootTilingContainer)
            #expect(!tiled.cycleColumnWidth(forward: true) && !tiled.centreColumn(), "outside a strip they do nothing")
        }

        /// T9: the centre mode picks where a focus move lands. Never scrolls the least; on overflow centres only a column
        /// that was not whole in view; always centres one that was, too.
        @Test(arguments: PilotBlock.CentreMode.allCases) mutating func theCentreModePicksWhereFocusLands(mode: PilotBlock.CentreMode) async throws {
            let (workspace, windows) = try desk(columns: 6)
            config.scrollingCentre = mode
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            #expect(try await focusedWindow().focusNeighbor(.right))
            try await pass(workspace, windows)
            let centred = Self.close(try focused().center.x, Self.usable.center.x)
            #expect(mode == .always ? centred : Self.close(try focused().minX, Self.usable.minX + Self.half + Self.gap), "column 2 was in view")
            #expect(try await focusedWindow().focusNeighbor(.right))
            try await pass(workspace, windows)
            #expect(mode == .never ? Self.close(try focused().maxX, Self.usable.maxX) : Self.close(try focused().center.x, Self.usable.center.x),
                    "column 3 was past the edge")
        }

        /// T10: Hyper+Alt+F makes the column full and gives its width back; Hyper+Alt+U takes a stacked window out into a
        /// column of its own right after the stack, and the one left becomes its column. Outside a strip both refuse.
        @Test mutating func maximiseAndLeaveAStack() async throws {
            config.enableNormalizationFlattenContainers = true
            let (workspace, windows) = try desk(columns: 3)
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            #expect(windows[0].cycleColumnWidth(forward: false), "a third")
            #expect(windows[0].toggleColumnMaximised())
            try await pass(workspace, windows)
            #expect(try focused() == Self.usable, "full")
            #expect(windows[0].toggleColumnMaximised())
            try await pass(workspace, windows)
            #expect(Self.close(try focused().width, Self.usable.width / 3 - Self.gap * 2 / 3), "back to a third")
            #expect(try windows[1].join(with: .right))
            #expect(try windows[1].leaveStack())
            try await run {}
            #expect(try workspace.rootTilingContainer.children.map { ($0 as? Window)?.windowId } == [1, 3, 2])
            #expect(try !windows[0].leaveStack(), "a column of one window has no stack")
            let tiled = try TestWindow.new(id: 9, parent: Workspace.get(byName: "tiles").rootTilingContainer)
            #expect(try !tiled.toggleColumnMaximised() && !tiled.leaveStack(), "outside a strip they do nothing")
        }

        /// T11: an app's column width holds across the refit a new window makes, while the others fit; an app that keeps
        /// focus gives it back to the window focused when its own opened, on the first focus change and within a second.
        @Test mutating func anAppsRuleKeepsItsWidthAndFocus() async throws {
            let (workspace, windows) = try desk(columns: 3)
            config.scrollingAppWidths = [TestApp.shared.rawAppBundleId ?? "": 1.0 / 3]
            #expect(try windows[0].focusWindow())
            try await pass(workspace, windows)
            #expect(windows.allSatisfy { Self.close($0.axRect?.width, Self.usable.width / 3 - Self.gap * 2 / 3) }, "a third each")
            config.scrollingAppWidths = [:]
            let opened = try TestWindow.new(id: 9, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
            try await opened.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
            try await pass(workspace, windows + [opened])
            #expect((windows + [opened]).allSatisfy { Self.close($0.axRect?.width, Self.half) }, "no rule, the automatic width")

            config.windowRules = [WindowRule(appId: TestApp.shared.rawAppBundleId, actions: [.keepFocus], checkFurtherRules: true)]
            let chat = try TestWindow.new(id: 10, parent: workspace.rootTilingContainer)
            try await onWindowDetected(chat)
            #expect(keptFocus(over: chat) === windows[0], "macOS focused the new window: focus goes back")
            #expect(keptFocus(over: chat) == nil, "once")
            try await onWindowDetected(chat)
            #expect(keptFocus(over: windows[1]) == nil && keptFocus(over: chat) == nil, "another focus change ends the wait")
            try await onWindowDetected(chat)
            #expect(keptFocus(over: chat, now: .now + .seconds(2)) == nil, "a click on it later stays")
        }

        /// The tiler stopping lays every column on screen, side by side, so none is left in the corner.
        @Test mutating func stoppingTheTilerBringsEveryColumnBack() async throws {
            let (workspace, windows) = try desk(columns: 6)
            #expect(try windows[5].focusWindow())
            try await pass(workspace, windows)
            #expect((windows[0].axRect?.minX ?? 0) > Self.ultrawide.maxX - 2, "column 1 hidden")
            try await workspace.layoutWorkspace(unhidingColumns: true)
            #expect(windows.allSatisfy { Self.isWhole($0.axRect) })
        }
    }
}
