import Foundation

/// Local authority, supplied explicitly by composition, separate from portable manifests.
public struct ThemeBinding: Codable, Equatable, Sendable {
    public let root, config, generated: String
    public init(root: String, config: String, generated: String) { self.root = root; self.config = config; self.generated = generated }
}

/// Future codecs implement lossless selected-key / membership edits here, rather than owning a parent object/array.
public enum ThemeSelector: Codable, Equatable, Sendable {
    case file
    case jsonValue(path: [String])
    case jsonMembership(path: [String], element: String, removeEmptyContainer: Bool)
    case block(begin: String, end: String, prefix: Int)
    /// A marked block right after one exact line, for a format that cannot take it at the end. Owns the newline before it.
    case blockAfter(anchor: String, begin: String, end: String)

    public func overlaps(_ other: ThemeSelector) -> Bool {
        if case .file = self { return true }; if case .file = other { return true }
        switch (self, other) {
        case (.jsonValue(let a), .jsonValue(let b)): return a.starts(with: b) || b.starts(with: a)
        case (.jsonMembership(let a, let x, _), .jsonMembership(let b, let y, _)): return a == b && x == y || a != b && (a.starts(with: b) || b.starts(with: a))
        case (.jsonValue(let a), .jsonMembership(let b, _, _)), (.jsonMembership(let b, _, _), .jsonValue(let a)): return a.starts(with: b) || b.starts(with: a)
        default: return true
        }
    }
}

public struct ThemeMutation: Codable, Equatable, Sendable {
    public var target: ThemeSnapshot
    public let selector: ThemeSelector
    public let before, after: Data?
    public let replacement: Data?
    public let release: Bool?
    public let bindingID: String?
    public init(target: ThemeSnapshot, selector: ThemeSelector, before: Data?, after: Data?, replacement: Data?, release: Bool? = nil, bindingID: String? = nil) {
        self.target = target; self.selector = selector; self.before = before; self.after = after; self.replacement = replacement; self.release = release
        self.bindingID = bindingID
    }
}

/// Immutable input observations, retained in-process under an opaque ID; never accepted back from a caller as authority.
public struct ThemePlan: Sendable {
    public let id: String
    public let packID: String?
    public let revision: String?
    public let binding: ThemeBinding
    public let zed: ThemeBinding?
    public let zedOptOut: Bool
    public let obsidian: [ThemeBinding]
    public let obsidianOptOut: Bool
    public var observations: [ThemeSnapshot]
    public let style: String
    public let ledger: ThemeSnapshot
    public let protectedLegacy: ThemeSnapshot?
    public var mutations: [ThemeMutation]
    public let selection: ThemePack?
    public let warnings: [String]
    public let wallpaperState: ThemeWallpaperState?
    public let wallpapers: [ThemeWallpaperMutation]
    /// Wallpaper the person changed since the theme set it: their choice stays, and only Pilot's claim on it goes.
    public let keptWallpapers: [ThemeWallpaperTarget]
    /// File regions the person changed since: their change stays, and only Pilot's claim on each goes.
    public let keptFiles: [ThemeClaim]
    /// Pilot's own parts the person changed since the theme: Restore leaves them, Apply gives them this theme with the
    /// person's choice as what Restore puts back.
    public let keptLook: [String]
    public let reloads: [ThemeReloadIntent]
    /// Ghostex's interface settings as read for this plan; nil when it is closed, absent or not bound.
    public let ghostexState: [String: String]?
    public let ghostex: [ThemeSettingMutation]
    /// What Pilot owns in Ghostex once this plan is committed.
    public let ghostexClaims: [ThemeSettingClaim]
    public let apps: [ThemeAppBinding]
    public init(id: String, packID: String?, revision: String?, binding: ThemeBinding, style: String, ledger: ThemeSnapshot,
                protectedLegacy: ThemeSnapshot?, zed: ThemeBinding? = nil, zedOptOut: Bool = false, observations: [ThemeSnapshot] = [], obsidian: [ThemeBinding] = [], obsidianOptOut: Bool = false, mutations: [ThemeMutation], selection: ThemePack?, warnings: [String], wallpaperState: ThemeWallpaperState? = nil, wallpapers: [ThemeWallpaperMutation] = [], keptWallpapers: [ThemeWallpaperTarget] = [], keptFiles: [ThemeClaim] = [], keptLook: [String] = [], reloads: [ThemeReloadIntent] = [], ghostexState: [String: String]? = nil, ghostex: [ThemeSettingMutation] = [], ghostexClaims: [ThemeSettingClaim] = [], apps: [ThemeAppBinding] = []) {
        self.id = id; self.packID = packID; self.revision = revision; self.binding = binding; self.style = style
        self.zed = zed; self.zedOptOut = zedOptOut; self.observations = observations
        self.obsidian = obsidian; self.obsidianOptOut = obsidianOptOut
        self.ledger = ledger; self.protectedLegacy = protectedLegacy; self.mutations = mutations; self.selection = selection; self.warnings = warnings
        self.wallpaperState = wallpaperState; self.wallpapers = wallpapers; self.keptWallpapers = keptWallpapers; self.keptFiles = keptFiles; self.keptLook = keptLook
        self.reloads = reloads
        self.ghostexState = ghostexState; self.ghostex = ghostex; self.ghostexClaims = ghostexClaims; self.apps = apps
    }
}

