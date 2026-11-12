import Foundation

/// One place another app keeps its font (Sven, Q711 and Q712: "instead of everywhere i have ability to set where uses
/// that font"): its config under home and the one key Pilot changes there. macOS has no system-wide font, so each app is
/// set in its own file; Pilot's own words and mono are its own settings (PilotFonts), not places.
public struct FontPlace: Equatable, Sendable, Identifiable {
    public enum Format: Equatable, Sendable {
        /// A top-level string key in a JSON file, comments allowed (VS Code, Cursor, Zed, Ghostex); `css` when the value is
        /// a CSS font-family list, so a pick is quoted and its first family shown.
        case json(key: String, css: Bool)
        /// The `font-family` lines in Pilot's Ghostty include, which Ghostty's config loads after its own (GhosttyFiles).
        case ghostty
        /// kitty's `font_family` line; the last one wins.
        case kitty
        /// Alacritty's `family` in its `[font.normal]` table.
        case alacritty
    }

    public let id: String, app: String, place: String
    public let bundles: [String]
    /// Under home.
    public let path: String
    public let format: Format
    /// Terminals and editors: only fixed-pitch fonts are offered.
    public var mono = true
    /// The app reads its config again as it changes (Ghostty: Pilot reloads it); else a running one needs a restart.
    public var live = true
    /// The app's other config places under home: with `path` missing and one of these there, the app reads that one, so
    /// Pilot refuses rather than make a file that would shadow it.
    public var others: [String] = []

    /// "VS Code · Editor".
    public var title: String { "\(app) · \(place)" }

    /// Each place's key from the app's own default settings or source (2026-11-01): Ghostty's Config.zig v1.3.1, Ghostex's
    /// settings catalog, VS Code's settings, Zed's assets/settings/default.json, kitty's and Alacritty's references.
    /// Left out: Empryo (no font setting; its TUI draws in the terminal's font), iTerm2 (a profile inside a plist it
    /// rewrites on quit), Terminal (an archived NSFont), WezTerm (its config is Lua code), Warp (no readable font store).
    public static let known: [FontPlace] = [
        .init(id: "ghostty", app: "Ghostty", place: "Terminal", bundles: ["com.mitchellh.ghostty"], path: ".config/ghostty/pilot.conf", format: .ghostty),
        .init(id: "ghostex", app: "Ghostex", place: "Terminal", bundles: ["com.madda.ghostex.gpui"],
              path: ".config/ghostex/native-sidebar-settings.json", format: .json(key: "terminalFontFamily", css: false), live: false),
        .init(id: "vscode.editor", app: "VS Code", place: "Editor", bundles: ["com.microsoft.VSCode"],
              path: "Library/Application Support/Code/User/settings.json", format: .json(key: "editor.fontFamily", css: true)),
        .init(id: "vscode.terminal", app: "VS Code", place: "Terminal", bundles: ["com.microsoft.VSCode"],
              path: "Library/Application Support/Code/User/settings.json", format: .json(key: "terminal.integrated.fontFamily", css: true)),
        .init(id: "cursor.editor", app: "Cursor", place: "Editor", bundles: ["com.todesktop.230313mzl4w4u92"],
              path: "Library/Application Support/Cursor/User/settings.json", format: .json(key: "editor.fontFamily", css: true)),
        .init(id: "cursor.terminal", app: "Cursor", place: "Terminal", bundles: ["com.todesktop.230313mzl4w4u92"],
              path: "Library/Application Support/Cursor/User/settings.json", format: .json(key: "terminal.integrated.fontFamily", css: true)),
        .init(id: "zed.editor", app: "Zed", place: "Editor", bundles: ["dev.zed.Zed"], path: ".config/zed/settings.json",
              format: .json(key: "buffer_font_family", css: false)),
        .init(id: "zed.ui", app: "Zed", place: "Interface", bundles: ["dev.zed.Zed"], path: ".config/zed/settings.json",
              format: .json(key: "ui_font_family", css: false), mono: false),
        .init(id: "kitty", app: "kitty", place: "Terminal", bundles: ["net.kovidgoyal.kitty"], path: ".config/kitty/kitty.conf", format: .kitty, live: false,
              others: ["Library/Preferences/kitty/kitty.conf"]),
        .init(id: "alacritty", app: "Alacritty", place: "Terminal", bundles: ["org.alacritty"], path: ".config/alacritty/alacritty.toml", format: .alacritty,
              others: [".config/alacritty.toml", ".alacritty.toml", ".config/alacritty/alacritty.yml", ".alacritty.yml"]),
    ]

