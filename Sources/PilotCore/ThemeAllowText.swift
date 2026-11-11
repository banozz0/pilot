import Foundation

/// Allow's one question about a theme plan. Allow refuses a question it cannot show whole, so this shortens by wording first:
/// home as ~, then screens and folders collapsed, then paths counted. An app is never dropped silently, and a file reached
/// through a link out of its app's folder stays named longest.
public enum ThemeAllowText {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let paths: [String]
        /// Wording that can go first, such as Ghostex's setting names.
        public let note: String?
        public let linked: Bool
        public let screen: Bool
        public init(name: String, paths: [String] = [], note: String? = nil, linked: Bool = false, screen: Bool = false) {
            self.name = name; self.paths = paths; self.note = note; self.linked = linked; self.screen = screen
        }
        /// The complete line Preview shows.
        public var line: String { name + (note ?? "") + (paths.isEmpty ? "" : ": " + paths.joined(separator: ", ")) }
    }

    public static func fit(lead: String, entries: [Entry], skipped: [String], limit: Int, home: String) -> String {
        func size(_ text: String) -> Int { text.unicodeScalars.count }
        func joined(_ parts: [String]) -> String { lead + ": " + parts.joined(separator: ". ") }
        func tilde(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }

        let whole = joined(entries.map(\.line) + skipped)
        if size(whole) <= limit { return whole }
        let homed = joined(entries.map { Entry(name: $0.name, paths: $0.paths.map(tilde), note: $0.note).line } + skipped)
        if size(homed) <= limit { return homed }

        // Wording goes: one line for all screens, folders once, setting names and skip reasons left to Preview.
        func folded(_ entry: Entry) -> String {
            let paths = entry.paths.map(tilde)
            guard !entry.linked, paths.count > 1 else { return paths.isEmpty ? entry.name : entry.name + ": " + paths.joined(separator: ", ") }
            var shared = paths[0].split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
            for path in paths.dropFirst() {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                shared = Array(zip(shared, parts).prefix { $0 == $1 }.map(\.0))
            }
            guard shared.count > 1 else { return entry.name + ": " + paths.joined(separator: ", ") }
            let folder = shared.joined(separator: "/")
            return entry.name + " in " + folder + ": " + paths.map { String($0.dropFirst(folder.count + 1)) }.joined(separator: ", ")
        }
        let screens = entries.filter(\.screen)
        var compact = entries.filter { !$0.screen }
        if !screens.isEmpty { compact.insert(screens.count == 1 ? screens[0] : Entry(name: "Wallpaper on \(screens.count) screens"), at: 0) }
        let skips = skipped.isEmpty ? [] : ["Skipped: " + skipped.map { $0.components(separatedBy: " skipped").first ?? $0 }.joined(separator: ", ")]
        let tight = joined(compact.map(folded) + skips)
        if size(tight) <= limit { return tight }

        // Still too long: every app by name, then as many paths as fit, the linked file first, and a count of the rest.
        let ordered = compact.filter(\.linked) + compact.filter { !$0.linked }
        func render(_ open: Set<Int>, kept: Int) -> String {
            var parts = ordered.prefix(kept).enumerated().map { open.contains($0.offset) ? folded($0.element) : $0.element.name }
            if kept == ordered.count { parts += skips }
            let unnamed = ordered.enumerated().reduce(0) { sum, row in
                row.offset >= kept ? sum + max(1, row.element.paths.count) : open.contains(row.offset) ? sum : sum + row.element.paths.count
            } + (kept == ordered.count ? 0 : skipped.count)
            if unnamed > 0 { parts.append("and \(unnamed) more, listed in Preview") }
            return joined(parts)
        }
        let linked = ordered.filter(\.linked).count
        var open = Set(0..<linked), kept = ordered.count
        while kept > linked, size(render(open, kept: kept)) > limit { kept -= 1 }
        for index in linked..<kept where size(render(open.union([index]), kept: kept)) <= limit { open.insert(index) }
        return render(open, kept: kept)
    }
}