/// Explicit local display/workspace observations. Portable packs never provide these bindings or preferences.
public struct ThemeWallpaperState: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public let id: String
        public let workspace: String?
        public let portrait: Bool
        public let image: String?
        public let pinned: Bool
        public init(id: String, workspace: String?, portrait: Bool, image: String?, pinned: Bool) {
            self.id = id; self.workspace = workspace; self.portrait = portrait; self.image = image; self.pinned = pinned
        }
    }
    public let sources: [String]
    public let displays: [Display]
    /// Existing order/shuffle/timer/fit/screen/workspace settings, observed for freshness, never replaced by a pack.
    public let preferences: [String: JSONValue]
    public init(sources: [String], displays: [Display], preferences: [String: JSONValue]) {
        self.sources = sources; self.displays = displays; self.preferences = preferences
    }
    public func value(_ target: ThemeWallpaperTarget) throws -> ThemeWallpaperValue {
        switch target {
        case .sources: return .sources(sources)
        case .display(let id):
            guard let display = displays.first(where: { $0.id == id }), !display.pinned else { throw ThemeFailure("wallpaper display unavailable or personally overridden") }
            return .image(display.image)
        }
    }
    public func validate() throws {
        guard Set(displays.map(\.id)).count == displays.count, displays.allSatisfy({ !$0.id.isEmpty }),
              sources.allSatisfy({ $0.hasPrefix("/") }), displays.allSatisfy({ $0.image == nil || $0.image!.hasPrefix("/") }) else { throw ThemeFailure("invalid locally bound wallpaper state") }
    }
}

public enum ThemeWallpaperTarget: Codable, Equatable, Sendable { case sources, display(String) }
public enum ThemeWallpaperValue: Codable, Equatable, Sendable { case sources([String]), image(String?) }
public struct ThemeWallpaperMutation: Codable, Equatable, Sendable {
    public let target: ThemeWallpaperTarget
    public let before, after: ThemeWallpaperValue
    public let release: Bool
    public init(target: ThemeWallpaperTarget, before: ThemeWallpaperValue, after: ThemeWallpaperValue, release: Bool = false) {
        self.target = target; self.before = before; self.after = after; self.release = release
    }
}

/// The apps a theme follows besides Ghostty, Zed and Obsidian. Paths and folder names are taken from each app's own
/// documentation; none of these apps has been run against this code, so what each one does with the file is unverified.
public enum ThemeAppKind: String, Codable, CaseIterable, Sendable {
    case vscode, cursor, windsurf, kitty, alacritty, wezterm, iterm2
    public static let schemeName = "Pilot Theme"
    public var name: String {
        switch self {
        case .vscode: "VS Code"; case .cursor: "Cursor"; case .windsurf: "Windsurf"
        case .kitty: "Kitty"; case .alacritty: "Alacritty"; case .wezterm: "WezTerm"; case .iterm2: "iTerm2"
        }
    }
    /// What the app does with the theme, when a person has to do something for it to show.
    public var followUp: String? {
        switch self {
        case .kitty: "Reload Kitty's config (Ctrl+Cmd+,) to see it."
        case .wezterm: "WezTerm: add config.color_scheme = '\(Self.schemeName)' to your wezterm.lua."
        case .iterm2: "iTerm2: pick the profile named \(Self.schemeName) in its Profiles settings."
        default: nil
        }
    }
}

public struct ThemeAppBinding: Codable, Equatable, Sendable {
    public let kind: ThemeAppKind
    public let root: String
    public let config, generated: String?
    public init(kind: ThemeAppKind, root: String, config: String?, generated: String?) { self.kind = kind; self.root = root; self.config = config; self.generated = generated }
    public var paths: [String] { [generated, config].compactMap { $0 } }
}

