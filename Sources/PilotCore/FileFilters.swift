import Foundation

/// The Files view's filters (N5, Sven 2026-10-09: "when I open file search there are sooooo many files that no human
/// should read"): a kind, a place and a time, each stepped with ⌘1, ⌘2 and ⌘3 or typed as `kind:pdf`, `in:downloads`,
/// `when:today`, and Show hidden (⌘⇧.). The file index applies them (pilot-files, filter.rs): Cardinal narrows its name
/// matches by kind, folder and date, and leaves dot names and bundle insides out unless `hidden`.
public struct FileFilters: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folders, documents, images, video, audio, code, archives, apps
        /// One extension, typed as `kind:pdf`.
        case ext(String)

        public static let all: [Kind] = [.folders, .documents, .images, .video, .audio, .code, .archives, .apps]

        public var title: String {
            switch self {
            case .folders: "Folders"
            case .documents: "Documents"
            case .images: "Images"
            case .video: "Video"
            case .audio: "Audio"
            case .code: "Code"
            case .archives: "Archives"
            case .apps: "Apps"
            case .ext(let ext): ext.uppercased()
            }
        }

        /// The helper's name for it (filter.rs, kind_terms); an extension goes as `ext`.
        var wire: String? {
            switch self {
            case .folders: "folders"
            case .documents: "documents"
            case .images: "images"
            case .video: "video"
            case .audio: "audio"
            case .code: "code"
            case .archives: "archives"
            case .apps: "apps"
            case .ext: nil
            }
        }
    }

    /// Where: Home is no place (the index holds only the home folder), so it is nil.
    public enum Place: Equatable, Sendable {
        case desktop, documents, downloads, iCloud
        /// A folder picked with Cmd+K's Search inside or typed as `in:~/code/pilot`, as an absolute path.
        case folder(String)

        public static let all: [Place] = [.desktop, .documents, .downloads, .iCloud]

        public var title: String {
            switch self {
            case .desktop: "Desktop"
            case .documents: "Documents"
            case .downloads: "Downloads"
            case .iCloud: "iCloud Drive"
            case .folder(let path): URL(fileURLWithPath: path).lastPathComponent
            }
        }

        public func path(home: String) -> String {
            switch self {
            case .desktop: home + "/Desktop"
            case .documents: home + "/Documents"
            case .downloads: home + "/Downloads"
            // Finder's iCloud Drive: every container in Mobile Documents, which the never-index list keeps (FileExclusions).
            case .iCloud: home + "/Library/Mobile Documents"
            case .folder(let path): path
            }
        }
    }

    public enum When: String, CaseIterable, Sendable {
        case today, week, month

        public var title: String {
            switch self {
            case .today: "Today"
            case .week: "This week"
            case .month: "This month"
            }
        }
    }

    public enum Facet: CaseIterable, Sendable { case kind, place, when }

    public var kind: Kind?
    public var place: Place?
    public var when: When?
    /// Dot names and bundle insides too (Show hidden and system files).
    public var hidden: Bool

    public init(kind: Kind? = nil, place: Place? = nil, when: When? = nil, hidden: Bool = false) {
        self.kind = kind
        self.place = place
        self.when = when
        self.hidden = hidden
    }

    /// The next (1) or previous (-1) value of `facet`, through Any (nil) and round again. A typed extension or a picked
    /// folder steps on to the first of the list.
    public mutating func step(_ facet: Facet, by step: Int) {
        func next<T: Equatable>(_ value: T?, in list: [T]) -> T? {
            let all: [T?] = [nil] + list.map(Optional.some)
            let at = all.firstIndex(of: value) ?? 0
            return all[((at + step) % all.count + all.count) % all.count]
        }
        switch facet {
        case .kind: kind = next(kind, in: Kind.all)
        case .place: place = next(place, in: Place.all)
        case .when: when = next(when, in: When.allCases)
        }
    }

    public mutating func clear(_ facet: Facet) {
        switch facet {
        case .kind: kind = nil
        case .place: place = nil
        case .when: when = nil
        }
    }

    public func isSet(_ facet: Facet) -> Bool {
        switch facet {
        case .kind: kind != nil
        case .place: place != nil
        case .when: when != nil
        }
    }

    /// These filters with what was typed over them: a typed `kind:` wins over the stepped kind.
    public func merged(with typed: FileFilters) -> FileFilters {
        FileFilters(kind: typed.kind ?? kind, place: typed.place ?? place, when: typed.when ?? when, hidden: hidden)
    }

    // MARK: Typed prefixes

    /// The search without its `kind:`, `in:` and `when:` words, and the filters they name. A word whose value is not one
    /// of them stays in the search (Cardinal's own `in:/path` still works).
    public static func typed(_ search: String, home: String) -> (text: String, filters: FileFilters) {
        var filters = FileFilters()
        let kept = search.split(separator: " ", omittingEmptySubsequences: false).filter { word in
            guard let (facet, value) = prefix(String(word)) else { return true }
            switch facet {
            case .kind: guard let kind = kind(value) else { return true }; filters.kind = kind
            case .place: guard let place = place(value, home: home) else { return true }; filters.place = place
            case .when: guard let when = when(value) else { return true }; filters.when = when
            }
            return false
        }
        return (kept.joined(separator: " "), filters)
    }

    /// The search with `facet`'s typed word taken out, for a chip's ×.
    public static func removing(_ facet: Facet, from search: String, home: String) -> String {
        search.split(separator: " ", omittingEmptySubsequences: false).filter { word in
            !(typed(String(word), home: home).filters.isSet(facet))
        }
        .joined(separator: " ")
    }

    private static func prefix(_ word: String) -> (Facet, String)? {
        let parts = word.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1])
        switch parts[0].lowercased() {
        case "kind": return (.kind, value.lowercased())
        case "in": return (.place, value)
        case "when": return (.when, value.lowercased())
        default: return nil
        }
    }

    private static func kind(_ value: String) -> Kind? {
        switch value {
        case "folder", "folders", "dir": .folders
        case "doc", "docs", "document", "documents": .documents
        case "image", "images", "img", "pic", "pics", "photo", "photos": .images
        case "video", "videos", "movie", "movies": .video
        case "audio", "music", "song", "songs": .audio
        case "code": .code
        case "archive", "archives": .archives
        case "app", "apps": .apps
        // Any other plain word is an extension: kind:pdf, kind:md.
        case let ext where !ext.isEmpty && ext.count <= 10 && ext.allSatisfy({ $0.isLetter || $0.isNumber }): .ext(ext)
        default: nil
        }
    }

    private static func place(_ value: String, home: String) -> Place? {
        switch value.lowercased() {
        case "home", "~": return nil
        case "desktop": return .desktop
        case "documents", "docs": return .documents
        case "downloads": return .downloads
        case "icloud": return .iCloud
        default:
            if value.hasPrefix("~/") { return .folder(home + value.dropFirst()) }
            if value.hasPrefix("/"), value.count > 1 { return .folder(value.hasSuffix("/") ? String(value.dropLast()) : value) }
            return nil
        }
    }

    private static func when(_ value: String) -> When? {
        switch value {
        case "today": .today
        case "week", "thisweek": .week
        case "month", "thismonth": .month
        default: nil
        }
    }
}