    /// The family a value names: a CSS list's first, unquoted; kitty's `family="…"`.
    public func family(_ value: String) -> String {
        var first = value.trimmingCharacters(in: .whitespaces)
        switch format {
        case .json(_, css: true): first = first.split(separator: ",").first.map(String.init) ?? first
        case .kitty: if let named = first.firstMatch(of: /family\s*=\s*["']?(?<name>[^"']+)/) { first = String(named.output.name) }
        default: break
        }
        first = first.trimmingCharacters(in: .whitespaces)
        if first.count > 1, let q = first.first, "\"'".contains(q), first.last == q { first = String(first.dropFirst().dropLast()) }
        return first
    }

    /// The value that names `family` in this place: quoted in a CSS list.
    public func value(_ family: String) -> String {
        guard case .json(_, css: true) = format else { return family }
        return family.contains("'") ? "\"\(family)\"" : "'\(family)'"
    }
}

/// Why a place's font was not read or changed, in the words its row shows.
public enum FontProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case noConfig(String)
    /// The app reads another of its config places, which Pilot does not edit (FontPlace.others).
    case elsewhere(app: String, path: String)
    /// The config is a link to a file that is not there.
    case brokenLink(String)
    /// Ghostty's config does not load Pilot's include yet.
    case notLoaded
    /// The key is set in a shape Pilot does not edit: twice, Alacritty's font as an inline table or a dotted key. FontEdit
    /// throws it with no app; FontPlaces names the app.
    case shape(String)
    case notJSON
    case badFamily
    case nothingToUndo
    case io(String)

    public var description: String {
        switch self {
        case .noConfig(let app): "No \(app) settings yet: open \(app) once"
        case .elsewhere(let app, let path): "\(app) reads \(path), which Pilot does not edit: set the font there"
        case .brokenLink(let path): "\(path) is a link to a file that is not there: fix the link first"
        case .notLoaded: "Ghostty does not load Pilot's file yet: pick a theme on Look first"
        case .shape(let app): "\(app) sets its font in a way Pilot does not edit; change it in \(app)"
        case .notJSON: "The settings file is not JSON Pilot can read, so it was left alone"
        case .badFamily: "That is not a font name"
        case .nothingToUndo: "Pilot has not changed this font"
        case .io(let why): why
        }
    }
}

/// Each place's file under a home: its font read, changed and undone, only the font's key touched and every other byte
/// kept (a byte-order mark and Windows line ends too). Each write goes to a new file beside the real one, synced, then
/// renamed over it, so a crash leaves the old file or the new one, never half of one, and a link stays a link. The first
/// change keeps a copy of the file (with its mode, as a config may hold a token) and the font it had, so Undo sets that
/// font again without undoing anything else changed since.
public struct FontPlaces: Sendable {
    public let home: URL
    /// Pilot's folder: the earlier fonts and the backups.
    public let support: URL

    public init(home: URL, support: URL) { self.home = home; self.support = support }

    /// The real home and Pilot's folder; in a test run a home inside the run's throwaway folder, so a sandbox host or a test
    /// never reaches Sven's configs.
    public static let standard = FontPlaces(home: PilotFolder.home, support: PilotFolder.support)

    public func file(_ place: FontPlace) -> URL { home.appending(path: place.path) }

    /// Ghostty's own config, which must load Pilot's include (GhosttyFiles.standard's).
    var ghosttyConfig: URL { home.appending(path: ".config/ghostty/config") }

    private var earlierFile: JSONFile<[String: Earlier]> { JSONFile(url: support.appending(path: "font-places.json")) }

    /// The font a place had before Pilot first changed it; nil `value` when the key was not set.
    public struct Earlier: Codable, Equatable, Sendable { public var value: String? }

    /// The value the place's key holds now; nil when unset, or its file is not there.
    public func value(_ place: FontPlace) throws(FontProblem) -> String? {
        guard let text = try read(place) else { return nil }
        return try named(place) { () throws(FontProblem) in try FontEdit.value(text, place.format) }
    }

