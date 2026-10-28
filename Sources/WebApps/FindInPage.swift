import Foundation

/// Find in page in a web app (card agent-bo-95422811): the bar counts matches in the page's text, says how many, and
/// steps through them with WKWebView's own find.
public enum FindInPage {
    /// The keys the find field takes for itself; Cmd+G and Shift+Cmd+G come through the Edit menu (menuItems).
    public enum Key: Equatable, Sendable { case `return`, escape }
    public enum Step: Equatable, Sendable { case show, next, previous, close }

    /// Matches of `query` in `text`, ignoring case, without overlaps (what the highlight steps through).
    public static func count(_ query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0, start = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            count += 1
            start = found.upperBound
        }
        return count
    }

    public static func label(query: String, count: Int) -> String {
        guard !query.isEmpty else { return "" }
        return switch count {
        case 0: "no matches"
        case 1: "1 match"
        default: "\(count) matches"
        }
    }

    /// What Return, Shift+Return and Escape do in the find field.
    public static func step(for key: Key, shift: Bool = false) -> Step {
        switch key {
        case .return: shift ? .previous : .next
        case .escape: .close
        }
    }

    /// The Edit menu's find items, Safari's keys: Cmd+F shows the bar (or closes it), Cmd+G and Shift+Cmd+G step.
    public static let menuItems: [(title: String, key: String, shift: Bool, step: Step)] = [
        ("Find…", "f", false, .show), ("Find Next", "g", false, .next), ("Find Previous", "g", true, .previous),
    ]
}
