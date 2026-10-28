import AppKit
import PilotCore
import SwiftUI

extension MenuGroups.Group {
    /// The heading's words: a search's branches under "Go to" when `goTo` (Instrument asks for it), else "Browse".
    func title(goTo: Bool) -> String {
        switch self {
        case .bestMatch: "Best match"
        case .apps: "Apps"
        case .windowsAndFiles: "Windows and files"
        case .actions: "Actions"
        case .menuItems: "Menu items"
        case .commands: "Commands"
        case .install: "Install"
        case .emoji: "Emoji"
        case .goTo: goTo ? "Go to" : "Browse"
        case .askOrSearch: "Ask or search"
        case .section(let title): title
        }
    }
}

/// A row's picture, resizable: an animated GIF (GIPHY's previews, story 164) plays in an NSImageView, as SwiftUI's
/// Image draws only its first frame; anything else is a plain Image.
struct ArtImage: View {
    let image: NSImage

    var body: some View {
        if Self.animated(image) { Animated(image: image) } else { Image(nsImage: image).resizable().interpolation(.high) }
    }

    static func animated(_ image: NSImage) -> Bool {
        ((image.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 0) > 1
    }

    private struct Animated: NSViewRepresentable {
        let image: NSImage

        func makeNSView(context: Context) -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.animates = true
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return view
        }

        func updateNSView(_ view: NSImageView, context: Context) { if view.image !== image { view.image = image } }
    }
}

extension MenuBranch {
    /// Each branch's SF Symbol (the artifact's Tabler icon's nearest), its tile colour and the line its root row
    /// says it holds while current. A table, not a switch: a branch added later gets the plain look until it has a row here.
    private static let looks: [MenuBranch: (symbol: String, colour: Int, hint: String)] = [
        .apps: ("square.grid.2x2", 0, "open any app"), .learn: ("book", 1, "every bind"),
        .trigger: ("bolt", 2, "captures, media, timer"), .install: ("arrow.down.circle", 3, "apps, fonts, web apps"),
        .remove: ("trash", 5, "apps you added"), .update: ("arrow.clockwise", 4, "what can upgrade"),
        .clean: ("sparkles", 2, "caches, with a preview"), .system: ("power", 5, "lock, sleep, Wi-Fi"),
        .config: ("doc.text", 0, "open a config file"), .extensions: ("puzzlepiece.extension", 3, "yours, and the catalogue"), .keybindings: ("command", 1, ""), .capture: ("camera.viewfinder", 2, ""),
        .homebrew: ("text.magnifyingglass", 3, ""), .translate: ("character.bubble", 3, ""), .reminders: ("bell", 4, ""),
        .snippets: ("text.quote", 1, ""),
        .notes: ("note.text", 1, ""), .qr: ("qrcode", 0, ""),
        .stickers: ("face.smiling", 2, ""), .emoji: ("face.smiling", 2, ""),
        .activity: (AppPage.activity.symbol, 5, "what runs, quit it"), .stats: (AppPage.stats.symbol, 4, "this Mac's readings"),
        .about: ("info.circle", 0, "this Mac and Pilot"),
    ]

    var look: (symbol: String, colour: Int, hint: String) {
        // A category wears its own glyph in Install and System (C6); in Remove and Update the look of the branch it browses
        // (card agent-bo-95423022).
        if case .category(let c, let browse) = self {
            if browse == .install { return (MenuIcon.category(c).symbol, 3, "") }
            let section = MenuLayout.section(self, in: .system)
            return (section.map { MenuLayout.systemSections[$0].symbol } ?? browse.look.symbol, browse.look.colour, "")
        }
        return Self.looks[self] ?? ("chevron.right", 0, "")
    }
}

extension MenuEntry {
    /// What a branch holds, on its root row while it is current.
    var hint: String {
        guard case .branch(let b) = target else { return "" }
        return b.look.hint
    }
}