    /// The family the app uses: its key's, else, for Ghostty, the one its own config names; nil for the app's default.
    public func family(_ place: FontPlace) throws(FontProblem) -> String? {
        if let value = try value(place) { return place.family(value) }
        guard place.format == .ghostty, let text = try? Self.text(ghosttyConfig) else { return nil }
        return try? FontEdit.value(text, .ghostty)
    }

    /// What Undo would set again, by place id: none once there is nothing to undo. One read for a whole page of rows.
    public func earlier() -> [String: Earlier] { (try? earlierFile.load(or: [:])) ?? [:] }
    public func earlier(_ place: FontPlace) -> Earlier? { earlier()[place.id] }

    /// Why a font cannot be set in the place now: Ghostty's needs its config to load Pilot's include, which is Look's to add.
    public func check(_ place: FontPlace) throws(FontProblem) {
        if place.format == .ghostty, !loadsInclude { throw .notLoaded }
    }

    /// Sets `family` as the place's font. Returns whether the file changed.
    @discardableResult
    public func use(_ family: String, in place: FontPlace) throws(FontProblem) -> Bool {
        let family = family.trimmingCharacters(in: .whitespaces)
        guard !family.isEmpty, !family.contains(where: { $0.isNewline || $0 == "\0" }) else { throw .badFamily }
        return try write(place.value(family), in: place, recording: true)
    }

    /// Sets the font the place had before Pilot first changed it, and forgets it. Returns whether the file changed.
    @discardableResult
    public func undo(_ place: FontPlace) throws(FontProblem) -> Bool {
        guard let earlier = earlier(place) else { throw .nothingToUndo }
        let changed = try write(earlier.value, in: place, recording: false)
        try io { var all = try earlierFile.load(or: [:]); all[place.id] = nil; try earlierFile.save(all) }
        return changed
    }

    /// The file's text, a byte-order mark kept: nil when it is not there yet but its folder is and no other config place
    /// of the app is, so the first write makes it.
    private func read(_ place: FontPlace) throws(FontProblem) -> String? {
        let url = file(place), path = url.path(percentEncoded: false), manager = FileManager.default
        let tilde = "~/" + place.path
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil, !manager.fileExists(atPath: path) { throw .brokenLink(tilde) }
        guard manager.fileExists(atPath: path) else {
            if let other = place.others.first(where: { manager.fileExists(atPath: home.appending(path: $0).path(percentEncoded: false)) }) {
                throw .elsewhere(app: place.app, path: "~/" + other)
            }
            guard manager.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)) else { throw .noConfig(place.app) }
            return nil
        }
        return try Self.text(url)
    }

    /// A file's bytes as text, exactly: String(contentsOf:) drops a byte-order mark, so a rewrite would too.
    static func text(_ url: URL) throws(FontProblem) -> String {
        guard let data = try? Data(contentsOf: url) else { throw .io("Could not read \(url.lastPathComponent)") }
        guard let text = String(validating: data, as: UTF8.self) else { throw .io("\(url.lastPathComponent) is not UTF-8 text, so it was left alone") }
        return text
    }

    /// Ghostty's config holds Pilot's block, so the include, and a font in it, is loaded. Read only.
    var loadsInclude: Bool {
        let config = (try? Self.text(ghosttyConfig)) ?? ""
        if case .at = GhosttyConfigBlock.marked.locate(TextLines(config).lines.map { TextLines.split($0).body }) {
            return true
        }
        return false
    }

    private func write(_ value: String?, in place: FontPlace, recording: Bool) throws(FontProblem) -> Bool {
        try check(place)
        let url = file(place)
        let old = try read(place)
        let next = try named(place) { () throws(FontProblem) in try FontEdit.setting(old ?? "", place.format, to: value) }
        guard next != old ?? "" else { return false }
        let real = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: real.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber
        // The backup first: a change it stops leaves no earlier font behind for Undo to set.
        if recording {
            if let old { try backUp(Data(old.utf8), of: url, as: place, mode: mode) }
            try io {
                var all = try earlierFile.load(or: [:])
                if all[place.id] == nil { all[place.id] = Earlier(value: try FontEdit.value(old ?? "", place.format)) }
                try earlierFile.save(all)
            }
        }
        try AtomicFile.write(Data(next.utf8), to: real, mode: mode.map { mode_t($0.uint16Value) } ?? 0o644)
        return true
    }

    /// The file as it was before Pilot first changed it, once per file, with the file's own mode from its first byte. It is
    /// written whole or not at all, so one that is there is complete; a failure stops the change.
    private func backUp(_ data: Data, of url: URL, as place: FontPlace, mode: NSNumber?) throws(FontProblem) {
        let backup = support.appending(path: "font-backups/\(place.id.split(separator: ".")[0])-\(url.lastPathComponent)")
        guard !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        try io { try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true) }
        do { try AtomicFile.write(data, to: backup, mode: mode.map { mode_t($0.uint16Value) } ?? 0o600) }
        catch { throw .io("No backup of \(url.lastPathComponent) could be kept, so it was left alone: \(error)") }
    }

    /// FontEdit's shape problem, with the app named.
    private func named<T>(_ place: FontPlace, _ body: () throws(FontProblem) -> T) throws(FontProblem) -> T {
        do { return try body() } catch {
            if case .shape = error { throw .shape(place.app) }
            throw error
        }
    }

    private func io(_ body: () throws -> Void) throws(FontProblem) {
        do { try body() } catch let problem as FontProblem { throw problem } catch { throw .io(error.localizedDescription) }
    }
}

