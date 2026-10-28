import Foundation

/// Tools › Captures › History (P73, after Snapzy's capture history): every capture and recording in Pilot's two folders,
/// and any Pilot saved elsewhere before a folder changed, with the app it came from. The folders are the history; the
/// index only adds what a file cannot say (its app), so captures from before the index still list.
public enum CaptureHistory {
    /// What Pilot noted as it saved a file: where it went, its kind and the app in front.
    public struct Record: Codable, Equatable, Sendable {
        public let path: String
        public let kind: CaptureKind
        public let app: String?

        public init(path: String, kind: CaptureKind, app: String?) {
            self.path = path
            self.kind = kind
            self.app = app
        }
    }

    /// One file the History page lists.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let url: URL
        public let kind: CaptureKind
        public let date: Date
        public let bytes: Int
        public let app: String?
        /// Named as Pilot names its files, or noted by Pilot: only these count toward the size cap and are ever trashed by it.
        public let pilotMade: Bool

        public var id: String { url.path(percentEncoded: false) }
        public var name: String { url.deletingPathExtension().lastPathComponent }

        public init(url: URL, kind: CaptureKind, date: Date, bytes: Int, app: String?, pilotMade: Bool) {
            self.url = url
            self.kind = kind
            self.date = date
            self.bytes = bytes
            self.app = app
            self.pilotMade = pilotMade
        }
    }

    /// The page's kinds filter.
    public enum Filter: String, CaseIterable, Sendable {
        case all, captures, recordings

        public func admits(_ kind: CaptureKind) -> Bool {
            switch self {
            case .all: true
            case .captures: kind == .capture
            case .recordings: kind == .recording
            }
        }
    }

    static let pictures: Set<String> = ["png", "jpg", "jpeg", "heic"]
    static let movies: Set<String> = ["mp4", "mov"]

    /// Every capture and recording, newest first: the files in the two folders, pictures as captures and movies as
    /// recordings, then any noted file outside them that is still there. Hidden files, folders and symbolic links are left
    /// out, so the size cap never follows a link. Off the main thread: it reads every file's size.
    public static func entries(records: [Record], captures: URL, recordings: URL, fileManager: FileManager = .default) -> [Entry] {
        let apps = Dictionary(records.map { ($0.path, $0.app) }, uniquingKeysWith: { _, last in last })
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        var seen = Set<String>()
        func entry(_ url: URL, _ kind: CaptureKind) -> Entry? {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(path), let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            seen.insert(path)
            let noted = apps.index(forKey: path) != nil
            return Entry(url: url.standardizedFileURL, kind: kind, date: date(url.lastPathComponent) ?? values.creationDate ?? .distantPast,
                         bytes: values.fileSize ?? 0, app: apps[path] ?? nil, pilotMade: noted || isPilotName(url.lastPathComponent))
        }
        func scan(_ folder: URL) -> [Entry] {
            let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { url in kind(url).flatMap { entry(url, $0) } }
        }
        var all = scan(captures)
        if recordings.standardizedFileURL != captures.standardizedFileURL { all += scan(recordings) }
        all += records.compactMap { entry(URL(filePath: $0.path), $0.kind) }
        return all.sorted { $0.date > $1.date }
    }

    /// A picture is a capture and a movie a recording, by extension; anything else is not history.
    public static func kind(_ url: URL) -> CaptureKind? {
        let ext = url.pathExtension.lowercased()
        return pictures.contains(ext) ? .capture : movies.contains(ext) ? .recording : nil
    }

    /// The entries `query` finds, by name or app, any word in any order, in `filter`'s kinds.
    public static func matching(_ entries: [Entry], query: String, filter: Filter) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return entries.filter { e in
            guard filter.admits(e.kind) else { return false }
            let text = "\(e.name) \(e.app ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// `Capture 2026-10-16 at 14.03.22`, `Recording … 2` or `Capture … edited`: a name Pilot gives its files.
    public static func isPilotName(_ name: String) -> Bool { date(name) != nil }

    /// The time a Pilot file name carries (CaptureFiles.name), in the Mac's zone: a capture's own time, which an editor's
    /// Done (it writes over the file) never moves. Nil for any other name.
    public static func date(_ name: String) -> Date? {
        for kind in CaptureKind.allCases where name.hasPrefix(kind.word + " ") {
            if let date = stamp.date(from: String(name.dropFirst(kind.word.count + 1).prefix(22))) { return date }
        }
        return nil
    }

    /// One formatter for every name a scan reads (thousands); reading a date is thread-safe.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// The size cap's choices in gigabytes; 0 keeps everything (the default).
    public static let caps = [0, 1, 2, 5, 10, 20]

    /// What the cap sends to the Trash: Pilot's own files, oldest first, until the ones Pilot made fit in `capBytes`.
    /// The newest is never one, so a capture just taken stays even when it alone is over the cap. No cap trashes nothing.
    public static func overCap(_ entries: [Entry], capBytes: Int) -> [Entry] {
        guard capBytes > 0 else { return [] }
        let mine = entries.filter(\.pilotMade).sorted { $0.date > $1.date }
        var total = mine.reduce(0) { $0 + $1.bytes }
        var out: [Entry] = []
        for e in mine.dropFirst().reversed() where total > capBytes {
            out.append(e)
            total -= e.bytes
        }
        return out
    }

    /// The bytes the files Pilot made take.
    public static func used(_ entries: [Entry]) -> Int { entries.filter(\.pilotMade).reduce(0) { $0 + $1.bytes } }
}

/// History's notes keep a file's kind by its raw name.
extension CaptureKind: Codable {}