/// A theme role, read when the row draws, so the tiles follow a theme change.
private typealias Tint = MenuIcon.Tint

/// A tile's colour as the row names it, a tint role or one of Binds' six modules (BindsKeyboard's order), resolved by
/// the view that draws it: Instrument in its own colours, Toybox in its candy colours (ToyMenu).
enum MenuPaint: Equatable {
    case tint(MenuIcon.Tint), module(Int)
}

extension MenuEntry {
    /// What the row shows of its app under Apps show as (story 154); a row that lists no app shows both.
    @MainActor var appShows: (icon: Bool, title: Bool) { AppsShowAs.current.shows(appRole) }

    /// What a row's icon draws (InstrumentMenu, ToyMenu).
    enum Art {
        /// An app's own icon; `badge` the glyph of what an app's action does.
        case icon(NSImage, badge: String?)
        /// A coloured tile.
        case tile(String, MenuPaint)
        /// A branch's or an action's symbol in the colour.
        case symbol(String, MenuPaint)
    }

    /// The row's icon, first match wins: an app's own; the icon of the app the row belongs to, badged when it is an
    /// action; an image's, PDF's or video's thumbnail once made (FileThumbnails); a file's own as Finder shows it (Sven, 2026-10-07), either badged when found by its words, and an app Remove lists; a Stickers picture its thumbnail (a GIPHY one animated), else its file's icon; a package's box; else its look, on a tile inside a branch (`tiled`) and as a symbol
    /// elsewhere.
    @MainActor func art(tiled: Bool) -> Art? {
        if case .app(let bundle) = target, let icon = AppsModule.icon(bundle: bundle) { return .icon(icon, badge: nil) }
        if let app, let icon = AppsModule.icon(bundle: app) { return .icon(icon, badge: kind.tab == .action ? actionGlyph : nil) }
        if case .sticker(.image(let path)) = target, let picture = AppsModule.thumbnail(path) { return .icon(picture, badge: nil) }
        if case .sticker(.giphy(let gif)) = target, let picture = AppsModule.webThumbnail(gif.id) { return .icon(picture, badge: nil) }
        let words = matchedWords == nil ? nil : "text.viewfinder"
        if case .file(let path) = target, let picture = FileThumbnails.shared.image(path) {
            return .icon(picture, badge: words)
        }
        if let path = target.filePath { return .icon(AppsModule.icon(file: path), badge: words) }
        if let icon { return Self.art(icon, tiled: tiled) }
        if kind == .package { return .tile("shippingbox", .tint(.good)) }
        guard let look else { return nil }
        return tiled ? .tile(look.symbol, look.colour) : .symbol(look.symbol, look.colour)
    }