/// A whole file written so a crash or a full disk never leaves half of it: a new file beside `url` with `mode` from the
/// start, synced to disk, then renamed over `url`. `url` is the real file; a link to it stays as it was.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, mode: mode_t) throws(FontProblem) {
        let path = url.path(percentEncoded: false)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).pilot-\(UUID().uuidString.prefix(8))").path(percentEncoded: false)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw .io("Could not write beside \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        // The umask may have narrowed `mode`: set it exactly before the first byte.
        var written = fchmod(fd, mode) == 0
        if written {
            written = data.withUnsafeBytes { bytes in
                var done = 0
                while done < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
        }
        written = written && fsync(fd) == 0
        // Each failure's own errno, read before the next call can change it.
        var why = written ? "" : String(cString: strerror(errno))
        close(fd)
        if written, rename(temp, path) != 0 { written = false; why = String(cString: strerror(errno)) }
        guard written else {
            unlink(temp)
            throw .io("Could not write \(url.lastPathComponent): \(why)")
        }
    }
}

/// A text's lines split at each "\n", every line keeping its own "\r" (a CRLF line end), so a file with Windows or mixed
/// line ends comes back as it was; a line Pilot adds takes its neighbour's end, and goes before the final line end, so a
/// file without one still has none.
struct TextLines {
    var lines: [String]

    init(_ text: String) {
        // Split on the byte: Swift reads "\r\n" as one character, which "\n" would never match.
        lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    var text: String { lines.joined(separator: "\n") }
    /// Where a line added at the end goes: before the empty last line a final line end leaves.
    var tail: Int { lines.last == "" ? lines.count - 1 : lines.count }

    /// `line` with the CR end of the line at `i`, so an added line matches the file's own ends.
    func ended(_ line: String, like i: Int) -> String { lines.indices.contains(i) && lines[i].hasSuffix("\r") ? line + "\r" : line }

    /// A line without its CR end, and that end.
    static func split(_ line: String) -> (body: String, cr: String) {
        line.hasSuffix("\r") ? (String(line.utf8.dropLast()) ?? line, "\r") : (line, "")
    }

    /// A line as a key is matched: no byte-order mark, CR end or spaces around it.
    static func bare(_ line: String) -> String {
        String(split(line).body.drop { $0 == "\u{FEFF}" }).trimmingCharacters(in: .whitespaces)
    }

    /// Whether a line holds nothing but a CR end.
    static func blank(_ line: String) -> Bool { bare(line).isEmpty }
}

/// The font key in a config's text, read and set with every other byte kept: the parsers find the value's span, and only
/// that span changes.
public enum FontEdit {
    /// The key's value; nil when the text does not set it.
    public static func value(_ text: String, _ format: FontPlace.Format) throws(FontProblem) -> String? {
        switch format {
        case .json(let key, _):
            // A value that is no string (null) reads as unset.
            return try jsonMember(text, key)?.string
        case .ghostty:
            // Ghostty's font-family lines add fallbacks; an empty one clears those before it, so the font is the first after
            // the last empty one.
            let families = TextLines(text).lines.compactMap(ghosttyFamily)
            return families.split(separator: "", omittingEmptySubsequences: false).last?.first
        case .kitty:
            let lines = TextLines(text).lines
            return kittyLine(lines).map { String(TextLines.split(lines[$0]).body.dropFirst(kittyPrefix(lines[$0]).count)).trimmingCharacters(in: .whitespaces) }
        case .alacritty: return try alacritty(TextLines(text).lines).family.flatMap { tomlValue($0.quoted) }
        }
    }

