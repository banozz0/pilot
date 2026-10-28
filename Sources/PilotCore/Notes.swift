import Foundation

/// One quick note (card agent-bo-95423042): a .md file in the notes folder, its file name its id, its first line its title.
public struct Note: Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String
    public var edited: Date
    public var pinned: Bool
    /// Its first line; Scratch is always "Scratch", so a Scratch written over never passes for a note that can go to
    /// the Trash (notes round 2, Sven 2026-10-10).
    public var title: String { isScratch ? "Scratch" : Notes.title(of: text) }
    public var isScratch: Bool { id == NoteStore.scratch }

    public init(id: String, text: String, edited: Date, pinned: Bool) {
        self.id = id; self.text = text; self.edited = edited; self.pinned = pinned
    }
}

/// Quick notes on disk (SuperCmd's notes, ideas only): one .md file per note in `folder`, named by a slug of its first
/// line plus a six-digit id, Scratch.md always there and kept empty (Sven 2026-10-15: what is written in Scratch moves
/// to a note of its own) and never pinned (Sven 2026-10-18: Scratch is a section of its own, over Pinned), the pins in
/// pins.json beside them. A .md
/// file written there by anything else is a note too and keeps its name. Every read goes to the disk, so a file added
/// outside Pilot shows on the next one.
public struct NoteStore: Sendable {
    public static let scratch = "Scratch.md"
    /// Scratch.md as Pilot wrote it before Scratch was kept empty (2026-10-15); still read as an empty Scratch.
    static let scratchText = "# Scratch\n\n"

    public let folder: URL
    private let now: @Sendable () -> Date
    private let newID: @Sendable () -> String
    /// Moves a file to the Trash: FileManager's, outside tests.
    private let trashItem: @Sendable (URL) throws -> Void

    public init(folder: URL, now: @escaping @Sendable () -> Date = { Date() },
                newID: @escaping @Sendable () -> String = { String(format: "%06d", Int.random(in: 0..<1_000_000)) },
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.folder = folder; self.now = now; self.newID = newID; self.trashItem = trash
    }

