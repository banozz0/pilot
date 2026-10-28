import Testing
@testable import PilotCore

/// Card agent-bo-95422973: a three-finger sideways swipe fires next or previous workspace once; fed fake frames only.
@Suite("WorkspaceSwipe")
struct WorkspaceSwipeTests {
    /// Every frame's result, in order; each frame's fingers all at its x.
    static func feed(_ frames: [(touches: Int, x: Double)]) -> [WorkspaceSwipe.Fire] {
        var swipe = WorkspaceSwipe()
        return frames.compactMap { swipe.frame(Array(repeating: $0.x, count: $0.touches)) }
    }

    @Test("The fingers' average x is what moves")
    func average() {
        var swipe = WorkspaceSwipe()
        #expect(swipe.frame([0.1, 0.9, 0.5]) == nil)
        #expect(swipe.frame([0.5, 0.5, 0.5]) == nil)
        #expect(swipe.frame([0.0, 0.6, 0.3]) == .next)
    }

    @Test("Three fingers moving left by 0.2 fire next once; moving right by 0.2 fire previous once")
    func fires() {
        #expect(Self.feed([(3, 0.6), (3, 0.5), (3, 0.4), (3, 0.3), (3, 0.2)]) == [.next])
        #expect(Self.feed([(3, 0.3), (3, 0.4), (3, 0.5), (3, 0.6)]) == [.previous])
    }

    @Test("A move of 0.1 fires nothing")
    func short() {
        #expect(Self.feed([(3, 0.5), (3, 0.45), (3, 0.4)]).isEmpty)
        #expect(Self.feed([(3, 0.5), (3, 0.6)]).isEmpty)
    }

    @Test("Two or four fingers fire nothing; a fourth finger mid-swipe ends it")
    func otherCounts() {
        #expect(Self.feed([(2, 0.6), (2, 0.3), (2, 0.1)]).isEmpty)
        #expect(Self.feed([(4, 0.6), (4, 0.3), (4, 0.1)]).isEmpty)
        #expect(Self.feed([(3, 0.6), (3, 0.5), (4, 0.4), (4, 0.3), (4, 0.2)]).isEmpty)
        #expect(Self.feed([(3, 0.6), (3, 0.4), (4, 0.3), (4, 0.1)]) == [.next])
    }

    @Test("One swipe fires once however far it goes; a second swipe after the fingers lift fires again")
    func again() {
        #expect(Self.feed([(3, 0.8), (3, 0.6), (3, 0.4), (3, 0.2), (3, 0.9)]) == [.next])
        #expect(Self.feed([(3, 0.8), (3, 0.6), (0, 0), (3, 0.8), (3, 0.6)]) == [.next, .next])
        #expect(Self.feed([(3, 0.2), (3, 0.4), (0, 0), (3, 0.8), (3, 0.6)]) == [.previous, .next])
    }
}