    /// The text with the key set to `value`, or taken out for nil.
    public static func setting(_ text: String, _ format: FontPlace.Format, to value: String?) throws(FontProblem) -> String {
        if case .json(let key, _) = format { return try setJSON(text, key: key, to: value) }
        var text = TextLines(text)
        switch format {
        case .json: break
        case .ghostty:
            text.lines.removeAll { ghosttyFamily($0) != nil }
            // The empty one clears what Ghostty's own config set first, so the pick is the font, not a fallback.
            if let value {
                let at = text.tail
                text.lines.insert(contentsOf: ["font-family = \"\"", "font-family = \(value)"].map { text.ended($0, like: at - 1) }, at: at)
            }
        case .kitty:
            switch (kittyLine(text.lines), value) {
            case (let i?, let value?): text.lines[i] = kittyPrefix(text.lines[i]) + value + TextLines.split(text.lines[i]).cr
            case (let i?, nil): text.lines.remove(at: i)
            case (nil, let value?): text.lines.insert(text.ended("font_family \(value)", like: text.tail - 1), at: text.tail)
            case (nil, nil): break
            }
        case .alacritty:
            let found = try alacritty(text.lines)
            switch (found.table, found.family, value) {
            case (_, let line?, let value?): text.lines[line.index] = line.prefix + tomlString(value) + line.rest
            case (let table, let line?, nil):
                text.lines.remove(at: line.index)
                // A table Pilot added, left empty at the end, goes with the blank line before it.
                if let table, text.lines[(table + 1)..<text.tail].allSatisfy(TextLines.blank) {
                    text.lines.removeSubrange(table..<text.tail)
                    if table > 0, TextLines.blank(text.lines[table - 1]) { text.lines.remove(at: table - 1) }
                }
            case (let table?, nil, let value?): text.lines.insert(text.ended("family = \(tomlString(value))", like: table), at: table + 1)
            case (nil, nil, let value?):
                let at = text.tail
                let blank = at > 0 && !TextLines.blank(text.lines[at - 1]) ? [""] : []
                text.lines.insert(contentsOf: (blank + ["[font.normal]", "family = \(tomlString(value))"]).map { text.ended($0, like: at - 1) }, at: at)
            case (_, nil, nil): break
            }
        }
        return text.text
    }

    // MARK: Ghostty

    /// `font-family = X` (X unquoted, Ghostty strips one pair of quotes).
    private static func ghosttyFamily(_ line: String) -> String? {
        guard let match = TextLines.bare(line).wholeMatch(of: /font-family\s*=\s*(?<value>.*)/) else { return nil }
        let value = String(match.output.value).trimmingCharacters(in: .whitespaces)
        return value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }

    // MARK: kitty

    /// The last `font_family` line, the one kitty uses.
    private static func kittyLine(_ lines: [String]) -> Int? {
        lines.lastIndex { TextLines.bare($0).firstMatch(of: /^font_family\s/) != nil }
    }

    /// The line up to its value: the key and the space after it, as written.
    private static func kittyPrefix(_ line: String) -> String { line.firstMatch(of: /^\W*font_family\s+/).map { String($0.output) } ?? "font_family " }

    // MARK: Alacritty

    /// A `family = "…"` line: what is before the value, the value as written, and what follows it (a comment).
    private struct TOMLFamily { let index: Int, prefix: String, quoted: String, rest: String }