    /// Every note, Scratch first, then pinned, then newest edited; Scratch.md is written first when it is missing.
    public func load() throws -> [Note] {
        try ensureScratch()
        let pins = try loadPins()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        let notes = try files.filter { $0.pathExtension.lowercased() == "md" }.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let edited = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let id = url.lastPathComponent
            return Note(id: id, text: text, edited: edited, pinned: id != Self.scratch && pins.contains(id))
        }
        return notes.sorted { a, b in
            (a.isScratch ? 0 : a.pinned ? 1 : 2, b.edited) < (b.isScratch ? 0 : b.pinned ? 1 : 2, a.edited)
        }
    }

    /// A new note holding `text`, written at once so it has a file to rename.
    @discardableResult
    public func create(text: String = "") throws -> Note {
        try ensureScratch()
        let id = "\(Notes.slug(Notes.title(of: text)))-\(newID()).md"
        try write(text, to: id)
        return Note(id: id, text: text, edited: now(), pinned: false)
    }

    /// Writes the note; when its first line changed, a note Pilot named gets the new slug (its short id kept) and its
    /// pin follows. Returns the id it is saved under.
    @discardableResult
    public func save(_ id: String, text: String) throws -> String {
        let renamed = Self.renamed(id, title: Notes.title(of: text)) ?? id
        try write(text, to: renamed)
        guard renamed != id else { return id }
        try FileManager.default.removeItem(at: folder.appending(path: id))
        var pins = try loadPins()
        if pins.remove(id) != nil { pins.insert(renamed); try savePins(pins) }
        return renamed
    }

    /// Pins or unpins a note; Scratch is never pinned whatever is asked.
    public func setPinned(_ id: String, _ on: Bool) throws {
        guard id != Self.scratch else { return }
        var pins = try loadPins()
        if on { pins.insert(id) } else { pins.remove(id) }
        try savePins(pins)
    }

    /// What Scratch holds, moved to a note of its own and Scratch emptied (Sven 2026-10-15): nil when it holds nothing
    /// (or only the old "# Scratch" heading, which does not move with the words and is cleared, so Scratch is "" after).
    /// The note is written before Scratch is emptied, so a failed write loses nothing.
    @discardableResult
    public func moveScratch() throws -> Note? {
        try ensureScratch()
        let url = folder.appending(path: Self.scratch)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !Notes.isBlankScratch(text) else {
            if !text.isEmpty { try write("", to: Self.scratch) }
            return nil
        }
        let note = try create(text: Notes.droppingScratchHeading(text))
        try write("", to: Self.scratch)
        return note
    }

    /// The menu's "note …": `line` on a line of its own at the end of Scratch.
    public func appendToScratch(_ line: String) throws {
        try ensureScratch()
        let url = folder.appending(path: Self.scratch)
        let text = try String(contentsOf: url, encoding: .utf8)
        try write(text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line, to: Self.scratch)
    }

    /// Moves a note to the Trash and drops its pin; never Scratch. Its images in attachments/ go with it, each only when
    /// no other note in the folder shows it.
    public func trash(_ id: String) throws {
        guard id != Self.scratch else { return }
        let url = folder.appending(path: id)
        let images = NoteAttachments.references(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        try trashItem(url)
        try setPinned(id, false)
        guard !images.isEmpty else { return }
        let others = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .flatMap { NoteAttachments.references(in: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
        for name in Set(images).subtracting(others) {
            let image = folder.appending(path: NoteAttachments.folder).appending(path: name)
            if FileManager.default.fileExists(atPath: image.path) { try trashItem(image) }
        }
    }

    /// The name a Pilot-named note takes for `title` ("slug-123456.md"); nil for Scratch and a file named elsewhere. Only
    /// Pilot's own shape (lowercase slug words, six digits) counts, so a vault note such as "Meeting-261008.md" is never
    /// renamed: on a case-insensitive disk the write would land on the old file and the remove would delete it.
    static func renamed(_ id: String, title: String) -> String? {
        guard id != scratch, let match = id.wholeMatch(of: /[a-z0-9]+(?:-[a-z0-9]+)*-(\d{6})\.md/) else { return nil }
        return "\(Notes.slug(title))-\(match.1).md"
    }

    private func ensureScratch() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: folder.appending(path: Self.scratch).path) { try write("", to: Self.scratch) }
    }

    private func write(_ text: String, to id: String) throws {
        try Data(text.utf8).write(to: folder.appending(path: id), options: .atomic)
    }

    private var pinsFile: JSONFile<[String]> { JSONFile(url: folder.appending(path: "pins.json")) }
    private func loadPins() throws -> Set<String> { Set(try pinsFile.load(or: [])) }
    private func savePins(_ pins: Set<String>) throws { try pinsFile.save(pins.sorted()) }
}

