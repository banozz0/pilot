import AppKit
import Observation
import SwiftUI

/// Whether the top bar's Other apps are unfolded (card agent-bo-95423018): folded at first, a click on the chevron
/// toggles them, and they fold again `foldAfter` once the pointer leaves the drawer; back inside first, they stay.
@Observable @MainActor
final class MenuAppsDrawer {
    static let foldAfter: Duration = .seconds(5)

    private(set) var isOpen = false
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var folding: Task<Void, Never>?

    init(sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) { self.sleep = sleep }

    /// A click on the chevron.
    func toggle() {
        stopFolding()
        isOpen.toggle()
    }

    /// The pointer entered or left the drawer: leaving an open one starts its fold, entering stops it.
    func pointer(inside: Bool) {
        stopFolding()
        guard !inside, isOpen else { return }
        folding = Task { [sleep] in
            await sleep(Self.foldAfter)
            guard !Task.isCancelled else { return }
            withAnimation(Self.animation) { isOpen = false }
        }
    }

    private func stopFolding() {
        folding?.cancel()
        folding = nil
    }

    /// The drawer's slide (better-ui: a spring of 0.3 s, no bounce), none with Reduce Motion on, for a click and the fold.
    static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.3, bounce: 0)
    }
}

/// What an app's item looks like in the drawer: its status item's own picture, a template drawn in the bar's glyph colour
/// as the macOS menu bar draws it. Pilot never pictures another app's item (no Screen Recording), so the picture comes
/// from the app's bundle: a symbol for Apple's own menu bar agents, else the menu-bar-sized template image the bundle ships
/// whose name most says status item (its asset catalog's and its loose files'), else the app's icon in full colour. Keying
/// the mark out of the icon drew grey boxes and stray letters (Sven, 2026-10-10). Read once per app.
@MainActor
enum MenuAppGlyph {
    enum Glyph {
        case symbol(String)
        case template(NSImage)
        case icon(NSImage?)

        var isTemplate: Bool { if case .icon = self { false } else { true } }
    }

    /// Apple's menu bar agents, whose app icons say nothing. Never switch.2 for Control Centre: that is its own button,
    /// which Pilot leaves out (MenuApps.menuBarOnly), so its other items (Sound, Display) drawn so read as the button (P44).
    static let symbols: [String: String] = [
        "com.apple.controlcenter": "square.grid.2x2.fill",
        "com.apple.TextInputMenuAgent": "keyboard",
        "com.apple.Spotlight": "magnifyingglass",
        "com.apple.systemuiserver": "menubar.rectangle",
    ]

    /// Words a status item image's name carries, and words that mark another platform's or another state's.
    static let statusWords = ["status", "menubar", "menuicon", "menuextra", "tray"]
    static let otherPlatform = ["windows", "win32", "linux"]
    static let otherState = ["dimmed", "off", "error", "animated", "update", "disabled", "alert", "warning"]

    /// The heights a menu bar picture comes in, in points: anything else is a toolbar, a menu or a window's image.
    static let menuBarHeights: ClosedRange<CGFloat> = 12...24
    /// How tall an app icon stands in for a picture: a status item's glyph height.
    static let iconSize: CGFloat = 16

    static func of(_ app: MenuExtrasApp) -> Glyph {
        guard let bundle = app.bundleId else { return .icon(nil) }
        if let cached = cache[bundle] { return cached }
        let glyph: Glyph = symbols[bundle].map(Glyph.symbol)
            ?? AppsModule.url(forBundle: bundle).flatMap { template(at: $0, app: app.name) }.map(Glyph.template)
            ?? .icon(AppsModule.icon(bundle: bundle))
        cache[bundle] = glyph
        return glyph
    }

    private static var cache: [String: Glyph] = [:]

