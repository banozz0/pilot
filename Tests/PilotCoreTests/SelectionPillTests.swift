import CoreGraphics
import Testing
@testable import PilotCore

/// The selection pill's rules (Sven Q214, Q215): a drag, not a click, and never in a skipped app.
@Suite("Selection pill rules")
struct SelectionPillTests {
    @Test("A press starts the gesture in any app but a skipped one")
    func starts() {
        let skip = SelectionPill.standardSkip
        #expect(SelectionPill.starts(app: "com.apple.Notes", skip: skip) && SelectionPill.starts(app: nil, skip: skip))
        #expect(!SelectionPill.starts(app: "com.mitchellh.ghostty", skip: skip))
    }

    @Test("A release six points away is a drag; closer is a click")
    func dragged() {
        #expect(SelectionPill.dragged(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 16, y: 10)))
        #expect(!SelectionPill.dragged(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13, y: 13)))
    }

    @Test("The skip list is the terminals until set; blanks and repeats go, an empty list skips nothing")
    func skip() {
        #expect(SelectionPill.skip(nil) == ["com.mitchellh.ghostty", "com.apple.Terminal"])
        #expect(SelectionPill.skip([" com.apple.Terminal", "", "com.apple.Terminal", "dev.zed.Zed "]) == ["com.apple.Terminal", "dev.zed.Zed"])
        #expect(SelectionPill.skip([]) == [])
    }

    @Test("A question carries the selection as data in its own tag, then the words")
    func ask() {
        #expect(SelectionPrompt.ask(" why? ", about: "teh fox").hasSuffix("<selected_text>\nteh fox\n</selected_text>\n\nwhy?"))
    }
}