/// What the panel and the menu show of the notes.
public enum Notes {
    /// The first line that has text, without Markdown's heading marks, past a line that only shows an image; "Untitled"
    /// for an empty note.
    public static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !NoteAttachments.isImageLine($0) }
        return line ?? "Untitled"
    }

    /// Scratch with nothing in it: no words, or only the "# Scratch" heading Pilot used to write.
    public static func isBlankScratch(_ text: String) -> Bool {
        droppingScratchHeading(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `text` without a "# Scratch" heading on its first line and the blank lines under it.
    static func droppingScratchHeading(_ text: String) -> String {
        guard text.hasPrefix("# Scratch\n") || text == "# Scratch" else { return text }
        return String(text.dropFirst("# Scratch".count).drop { $0.isNewline })
    }

    /// Lowercase letters and digits, runs of anything else one hyphen, at most 40 characters.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = String(words.joined(separator: "-").prefix(40))
        return slug.isEmpty ? "untitled" : slug
    }

    /// The list's sections, top to bottom: Scratch alone on top in a section of its own, then Pinned, Today, Yesterday
    /// and Earlier (Sven 2026-10-18, direction B: "add scratch uptop as like its own section and pinned under it").
    public enum Section: String, CaseIterable, Sendable {
        case scratch, pinned, today, yesterday, earlier

        public var title: String { rawValue.capitalized }
    }

    /// One section's notes, newest edited first.
    public struct Group: Equatable, Sendable {
        public let section: Section
        public let notes: [Note]
        public var title: String { section.title }
    }

    public static func groups(_ notes: [Note], now: Date, calendar: Calendar = .current) -> [Group] {
        let bySection = Dictionary(grouping: notes) { section(of: $0, now: now, calendar: calendar) }
        return Section.allCases.compactMap { section in
            bySection[section].map { Group(section: section, notes: $0.sorted { $0.edited > $1.edited }) }
        }
    }

    /// The section a note is listed in: Scratch's own, Pinned, else the day it was last edited; the head's crumb names it.
    public static func section(of note: Note, now: Date, calendar: Calendar = .current) -> Section {
        if note.isScratch { return .scratch }
        if note.pinned { return .pinned }
        let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: note.edited), to: calendar.startOfDay(for: now)).day ?? 0
        return ago <= 0 ? .today : ago == 1 ? .yesterday : .earlier
    }

    /// A row's line of words under its title (Q306, Sven 2026-10-18): with `query` typed, the first line past the title
    /// holding every typed word; else the lines after the title joined by " · ". Marks left out; empty when nothing is
    /// past the title. Only the first lines are read: a row shows one.
    public static func line(of text: String, query: String = "") -> String {
        let lines = words(text, upTo: 240).dropFirst()
        let typed = query.split(whereSeparator: \.isWhitespace)
        if !typed.isEmpty, let found = lines.first(where: { line in typed.allSatisfy { line.localizedCaseInsensitiveContains($0) } }) {
            return found
        }
        return lines.joined(separator: " · ")
    }

    /// Each line with words, as it reads: past a heading's `#`, a quote's `>`, a list's or a checkbox's mark, and the
    /// bold, italic, code and link marks; a fence, a table's rule and a line that only shows a picture left out. The first
    /// is the title's. Stops once `upTo` characters are gathered.
    static func words(_ text: String, upTo limit: Int = .max) -> [String] {
        var out: [String] = [], gathered = 0
        for raw in text.split(whereSeparator: \.isNewline) where gathered < limit {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !NoteAttachments.isImageLine(line), !line.hasPrefix("```"), !line.allSatisfy({ "|-: ".contains($0) }) else { continue }
            for (mark, keep) in plainMarks {
                line = mark.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: keep)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line); gathered += line.count }
        }
        return out
    }

    /// What `words` takes off a line, in order, and what it keeps of each match.
    private static let plainMarks: [(NSRegularExpression, String)] = [
        (#"^(#{1,6}|>)[ \t]*"#, ""), (#"^([-*+][ \t]+\[[ xX]\]|[-*+]|\d+[.)])[ \t]+"#, ""), (#"\[([^\]\n]+)\]\([^)\s]+\)"#, "$1"),
        (#"\*\*|__|`"#, ""), (#"(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])"#, "$1"), (#"[ \t]*\|[ \t]*"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The Notes page's search: titles that match, best first, then notes with the words in their text.
    public static func search(_ notes: [Note], query: String) -> [Note] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        let titled = FuzzyRanker.rank(notes, query: query, title: \.title), ids = Set(titled.map(\.id))
        let words = query.split(whereSeparator: \.isWhitespace)
        let inText = notes.filter { note in !ids.contains(note.id) && words.allSatisfy { note.text.localizedCaseInsensitiveContains($0) } }
        return titled + inText
    }

    /// The menu's Notes branch: a row per note; search matches its title and text, Return opens it in the panel.
    public static func rows(_ notes: [Note]) -> [MenuEntry] {
        notes.map { note in
            MenuEntry(title: note.title, target: .note(.open(note.id)), home: .notes, detail: note.pinned ? "Pinned" : nil,
                      inSearch: false, keywords: note.text)
        }
    }

    /// The root's answer for "note buy milk": a row that saves the text as a note (through Scratch, which moves it).
    public static func entries(for query: String) -> [MenuEntry] {
        let words = query.split(separator: " ")
        guard words.count >= 2, words[0].lowercased() == "note" else { return [] }
        let text = words.dropFirst().joined(separator: " ")
        return [MenuEntry(title: "New note", target: .note(.append(text)), detail: "Return saves the line as a note", isAnswer: true, subtitle: text)]
    }

    /// What a note row does on Return: open that note in the panel, or add a line to Scratch.
    public enum Pick: Hashable, Sendable { case open(String), append(String) }
}