    /// A MenuIcon drawn: the app at its path or with its bundle id when that app is on the Mac, else its glyph in its
    /// role, on a tile inside a branch (`tiled`) and bare elsewhere.
    @MainActor static func art(_ icon: MenuIcon, tiled: Bool, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Art {
        if let image = icon.appImage(exists: exists) { return .icon(image, badge: nil) }
        return tiled ? .tile(icon.symbol, .tint(icon.tint)) : .symbol(icon.symbol, .tint(icon.tint))
    }

    /// A row's symbol and colour; nil for an app or an emoji, which draw their own. A branch its look; an action its row
    /// in `actionLooks`, else its module's glyph in the module's colour (BindsKeyboard's six, as Binds colours them); a
    /// row of a branch's own (a cache Clean lists, a translation) its branch's look.
    private var look: (symbol: String, colour: MenuPaint)? {
        switch target {
        case .branch(let b): return (b.look.symbol, .module(b.look.colour))
        case .searchFiles: return ("magnifyingglass", .module(0))
        case .searchWeb: return ("globe", .module(0))
        case .searchInstall: return (MenuBranch.homebrew.look.symbol, .module(MenuBranch.homebrew.look.colour))
        case .window: return ("macwindow", .module(0))
        case .app, .emoji: return nil
        case .ask: return Self.actionLook("ai.ask").map { ($0.symbol, .tint($0.tint)) }
        case .action(let id):
            if let look = Self.actionLook(id) { return (look.symbol, .tint(look.tint)) }
            let module = BindsKeyboard.module(String(id.prefix { $0 != "." }))
            return (Self.moduleGlyphs[module], .module(module))
        default:
            let look = home?.look
            return (look?.symbol ?? "bolt", .module(look?.colour ?? 0))
        }
    }

    /// Each action's tile by id: the Tabler icon's nearest SF Symbol and its role. System's after Omarchy's System menu
    /// (mockup B); Trigger's and Capture's after mockup A; Install's Make a web app after the Web apps page's
    /// New web app block. A table, not a switch: an action added later wears its module's glyph until it has a row here.
    private static let actionLooks: [String: (symbol: String, tint: Tint)] = [
        "extensions.catalogue": ("bag", .accent),
        "system.lock": ("lock", .neutral), "system.lockKeyboard": ("lock.rectangle", .neutral), "system.sleep": ("moon", .accent), "system.restart": ("arrow.triangle.2.circlepath", .amber),
        "system.shutDown": ("power", .problem), "system.logOut": ("rectangle.portrait.and.arrow.right", .neutral), "system.ejectAll": ("eject", .neutral),
        "system.darkMode": ("circle.lefthalf.filled", .second), "system.keepAwake": ("cup.and.saucer", .amber),
        "system.nightShift": ("sun.min", .amber), "system.idleLock": ("hourglass", .neutral),
        "system.wifi": ("wifi", .accent), "system.bluetoothSettings": ("dot.radiowaves.left.and.right", .accent),
        "system.displaySettings": ("display", .third), "system.rotateDisplay": ("rotate.right", .third), "system.focusSettings": ("moon.stars", .second),
        "workspaces.rescue": ("lifepreserver", .good), "system.killProcess": ("xmark.circle", .problem),
        "system.speedTest": ("gauge.with.dots.needle.67percent", .third),
        "system.activityMenu": ("cpu", .problem), "system.statsMenu": (AppPage.stats.symbol, .amber),
        "apps.emoji": ("face.smiling", .amber), "apps.clipboard": ("list.clipboard", .good),
        "captures.area": ("rectangle.dashed", .accent), "captures.activeWindow": ("macwindow.on.rectangle", .third),
        "captures.fullscreen": ("rectangle.inset.filled", .second), "captures.scrolling": ("arrow.up.and.down.text.horizontal", .good),
        "captures.screenRecording": ("record.circle", .problem), "captures.pauseRecording": ("pause.circle", .problem), "captures.editLast": ("pencil.tip.crop.circle", .accent), "captures.pinLast": ("pin", .accent), "captures.editVideo": ("film", .accent), "captures.restoreThumbnail": ("photo.stack", .accent), "captures.toggleDesktopIcons": ("menubar.dock.rectangle", .second), "captures.repeatArea": ("arrow.counterclockwise.circle", .accent), "captures.delayed": ("timer", .second), "captures.scrollingUp": ("arrow.up.to.line.compact", .good), "captures.ocr": ("text.viewfinder", .amber),
        "captures.smartElement": ("square.dashed.inset.filled", .accent), "captures.subject": ("person.crop.rectangle", .third),
        "captures.markup": ("pencil.and.scribble", .accent), "captures.pickColour": ("eyedropper.halffull", .second),
        "captures.makeQR": ("qrcode", .accent), "captures.readQR": ("qrcode.viewfinder", .good),
        "captures.readQRScreen": ("viewfinder", .good),
        "apps.webApp": ("link", .accent), "apps.reports": ("doc.text.magnifyingglass", .third), "ai.ask": ("sparkles", .accent), "ai.chat": ("bubble.left.and.text.bubble.right", .accent), "ai.fix": ("wand.and.stars", .second),
        // Windows' own (card agent-bo-95423004: no glyph shared by rows that do different things).
        "windows.toggleFloat": ("square.on.square", .second), "windows.toggleFloatWorkspace": ("square.stack.3d.up", .second),
        "windows.minimise": ("minus.square", .neutral), "windows.flipSplit": ("rectangle.split.2x1", .third),
        "windows.toggleScrolling": ("rectangle.split.3x1.fill", .third), "windows.cycleColumnWidth": ("arrow.left.and.right.square", .accent),
        "windows.cycleColumnWidthBack": ("arrow.uturn.left.square", .accent), "windows.centreColumn": ("align.horizontal.center", .second),
        "windows.maximiseColumn": ("arrow.up.left.and.arrow.down.right.square", .accent), "windows.leaveStack": ("square.split.2x1", .second),
        "windows.focusNext": ("arrow.right.circle", .accent),
        "windows.focusPrevious": ("arrow.left.circle", .accent), "windows.resetLayout": ("arrow.uturn.backward.square", .amber),
        "windows.balance": ("equal.square", .good), "windows.closeOthers": ("xmark.rectangle", .problem),
        "windows.showDesktop": ("desktopcomputer", .neutral),
        "windows.fullscreen": ("arrow.up.left.and.arrow.down.right", .accent), "windows.close": ("xmark.square", .problem),
        "windows.closeAll": ("xmark.app", .problem), "windows.cycle": ("arrow.2.squarepath", .second),
        // Workspaces'.
        "workspaces.toggleGaps": ("squareshape.split.2x2.dotted", .third), "workspaces.cycleLayout": ("rectangle.3.offgrid", .accent),
        "workspaces.saveSnapshot": ("camera", .good), "workspaces.restoreSnapshot": ("clock.arrow.circlepath", .amber),
        "workspaces.next": ("chevron.right.2", .accent),
        "workspaces.previous": ("chevron.left.2", .accent),
        // Media and notifications.
        "media.volumeUp": ("speaker.plus", .good), "media.volumeDown": ("speaker.minus", .amber), "media.mute": ("speaker.slash", .neutral),
        "media.playPause": ("playpause", .accent), "media.next": ("forward", .second), "media.previous": ("backward", .second),
        "system.missionControl": ("rectangle.3.group", .third), "system.soundSettings": ("speaker.wave.2", .second),
        "system.wifiSettings": ("wifi.circle", .accent), "system.clearNotification": ("bell.slash", .neutral),
        "system.clearAllNotifications": ("bell.badge.slash", .problem), "system.openNotification": ("bell.badge", .amber),
        "system.translationLanguages": ("character.bubble", .third),
        // Apps' and captures' own tools.
        "apps.launcher": ("magnifyingglass", .accent), "apps.appsMenu": ("square.grid.3x3", .second), "apps.lazygit": ("arrow.triangle.branch", .amber),
        "apps.generatePassword": ("dice", .good), "apps.clipboardOptionV": ("doc.on.clipboard", .good),
        // The apps a bind opens, as Home's keyboard draws them (Moody: Learn showed four Apps grids).
        "apps.terminal": ("terminal", .neutral), "apps.files": ("folder", .accent),
        "apps.editor": ("chevron.left.forwardslash.chevron.right", .third), "apps.passwords": ("key", .amber),
        // Pilot's own.
        "engine.hyper": ("command", .accent), "engine.openWindow": ("macwindow.badge.plus", .accent), "engine.sheet": ("keyboard", .second),
        "engine.topBar": ("menubar.rectangle", .third),
    ]

    /// An action's tile: its row in the table; a sound output (`system.output:<id>`) a speaker.
    private static func actionLook(_ id: String) -> (symbol: String, tint: Tint)? {
        if id.hasPrefix("system.output:") { return ("hifispeaker", .problem) }
        // Workspace N: its number on a square, going there outlined, sending a window there filled.
        if let n = id.split(separator: ":").last.flatMap({ Int($0) }), (0...50).contains(n) {
            if id.hasPrefix("workspaces.go:") { return ("\(n).square", .accent) }
            if id.hasPrefix("workspaces.move:") { return ("\(n).square.fill", .second) }
        }
        if let look = actionLooks[id] { return look }
        // A direction: focus an arrow, move an arrow to its edge, resize the arrows out.
        let lower = id.lowercased()
        for (word, arrow) in [("left", "left"), ("right", "right"), ("up", "up"), ("down", "down")] where lower.hasSuffix(word) {
            if lower.contains("focus") { return ("arrow.\(arrow)", .accent) }
            if lower.contains("move") || lower.contains("swap") { return ("arrow.\(arrow).to.line", .second) }
            if lower.contains("resize") || lower.contains("grow") || lower.contains("shrink") {
                return (arrow == "left" || arrow == "right" ? "arrow.left.and.right" : "arrow.up.and.down", .amber)
            }
        }
        return nil
    }

    /// Every action id with its own glyph in the table, for the tests that hold it to one meaning per glyph.
    static var tabledActions: [String] { Array(actionLooks.keys) }
    /// An action's glyph, or nil when it wears its module's.
    static func actionSymbol(_ id: String) -> String? { actionLook(id)?.symbol }
    /// An action's glyph, else its module's, as its row wears it (the ring's wedges, P74).
    static func symbol(forAction id: String) -> String {
        actionSymbol(id) ?? moduleGlyphs[BindsKeyboard.module(String(id.prefix { $0 != "." }))]
    }

    /// The glyph of each of Binds' six modules: Apps, Windows, Workspaces, Captures, System, Pilot.
    private static let moduleGlyphs = ["square.grid.2x2", "macwindow", "rectangle.split.3x1", "camera.viewfinder", "gearshape", "command"]

    /// The glyph on an app action's badge: an app command's own (P38), else by the verb its shown title starts with
    /// (mockup C: Search vault a magnifier, Fill login a form, Lock all vaults a lock); a bolt for a verb the table lacks.
    private static let verbGlyphs: [String: String] = [
        "search": "magnifyingglass", "find": "magnifyingglass", "fill": "rectangle.and.pencil.and.ellipsis",
        "lock": "lock", "unlock": "lock.open", "password": "key", "generate": "key", "forget": "eraser", "clear": "eraser",
        "open": "arrow.up.forward.app", "new": "plus", "add": "plus", "copy": "doc.on.doc", "paste": "doc.on.clipboard",
        "close": "xmark", "quit": "xmark", "delete": "trash", "remove": "trash", "reload": "arrow.clockwise",
        "refresh": "arrow.clockwise", "sync": "arrow.triangle.2.circlepath", "use": "paintbrush", "apply": "paintbrush",
        "play": "play", "pause": "pause", "share": "square.and.arrow.up", "save": "square.and.arrow.down",
        "settings": "gearshape", "preferences": "gearshape",
    ]

    private var actionGlyph: String {
        if kind == .command, let icon { return icon.symbol }
        return Self.verbGlyphs[shownTitle.prefix { $0 != " " }.lowercased()] ?? "bolt"
    }
}

/// Where the scrolled actions are cut off: above once scrolled down, below until the last one shows.
struct Cut: Equatable {
    var above = false, below = true

