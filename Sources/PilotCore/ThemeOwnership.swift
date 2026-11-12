import Foundation
import Darwin

/// A read observation, including the locally bound path, parent/link identities and exact file bytes/mode.
public struct ThemeSnapshot: Codable, Equatable, Sendable {
    public let root, path, resolved, anchor: String
    public let inode: UInt64?
    public let mode: UInt16
    public let bytes: Data?
    /// A linked leaf whose real file is outside the bound root.
    public var linkedOut: Bool { !resolved.hasPrefix(root + "/") }
}

/// Descriptor-relative reads/replacements. Resolved internal symlinks stay symlinks; broken/hard links refuse, and so do
/// escaping ones, unless the caller passes `linkedLeaf` for a destination that may be a link to a real file elsewhere.
public enum ThemeFiles {
    public static func relative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0) &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func identity(_ s: stat) -> String { "\(s.st_dev):\(s.st_ino):\(s.st_mode)" }
    private static func info(_ path: String) throws -> stat {
        var s = stat()
        guard lstat(path, &s) == 0 else { throw ThemeFailure("cannot inspect target: \(path)") }
        return s
    }

    private static func location(root: String, path: String, linkedLeaf: Bool) throws -> (String, String) {
        guard root.hasPrefix("/"), relative(path), !root.utf8.contains(0) else { throw ThemeFailure("unsafe bound path") }
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical == URL(fileURLWithPath: root).standardizedFileURL.path else { throw ThemeFailure("root must be an explicit real directory") }
        let logical = canonical + "/" + path
        var resolved = URL(fileURLWithPath: logical).resolvingSymlinksInPath().standardizedFileURL.path
        if !resolved.hasPrefix(canonical + "/") {
            guard linkedLeaf, !path.contains("/"), try info(logical).st_mode & S_IFMT == S_IFLNK else { throw ThemeFailure("target escapes bound root") }
            guard let real = realpath(logical, nil) else { throw ThemeFailure("broken symlink") }  // Not FileOps.real: proofs compile this file alone.
            defer { free(real) }
            resolved = String(cString: real)
        }
        var signature = ""
        // Capture every original component as well as the resolved parent. Broken links cannot become absent files.
        var current = canonical
        signature += identity(try info(current))
        for component in path.split(separator: "/") {
            current += "/" + component
            var s = stat()
            if lstat(current, &s) == 0 {
                if s.st_mode & S_IFMT == S_IFLNK {
                    var followed = stat()
                    guard stat(current, &followed) == 0 else { throw ThemeFailure("broken symlink") }
                    // A leaf linked out is known by where it points: re-making the same link (ln -sf) is no change.
                    let own = resolved.hasPrefix(canonical + "/") ? identity(s) + ":" : ""
                    signature += "|link:\(current):\(own)\(URL(fileURLWithPath: current).resolvingSymlinksInPath().path)"
                } else if current != logical { signature += "|\(identity(s))" }
            } else if errno != ENOENT || current != logical { throw ThemeFailure("missing/unsafe target parent") }
        }
        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        signature += "|parent:\(parent):\(identity(try info(parent)))"
        return (resolved, signature)
    }

    private static func parentFD(root: String, resolved: String, linkedLeaf: Bool) throws -> Int32 {
        // A linked leaf's real folder is outside the root: walk to it from / so a link anywhere on the way refuses.
        let inside = resolved.hasPrefix(root + "/")
        guard inside || linkedLeaf else { throw ThemeFailure("target escapes bound root") }
        var fd = open(inside ? root : "/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ThemeFailure("cannot anchor root") }
        let relative = inside ? String(resolved.dropFirst(root.count + 1)) : resolved
        for part in relative.split(separator: "/").dropLast() {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd); fd = next
            guard fd >= 0 else { throw ThemeFailure("unsafe resolved parent") }
        }
        return fd
    }

    /// An anchor written by a build that still recorded a linked leaf's own identity, as this build writes it now.
    public static func withoutLinkIdentity(_ anchor: String) -> String {
        anchor.replacing(#/\|link:([^|]*?):\d+:\d+:\d+:/#) { "|link:\($0.1):" }
    }

    public static let folderMissing = "folder missing"
    /// A destination whose own folder does not exist yet, up to three levels under a real folder: nothing to read, and
    /// Apply makes the folders (an app installed but never opened, or WezTerm's ~/.config/wezterm/colors).
    public static func inMissingFolder(root: String, path: String) -> ThemeSnapshot? {
        missingFolders(root + "/" + path)?.isEmpty != false ? nil : ThemeSnapshot(root: root, path: path, resolved: root + "/" + path, anchor: folderMissing, inode: nil, mode: 0o600, bytes: nil)
    }
    /// The folders above `file` that are missing, outermost first (none when its folder is there), when at most three are
    /// and the first that exists is a real folder; nil when they can't be made.
    public static func missingFolders(_ file: String) -> [String]? {
        var folder = URL(fileURLWithPath: file).deletingLastPathComponent(), missing: [String] = []
        var s = stat()
        while lstat(folder.path, &s) != 0 {
            guard errno == ENOENT, missing.count < 3, folder.path != "/" else { return nil }
            missing.insert(folder.path, at: 0); folder.deleteLastPathComponent()
        }
        return s.st_mode & S_IFMT == S_IFDIR ? missing : nil
    }

    public static func read(root: String, path: String, linkedLeaf: Bool = false) throws -> ThemeSnapshot {
        let (resolved, anchor) = try location(root: root, path: path, linkedLeaf: linkedLeaf)
        let parent = try parentFD(root: root, resolved: resolved, linkedLeaf: linkedLeaf); defer { close(parent) }
        let leaf = URL(fileURLWithPath: resolved).lastPathComponent
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        var bytes: Data?, inode: UInt64?, mode: UInt16 = 0o600
        if fd >= 0 {
            defer { close(fd) }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else { throw ThemeFailure("target must be a regular file with one link") }
            inode = s.st_ino; mode = s.st_mode & 0o777
            bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            var after = stat()
            guard fstat(fd, &after) == 0, s.st_size == after.st_size,
                  s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ThemeFailure("concurrent read") }
        } else if errno != ENOENT { throw ThemeFailure("unsafe/unreadable target") }
        let checked = try location(root: root, path: path, linkedLeaf: linkedLeaf)
        guard checked.0 == resolved, checked.1 == anchor else { throw ThemeFailure("target changed during read") }
        return ThemeSnapshot(root: root, path: path, resolved: resolved, anchor: anchor, inode: inode, mode: mode, bytes: bytes)
    }

    /// No cross-process CAS is claimed: compare immediately before replacement, verify afterwards, retain journal on conflict.
    public static func write(_ bytes: Data?, over expected: ThemeSnapshot, linkedLeaf: Bool = false) throws -> ThemeSnapshot {
        func again() throws -> ThemeSnapshot { try read(root: expected.root, path: expected.path, linkedLeaf: linkedLeaf) }
        guard try again() == expected else { throw ThemeFailure("stale target before write") }
        let parent = try parentFD(root: expected.root, resolved: expected.resolved, linkedLeaf: linkedLeaf); defer { close(parent) }
        var p = stat()
        guard fstat(parent, &p) == 0 else { throw ThemeFailure("lost parent") }
        let canonicalParent = URL(fileURLWithPath: expected.resolved).deletingLastPathComponent().path
        let checkParent = try info(canonicalParent)
        guard p.st_ino == checkParent.st_ino, p.st_dev == checkParent.st_dev else { throw ThemeFailure("parent swapped") }
        let leaf = URL(fileURLWithPath: expected.resolved).lastPathComponent
        if let bytes {
            let temp = ".pilot-theme-" + UUID().uuidString
            let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(expected.mode))
            guard fd >= 0 else { throw ThemeFailure("cannot stage file") }
            defer { close(fd); unlinkat(parent, temp, 0) }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
            guard fchmod(fd, mode_t(expected.mode)) == 0, fsync(fd) == 0 else { throw ThemeFailure("cannot sync staged file") }
            guard try again() == expected else { throw ThemeFailure("concurrent edit before replacement") }
            guard renameat(parent, temp, parent, leaf) == 0 else { throw ThemeFailure("cannot replace target") }
        } else if expected.bytes != nil {
            guard try again() == expected, unlinkat(parent, leaf, 0) == 0 else { throw ThemeFailure("cannot remove owned file") }
        }
        guard fsync(parent) == 0 else { throw ThemeFailure("cannot sync parent") }
        let observed = try again()
        guard observed.bytes == bytes, observed.anchor == expected.anchor, observed.resolved == expected.resolved else { throw ThemeFailure("concurrent edit after write; journal retained") }
        return observed
    }
}