    /// The app's own words in its name, a plural's s dropped ("Reminders MenuBar" names its icon-reminder-1).
    static func words(_ app: String) -> [String] {
        app.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }
    }

    /// How much `name` says it is the status item's picture of the app whose `words` are given, 0 for not at all.
    static func score(_ name: String, words: [String]) -> Int {
        let n = name.lowercased()
        guard !otherPlatform.contains(where: n.contains) else { return 0 }
        let score = (statusWords.contains(where: n.contains) ? 3 : 0) + (words.contains(where: n.contains) ? 2 : 0)
            + (n.hasSuffix("template") ? 1 : 0)
        return score == 0 ? 0 : score - (otherState.contains(where: n.contains) ? 1 : 0)
    }

    /// The bundle's status item picture as a template: of its asset catalog's images and its loose ones (Resources and
    /// three folders down, as Electron apps keep their tray icons), the best named (`score`, then the shortest name) that
    /// is a template or one colour, at a menu bar height.
    static func template(at url: URL, app: String) -> NSImage? {
        guard let bundle = Bundle(url: url) else { return nil }
        var loaders: [String: () -> NSImage?] = [:]
        for name in catalogNames(bundle) { loaders[name] = { bundle.image(forResource: name) } }
        for (name, file) in looseImages(bundle) where loaders[name] == nil { loaders[name] = { loose(file, name: name) } }
        let own = words(app)
        let ranked = loaders.keys.map { (name: $0, score: score($0, words: own)) }.filter { $0.score > 0 }
            .sorted { ($0.score, -$0.name.count, $1.name) > ($1.score, -$1.name.count, $0.name) }
        for (name, _) in ranked {
            guard let image = loaders[name]?(), menuBarHeights.contains(image.size.height) else { continue }
            if image.isTemplate { return image }
            if isOneColour(image), let copy = image.copy() as? NSImage {
                copy.isTemplate = true
                return copy
            }
        }
        return nil
    }

    /// The image names in the bundle's asset catalog. CoreUI's catalog is the one way to list them (NSBundle only finds
    /// a name it is given); asked only if it still answers, else none.
    static func catalogNames(_ bundle: Bundle) -> [String] {
        let catalog: AnyObject? = NSClassFromString("CUICatalog")
        let forBundle = NSSelectorFromString("defaultUICatalogForBundle:")
        guard let catalog, catalog.responds(to: forBundle),
              let found = catalog.perform(forBundle, with: bundle)?.takeUnretainedValue() as? NSObject,
              found.responds(to: NSSelectorFromString("allImageNames")) else { return [] }
        return found.value(forKey: "allImageNames") as? [String] ?? []
    }

    /// The loose images under Resources by name (a @2x or @3x file under its plain name), skipping localisations,
    /// nested apps and Electron's archive.
    static func looseImages(_ bundle: Bundle) -> [String: URL] {
        guard let resources = bundle.resourceURL,
              let walk = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        var found: [String: URL] = [:]
        for case let file as URL in walk {
            let ext = file.pathExtension.lowercased()
            if walk.level > 3 || ["lproj", "app", "asar", "unpacked", "framework"].contains(where: ext.hasSuffix) {
                walk.skipDescendants()
                continue
            }
            guard ["png", "pdf", "tiff", "tif"].contains(ext) else { continue }
            let base = file.deletingPathExtension().lastPathComponent
            let name = base.replacingOccurrences(of: "@2x", with: "").replacingOccurrences(of: "@3x", with: "")
            // The plain file over its @2x and @3x: its size is the one in points.
            if found[name] == nil || name == base { found[name] = file }
        }
        return found
    }

    /// A loose file at its size in points (a @2x or @3x file alone is that many pixels per point), a template when its
    /// `name` (@2x and @3x taken off) says so, as NSImage(named:) reads one.
    private static func loose(_ file: URL, name: String) -> NSImage? {
        guard let image = NSImage(contentsOf: file) else { return nil }
        image.isTemplate = name.hasSuffix("Template")
        let base = file.deletingPathExtension().lastPathComponent
        let scale: CGFloat = base.hasSuffix("@3x") ? 3 : base.hasSuffix("@2x") ? 2 : 1
        if scale > 1, let rep = image.representations.first {
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        return image
    }

    /// Whether every pixel the image draws is one grey (black, white or between): a template in all but its flag, as
    /// Electron's tray icons are.
    nonisolated static func isOneColour(_ image: NSImage) -> Bool {
        let n = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var count = 0, low = 1.0, high = 0.0
        for i in 0..<(n * n) {
            let a = Double(data[i * 4 + 3])
            guard a > 128 else { continue }
            let r = Double(data[i * 4]) / a, g = Double(data[i * 4 + 1]) / a, b = Double(data[i * 4 + 2]) / a
            guard max(r, g, b) - min(r, g, b) < 0.1 else { return false }
            (count, low, high) = (count + 1, min(low, r), max(high, r))
        }
        return count > 4 && high - low < 0.15
    }
}

/// One app in the drawer or the settings' preview: its template glyph in the bar's glyph colour, as the macOS menu bar
/// tints a status item; else its app icon in full colour at the glyph's height; an app with neither shows its name.
struct MenuAppIcon: View {
    @Environment(\.style) private var style
    let glyph: MenuAppGlyph.Glyph
    /// Shown when the app has neither a glyph nor an icon.
    let name: String

    init(app: MenuExtrasApp) { self.init(glyph: MenuAppGlyph.of(app), name: app.name) }
    init(glyph: MenuAppGlyph.Glyph, name: String) { self.glyph = glyph; self.name = name }

    var body: some View {
        switch glyph {
        case .symbol(let name): Image(systemName: name).font(BarMetrics.glyph).foregroundStyle(ink)
        case .template(let image):
            // Drawn at its own size up to the menu bar's 18 pt, as macOS draws a status item.
            let scale = min(1, 18 / max(image.size.height, 1))
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: image.size.width * scale, height: image.size.height * scale).foregroundStyle(ink)
        case .icon(let icon?): Self.iconImage(icon)
        case .icon(nil): Text(name).lineLimit(1).foregroundStyle(ink)
        }
    }

    private var ink: Color { BarMetrics.glyphInk(style) }

    /// An app icon at the glyph's height.
    static func iconImage(_ icon: NSImage) -> some View {
        Image(nsImage: icon).resizable().interpolation(.high).frame(width: MenuAppGlyph.iconSize, height: MenuAppGlyph.iconSize)
    }
}