    /// The `[font.normal]` table's line and its `family` line. Any other shape of font.normal (an inline table, a dotted key,
    /// a top-level `font =`, a second table or family) is refused, as writing beside it would break the file.
    private static func alacritty(_ lines: [String]) throws(FontProblem) -> (table: Int?, family: TOMLFamily?) {
        var section = "", table: Int?, family: TOMLFamily?
        for (i, line) in lines.enumerated() {
            let bare = TextLines.bare(line)
            if bare.hasPrefix("[") {
                // `[ font . "normal" ]` is `[font.normal]`; an array of tables is no table of ours.
                section = bare.hasPrefix("[[") ? "[[" : String(bare.dropFirst().prefix { $0 != "]" }.filter { !" \t\"'".contains($0) })
                if section == "font.normal" {
                    guard table == nil else { throw .shape("") }
                    table = i
                }
                continue
            }
            switch section {
            case "": if bare.firstMatch(of: /^["']?font["']?\s*[.=]/) != nil { throw .shape("") }
            case "font": if bare.firstMatch(of: /^["']?normal["']?\s*[.=]/) != nil { throw .shape("") }
            case "font.normal":
                guard bare.firstMatch(of: /^["']?family["']?\s*=/) != nil else { continue }
                // Matched without its CR end, which goes back after the rest; a multi-line string ("""…""") is refused.
                let (body, cr) = TextLines.split(line)
                guard family == nil, let match = body.wholeMatch(of: /(?<prefix>\W*family\s*=\s*)(?<quoted>"(?:[^"\\]|\\.)*"|'[^']*')(?<rest>.*)/),
                      tomlValue(String(match.output.quoted)) != nil, !match.output.rest.hasPrefix("\""), !match.output.rest.hasPrefix("'") else { throw .shape("") }
                family = TOMLFamily(index: i, prefix: String(match.output.prefix), quoted: String(match.output.quoted), rest: String(match.output.rest) + cr)
            default: continue
            }
        }
        return (table, family)
    }

    /// A TOML string as written: "basic" with \" and \\, or 'literal'.
    private static func tomlValue(_ quoted: String) -> String? {
        if let m = quoted.wholeMatch(of: /'(?<s>[^']*)'/) { return String(m.output.s) }
        guard let m = quoted.wholeMatch(of: /"(?<s>(?:[^"\\]|\\.)*)"/) else { return nil }
        return String(m.output.s).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: JSON

    /// The key's member; shape when it is there twice, as an app reads the last and a write to one would not take.
    private static func jsonMember(_ text: String, _ key: String) throws(FontProblem) -> JSONMembers.Member? {
        let found = try JSONMembers(text)?.members.filter { $0.key == key } ?? []
        guard found.count < 2 else { throw .shape("") }
        return found.first
    }

    private static func setJSON(_ text: String, key: String, to value: String?) throws(FontProblem) -> String {
        let bytes = Array(text.utf8)
        func spliced(_ range: Range<Int>, _ with: String) -> String {
            String(decoding: bytes[..<range.lowerBound] + Array(with.utf8) + bytes[range.upperBound...], as: UTF8.self)
        }
        let end = text.contains("\r\n") ? "\r\n" : "\n"
        let literal = value.map(jsonString)
        _ = try jsonMember(text, key)
        guard let object = try JSONMembers(text) else {
            // No object yet: one holding only the key, after any comments the file has.
            guard let literal else { return text }
            let lead = text.allSatisfy(\.isWhitespace) ? "" : text + (text.hasSuffix("\n") ? "" : end)
            return lead + "{\(end)  \(jsonString(key)): \(literal)\(end)}\(end)"
        }
        if let i = object.members.firstIndex(where: { $0.key == key }) {
            let member = object.members[i]
            guard let literal else {
                // Out with its comma: up to the next key, or back to the comma before it when it is the last.
                if let next = object.members.indices.contains(i + 1) ? object.members[i + 1] : nil { return spliced(member.start..<next.start, "") }
                if i > 0 { return spliced(object.members[i - 1].end..<member.end, "") }
                // The only key: an object of spaces again, as Pilot found it.
                let rest = bytes[member.end..<object.close]
                return spliced(object.open + 1..<(rest.allSatisfy { JSONMembers.Scanner.isSpace($0) || $0 == UInt8(ascii: ",") } ? object.close : member.end), "")
            }
            return spliced(member.value, literal)
        }
        guard let literal else { return text }
        let line = "\(jsonString(key)): \(literal)"
        guard let first = object.members.first else { return spliced(object.open + 1..<object.open + 1, "\(end)  \(line)\(end)") }
        // Before the first key, on a line of its own at that key's indent.
        let indent = bytes[..<first.start].reversed().prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        let lineStart = first.start - indent.count
        let ownLine = lineStart > 0 && bytes[lineStart - 1] == UInt8(ascii: "\n")
        return spliced(first.start..<first.start, line + "," + (ownLine ? end + String(decoding: indent.reversed(), as: UTF8.self) : " "))
    }

    private static func jsonString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}

/// A JSON object's top-level members as byte spans, with `//` and `/* */` comments and trailing commas allowed (VS Code's
/// and Zed's settings): nothing is decoded but the keys and the string values asked for, so writing a span keeps the rest.
struct JSONMembers {
    struct Member {
        let key: String
        /// From the key's quote to the value's end, and the value alone; `end` is past the value.
        let start: Int, value: Range<Int>
        var end: Int { value.upperBound }
        let string: String?
    }

    /// The object's braces.
    let open: Int, close: Int
    let members: [Member]

    func member(_ key: String) -> Member? { members.last { $0.key == key } }

    /// Nil for a text of only spaces and comments; notJSON for anything but one object.
    init?(_ text: String) throws(FontProblem) {
        var scanner = Scanner(bytes: Array(text.utf8))
        scanner.skip()
        if scanner.at == scanner.bytes.count { return nil }
        guard scanner.peek == UInt8(ascii: "{") else { throw .notJSON }
        open = scanner.at
        scanner.at += 1
        var members: [Member] = []
        while true {
            scanner.skip()
            guard let c = scanner.peek else { throw .notJSON }
            if c == UInt8(ascii: "}") { close = scanner.at; break }
            let start = scanner.at
            let keySpan = try scanner.string()
            scanner.skip()
            guard scanner.peek == UInt8(ascii: ":") else { throw .notJSON }
            scanner.at += 1
            scanner.skip()
            let valueStart = scanner.at
            let isString = scanner.peek == UInt8(ascii: "\"")
            try scanner.value()
            let value = valueStart..<scanner.at
            members.append(Member(key: try scanner.decoded(keySpan), start: start, value: value,
                                  string: isString ? try scanner.decoded(value) : nil))
            scanner.skip()
            if scanner.peek == UInt8(ascii: ",") { scanner.at += 1 }
            else if scanner.peek != UInt8(ascii: "}") { throw .notJSON }
        }
        self.members = members
    }

    struct Scanner {
        let bytes: [UInt8]
        var at = 0
        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        /// Spaces, newlines and comments.
        mutating func skip() {
            while let c = peek {
                if Self.isSpace(c) || (at == 0 && c == 0xEF) {
                    at += c == 0xEF ? 3 : 1
                } else if c == UInt8(ascii: "/"), at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "/") {
                    while let c = peek, c != 0x0A { _ = c; at += 1 }
                } else if c == UInt8(ascii: "/"), at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "*") {
                    at += 2
                    while at + 1 < bytes.count, !(bytes[at] == UInt8(ascii: "*") && bytes[at + 1] == UInt8(ascii: "/")) { at += 1 }
                    at = min(at + 2, bytes.count)
                } else { return }
            }
        }

        mutating func string() throws(FontProblem) -> Range<Int> {
            let start = at
            guard peek == UInt8(ascii: "\"") else { throw .notJSON }
            at += 1
            while let c = peek {
                at += c == UInt8(ascii: "\\") ? 2 : 1
                if c == UInt8(ascii: "\"") { return start..<at }
            }
            throw .notJSON
        }

        /// Any value: a string, an object or array (their strings and comments skipped), or a bare word or number.
        mutating func value() throws(FontProblem) {
            guard let c = peek else { throw .notJSON }
            if c == UInt8(ascii: "\"") { _ = try string(); return }
            if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                var depth = 0
                while let c = peek {
                    if c == UInt8(ascii: "\"") { _ = try string(); continue }
                    if c == UInt8(ascii: "/") { let before = at; skip(); if at != before { continue } }
                    at += 1
                    if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                    if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return } }
                }
                throw .notJSON
            }
            let start = at
            while let c = peek, !(c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "/") || Self.isSpace(c)) { at += 1 }
            if at == start { throw .notJSON }
        }

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        /// A string literal's text: its bytes as they are when it has no escape, else JSON's own decoding.
        func decoded(_ span: Range<Int>) throws(FontProblem) -> String {
            let inner = bytes[span.lowerBound + 1..<span.upperBound - 1]
            if !inner.contains(UInt8(ascii: "\\")) { return String(decoding: inner, as: UTF8.self) }
            guard let s = try? JSONDecoder().decode(String.self, from: Data(bytes[span])) else { throw .notJSON }
            return s
        }
    }
}