public struct ThemeClaim: Codable, Equatable, Sendable {
    public let root, path, resolved, anchor: String
    public let selector: ThemeSelector
    public let original, last: Data?
    public let codec: Int
    public var bindingID: String? = nil
    public var identity: String { ThemeResource.identity(root, path) + ":" + ((try? ThemeDigest.encoded(selector)).map(ThemeDigest.of) ?? "invalid") }
    public let originalFileAbsent: Bool
    public init(root: String, path: String, resolved: String, anchor: String, selector: ThemeSelector,
                original: Data?, last: Data?, codec: Int, originalFileAbsent: Bool) {
        self.root = root; self.path = path; self.resolved = resolved; self.anchor = anchor; self.selector = selector
        self.original = original; self.last = last; self.codec = codec; self.originalFileAbsent = originalFileAbsent
    }
    /// The same claim with its region as the file holds it now.
    public func reading(_ now: Data?) -> ThemeClaim {
        var claim = ThemeClaim(root: root, path: path, resolved: resolved, anchor: anchor, selector: selector, original: original, last: now, codec: codec, originalFileAbsent: originalFileAbsent)
        claim.bindingID = bindingID
        return claim
    }
}

public struct ThemeLedger: Codable, Equatable, Sendable {
    public var schema = 1
    public var epoch = 0
    public var selected: ThemePack?
    public var claims: [ThemeClaim] = []
    public var wallpapers: [ThemeWallpaperClaim]? = nil
    public var appearance: ThemeAppearanceOwnership? = nil
    public var ghostexSettings: [ThemeSettingClaim]? = nil
    public init() {}