/// Ghostex's window and sidebar colour, set through its own settings. Never its terminal colours (Sven, Q20, Q21).
public enum GhostexInterface {
    /// The window and sidebar settings Ghostex's custom colour square saves; a Ghostex without all of them counts as not there.
    public static let required = ["sidebarTheme", "darkThemePreset", "lightThemePreset", "customSidebarTitlebarBackgroundTintColor", "customSidebarTitlebarLightBackgroundTintColor"]
    /// Those and the chat's own Light or Dark (Sven, 2180: a light theme left the chat dark, light text on a light tint),
    /// which an older Ghostex without it simply skips.
    /// Colourfulness, sidebar and work area: Ghostex's numbers, read and written as their text.
    public static let numbers = ["themeSidebarContrast", "themeWorkAreaContrast"]
    public static let keys = required + ["sessionChatTheme"] + numbers
    /// Colourfulness at Full, Ghostex's -24 points: the window shows the picked colour itself, as Ghostex's own theme
    /// presets set it. At Sven's Subtle (+4) a custom dark colour only nudges the neutral grey by its hue, so a dark pack
    /// looked like Ghostex's default (Sven on 2189, Lagoon).
    public static let full = "-24"

    /// How Ghostex's Settings › Interface names each one.
    public static let names = ["sidebarTheme": "Appearance", "darkThemePreset": "Dark mode colour", "lightThemePreset": "Light mode colour",
                               "customSidebarTitlebarBackgroundTintColor": "Custom dark tint", "customSidebarTitlebarLightBackgroundTintColor": "Custom light tint", "sessionChatTheme": "Chat theme",
                               "themeSidebarContrast": "Sidebar colourfulness", "themeWorkAreaContrast": "Work area colourfulness"]

    /// The colour Ghostex is tinted with: a dark pack's panel (`lighter_background`), which keeps its hue where a near-black
    /// ground reads as plain black; a light pack's ground. Ghostex deepens a dark colour past luminance 0.04 itself.
    public static func tint(_ pack: ThemePack) throws -> String {
        guard let colour = (pack.dark ? pack.palette["lighter_background"] : nil) ?? pack.palette["background"] else { throw ThemeFailure("pack has no background colour") }
        return colour
    }

    /// The same settings Ghostex's own theme presets save, for this pack.
    public static func values(_ pack: ThemePack) throws -> [String: String] {
        let colour = try tint(pack)
        return ["sidebarTheme": pack.dark ? "dark-2" : "plain-light", "darkThemePreset": "custom", "lightThemePreset": "custom",
                "customSidebarTitlebarBackgroundTintColor": colour, "customSidebarTitlebarLightBackgroundTintColor": colour, "sessionChatTheme": pack.dark ? "dark" : "light",
                "themeSidebarContrast": full, "themeWorkAreaContrast": full]
    }

    /// A number setting's value as its text: whole numbers without a fraction, so a read matches what was written.
    public static func text(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e9 ? String(Int(number)) : String(number)
    }

    /// Only these keys, with values that are safe as one command-line argument (Pilot passes them after `--`, so a
    /// negative number stays a value). A damaged ledger or journal adds no authority.
    public static func valid(key: String, values: [String]) -> Bool {
        keys.contains(key) && values.allSatisfy { value in
            !value.isEmpty && value.count <= 64 && (!value.hasPrefix("-") || (numbers.contains(key) && Double(value) != nil))
                && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }
}

public struct ThemeSettingClaim: Codable, Equatable, Sendable {
    public let key, original, last: String
    public init(key: String, original: String, last: String) { self.key = key; self.original = original; self.last = last }
}
public struct ThemeSettingMutation: Codable, Equatable, Sendable {
    public let key, before, after: String
    public init(key: String, before: String, after: String) { self.key = key; self.before = before; self.after = after }
}

public enum ThemeRegions {
    /// What a JSON file is once its last key has gone, comments aside from none: a file Pilot made goes with it.
    public static func emptyObject(_ bytes: Data?) -> Bool {
        bytes.map { String(decoding: $0, as: UTF8.self).filter { !$0.isWhitespace } == "{}" } ?? false
    }

    /// Container absence is distinct from an empty array; later unrelated members may keep a new container alive.
    public static func preservesContainer(_ selector: ThemeSelector, in actual: Data?, of expected: Data?) -> Bool {
        do {
        guard case .jsonMembership(let path, _, _) = selector else { return true }
        let a = try ThemeJSONC(actual ?? Data("{}".utf8)).node(path)
        let e = try ThemeJSONC(expected ?? Data("{}".utf8)).node(path)
        if e != nil { return a != nil }
        if case .array(_, let members) = a { return !members.isEmpty }
        if case nil = a { return true }; return false
        } catch { return false }
    }