/// The never-index list (N5): folders the file index skips entirely, so they cost it no memory and no walk. Sven edits
/// it on Files › File search; an entry is a folder name (`node_modules`, any folder so named) or a path under home
/// (`~/Library`, that one folder). The helper takes it as gitignore lines (`--ignore`); a changed list walks again.
public enum FileExclusions {
    /// The shipped list, as the helper's DEFAULT_IGNORE holds it: ~/Library but iCloud Drive, the Trash, package caches,
    /// version control and build output.
    public static let defaults = ["~/Library", "~/.Trash", "~/.cache", "~/.bun", "~/.npm", "~/.cargo", "~/.rustup",
                                  "node_modules", ".git", ".build", "DerivedData", "target", "__pycache__", "venv", ".venv"]

    /// A typed entry as the list keeps it: trimmed, without a trailing slash, a path under home written with `~`; nil
    /// for a blank, home itself, a path outside home (never indexed anyway) or gitignore syntax.
    public static func entry(_ typed: String, home: String) -> String? {
        var entry = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while entry.count > 1, entry.hasSuffix("/") { entry.removeLast() }
        if entry.hasPrefix(home + "/") { entry = "~" + entry.dropFirst(home.count) }
        guard !entry.isEmpty, entry != "~", entry != home, !entry.contains("\n"),
              !entry.hasPrefix("!"), !entry.hasPrefix("#"), !entry.contains("*"), !entry.hasPrefix("/") else { return nil }
        if entry.hasPrefix("~") && !entry.hasPrefix("~/") { return nil }
        return entry
    }

    /// The helper's gitignore lines, relative to home: `~/Library` keeps Mobile Documents (iCloud Drive, a Where).
    public static func lines(_ entries: [String]) -> [String] {
        entries.flatMap { entry -> [String] in
            if entry == "~/Library" { return ["/Library/*", "!/Library/Mobile Documents/"] }
            if entry.hasPrefix("~/") { return ["/" + entry.dropFirst(2) + "/"] }
            return [entry + "/"]
        }
    }
}
