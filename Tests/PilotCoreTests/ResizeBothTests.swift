import Foundation
import Testing
@testable import PilotCore

/// Grow and shrink both ways (card agent-bo-95422754): the tiler refuses the height step of a window with no vertical
/// split, and the width step of one with no horizontal split. That is no failure: the other axis still changes.
@MainActor
@Suite("Resize both ways")
struct ResizeBothTests {
    struct Refused: AeroCallRefusal {}
    struct Gone: Error {}

    /// A tiler stand-in: logs each call, and refuses the axes named in `refuse`, or fails every call when `fail`.
    final class Fake: TilerRunning, @unchecked Sendable {
        let refuse: [AeroCommand.Axis], fail: Bool
        private(set) var calls: [[String]] = []

        init(refuse: [AeroCommand.Axis] = [], fail: Bool = false) { self.refuse = refuse; self.fail = fail }

        func run(_ command: AeroCommand) async throws -> String {
            calls.append(command.arguments)
            if fail { throw Gone() }
            if case .resize(_, let axis, _) = command, refuse.contains(axis) { throw Refused() }
            return ""
        }

        func events() -> AsyncStream<AeroEvent> { AsyncStream { $0.finish() } }
    }

    @Test("Side by side only: the width changes and the refused height is no error")
    func noVerticalSplit() async throws {
        let tiler = Fake(refuse: [.height])
        #expect(try await tiler.resizeBoth(id: 7, by: 50, settle: .zero) == [.width])
        #expect(tiler.calls == [["resize", "--window-id", "7", "width", "+50"], ["resize", "--window-id", "7", "height", "+50"]])
    }

    @Test("With a split both ways both axes change; stacked only, the height alone")
    func splits() async throws {
        #expect(try await Fake().resizeBoth(id: 7, by: -50, settle: .zero) == [.width, .height])
        #expect(try await Fake(refuse: [.width]).resizeBoth(id: 7, by: 50, settle: .zero) == [.height])
        #expect(try await Fake(refuse: [.width, .height]).resizeBoth(id: 7, by: 50, settle: .zero) == [])
    }

    @Test("Any other failure still throws")
    func otherFailure() async throws {
        await #expect(throws: Gone.self) { try await Fake(fail: true).resizeBoth(id: 7, by: 50, settle: .zero) }
    }
}
