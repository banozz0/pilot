import Foundation

/// What a menu row's icon shows when its target alone does not say (card agent-bo-95423004; Sven, 2026-10-07: "for apps
/// use their own logo ... atleast some categories have different stuff"): an app's own icon, by its path or bundle id,
/// when that app is on the Mac; else a glyph in a theme role that says what the row is (a command-line tool a terminal, a
/// font its letters, an Install category its own symbol). The row draws it; the branch that lists the row picks it.
public struct MenuIcon: Hashable, Sendable {
    /// A theme role, read when the row draws.
    public enum Tint: String, Sendable { case neutral, accent, second, third, good, amber, problem }

    /// An app bundle on disk whose own icon the row wears (`/Applications/Zed.app`).
    public var appPath: String?
    /// An app's bundle id whose own icon the row wears once that app is installed.
    public var bundle: String?
    /// The glyph when there is no app icon to show.
    public var symbol: String
    public var tint: Tint
    /// An emoji drawn in the glyph's place, a script command's (card agent-bo-95423029).
    public var emoji: String?
    /// A catalogue entry's own picture shipped in the app (`catalogue-icons/<id>.png`, Scripts/catalogue-icons.swift),
    /// worn until the app itself is installed (C5); or with its own folder, a folder design's art (`folder-designs/kraft`, P43).
    public var bundled: String?
    /// A picture on disk by its path, drawn as it dresses a folder: one of Your designs (P55).
    public var picture: String?
    /// A picture on the network an Install search found (App Store artwork, a repo owner's avatar, a site's icon), worn
    /// once it arrives (N9).
    public var remote: String?

    public init(appPath: String? = nil, bundle: String? = nil, symbol: String, tint: Tint, emoji: String? = nil, bundled: String? = nil,
                picture: String? = nil, remote: String? = nil) {
        self.appPath = appPath; self.bundle = bundle; self.symbol = symbol; self.tint = tint; self.emoji = emoji
        self.bundled = bundled; self.picture = picture; self.remote = remote
    }

    public static func glyph(_ symbol: String, _ tint: Tint) -> MenuIcon { MenuIcon(symbol: symbol, tint: tint) }

    /// This glyph, wearing the app at `path` (or with `bundle`) once that app is on the Mac.
    public func app(path: String? = nil, bundle: String? = nil) -> MenuIcon {
        MenuIcon(appPath: path, bundle: bundle, symbol: symbol, tint: tint, emoji: emoji, bundled: bundled, picture: picture, remote: remote)
    }

    // MARK: What a thing is

    public static let formula = glyph("terminal", .good)
    /// A command's row (a script's, an extension's): its emoji, else a terminal.
    public static func command(emoji: String?) -> MenuIcon {
        var icon = formula
        icon.emoji = emoji
        return icon
    }
    /// A quicklink (card agent-bo-95423030).
    public static let quicklink = glyph("link", .accent)
    public static let font = glyph("textformat", .accent)
    public static let cask = glyph("shippingbox", .amber)
    public static let uv = glyph("chevron.left.forwardslash.chevron.right", .second)
    public static let npm = glyph("curlybraces", .problem)
    public static let bun = glyph("hare", .amber)
    public static let cargo = glyph("gearshape.2", .third)
    public static let appStore = glyph("bag", .accent)
    public static let macOS = glyph("apple.logo", .neutral)
    public static let webApp = glyph("globe", .accent)
    /// Update's and Clean's Reports row (story 153).
    public static let reports = glyph("doc.text.magnifyingglass", .third)
    public static let app = glyph("app.dashed", .neutral)
    public static let download = glyph("arrow.down.to.line", .second)
    public static let github = glyph("arrow.triangle.branch", .third)
    public static let go = glyph("g.square", .accent)

    /// A Homebrew, uv, npm or App Store package: a font cask (Homebrew names them `font-…`) its letters, a formula a
    /// terminal; a cask that names its app wears that app.
    public static func package(_ p: Package, app path: String? = nil) -> MenuIcon {
        switch p.kind {
        case .formula: formula
        case .uv, .pipx: uv
        case .npm: npm
        case .cargo: cargo
        case .go: go
        case .mas: appStore.app(path: path)
        case .cask:
            if p.name.split(separator: "/").last?.hasPrefix("font-") == true { font }
            else if let path { cask.app(path: path) }
            else { cask }
        }
    }

    /// Each Install catalogue category's glyph, all different (the shipped catalogue's sixteen, plus Pilot's own names);
    /// a category the table lacks a box.
    public static func category(_ name: String) -> MenuIcon {
        categories[name.lowercased()] ?? glyph("shippingbox", .neutral)
    }

