import Foundation

/// Full-document JSONC grammar with byte spans. No personal document is decoded and reserialized.
/// The selected-value seam can later host membership edits without granting a parent array's ownership.
public struct ThemeJSONC {
    public struct Member {
        let key: String
        let keyStart: Int
        let value: Node
        let comma: Int?
    }
    public indirect enum Node {
        case object(Range<Int>, [Member])
        case array(Range<Int>, [Member])
        case scalar(Range<Int>)
        var span: Range<Int> {
            switch self { case .object(let r, _), .array(let r, _), .scalar(let r): return r }
        }
        var members: [Member]? { if case .object(_, let m) = self { return m }; return nil }
    }
    let bytes: Data
    let root: Node
    let comments: [Range<Int>]

    public init(_ bytes: Data) throws {
        guard String(data: bytes, encoding: .utf8) != nil else { throw ThemeFailure("JSONC is not UTF-8") }
        var scanner = Scanner(bytes: Array(bytes))
        if scanner.bytes.starts(with: [239, 187, 191]) { scanner.i = 3 }
        let root = try scanner.value(depth: 0)
        try scanner.space()
        guard scanner.i == bytes.count, root.members != nil else { throw ThemeFailure("invalid full JSONC object") }
        self.bytes = bytes; self.root = root; self.comments = scanner.comments
    }

