import Foundation

/// A script command (card agent-bo-95423029, audit gap 3, after Raycast's Script Commands): an executable file in Pilot's
/// Scripts folder, listed in Hyper+Space and bindable as `scripts.run:<file name>`. Its Raycast-style header comments
/// (`# @raycast.title …`, after `#`, `//` or `--`) name its title, an emoji icon and how it runs; a file without them
/// is titled from its name and shows its last output line. It runs through the drive shell route. Its arguments
/// (`@raycast.argument1` to 3, card agent-bo-95423048) are typed after its title in Hyper+Space and reach it as $1 $2 $3.
public struct ScriptCommand: Equatable, Sendable {
    /// Raycast's silent (the last line in a HUD when one was printed); its compact and inline as a HUD line, "<title> ran"
    /// when nothing was printed; its fullOutput in a visible terminal.
    public enum Mode: Equatable, Sendable { case silent, hud, terminal }

    /// One `@raycast.argument<n>` line: a JSON object with its type, placeholder, and optional and percentEncoded flags.
    public struct Argument: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case text, password, dropdown([Choice]) }
        public struct Choice: Equatable, Sendable, Decodable {
            public let title: String, value: String
            public init(title: String, value: String) { self.title = title; self.value = value }
        }

        public let kind: Kind, placeholder: String, optional: Bool, percentEncoded: Bool

        private struct Line: Decodable {
            let type: String, placeholder: String?, optional: Bool?, percentEncoded: Bool?, secure: Bool?, data: [Choice]?
        }

        /// The argument a header line's JSON names; nil when it does not decode, its type is unknown or a dropdown has no
        /// choices.
        init?(json: String) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(json.utf8)) else { return nil }
            switch line.type {
            case "text": kind = line.secure == true ? .password : .text
            case "password": kind = .password
            case "dropdown":
                guard let data = line.data, !data.isEmpty else { return nil }
                kind = .dropdown(data)
            default: return nil
            }
            placeholder = line.placeholder ?? ""
            optional = line.optional ?? false
            percentEncoded = line.percentEncoded ?? false
        }

        /// What `word` passes: a dropdown the value of the choice it names by title or value, case ignored (nil when
        /// none), percent-encoded when asked.
        func value(_ word: String) -> String? {
            var value = word
            if case .dropdown(let choices) = kind, !word.isEmpty {
                guard let choice = choices.first(where: {
                    $0.title.caseInsensitiveCompare(word) == .orderedSame || $0.value.caseInsensitiveCompare(word) == .orderedSame
                }) else { return nil }
                value = choice.value
            }
            return percentEncoded ? value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value : value
        }

        /// What the answer says it takes while unfilled: a dropdown its choices, else its placeholder.
        var wanted: String {
            guard case .dropdown(let choices) = kind else { return "next: \(placeholder)" }
            let titles = choices.map(\.title)
            return "\(placeholder): " + (titles.count > 1 ? titles.dropLast().joined(separator: ", ") + " or " + titles.last! : titles[0])
        }

        /// RFC 3986's unreserved characters, the strictest encoding (encodeURIComponent also keeps !'()*).
        private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }

    public static let prefix = "scripts.run:"
    /// ~/Library/Application Support/Pilot/Scripts
    public static let folder = PilotFolder.support.appending(path: "Scripts")
    /// The header is read from the file's start only.
    static let headerBytes = 4096

    public let file: String, title: String, icon: String?, mode: Mode
    /// Its arguments in order, at most three; reading stops at the first missing or unreadable one.
    public let arguments: [Argument]

    public init(file: String, header: String) {
        var fields: [String: String] = [:]
        for line in header.split(whereSeparator: \.isNewline) {
            if let m = line.wholeMatch(of: /\s*(?:#|\/\/|--)\s*@raycast\.(\w+)\s+(.+?)\s*/) { fields[String(m.1)] = String(m.2) }
        }
        self.file = file
        title = fields["title"] ?? Self.title(file: file)
        icon = fields["icon"].flatMap { Self.isEmoji($0) ? $0 : nil }
        mode = switch fields["mode"] { case "silent": .silent; case "fullOutput": .terminal; default: .hud }
        arguments = Array((1...3).lazy.map { fields["argument\($0)"].flatMap(Argument.init(json:)) }.prefix { $0 != nil }.compactMap { $0 })
    }

    /// A required argument: Return on its row, or a bind, asks for the words first.
    public var needsArguments: Bool { arguments.contains { !$0.optional } }
    /// A password argument: Pilot does not ask for one yet, since the search would show it as typed.
    public var takesPassword: Bool { arguments.contains { $0.kind == .password } }

    public var actionID: String { Self.prefix + file }

    /// The run with these values (the root's answer): the file, a slash no file name holds, then the values as JSON.
    public func actionID(arguments values: [String]) -> String {
        actionID + "/" + String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// The file a `scripts.run:` id names; nil for any other id.
    public static func file(inAction id: String) -> String? {
        guard id.hasPrefix(prefix), id.count > prefix.count else { return nil }
        let rest = id.dropFirst(prefix.count)
        return String(rest[..<(rest.firstIndex(of: "/") ?? rest.endIndex)])
    }

    /// The values a `scripts.run:` id carries; nil when it carries none (a bind, the plain row).
    public static func arguments(inAction id: String) -> [String]? {
        guard file(inAction: id) != nil, let slash = id.firstIndex(of: "/") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(id[id.index(after: slash)...].utf8))
    }

    /// The line the shell runs: the path and each value single-quoted, so nothing typed runs as a command.
    public static func line(path: String, arguments: [String]) -> String {
        ([path] + arguments).map(VisibleRun.quoted).joined(separator: " ")
    }

    /// `text` split into at most `count` words, the last taking the rest; a double-quoted phrase stays one word, quotes
    /// dropped.
    public static func words(_ text: String, count: Int) -> [String] {
        var rest = Substring(text), words: [String] = []
        while words.count < count {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { break }
            if words.count == count - 1 {
                let last = String(rest).trimmingCharacters(in: .whitespaces)
                words.append(last.count > 1 && last.hasPrefix("\"") && last.hasSuffix("\"") ? String(last.dropFirst().dropLast()) : last)
                break
            }
            if rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") {
                words.append(String(rest[rest.index(after: rest.startIndex)..<close]))
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
                words.append(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        return words
    }

    /// The values the words typed after the title pass, one per argument, an optional one left out as ""; nil when a
    /// required one is missing or a dropdown does not offer the word.
    public func values(for typed: String) -> [String]? {
        let filled = fill(Self.words(typed, count: arguments.count))
        return filled.unfilled == nil ? filled.values : nil
    }

    /// Whether `values` (a run's, from its id) leave an argument unfilled, so the run asks for the words instead.
    /// The values are already mapped and encoded, so only presence counts (Moody EcNC-D0gD9g).
    public func lacksArguments(_ values: [String]) -> Bool {
        arguments.indices.contains { !arguments[$0].optional && ($0 >= values.count || values[$0].isEmpty) }
    }

    /// The words' values in order, up to the first argument they leave unfilled: a required one with no word, or a
    /// dropdown's word it does not offer.
    private func fill(_ words: [String]) -> (values: [String], unfilled: Argument?) {
        var values: [String] = []
        for (i, argument) in arguments.enumerated() {
            let word = i < words.count ? words[i] : ""
            guard !word.isEmpty || argument.optional, let value = argument.value(word) else { return (values, argument) }
            values.append(value)
        }
        return (values, nil)
    }

    /// The root's answer to a script's title, a space and words (`flights malta rome`): its run with those values, first
    /// in the menu. While a required word is missing the answer says what it takes and Return types a space instead. None
    /// for a word a dropdown does not offer (Moody EcNC-D0gD9g) or a script that takes a password.
    public static func answers(for query: String, in scripts: [ScriptCommand]) -> [MenuEntry] {
        for script in scripts where !script.arguments.isEmpty && !script.takesPassword {
            let head = script.title + " "
            guard query.range(of: head, options: [.anchored, .caseInsensitive]) != nil else { continue }
            let typed = String(query.dropFirst(head.count))
            let words = words(typed, count: script.arguments.count)
            guard !words.isEmpty else { continue }
            let filled = script.fill(words)
            guard let unfilled = filled.unfilled else {
                let detail = zip(script.arguments, words).map { "\($0.placeholder) \($1)" }.joined(separator: " · ")
                return [MenuEntry(title: "Run \(script.title)", target: .action(script.actionID(arguments: filled.values)), detail: detail,
                                  isAnswer: true, icon: script.menuIcon)]
            }
            // A word was typed where the unfilled argument is: a dropdown that does not offer it.
            if filled.values.count < words.count && !words[filled.values.count].isEmpty { return [] }
            return [MenuEntry(title: "Run \(script.title)", target: .action(script.actionID), detail: unfilled.wanted,
                              isAnswer: true, icon: script.menuIcon, fills: query.hasSuffix(" ") ? query : query + " ")]
        }
        return []
    }

    /// "restart-dock_now.sh" is "Restart dock now"; a name that is all extension stays as it is.
    public static func title(file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        let words = (stem.isEmpty ? file : stem).replacing(/[-_]+/, with: " ").trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// One emoji, as Raycast's icon field holds it besides a path or a URL.
    static func isEmoji(_ s: String) -> Bool {
        s.count == 1 && s.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }

    /// The scripts in `folder`, by title: its executable regular files, hidden ones left out; none when it is missing.
    public static func find(in folder: URL = folder) -> [ScriptCommand] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { named($0, in: folder) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The script `file` names in `folder`, its header read again; nil when it is not an executable regular file there.
    public static func named(_ file: String, in folder: URL = folder) -> ScriptCommand? {
        guard !file.hasPrefix("."), !file.contains("/") else { return nil }
        let path = folder.appending(path: file).path
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        // fileExists and isExecutableFile follow a symlink, so a linked script counts.
        guard fm.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
              fm.isExecutableFile(atPath: path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headerBytes)) ?? Data()
        return ScriptCommand(file: file, header: String(decoding: head, as: UTF8.self))
    }

    /// What the HUD shows after a run: the last line printed, trimmed, at most 120 characters; "<title> ran" when none.
    public static func hudLine(_ output: String, title: String) -> String { lastLine(output) ?? "\(title) ran" }

    /// The last line printed, trimmed, at most 120 characters; nil when nothing was.
    public static func lastLine(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).reversed().lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            .map { String($0.prefix(120)) }
    }

    /// The row's icon: its emoji, else a terminal.
    public var menuIcon: MenuIcon { .command(emoji: icon) }

    /// What Return on a script's row types into the search instead of running it (card agent-bo-95423048): its title
    /// and a space while it needs an argument, so the words go after it; by action id, for MenuEntries.build.
    public static func fills(_ scripts: [ScriptCommand]) -> [String: String] {
        Dictionary(scripts.filter { $0.needsArguments && !$0.takesPassword }.map { ($0.actionID, "\($0.title) ") }) { first, _ in first }
    }

    /// What the menu lists (card agent-bo-95423029): the Binds screen's actions with every script among them, a bound
    /// script's info replaced by its own so it wears its icon; MenuEntries.build places each as it places any action.
    public static func actions(_ actions: [BindsPage.ActionInfo], with scripts: [ScriptCommand]) -> [BindsPage.ActionInfo] {
        BindsPage.adding(scripts.map { BindsPage.ActionInfo(id: $0.actionID, label: $0.title, module: Module.drive.rawValue, icon: $0.menuIcon) },
                         to: actions)
    }
}