    static let categories: [String: MenuIcon] = [
        "featured": glyph("star", .amber), "chat": glyph("message", .accent),
        "ai agents": glyph("brain.head.profile", .third), "ai": glyph("sparkles", .accent),
        "ades": glyph("rectangle.3.group", .second), "services": glyph("cloud", .accent),
        "development": glyph("hammer", .amber), "editors": glyph("square.and.pencil", .good),
        "fonts": font, "gaming": glyph("gamecontroller", .problem), "browsers": glyph("safari", .accent),
        "terminals": glyph("apple.terminal", .good),
        "command-line tools": glyph("chevron.forward.2", .third), "window manager": glyph("rectangle.split.2x2", .amber),
        "utilities": glyph("wrench.and.screwdriver", .neutral), "media": glyph("play.rectangle", .problem),
        "productivity": glyph("checklist", .good), "communication": glyph("bubble.left.and.bubble.right", .accent),
        "design": glyph("paintbrush.pointed", .second), "security": glyph("lock.shield", .amber),
    ]

    /// A catalogue entry: the installed app's own icon by its bundle id or app path, else the picture the app ships for
    /// it (C5), else a font or a command-line tool by its kind, any other app its category's glyph.
    public static func catalogue(_ e: CatalogueEntry) -> MenuIcon {
        var app: String?, bundle: String?
        switch e.check {
        case .bundle(let id): bundle = id
        case .paths(let paths): app = paths.first { $0.hasSuffix(".app") }.map { NSString(string: $0).expandingTildeInPath }
        case .command: break
        }
        var icon: MenuIcon
        if let p = e.method.package, p.kind.isTool { icon = package(p) }
        else if let p = e.method.package, p.kind == .cask, package(p) == font { icon = font }
        else if e.category.lowercased() == "fonts" { icon = font }
        else { icon = category(e.category).app(path: app, bundle: bundle) }
        icon.bundled = e.id
        return icon
    }

    /// What Update lists: each kind its glyph, an App Store app its own icon by name in /Applications.
    public static func updatable(_ item: Updatable, app: String? = nil) -> MenuIcon {
        switch item {
        case .package(let p): package(p, app: app)
        case .npm: npm
        case .bun: bun
        case .cargo: cargo
        case .appStore(_, let name): appStore.app(path: "/Applications/\(name).app")
        case .macOS: macOS
        }
    }

    /// A row Remove lists: an app, or a cask's app, its own icon; a web app Pilot stamped its own by bundle id; any other
    /// kind its glyph.
    public static func remove(_ r: RemoveRow) -> MenuIcon {
        switch r.source {
        case .app(let path): app.app(path: path)
        case .webApp(let id): webApp.app(bundle: id)
        case .npm: npm
        case .package(let p): package(p, app: r.app)
        }
    }

    /// Remove's categories (card agent-bo-95423022) wear the glyph of what they hold.
    public static func removeCategory(_ c: RemoveList.Category) -> MenuIcon {
        switch c {
        case .apps: app
        case .tools: formula
        case .casks: cask
        case .webApps: webApp
        case .system: macOS
        }
    }

    /// Update's categories wear the same glyphs, macOS its logo.
    public static func updateCategory(_ c: UpdateList.Category) -> MenuIcon {
        switch c {
        case .apps: app
        case .tools: formula
        case .macOS: macOS
        }
    }

    /// One line of Mole's preview, by what it names: a browser's cache a compass, a developer tool's a hammer, logs a page,
    /// the Trash a bin, an app's leftovers an app; else by Mole's section, else a box of caches.
    public static func clean(title: String, section: String) -> MenuIcon {
        // Whole words, a plural too: "arc" is not Archives, "log" not Login (Moody).
        let words = " " + EmojiSearch.words("\(title) \(section)").joined(separator: " ") + " "
        func names(_ rule: String) -> Bool { ["", "s", "es"].contains { words.contains(" \(rule)\($0) ") } }
        return cleanRules.first { $0.0.contains(where: names) }?.1 ?? glyph("archivebox", .good)
    }

    private static let cleanRules: [([String], MenuIcon)] = [
        (["chrome", "safari", "firefox", "brave", "edge", "arc", "zen", "browser", "service worker"], glyph("safari", .accent)),
        (["xcode", "simulator", "derived", "vs code", "npm", "yarn", "pip", "cargo", "gradle", "go", "developer", "homebrew", "brew"],
         glyph("hammer", .amber)),
        (["log"], glyph("doc.plaintext", .neutral)),
        (["trash"], glyph("trash", .problem)),
        (["download"], glyph("arrow.down.circle", .second)),
        (["mail", "message", "slack", "discord", "telegram"], glyph("bubble.left", .accent)),
        (["spotify", "music", "photo", "media", "video"], glyph("play.rectangle", .problem)),
        (["system"], glyph("gearshape", .neutral)),
        (["app", "extension", "leftover"], glyph("app.badge", .third)),
    ]
}