    init() {}
    init(_ scroll: ScrollGeometry) {
        above = scroll.visibleRect.minY > 1
        below = scroll.visibleRect.maxY < scroll.contentSize.height - 1
    }

    /// The scrolled actions between two markers, the list's very top and end, which `scroll` brings into view.
    @MainActor static func ends(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).id(top)
            content()
            Color.clear.frame(height: 0).id(end)
        }
    }
    private static let top = "cut.top", end = "cut.end"

    /// Brings the current action, `new`, clear of the fades as it moved from `old`: the neighbour past it the way it moved
    /// shows too, and the first or the last brings the list's very top or end, so nothing is cut there and no fade or
    /// chevron draws over it (B3, Sven 2026-10-09: the last action, Set Hyper bind, sat under the bottom fade).
    @MainActor static func scroll<ID: Hashable>(_ proxy: ScrollViewProxy, from old: Int?, to new: Int?, in visible: [ID]) {
        guard let old, let new, visible.indices.contains(new) else { return }
        if new == visible.count - 1 { return proxy.scrollTo(end, anchor: .bottom) }
        if new == 0 { return proxy.scrollTo(top, anchor: .top) }
        proxy.scrollTo(visible[new + (new > old ? 1 : -1)])
    }

    /// The chevron in a cut edge's clear strip.
    @MainActor static func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity).frame(height: strip).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// The clear strip at a cut edge that holds the chevron, and the fade inside it.
    static let strip: CGFloat = 14, fade: CGFloat = 16

    /// The scroll's mask: whole, and at an edge with more past it a clear strip for the chevron with a fade inside it,
    /// so a row half under the edge fades out instead of being sliced.
    struct Fade: View {
        let cut: Cut
        var body: some View {
            VStack(spacing: 0) {
                if cut.above {
                    Color.clear.frame(height: strip)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                }
                Color.black
                if cut.below {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
                    Color.clear.frame(height: strip)
                }
            }
        }
    }
}

