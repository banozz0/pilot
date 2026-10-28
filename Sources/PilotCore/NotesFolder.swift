import Foundation

/// Where quick notes live (task N1, Sven 2026-10-09: "a native notes place in Pilot that the notes are saved to by
/// default, which can be moved anywhere"): Pilot's own folder in Documents unless Sven picked another, and a move that
/// carries every note and its pin from one folder to the next.
public enum NotesFolder {
    /// Pilot's own place, made on first use.
    public static let pilotDefault = URL.documentsDirectory.appending(path: "Pilot Notes", directoryHint: .isDirectory)
    /// Pilot's place before N1; notes found there stay there.
    public static let legacy = PilotFolder.support.appending(path: "Notes", directoryHint: .isDirectory)

    /// The saved folder setting at launch: the one Sven picked, else the old folder while it holds a note, so nothing
    /// written there goes missing; nil is Pilot's own.
    public static func kept(saved: String?, legacy: URL = legacy) -> String? {
        saved ?? (notes(in: legacy).isEmpty ? nil : legacy.path)
    }

    /// The folder a setting names: nil is Pilot's own.
    public static func folder(_ setting: String?) -> URL {
        setting.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? pilotDefault
    }

    /// The setting that names `folder`: nil for Pilot's own.
    public static func setting(_ folder: URL) -> String? {
        same(folder, pilotDefault) ? nil : folder.path
    }

    /// The notes worth moving out of `folder`: every .md file but a Scratch nobody wrote in.
    public static func notes(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" && !untouchedScratch($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// What a move did: how many notes went, and the ones that took a new name because the new folder had one by
    /// theirs (old name to new).
    public struct Moved: Equatable, Sendable {
        public var count = 0
        public var renamed: [String: String] = [:]
        public init(count: Int = 0, renamed: [String: String] = [:]) { self.count = count; self.renamed = renamed }
    }

    /// Moves every note and its pin from `old` to `new` (made when missing), and the pictures in attachments/ with them.
    /// A name the new folder already has is kept there and the incoming note becomes "name 2.md", an incoming picture
    /// "name 2.png" with the moved notes' links to it rewritten; an unwritten Scratch on either side gives way to the
    /// other. Anything else stays in `old`. The same folder twice moves nothing.
    public static func move(from old: URL, to new: URL) throws -> Moved {
        var moved = Moved()
        guard !same(old, new) else { return moved }
        let fm = FileManager.default
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let pictures = try moveAttachments(from: old, to: new)
        let oldScratch = old.appending(path: NoteStore.scratch)
        if untouchedScratch(oldScratch) { try fm.removeItem(at: oldScratch) }
        // The names already there, in lower case: the Mac's disk does not tell "Inbox.md" from "inbox.md".
        var taken = Set(try fm.contentsOfDirectory(atPath: new.path).map { $0.lowercased() })
        for file in notes(in: old) {
            var name = file.lastPathComponent
            let target = new.appending(path: name)
            if name == NoteStore.scratch && untouchedScratch(target) {
                try fm.removeItem(at: target)
            } else if taken.contains(name.lowercased()) {
                name = freeName(name, taken: taken)
                moved.renamed[file.lastPathComponent] = name
            }
            try fm.moveItem(at: file, to: new.appending(path: name))
            if !pictures.isEmpty { try relink(new.appending(path: name), pictures) }
            taken.insert(name.lowercased())
            moved.count += 1
        }
        let oldPins = JSONFile<[String]>(url: old.appending(path: "pins.json")), newPins = JSONFile<[String]>(url: new.appending(path: "pins.json"))
        let pins = try oldPins.load(or: []).map { moved.renamed[$0] ?? $0 }
        if !pins.isEmpty { try newPins.save(Set(try newPins.load(or: []) + pins).sorted()) }
        if fm.fileExists(atPath: oldPins.url.path) { try fm.removeItem(at: oldPins.url) }
        return moved
    }

    /// Moves `old`/attachments/ into `new`/attachments/, a name taken there becoming "name 2.png"; returns those renames.
    private static func moveAttachments(from old: URL, to new: URL) throws -> [String: String] {
        let fm = FileManager.default
        let from = old.appending(path: NoteAttachments.folder), to = new.appending(path: NoteAttachments.folder)
        guard let files = try? fm.contentsOfDirectory(atPath: from.path), !files.isEmpty else { return [:] }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var taken = Set(try fm.contentsOfDirectory(atPath: to.path).map { $0.lowercased() }), renamed: [String: String] = [:]
        for file in files.sorted() {
            let name = freeName(file, taken: taken)
            if name != file { renamed[file] = name }
            try fm.moveItem(at: from.appending(path: file), to: to.appending(path: name))
            taken.insert(name.lowercased())
        }
        if (try? fm.contentsOfDirectory(atPath: from.path))?.isEmpty == true { try fm.removeItem(at: from) }
        return renamed
    }

    /// `name`, or "name 2.ext", "name 3.ext" (with `separator` between) when `taken`, which holds lower-case names: the
    /// Mac's disk does not tell "Inbox.md" from "inbox.md".
    static func freeName(_ name: String, taken: Set<String>, separator: String = " ") -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return (1...).lazy.map { n in n == 1 ? name : "\(stem)\(separator)\(n)" + (ext.isEmpty ? "" : ".\(ext)") }
            .first { !taken.contains($0.lowercased()) }!
    }

    /// Points a moved note's picture links at the names their pictures took.
    private static func relink(_ note: URL, _ renamed: [String: String]) throws {
        let text = try String(contentsOf: note, encoding: .utf8)
        var linked = text
        for (old, new) in renamed {
            let encoded = { (name: String) in name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name }
            for form in Set([old, encoded(old)]) {
                linked = linked.replacingOccurrences(of: "](\(NoteAttachments.folder)/\(form))", with: "](\(NoteAttachments.folder)/\(encoded(new)))")
            }
        }
        if linked != text { try Data(linked.utf8).write(to: note, options: .atomic) }
    }

    /// Whether two paths name one folder, however they are written.
    public static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Scratch.md with nothing written in it (empty, or the heading Pilot used to write).
    private static func untouchedScratch(_ url: URL) -> Bool {
        url.lastPathComponent == NoteStore.scratch && (try? String(contentsOf: url, encoding: .utf8)).map(Notes.isBlankScratch) == true
    }
}