    func node(_ path: [String]) throws -> Node? {
        var node = root
        for key in path {
            guard let members = node.members else { throw ThemeFailure("unsupported JSONC selector parent") }
            let matches = members.filter { $0.key == key }
            guard matches.count <= 1 else { throw ThemeFailure("ambiguous duplicate owned JSONC key: \(key)") }
            guard let match = matches.first else { return nil }
            node = match.value
        }
        return node
    }
    public func owned(_ path: [String]) throws -> Data? { try node(path).map { bytes.subdata(in: $0.span) } }
    func string(_ path: [String]) throws -> String? {
        guard let data = try owned(path) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    public func replacing(_ path: [String], with value: Data?) throws -> Data {
        guard !path.isEmpty else { throw ThemeFailure("empty JSONC selector") }
        var output = bytes
        if let node = try node(path) {
            if let value { output.replaceSubrange(node.span, with: value) }
            else {
                guard let parent = try self.node(Array(path.dropLast())), let members = parent.members,
                      let index = members.firstIndex(where: { $0.key == path.last }) else { throw ThemeFailure("missing JSONC parent") }
                let member = members[index]
                // Key/colon/value trivia lies inside this deletion too, not just array interiors.
                guard !comments.contains(where: { $0.overlaps(member.keyStart..<node.span.upperBound) }) else {
                    throw ThemeFailure("JSONC property removal would delete comments; retained")
                }
                // Delete only syntax owned by this member, keeping comments and all other member bytes.
                if let comma = member.comma {
                    output.removeSubrange(comma..<(comma + 1))
                } else if index > 0, let comma = members[index - 1].comma {
                    output.removeSubrange(comma..<(comma + 1))
                    let shift = comma < member.keyStart ? 1 : 0
                    output.removeSubrange((member.keyStart - shift)..<(node.span.upperBound - shift))
                    _ = try ThemeJSONC(output)
                    return output
                }
                output.removeSubrange(member.keyStart..<node.span.upperBound)
            }
        } else if let value {
            guard let parent = try node(Array(path.dropLast())), let members = parent.members else { throw ThemeFailure("missing JSONC selector container") }
            let key = try ThemeDigest.encoded(path.last!)
            let prefix = members.isEmpty || members.last?.comma != nil ? Data() : Data(",".utf8)
            let insertion = prefix + key + Data(":".utf8) + value + (members.last?.comma != nil ? Data(",".utf8) : Data())
            // Before closing brace, after any trailing comment/newline. Existing bytes never move relative to each other.
            output.insert(contentsOf: insertion, at: parent.span.upperBound - 1)
        }
        let check = try ThemeJSONC(output)
        guard try check.owned(path) == value else { throw ThemeFailure("JSONC replacement not verified") }
        return output
    }

    // Membership owns one decoded string, never the array. The selector remembers whether
    // Pilot created the container; remove it only while no later members/comments remain.
    func membership(_ path: [String], element: String) throws -> Node? {
        guard let array = try node(path) else { return nil }
        guard case .array(_, let members) = array else { throw ThemeFailure("snippet membership container must be an array") }
        var matches: [Node] = []
        for member in members {
            guard let string = try? JSONDecoder().decode(String.self, from: bytes.subdata(in: member.value.span)) else { throw ThemeFailure("snippet membership must contain strings") }
            if string == element { matches.append(member.value) }
        }
        guard matches.count <= 1 else { throw ThemeFailure("duplicate owned snippet membership") }
        return matches.first
    }

    func replacingMembership(_ path: [String], element: String, with value: Data?, removeEmptyContainer: Bool) throws -> Data {
        let owned = try membership(path, element: element)
        if let value {
            guard (try? JSONDecoder().decode(String.self, from: value)) == element else { throw ThemeFailure("invalid snippet membership value") }
        }
        guard let array = try node(path) else {
            return try value.map { try replacing(path, with: Data("[".utf8) + $0 + Data("]".utf8)) } ?? bytes
        }
        guard case .array(let span, let members) = array else { throw ThemeFailure("invalid membership container") }
        var output = bytes
        if let owned, let index = members.firstIndex(where: { $0.value.span == owned.span }) {
            if let value { output.replaceSubrange(owned.span, with: value) }
            else {
                let member = members[index]
                if let comma = member.comma { output.removeSubrange(comma..<(comma + 1)); output.removeSubrange(owned.span) }
                else if index > 0, let comma = members[index - 1].comma {
                    output.removeSubrange(owned.span); output.removeSubrange(comma..<(comma + 1))
                } else { output.removeSubrange(owned.span) }
            }
        } else if let value {
            let prefix = members.isEmpty || members.last?.comma != nil ? Data() : Data(",".utf8)
            output.insert(contentsOf: prefix + value + (members.last?.comma != nil ? Data(",".utf8) : Data()), at: span.upperBound - 1)
        }
        var check = try ThemeJSONC(output)
        if value == nil, removeEmptyContainer, let node = try check.node(path),
           case .array(let range, let remaining) = node, remaining.isEmpty,
           output.subdata(in: (range.lowerBound + 1)..<(range.upperBound - 1)).allSatisfy({ [9, 10, 13, 32].contains($0) }) {
            output = try check.replacing(path, with: nil); check = try ThemeJSONC(output)
        }
        guard try check.membership(path, element: element).map({ output.subdata(in: $0.span) }) == value else { throw ThemeFailure("snippet membership replacement not verified") }
        return output
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        var comments: [Range<Int>] = []
        mutating func space() throws {
            while i < bytes.count {
                if [9, 10, 13, 32].contains(bytes[i]) { i += 1; continue }
                if bytes[i] == 47, i + 1 < bytes.count {
                    let start = i
                    if bytes[i + 1] == 47 {
                        i += 2; while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                        comments.append(start..<i); continue
                    }
                    if bytes[i + 1] == 42 {
                        i += 2
                        while i + 1 < bytes.count && !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                        guard i + 1 < bytes.count else { throw ThemeFailure("unterminated JSONC comment") }
                        i += 2; comments.append(start..<i); continue
                    }
                }
                break
            }
        }
        mutating func value(depth: Int) throws -> Node {
            guard depth < 128 else { throw ThemeFailure("JSONC nesting limit") }
            try space(); let start = i
            guard i < bytes.count else { throw ThemeFailure("missing JSONC value") }
            if bytes[i] == 123 || bytes[i] == 91 {
                let object = bytes[i] == 123, close: UInt8 = object ? 125 : 93
                i += 1; try space()
                var members: [Member] = []
                if i < bytes.count && bytes[i] == close { i += 1; return object ? .object(start..<i, []) : .array(start..<i, []) }
                while true {
                    try space(); let keyStart = i
                    var key = ""
                    if object {
                        let range = try string()
                        key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
                        try space(); guard i < bytes.count && bytes[i] == 58 else { throw ThemeFailure("JSONC missing colon") }; i += 1
                    }
                    let child = try value(depth: depth + 1)
                    try space()
                    let comma = i < bytes.count && bytes[i] == 44 ? i : nil
                    members.append(Member(key: key, keyStart: keyStart, value: child, comma: comma))
                    if comma != nil { i += 1; try space() }
                    guard i < bytes.count else { throw ThemeFailure("unclosed JSONC container") }
                    if bytes[i] == close { i += 1; break }
                    guard comma != nil else { throw ThemeFailure("JSONC missing comma") }
                }
                return object ? .object(start..<i, members) : .array(start..<i, members)
            }
            if bytes[i] == 34 { return .scalar(try string()) }
            while i < bytes.count && ![9, 10, 13, 32, 44, 93, 125, 47].contains(bytes[i]) { i += 1 }
            guard i > start else { throw ThemeFailure("invalid JSONC token") }
            let token = Data(bytes[start..<i])
            // JSONDecoder rejects NaN, incomplete numbers, bare keys and trailing token garbage.
            guard (try? JSONDecoder().decode(JSONValue.self, from: token)) != nil else { throw ThemeFailure("invalid JSONC scalar") }
            return .scalar(start..<i)
        }
        mutating func string() throws -> Range<Int> {
            let start = i
            guard i < bytes.count && bytes[i] == 34 else { throw ThemeFailure("JSONC key must be a string") }
            i += 1
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if c == 92 { guard i < bytes.count else { break }; i += 1 }
                else if c == 34 {
                    let range = start..<i
                    guard (try? JSONDecoder().decode(String.self, from: Data(bytes[range]))) != nil else { throw ThemeFailure("invalid JSONC string") }
                    return range
                }
            }
            throw ThemeFailure("unterminated JSONC string")
        }
    }
}