    public static func range(_ selector: ThemeSelector, in bytes: Data?) throws -> Range<Int>? {
        if case .jsonMembership(let path, let element, _) = selector { return try bytes.flatMap { try ThemeJSONC($0).membership(path, element: element)?.span } }
        if case .jsonValue(let path) = selector { return try bytes.flatMap { try ThemeJSONC($0).node(path)?.span } }
        if case .blockAfter(_, let begin, let end) = selector { return try range(.block(begin: begin, end: end, prefix: 1), in: bytes) }
        guard case .block(let begin, let end, let prefix) = selector else { return bytes.map { 0..<$0.count } }
        guard let bytes else { return nil }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ThemeFailure("config is not UTF-8") }
        // Byte offsets retain BOM, CRLF, blank lines and the absence of a final newline.
        let data = Array(bytes), starts = [0] + data.indices.filter { data[$0] == 10 }.map { $0 + 1 }
        var bs: [Int] = [], es: [Int] = []
        for start in starts where start < data.count {
            var finish = start
            while finish < data.count && data[finish] != 10 { finish += 1 }
            let line = String(decoding: data[start..<finish], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == begin { bs.append(start) }
            if line == end { es.append(finish > start && data[finish - 1] == 13 ? finish - 1 : finish) }
        }
        if bs.isEmpty && es.isEmpty {
            guard !text.contains(begin), !text.contains(end) else { throw ThemeFailure("broken theme markers") }
            return nil
        }
        guard bs.count == 1, es.count == 1, bs[0] < es[0],
              text.components(separatedBy: begin).count == 2, text.components(separatedBy: end).count == 2 else { throw ThemeFailure("broken or duplicate theme markers") }
        guard prefix >= 0, prefix <= 2, bs[0] >= prefix,
              prefix == 0 || data[(bs[0] - prefix)..<bs[0]].allSatisfy({ $0 == 10 || $0 == 13 }) else { throw ThemeFailure("owned marker separator changed") }
        return (bs[0] - prefix)..<es[0]
    }

    public static func owned(_ selector: ThemeSelector, in bytes: Data?) throws -> Data? {
        guard let bytes, let range = try range(selector, in: bytes) else { return nil }
        return bytes.subdata(in: range)
    }

    /// Two owned regions that say the same thing: equal bytes, or for a JSON value the same parsed value, so an editor
    /// that reformats its settings on save leaves Pilot's colours Pilot's.
    public static func sameMeaning(_ selector: ThemeSelector, _ a: Data?, _ b: Data?) -> Bool {
        if a == b { return true }
        switch selector {
        case .jsonValue, .jsonMembership:
            guard let a, let b,
                  let x = try? JSONSerialization.jsonObject(with: a, options: [.json5Allowed, .fragmentsAllowed]) as? NSObject,
                  let y = try? JSONSerialization.jsonObject(with: b, options: [.json5Allowed, .fragmentsAllowed]) as? NSObject else { return false }
            return x.isEqual(y)
        default: return false
        }
    }

    public static func replacing(_ selector: ThemeSelector, in bytes: Data?, with owned: Data?, insertedPrefix: Data = Data()) throws -> Data? {
        if case .file = selector { return owned }
        if case .jsonValue(let path) = selector {
            return try ThemeJSONC(bytes ?? Data("{}".utf8)).replacing(path, with: owned)
        }
        if case .jsonMembership(let path, let element, let removeEmpty) = selector {
            return try ThemeJSONC(bytes ?? Data("{}".utf8)).replacingMembership(path, element: element, with: owned, removeEmptyContainer: removeEmpty)
        }
        var file = bytes ?? Data()
        if let range = try range(selector, in: bytes) { file.replaceSubrange(range, with: owned ?? Data()) }
        else if case .blockAfter(let anchor, _, _) = selector, let owned {
            let text = String(decoding: file, as: UTF8.self)
            var offset = 0, found: Int?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces) == anchor { found = offset + line.utf8.count; break }
                offset += line.utf8.count + 1
            }
            guard let found else { throw ThemeFailure("expected line is missing") }
            file.insert(contentsOf: owned, at: found)
        }
        else if let owned { file.append(insertedPrefix); file.append(owned) }
        guard try self.owned(selector, in: file) == owned else { throw ThemeFailure("replacement does not preserve owned region") }
        return file
    }
}
