// Card agent-bo-95423033: tiled windows glide 180 ms (ease-out) to their new frames on their app's AX thread, the
// position alone, the size shrunk before the move and grown after it (Sven's Q147). The glide set on a fake clock, and
// layout's choice of where a glide starts.
import AppKit
@testable import PilotTiler
import Testing

@Suite struct GlideSetTests {
    let a = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
    let b = Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080)
    let c = Rect(topLeftX: 0, topLeftY: 540, width: 1920, height: 540)
    let t0 = ContinuousClock.now

    @Test func easesOutOver180Milliseconds() {
        #expect(GlideSet.frame(from: a, to: b, progress: 0) == a)
        #expect(GlideSet.frame(from: a, to: b, progress: 1) == b)
        // Half the time, seven eighths of the way: 1 - (1 - 0.5)^3
        #expect(GlideSet.frame(from: a, to: b, progress: 0.5).minX == 840)
        var set = GlideSet()
        #expect(set.retarget(1, from: a, to: b, now: t0) == true)
        #expect(set.step(t0 + .milliseconds(90)).map(\.frame) == [GlideSet.frame(from: a, to: b, progress: 0.5)])
        #expect(set.step(t0 + .milliseconds(180)).map(\.frame) == [b]) // lands exactly on the target
        #expect(set.isEmpty)
    }

    /// The size never eases: the smaller one on each side until the window lands, so an app relayouts at most twice a
    /// glide, never once a frame (gliding windows report: a heavy layout missed 50 of 66 frames resized every frame).
    @Test func onlyThePositionEases() {
        let mid = GlideSet.frame(from: a, to: c, progress: 0.5)
        #expect(mid.minY == 472.5 && mid.width == 960 && mid.height == 540) // 7/8 of the way down, narrow and short
        #expect(GlideSet.frame(from: a, to: c, progress: 0.99).size == mid.size)
        #expect(GlideSet.frame(from: a, to: c, progress: 1) == c)
    }

    @Test func aNewTargetStartsFromWhereTheWindowIs() {
        var set = GlideSet()
        _ = set.retarget(1, from: a, to: b, now: t0)
        let there = set.step(t0 + .milliseconds(30))[0].frame
        #expect(set.retarget(1, from: b, to: c, now: t0 + .milliseconds(30)) == true)
        // Not from a, not from b: from where it is, shrunk to c's height before it moves on
        #expect(set.step(t0 + .milliseconds(30))[0].frame == Rect(topLeftX: there.minX, topLeftY: there.minY, width: 960, height: 540))
        #expect(set.step(t0 + .milliseconds(210)).map(\.frame) == [c])
    }

    @Test func aBurstRetargetsOneGlide() {
        var set = GlideSet()
        let targets = (1...10).map { Rect(topLeftX: CGFloat($0) * 10, topLeftY: 0, width: 500, height: 500) }
        for (i, target) in targets.enumerated() {
            _ = set.retarget(1, from: a, to: target, now: t0 + .milliseconds(5 * i))
            #expect(set.step(t0 + .milliseconds(5 * i)).count == 1)
        }
        #expect(set.step(t0 + .milliseconds(45 + 180)).map(\.frame) == [targets[9]])
        #expect(set.isEmpty)
    }

    @Test func theSameTargetAgainKeepsTheGlide() {
        var set = GlideSet()
        _ = set.retarget(1, from: a, to: b, now: t0)
        #expect(set.retarget(1, from: nil, to: b, now: t0 + .milliseconds(50)) == true)
        #expect(set.step(t0 + .milliseconds(90)).map(\.frame) == [GlideSet.frame(from: a, to: b, progress: 0.5)])
    }

    @Test func aJumpEndsTheGlide() {
        var set = GlideSet()
        _ = set.retarget(1, from: a, to: b, now: t0)
        #expect(set.retarget(1, from: nil, to: c, now: t0 + .milliseconds(10)) == false)
        #expect(set.isEmpty)
        #expect(set.retarget(2, from: a, to: a, now: t0) == false) // already there
        #expect(set.retarget(3, from: a, to: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), now: t0) == false,
                "a resize in place has nothing to glide")
    }
}

@Suite struct GliderTests {
    @Test func aGlidingWindowsOwnMovesAreNotNews() {
        let glider = Glider()
        let a = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
        _ = glider.retarget(901, from: a, to: Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080), now: .now)
        #expect(isGliding(901) && !isGliding(902) && !isGliding(nil))
        glider.stop(901)
        #expect(!isGliding(901))
        _ = glider.retarget(901, from: nil, to: a, now: .now) // a jump never glides
        #expect(!isGliding(901))
    }
}