/// Palette-only Zed adapter. Local settings and generated destination authority never comes from a pack.
public enum ZedThemeAdapter {
    public static func name(_ pack: ThemePack) -> String { "Pilot \(pack.id) \(pack.dark ? "Dark" : "Light")" }
    /// Style keys Zed draws as text; these and every syntax colour read at 4.5:1 on its three backgrounds.
    private static let textKeys: Set<String> = ["text", "text.muted", "text.accent", "editor.foreground", "editor.line_number", "editor.active_line_number",
                                               "terminal.foreground", "error", "warning", "success", "info", "hint"]
    private static let grounds = ["background", "dark_background", "lighter_background"]
    static func readable(_ colour: String, _ p: [String: String]) -> String { Contrast.readable(colour, on: grounds.compactMap { p[$0] }, toward: p["foreground"]!) }

    public static func asset(_ pack: ThemePack) throws -> Data {
        _ = try ThemePack.decode(ThemeDigest.encoded(pack))
        let p = pack.palette
        let roles = ["background": "background", "surface.background": "dark_background", "elevated_surface.background": "lighter_background",
                     "text": "foreground", "text.muted": "muted", "text.accent": "accent", "border": "muted", "border.focused": "accent",
                     "editor.background": "background", "editor.foreground": "foreground", "editor.gutter.background": "background",
                     "editor.active_line.background": "dark_background", "editor.line_number": "muted", "editor.active_line_number": "foreground",
                     "status_bar.background": "dark_background", "title_bar.background": "dark_background", "toolbar.background": "dark_background",
                     "tab_bar.background": "dark_background", "tab.active_background": "background", "tab.inactive_background": "dark_background",
                     "panel.background": "dark_background", "terminal.background": "background", "terminal.foreground": "foreground",
                     "error": "red", "warning": "yellow", "success": "green", "info": "blue", "hint": "muted"]
        var style: [String: JSONValue] = [:]
        for (key, role) in roles { style[key] = .string(textKeys.contains(key) ? readable(p[role]!, p) : p[role]!) }
        let ansi = ["black": "dark_background", "red": "red", "green": "green", "yellow": "yellow", "blue": "blue", "magenta": "magenta", "cyan": "cyan", "white": "foreground"]
        for (key, role) in ansi {
            style["terminal.ansi.\(key)"] = .string(p[role]!)
            style["terminal.ansi.bright_\(key)"] = .string(p["bright_" + key] ?? p[key == "black" ? "muted" : "bright_foreground"]!)
        }
        let syntax = ["comment": "muted", "keyword": "magenta", "string": "green", "number": "yellow", "boolean": "yellow", "function": "blue", "type": "cyan", "variable": "foreground", "operator": "accent", "punctuation": "dark_foreground", "constant": "yellow", "attribute": "cyan"]
        style["syntax"] = .object(syntax.mapValues { .object(["color": .string(readable(p[$0]!, p))]) })
        style["players"] = .array([.object(["cursor": .string(p["accent"]!), "background": .string(p["accent"]!), "selection": .string(p["selection"]!)])])
        return try ThemeDigest.encoded(JSONValue.object(["$schema": .string("https://zed.dev/schema/themes/v0.2.0.json"), "name": .string("Pilot \(pack.id)"), "author": .string("Pilot"),
            "themes": .array([.object(["name": .string(name(pack)), "appearance": .string(pack.dark ? "dark" : "light"), "style": .object(style)])])]))
    }