extension RowActionsMenu.Choice {
    /// An extension row's own actions come first, as one group; Pilot's keep theirs.
    var group: Int { if case .row(let action) = self { action.group } else { -1 } }
    var danger: Bool { if case .row(let action) = self { action.danger } else { false } }
    func symbol(on row: MenuEntry) -> String { if case .row(let action) = self { action.symbol(on: row) } else { "bolt" } }
    /// An extension action's key as the row names it ("⌘E", To-do B); nil for Pilot's and for one with none.
    func key(on row: MenuEntry) -> String? {
        guard case .own(let index, _) = self, let keys = row.ownKeys, keys.indices.contains(index) else { return nil }
        return keys[index]?.symbol
    }
}

extension RowAction {
    /// Mockup C's groups: what Return or a pick does; copying; favourites, ranking and alias; quitting or removing.
    var group: Int {
        switch self {
        case .open, .openWith, .convert, .run, .focus, .install, .showInFinder, .searchInside, .setBind, .changeLanguages, .openApp: 0
        case .copyPath, .copyBundleID, .copyTitle, .copyID: 1
        case .favourite, .unfavourite, .resetRanking, .setAlias: 2
        case .quit, .forceQuit, .uninstall, .trash: 3
        }
    }

    /// Force quit, Uninstall and Move to Trash, set in red.
    var danger: Bool { [.forceQuit, .uninstall, .trash].contains(self) }

    func symbol(on row: MenuEntry) -> String {
        switch self {
        case .open: row.kind == .file ? "doc" : row.kind == .branch ? "arrow.right.circle" : "macwindow"
        case .focus: "macwindow"
        case .run: "play"
        case .install: "arrow.down.circle"
        case .showInFinder: "folder"
        case .setBind: "command"
        case .copyPath, .copyBundleID, .copyTitle, .copyID: "doc.on.doc"
        case .favourite: "star"
        case .unfavourite: "star.slash"
        case .resetRanking: "arrow.counterclockwise"
        case .setAlias: "character.cursor.ibeam"
        case .quit: "xmark"
        case .forceQuit: "xmark.circle"
        case .uninstall, .trash: "trash"
        case .openWith, .openApp: "arrow.up.forward.app"
        case .convert: "arrow.triangle.2.circlepath"
        case .searchInside: "magnifyingglass"
        case .changeLanguages: "character.bubble"
        }
    }
}