    /// Current and embedded schema-1 ledgers have exactly the same native authority boundary.
    public static func decode(_ bytes: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try validateNativeFields(bytes, appearance: value.appearance.map { try ThemeDigest.encoded($0) })
        if case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: bytes),
           case .object(let selected)? = fields["selected"], selected["customMappings"] != nil {
            try validateFields(bytes, field: "selected", encoded: value.selected.map { try ThemeDigest.encoded($0) })
        }
        return value
    }

    /// Preserve older file/wallpaper encodings; strictly check only the additive native subtree.
    public static func validateNativeFields(_ bytes: Data, appearance: Data?) throws {
        try validateFields(bytes, field: "appearance", encoded: appearance)
    }

    /// Strict additive authority, including duplicates; nil field checks the complete object.
    public static func validateFields(_ bytes: Data, field: String? = nil, encoded: Data?) throws {
        let actual = try JSONDecoder().decode(JSONValue.self, from: bytes)
        let expected = try encoded.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        guard case .object(let fields) = actual else { throw ThemeFailure("invalid authority object") }
        let observed: JSONValue? = if let field { fields[field] } else { actual }
        guard observed == expected else {
            throw ThemeFailure("unknown/null native ownership fields")
        }
        // Codable and JSON dictionaries discard duplicate keys. Scan member names in the
        // native subtree too, after the decoder has established valid JSON syntax.
        // JSONDecoder accepts BOMs and UTF-16/32 too. Scan the same text, preserving
        // duplicate members rather than re-encoding a dictionary that has lost them.
        let prefix = Array(bytes.prefix(4)), encoding: String.Encoding
        if prefix.starts(with: [0, 0, 254, 255]) || prefix.starts(with: [255, 254, 0, 0]) { encoding = .utf32 }
        else if prefix.starts(with: [254, 255]) || prefix.starts(with: [255, 254]) { encoding = .utf16 }
        else if prefix.starts(with: [0, 0, 0]) { encoding = .utf32BigEndian }
        else if prefix.count == 4 && prefix[1...3].allSatisfy({ $0 == 0 }) { encoding = .utf32LittleEndian }
        else if prefix.first == 0 { encoding = .utf16BigEndian }
        else if prefix.count > 1 && prefix[1] == 0 { encoding = .utf16LittleEndian }
        else { encoding = .utf8 }
        guard let text = String(data: bytes, encoding: encoding) else { throw ThemeFailure("invalid native authority encoding") }
        let input = Array(text.utf8); var index = input.starts(with: [239, 187, 191]) ? 3 : 0
        func whitespace() { while index < input.count && [9, 10, 13, 32].contains(input[index]) { index += 1 } }
        func string() throws -> String {
            let start = index; index += 1
            while input[index] != 34 { if input[index] == 92 { index += 1 }; index += 1 }
            index += 1
            return try JSONDecoder().decode(String.self, from: Data(input[start..<index]))
        }
        func scan(_ strict: Bool, depth: Int) throws {
            whitespace()
            switch input[index] {
            case 123:
                index += 1; whitespace(); var names = Set<String>()
                while input[index] != 125 {
                    let name = try string(), inserted = names.insert(name).inserted
                    guard inserted || !(strict || depth == 0 && name == field) else { throw ThemeFailure("duplicate native ownership field") }
                    whitespace(); index += 1
                    try scan(strict || depth == 0 && name == field, depth: depth + 1)
                    whitespace(); if input[index] != 44 { break }; index += 1; whitespace()
                }
                index += 1
            case 91:
                index += 1; whitespace()
                while input[index] != 93 {
                    try scan(strict, depth: depth + 1); whitespace()
                    if input[index] != 44 { break }; index += 1
                }
                index += 1
            case 34: _ = try string()
            default:
                while index < input.count && ![9, 10, 13, 32, 44, 93, 125].contains(input[index]) { index += 1 }
            }
        }
        whitespace()
        guard index < input.count, input[index] == 123 else { throw ThemeFailure("invalid native authority object") }
        try scan(field == nil, depth: 0)
    }
}