/// The timer's ticks with a fake frame writer and a fake clock (AC3): what the app's AX thread would write each frame.
@Suite struct GliderTickTests {
    let a = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
    let t0 = ContinuousClock.now

    @Test func aBurstOfTenBindsEndsAtTheLastTargetWithOneGlide() {
        let glider = Glider()
        var writes: [(id: UInt32, frame: Rect, resized: Bool)] = []
        let targets = (0..<10).map { Rect(topLeftX: CGFloat($0 + 1) * 50, topLeftY: 0, width: 960, height: 1080) }
        for (i, target) in targets.enumerated() { // ten binds within 50 ms, a tick between each
            #expect(glider.retarget(911, from: a, to: target, now: t0 + .milliseconds(5 * i)))
            _ = glider.tick(t0 + .milliseconds(5 * i + 2)) { writes.append(($0.id, $0.frame, $0.frame.size != $0.from.size)) }
        }
        #expect(Set(writes.map(\.id)) == [911] && writes.count == 10, "one glide, one write per tick")
        var landed = false
        for frame in 1...15 where !landed {
            landed = glider.tick(t0 + .milliseconds(45 + 16 * frame)) { writes.append(($0.id, $0.frame, $0.frame.size != $0.from.size)) }
        }
        #expect(landed && writes.last?.frame == targets[9] && !isGliding(911))
        #expect(writes.allSatisfy { !$0.resized }, "a pure move never writes a size")
    }

    /// What the run hands TilerFrames, so Pilot's border re-reads a window whose glide it skipped (Sven's test 2026-10-09).
    @Test func eachLandingIsReportedOnce() {
        let glider = Glider()
        _ = glider.retarget(913, from: a, to: Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080), now: t0)
        _ = glider.retarget(914, from: a, to: Rect(topLeftX: 0, topLeftY: 540, width: 960, height: 540), now: t0 + .milliseconds(50))
        _ = glider.tick(t0 + .milliseconds(60)) { _ in }
        #expect(glider.takeLanded().isEmpty, "mid-glide")
        _ = glider.tick(t0 + .milliseconds(190)) { _ in }
        #expect(glider.takeLanded() == [913])
        #expect(glider.takeLanded().isEmpty)
        #expect(glider.tick(t0 + .milliseconds(240)) { _ in })
        #expect(glider.takeLanded() == [914])
    }

    /// The AX writes a glide makes, as Glider.run hands each tick to FrameSteps: "size" or "move".
    private func writes(from: Rect, to: Rect) -> [String] {
        let glider = Glider()
        var writes: [String] = []
        #expect(glider.retarget(912, from: from, to: to, now: t0))
        var landed = false
        for frame in 1...30 where !landed {
            landed = glider.tick(t0 + .microseconds(8333 * frame)) { step in
                _ = FrameSteps(current: step.from, target: step.frame, resetSize: false).run(
                    setSize: { _, _ in writes.append("size"); return nil }, setPosition: { _ in writes.append("move") })
            }
        }
        #expect(landed)
        return writes
    }

    @Test func aShrinkingWindowShrinksOnceBeforeItMoves() {
        let w = writes(from: a, to: Rect(topLeftX: 960, topLeftY: 0, width: 640, height: 1080))
        #expect(w.first == "size" && w.dropFirst().allSatisfy { $0 == "move" } && w.count > 15, "\(w)")
    }

    @Test func aGrowingWindowGrowsOnceAfterItMoves() {
        let w = writes(from: a, to: Rect(topLeftX: 480, topLeftY: 0, width: 1440, height: 1080))
        #expect(w.last == "size" && w.dropLast().allSatisfy { $0 == "move" } && w.count > 15, "\(w)")
    }

    @Test func aJumpLeavesNothingToTick() {
        let glider = Glider()
        _ = glider.retarget(912, from: a, to: Rect(topLeftX: 480, topLeftY: 0, width: 640, height: 1080), now: t0)
        _ = glider.retarget(912, from: nil, to: a, now: t0 + .milliseconds(20))
        #expect(glider.tick(t0 + .milliseconds(36)) { _ in Issue.record("a jump leaves nothing to tick") })
    }

    /// What this card adds to each move of a dragged window: the engine's and Pilot's border observer's gliding checks.
    @Test func aDragMovePaysAlmostNothingForGlides() {
        let glider = Glider()
        let element = AXUIElementCreateApplication(getpid())
        let clock = ContinuousClock()
        // The fastest of five runs: a loaded Mac only adds time to a run, so the fastest is the checks' own cost.
        func fastest(_ checks: () -> Void) -> Duration { (0..<5).map { _ in clock.measure(checks) }.min()! }
        let idle = fastest { for i in 0..<10_000 { _ = isGliding(UInt32(i)) || tilerIsGliding(element) } }
        for id in UInt32(941)...952 { _ = glider.retarget(id, from: a, to: Rect(topLeftX: CGFloat(id), topLeftY: 0, width: 480, height: 540), now: t0) }
        let gliding = fastest { for i in 0..<10_000 { _ = isGliding(UInt32(i)) } }
        for id in UInt32(941)...952 { glider.stop(id) }
        print("drag move, gliding checks: \(idle / 10_000) per move with nothing gliding, \(gliding / 10_000) with 12 windows gliding")
        #expect(idle / 10_000 < .microseconds(5) && gliding / 10_000 < .microseconds(5))
    }

    @Test func aTickOfTwelveGlidingWindowsIsCheap() {
        let glider = Glider()
        for id in UInt32(921)...932 {
            _ = glider.retarget(id, from: a, to: Rect(topLeftX: CGFloat(id), topLeftY: 0, width: 480, height: 540), now: t0)
        }
        let clock = ContinuousClock()
        var writes = 0
        let elapsed = clock.measure { for i in 0..<100 { _ = glider.tick(t0 + .microseconds(i * 100)) { _ in writes += 1 } } }
        print("glide tick, 12 windows: \(elapsed / 100) per tick, before AX")
        #expect(writes == 1200 && elapsed / 100 < .microseconds(200))
        for id in UInt32(921)...932 { glider.stop(id) }
    }
}

