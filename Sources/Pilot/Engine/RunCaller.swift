import Foundation

/// Who is running the action that runs now: a bind's trigger, a link, the menu, the `pilot` command, an extension, the
/// top bar or the dropdown. The lines that open a terminal or start Clean's preview name it ("via Mouse 3"), so a log
/// says which press or path did it (tester feedback 2026-11-18: Ghostty opened with no press anyone could see). A
/// caller nobody set reads "unknown", itself a sign of a path to name.
@MainActor
enum RunCaller {
    private(set) static var current: String?

    static var name: String { current ?? "unknown" }

    /// Runs `body` with `caller` as the caller, then puts back the one before.
    static func with<T>(_ caller: String, _ body: () throws -> T) rethrows -> T {
        let before = current
        current = caller
        defer { current = before }
        return try body()
    }
}