/// Persist before any target write. A pending operation is either committed (ledger matches after) or rolled back to before.
public struct ThemeJournal: Codable, Sendable {
    public let schema: Int
    public let beforeLedger, afterLedger: Data?
    public let mutations: [ThemeMutation]
    public let wallpapers: [ThemeWallpaperMutation]?
    public var appearance: ThemeAppearanceMutation? = nil
    public var ghostexSettings: [ThemeSettingMutation]? = nil
    /// Wallpaper claims this operation drops without touching the screen or collection: the person changed them since.
    public var keptWallpapers: [ThemeWallpaperTarget]? = nil
    /// File claims this operation drops without writing: the person changed those regions since.
    public var keptFiles: [ThemeClaim]? = nil
    /// Pilot's own parts the person changed since, let go by this operation (ThemeAppearanceOwnership.parts).
    public var keptLook: [String]? = nil
    public init(schema: Int, beforeLedger: Data?, afterLedger: Data?, mutations: [ThemeMutation], wallpapers: [ThemeWallpaperMutation]? = nil, appearance: ThemeAppearanceMutation? = nil, ghostexSettings: [ThemeSettingMutation]? = nil, keptWallpapers: [ThemeWallpaperTarget]? = nil, keptFiles: [ThemeClaim]? = nil, keptLook: [String]? = nil) {
        self.schema = schema; self.beforeLedger = beforeLedger; self.afterLedger = afterLedger; self.mutations = mutations
        self.wallpapers = wallpapers; self.keptWallpapers = keptWallpapers; self.keptFiles = keptFiles; self.keptLook = keptLook
        self.appearance = appearance
        self.ghostexSettings = ghostexSettings
    }
}