extension TilerTreeTests {
    @MainActor
    @Suite
    struct GlideLayoutTests {
        private func twoWindows() async throws -> (Workspace, TestWindow) {
            let workspace = try Workspace.get(byName: name)
            let first = try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
            _ = try TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
            #expect(workspace.focusWorkspace())
            try await workspace.layoutWorkspace()
            return (workspace, first)
        }

        @Test func layoutGlidesFromWhereItLaidTheWindowOutLast() async throws {
            reduceMotion = { false }
            let (workspace, first) = try await twoWindows()
            #expect(first.lastGlidingFrom == nil) // never laid out: it jumps
            let before = try #require(first.lastAppliedLayoutPhysicalRect)
            try first.setWeight(.h, 1500)
            try await workspace.layoutWorkspace()
            #expect(first.lastGlidingFrom == before)
        }

        @Test func aLayoutPassOfTwelveWindowsStaysCheap() async throws {
            reduceMotion = { false }
            let workspace = try Workspace.get(byName: name)
            for id in UInt32(1)...12 { _ = try TestWindow.new(id: id, parent: workspace.rootTilingContainer) }
            #expect(workspace.focusWorkspace())
            try await workspace.layoutWorkspace()
            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                for i in 0..<100 {
                    try workspace.rootTilingContainer.children[0].setWeight(.h, CGFloat(100 + i))
                    try await workspace.layoutWorkspace()
                }
            }
            print("layout pass with glides, 12 windows: \(elapsed / 100) per pass on the main thread")
            #expect(elapsed / 100 < .milliseconds(1))
        }

        @Test func reduceMotionJumps() async throws {
            reduceMotion = { true }
            defer { reduceMotion = { false } }
            let (workspace, first) = try await twoWindows()
            try first.setWeight(.h, 1500)
            try await workspace.layoutWorkspace()
            #expect(first.lastGlidingFrom == nil)
        }

        @Test func lowPowerModeJumps() async throws {
            lowPowerMode = { true }
            defer { lowPowerMode = { false } }
            let (workspace, first) = try await twoWindows()
            try first.setWeight(.h, 1500)
            try await workspace.layoutWorkspace()
            #expect(first.lastGlidingFrom == nil)
        }

        @Test func glideWindowsOffJumps() async throws {
            config.glide = false
            let (workspace, first) = try await twoWindows()
            try first.setWeight(.h, 1500)
            try await workspace.layoutWorkspace()
            #expect(first.lastGlidingFrom == nil)
        }

        @Test func aMouseResizeMovesTheNeighboursAtOnce() async throws {
            reduceMotion = { false }
            let (workspace, first) = try await twoWindows()
            currentlyManipulatedWithMouseWindowId = 2
            try first.setWeight(.h, 1500)
            try await workspace.layoutWorkspace()
            #expect(first.lastGlidingFrom == nil)
        }
    }
}