    /// `absentFollows`: a detected Zed with no theme chosen gets one, and Restore takes it back out.
    /// Where the theme's name goes in settings.json. A dynamic selection takes it in both its light and dark slots, so the
    /// theme shows whichever mode macOS is in; Restore puts each slot back on its own.
    public static func selectors(_ pack: ThemePack, settings: Data?, absentFollows: Bool = false) throws -> ([ThemeSelector], [String]) {
        guard let settings else { throw ThemeFailure("Zed settings missing; choose an existing explicit settings file; installation unknown") }
        let document = try ThemeJSONC(settings)
        guard let node = try document.node(["theme"]) else {
            if absentFollows { return ([.jsonValue(path: ["theme"])], ["Zed had no theme chosen; Pilot sets one and Restore takes it back out"]) }
            throw ThemeFailure("unsupported absent/inherited Zed theme selection; select an explicit static or complete dynamic theme first")
        }
        var warnings = ["Zed should update by itself. If it doesn't, reopen it", "Zed: fonts, icons and workspace settings stay. A workspace or profile can still override the theme"]
        if try document.node(["theme_overrides"]) != nil || document.node(["experimental.theme_overrides"]) != nil {
            warnings.append("Zed: your theme_overrides stay and can change some colours")
        }
        if try document.node(["profiles"]) != nil { warnings.append("Zed: a profile can still choose a different theme") }
        if node.members != nil {
            guard try document.string(["theme", "light"])?.isEmpty == false,
                  try document.string(["theme", "dark"])?.isEmpty == false else { throw ThemeFailure("unsupported incomplete dynamic Zed selection; opposite appearance cannot be synthesized") }
            if try document.owned(["theme", "mode"]) != nil {
                guard let mode = try document.string(["theme", "mode"]), ["system", "light", "dark"].contains(mode) else { throw ThemeFailure("unsupported Zed theme mode") }
            }
            warnings.append("Zed stays automatic, with the theme as both its light and its dark theme, so it shows in either mode")
            return ([.jsonValue(path: ["theme", "light"]), .jsonValue(path: ["theme", "dark"])], warnings)
        }
        guard try document.string(["theme"])?.isEmpty == false else { throw ThemeFailure("unsupported Zed theme selection") }
        return ([.jsonValue(path: ["theme"])], warnings)
    }
}
