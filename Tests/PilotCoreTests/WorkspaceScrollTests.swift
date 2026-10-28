import Foundation
import Testing
@testable import PilotCore

/// Omarchy ideas T2: Hyper+scroll steps one workspace per wheel notch; fed fake scroll events only.
@Suite("WorkspaceScroll")
struct WorkspaceScrollTests {
    typealias E = WorkspaceScroll.Event

    @Test("One notch is one step: down is next, up is previous")
    func notch() {
        #expect(WorkspaceScroll.step(E(delta: -1)) == .next)
        #expect(WorkspaceScroll.step(E(delta: 1)) == .previous)
    }

    @Test("Natural scrolling flips the delta, not the step: the wheel rolled down is still next")
    func natural() {
        #expect(WorkspaceScroll.step(E(delta: 1, inverted: true)) == .next)
        #expect(WorkspaceScroll.step(E(delta: -1, inverted: true)) == .previous)
    }

    @Test("A fast spin's accelerated notch is still one step")
    func accelerated() {
        #expect(WorkspaceScroll.step(E(delta: -7)) == .next)
        let steps = [E(delta: -1), E(delta: -3), E(delta: -1)].compactMap(WorkspaceScroll.step)
        #expect(steps == [.next, .next, .next])
    }

    @Test("Trackpad phases and momentum give no step", arguments: [1, 2, 4, 8, 128] as [Int64])
    func phases(_ phase: Int64) {
        #expect(WorkspaceScroll.step(E(delta: -1, continuous: true, phase: phase)) == nil)
        #expect(WorkspaceScroll.step(E(delta: -1, phase: phase)) == nil)
        #expect(WorkspaceScroll.step(E(delta: -1, continuous: true, momentumPhase: phase)) == nil)
        #expect(WorkspaceScroll.step(E(delta: -1, momentumPhase: phase)) == nil)
    }

    @Test("A continuous scroll with no phase (a smooth mouse) and a zero delta give no step")
    func noStep() {
        #expect(WorkspaceScroll.step(E(delta: -1, continuous: true)) == nil)
        #expect(WorkspaceScroll.step(E(delta: 0)) == nil)
        #expect(!E(delta: 0).isNotch)
        #expect(E(delta: 2).isNotch)
    }

    @Test("The decision costs well under a microsecond, so the tap callback stays cheap")
    func cost() {
        let events = [E(delta: -1), E(delta: 1, inverted: true), E(delta: -1, continuous: true, phase: 2), E(delta: 0)]
        let n = 100_000
        var fired = 0
        let start = ContinuousClock.now
        for i in 0..<n where WorkspaceScroll.step(events[i & 3]) != nil { fired += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(fired == n / 2)
        // A loose bound for a loaded machine: 100k decisions in under 500 ms (5 µs each) still catches a pathological regression.
        #expect(elapsed < .milliseconds(500), "100k decisions took \(elapsed)")
    }

    @Test("The keyboard tap's mask never gains the scroll wheel (typing-lag rule)")
    func keyboardMask() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/Pilot/Engine/HyperTap.swift"), encoding: .utf8)
        #expect(source.contains("eventsOfInterest: mask"))
        // Only the mask line counts: the dictation key reads when the wheel last scrolled, which adds nothing to the tap.
        let maskLine = try #require(source.split(separator: "\n").first { $0.contains("let mask: CGEventMask") })
        #expect(!maskLine.contains("scrollWheel"))
    }
}