/// Local ownership only. Ownership and mutations never occur in a portable pack or export envelope.
public struct ThemeAppearanceOwnership: Codable, Equatable, Sendable {
    public var original, last: ThemeNativeAppearance
    public var following: ThemeFollowing
    public var paletteOwned, materialOwned: Bool
    public var barOwned: Bool? = nil
    public var cursorOwned: Bool? = nil
    /// macOS's Light or Dark mode, set to the theme's (Sven Q43).
    public var modeOwned: Bool? = nil
    public init(original: ThemeNativeAppearance, last: ThemeNativeAppearance, following: ThemeFollowing, paletteOwned: Bool, materialOwned: Bool, barOwned: Bool? = nil, cursorOwned: Bool? = nil, modeOwned: Bool? = nil) {
        self.original = original; self.last = last; self.following = following
        self.paletteOwned = paletteOwned; self.materialOwned = materialOwned; self.barOwned = barOwned; self.cursorOwned = cursorOwned; self.modeOwned = modeOwned
    }
    /// Pilot's own parts: Look's palette, glass, top bar layout, cursor colours and macOS's mode.
    public static let parts = ["palette", "material", "bar", "cursor", "mode"]
    /// The owned parts the person has changed since: `current` differs from what the theme last set.
    public func changed(in current: ThemeNativeAppearance) -> [String] {
        [paletteOwned && current.palette != last.palette ? "palette" : nil, materialOwned && current.material != last.material ? "material" : nil,
         barOwned == true && current.bar != last.bar ? "bar" : nil, cursorOwned == true && current.cursor != last.cursor ? "cursor" : nil,
         modeOwned == true && (current.dark != last.dark || current.auto != last.auto) ? "mode" : nil].compactMap { $0 }
    }
    /// This ownership with `parts` let go: the person's choice there is theirs, neither put back nor checked.
    public func releasing(_ parts: [String]) -> ThemeAppearanceOwnership {
        var next = self
        if parts.contains("palette") { next.paletteOwned = false }
        if parts.contains("material") { next.materialOwned = false }
        if parts.contains("bar") { next.barOwned = nil }
        if parts.contains("cursor") { next.cursorOwned = nil }
        if parts.contains("mode") { next.modeOwned = nil }
        return next
    }
}
public struct ThemeAppearanceMutation: Codable, Equatable, Sendable {
    public let before, after: ThemeNativeAppearance
    public let palette, material: Bool
    public let bar: Bool?
    public let cursor: Bool?
    public var mode: Bool? = nil
    public init(before: ThemeNativeAppearance, after: ThemeNativeAppearance, palette: Bool, material: Bool, bar: Bool? = nil, cursor: Bool? = nil, mode: Bool? = nil) {
        self.before = before; self.after = after; self.palette = palette; self.material = material; self.bar = bar; self.cursor = cursor; self.mode = mode
    }
    public func matches(_ current: ThemeNativeAppearance, _ expected: ThemeNativeAppearance) -> Bool {
        (!palette || current.palette == expected.palette) && (!material || current.material == expected.material) && (bar != true || current.bar == expected.bar) && (cursor != true || current.cursor == expected.cursor) && (mode != true || (current.dark == expected.dark && current.auto == expected.auto))
    }
    public func merging(_ expected: ThemeNativeAppearance, into current: ThemeNativeAppearance) -> ThemeNativeAppearance {
        .init(palette: palette ? expected.palette : current.palette, material: material ? expected.material : current.material, bar: bar == true ? expected.bar : current.bar, cursor: cursor == true ? expected.cursor : current.cursor, dark: mode == true ? expected.dark : current.dark, auto: current.auto)
    }
}
public struct ThemeMaterial: Codable, Equatable, Sendable {
    public var glass: Bool
    public var transparency: Int
    public var blur: String
    public init(glass: Bool, transparency: Int, blur: String) { self.glass = glass; self.transparency = transparency; self.blur = blur }
    public func validate() throws {
        guard (0...100).contains(transparency), ["full", "light", "off"].contains(blur) else { throw ThemeFailure("invalid material") }
    }
}
public enum ThemeNativePalette: Codable, Equatable, Sendable {
    case stock(String), pack(ThemePack)
    /// A saved stock palette of a retired theme as its successor (PilotTheme.retired); anything else as it is.
    public var current: ThemeNativePalette {
        if case .stock(let id) = self, let next = PilotTheme.retired[id] { return .stock(next) }
        return self
    }
    public func validate() throws {
        switch self {
        // A retired theme's id stays valid as saved (Restore's original, a style's memory); it means its successor.
        case .stock(let id): guard PilotTheme.named(PilotTheme.retired[id] ?? id) != nil else { throw ThemeFailure("unknown local stock palette") }
        case .pack(let pack): _ = try ThemePack.decode(ThemeDigest.encoded(pack))
        }
    }
    public func compatible(with style: String) -> Bool {
        switch self {
        case .stock(let id): return !["toybox", "toybox-night"].contains(id) || style == "toybox"
        case .pack(let pack): return pack.compatible(with: style)
        }
    }
}
public struct ThemeNativeAppearance: Codable, Equatable, Sendable {
    public var palette: ThemeNativePalette
    public var material: ThemeMaterial
    public var bar: ThemeBarPresetState?
    /// Look › Cursor › Colours: theme, own or custom. Nil where a host has no cursor settings.
    public var cursor: String?
    /// macOS's Dark mode, on or off. Nil where a host can't read or set it.
    public var dark: Bool? = nil
    /// macOS's Auto appearance (Light by day, Dark at night): true when on, nil when off or unread. A theme never sets it
    /// and claims no mode while it is on, so Restore tells Light, Dark and Auto apart.
    public var auto: Bool? = nil
    public init(palette: ThemeNativePalette, material: ThemeMaterial, bar: ThemeBarPresetState? = nil, cursor: String? = nil, dark: Bool? = nil, auto: Bool? = nil) {
        self.palette = palette; self.material = material; self.bar = bar; self.cursor = cursor; self.dark = dark; self.auto = auto
    }
    public func validate() throws {
        try palette.validate(); try material.validate(); try bar?.validate()
        guard cursor == nil || ["theme", "own", "custom"].contains(cursor!) else { throw ThemeFailure("invalid cursor colours") }
    }
}
/// Staged local preferences. Missing bar means personal, retaining schema-1 records.
public struct ThemeFollowing: Codable, Equatable, Sendable {
    public var palette = true
    public var wallpapers = true
    public var material = false
    public var bar: Bool? = nil
    /// Nil follows: a pack colours the cursor unless kept personal.
    public var cursor: Bool? = nil
    /// Nil follows: a light theme switches macOS to Light mode and a dark one to Dark (Sven Q43, on by default).
    public var mode: Bool? = nil
    public init() {}
}

/// Original captured once; last updated by pack switches and the existing wallpaper cycle, never by imports.
public struct ThemeWallpaperClaim: Codable, Equatable, Sendable {
    public let target: ThemeWallpaperTarget
    public let original, last: ThemeWallpaperValue
    public init(target: ThemeWallpaperTarget, original: ThemeWallpaperValue, last: ThemeWallpaperValue) {
        self.target = target; self.original = original; self.last = last
    }
}

/// Resource and selector identity are independent of ambiguous leaf filenames.
public enum ThemeResource {
    public static func identity(_ root: String, _ path: String) -> String { "\(root.utf8.count):\(root)\(path)" }
}
