import AppKit
import Observation
import PilotCore
import SwiftUI
import WebKit

/// Each widget as it will look before it is added (Sven, 1.0.2: "widgets should have a preview before we add them to
/// desktop so someone adding knows how they would look"): its own tile in the style and Glass of the moment. A blocks
/// widget's tile is drawn live, read once as the Widgets page opens: its readings, its notes, the repos (git's last read
/// if under a minute old), its note's text, the Launcher's tiles, its buttons; no command runs for a look (a desk page's feed may reach the network or an extension
/// before anything is added). A locked widget shows the Trust to run card the desktop would. A page is a picture, at
/// its content's height as the desktop fits it: the one the desktop or Home last drew (kept as it drew its data), else
/// one of Pilot's desk pages fed by readings or a setting, loaded once in the desk pages' shared WebContent
/// (WidgetWebView), fed once and snapshotted, then ended, one at a time; until it has one, a page's tile is the kit's
/// panel with a line saying it draws once placed, as a command widget's says, so every preview wears one frame (Sven,
/// build 7: some looked glass, some clear). Pictures are kept for the theme they were taken in, at the size the card
/// draws them, while Pilot runs.
@Observable @MainActor
final class WidgetPreviews {
    static let shared = WidgetPreviews()

    /// The tiles by widget id, as the last load drew them.
    var models: [String: WidgetTileModel] = [:]
    /// A page's picture by widget id, in `shotsTheme`.
    var shots: [String: NSImage] = [:]
    @ObservationIgnored private var shotsTheme = ""
    /// Pictures being taken of a desk or Home page, by widget id.
    @ObservationIgnored private var taking: Set<String> = []
    /// The see-through tile a page's picture sits on, as a page sits on its tile on the desktop.
    static let pageGround: WidgetTileModel = { let model = WidgetTileModel(); model.page = true; return model }()

    /// Each widget's tile as it shows before any data, read again each time the page opens (an installed widget may
    /// have changed); `load` fills them.
    @discardableResult func prepare(_ widgets: [Widget], store: WidgetStore) -> [(Widget, WidgetTileModel)] {
        let tiles = widgets.map { ($0, Self.tile($0, store: store)) }
        models = Dictionary(tiles.map { ($0.0.id, $0.1) }) { a, _ in a }
        return tiles
    }

    /// What a tile shows before its data: title, its buttons and the Launcher's tiles at their defaults, the Trust card
    /// when it would run but is locked, a line for a command or an extension page it shows once placed.
    static func tile(_ widget: Widget, store: WidgetStore) -> WidgetTileModel {
        let model = WidgetTileModel()
        model.show(widget, values: defaults(widget))
        if WidgetAsks.runsOnShow(widget), !store.trust(of: widget).runs { model.locked = widget; return model }
        if widget.draw == .html {
            model.message = ReadyWidgets.isDesk(widget) && drawsUnplaced(widget) ? "Drawing its preview…"
                : "Its page draws once it is on the desktop or Home."
            return model
        }
        if widget.id == ReadyWidgets.folder { model.folder = WidgetFolder.sample() }
        switch widget.data {
        case .command: model.message = "It shows what its command prints, once it is on the desktop or Home."
        case .extensionPage(let id): model.message = "It shows extension \(id)'s page, once it is on the desktop or Home."
        case .markets: WidgetMarkets.preview(model, values: defaults(widget))
        case .none where model.grid.isEmpty && model.tiles.isEmpty: model.message = widget.description
        default: break
        }
        return model
    }

    /// Its settings at their defaults, as a new placement starts with them.
    private static func defaults(_ widget: Widget) -> [String: JSONValue] {
        Dictionary(widget.settings.compactMap { field in field.initial.map { (field.name, $0) } }) { a, _ in a }
    }

    /// The preview's tiles go with the page; the pictures stay, small, for its next open.
    func drop() { models = [:] }

    /// A desk or Home page that just drew its data: its picture is kept for the Widgets page, once a theme, so a placed
    /// page previews as it last looked though its panel has hidden since.
    func remember(_ id: String, _ page: WidgetWebView) {
        let theme = Look.shared.theme.id
        if theme != shotsTheme { (shots, shotsTheme) = ([:], theme) }
        guard shots[id] == nil, taking.insert(id).inserted else { return }
        Task { [weak self, weak view = page.view] in
            // Once the page has drawn its data and the desk has fitted it.
            try? await Task.sleep(for: .seconds(1))
            defer { self?.taking.remove(id) }
            guard let view, view.window != nil, Look.shared.theme.id == theme,
                  let shot = await Self.snapshot(view, width: 240), let self, self.shotsTheme == theme else { return }
            self.shots[id] = self.shots[id] ?? shot
        }
    }

    /// Reads what each blocks tile shows and takes each page's picture not taken yet in this theme, one at a time; a
    /// cancel (the page closed) stops it, and a page being snapshotted ends with it.
    func load(_ widgets: [Widget], store: WidgetStore) async {
        let theme = Look.shared.theme.id
        if theme != shotsTheme { (shots, shotsTheme) = ([:], theme) }
        let tiles = prepare(widgets, store: store)
        let readings = Array(Set(widgets.flatMap { widget -> [Widget.Reading] in
            if case .reading(let r) = widget.data { r } else { [] }
        }))
        // Every reading once, after a moment's watch for the sampler's; each tile takes its own from them.
        let held = Task { await WidgetReadings.watch(readings) }
        defer { held.cancel() }
        if readings.contains(where: { [.cpu, .memory, .network].contains($0) }) { try? await Task.sleep(for: .milliseconds(1200)) }
        var read: [String: JSONValue] = [:]
        for reading in readings { read[reading.rawValue] = await WidgetReadings.data(reading) }
        let notes = widgets.contains { if case .notes = $0.data { true } else { false } } ? await WidgetNotes.read(WidgetNotes.folder) : []
        let repos = widgets.contains { $0.data == .repos } ? await WidgetRepos.read() : []
        for (widget, model) in tiles where model.locked == nil && widget.draw == .blocks {
            guard !Task.isCancelled else { return }
            let values = Self.defaults(widget)
            switch widget.data {
            case .reading(let readings):
                let data = readings.count == 1 ? read[readings[0].rawValue] ?? .object([:]) : .object(read.filter { key, _ in readings.contains { $0.rawValue == key } })
                model.blocks = WidgetReadings.blocks(readings, data)
            case .notes(let name): model.blocks = WidgetNotes.blocks(notes, picked: values[name]?.string ?? "").blocks
            case .repos: model.blocks = WidgetRepos.blocks(repos)
            case .ci: model.blocks = WidgetCI.preview()
            case .github: await WidgetGitHub.preview(model, user: WidgetGitHub.user(values[WidgetGitHub.userName]))
            case .nowPlaying: model.nowPlaying = await NowPlaying.preview()
            case .setting(let name):
                let text = values[name]?.string ?? ""
                model.blocks = [.markdown(text.isEmpty ? "–" : text)]
            default: break
            }
        }
        for (widget, model) in tiles where widget.draw == .html && model.locked == nil && shots[widget.id] == nil {
            guard !Task.isCancelled else { return }
            if let shot = await Self.shot(widget, store: store), !Task.isCancelled, Look.shared.theme.id == theme { shots[widget.id] = shot }
        }
    }

    /// A page's picture: the one the desktop or Home shows now, else one of Pilot's desk pages fed by readings or a
    /// setting (or `data`, a render's), loaded offscreen in the shared WebContent, fed once and fitted to its content's
    /// height as the desk fits it; nil for any other page not showing.
    static func shot(_ widget: Widget, store: WidgetStore, data given: JSONValue? = nil) async -> NSImage? {
        // The card's box draws it at most 240 points wide.
        let width = min(widget.size.width, 240)
        if given == nil, let live = WidgetDesk.shared.livePage(of: widget.id) { return await snapshot(live.view, width: width) }
        guard ReadyWidgets.isDesk(widget), given != nil || Self.drawsUnplaced(widget), let page = WidgetWebView(widget: widget, store: store) else { return nil }
        defer { page.end() }
        // Its default size's class, as a new placement draws it, however tall its content fits it.
        page.fixed = CGSize(width: widget.size.width, height: widget.size.height)
        // Never ordered in: it draws on no screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: widget.size.width, height: widget.size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        defer { window.close() }
        page.view.frame = NSRect(x: 0, y: 0, width: widget.size.width, height: widget.size.height)
        window.contentView = page.view
        for _ in 0..<60 where page.view.isLoading || page.view.url == nil {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        switch (given, widget.data) {
        case (let data?, _): page.send(data)
        case (nil, .reading(let readings)): page.send(await WidgetReadings.data(readings))
        case (nil, .setting(let name)): page.send(.object([name: .string(defaults(widget)[name]?.string ?? "")]))
        default: break
        }
        try? await Task.sleep(for: .milliseconds(400))
        // Its content's height, as the desk fits a desk page (PilotKit.height), so its card ends where the page's does.
        let height = try? await page.view.callAsyncJavaScript("return window.PilotKit && PilotKit.height ? PilotKit.height() : 0",
                                                              contentWorld: .page) as? Double
        if let height, height > 0 {
            let fitted = NSSize(width: widget.size.width, height: Widget.Size.clamp(height))
            window.setContentSize(fitted)
            page.view.frame = NSRect(origin: .zero, size: fitted)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Task.isCancelled ? nil : await snapshot(page.view, width: width)
    }

    /// Whether a desk page draws before it is placed: fed by readings or a setting, nothing run.
    static func drawsUnplaced(_ widget: Widget) -> Bool {
        switch widget.data { case .reading, .setting: true; default: false }
    }

    private static func snapshot(_ view: WKWebView, width: Double) async -> NSImage? {
        let config = WKSnapshotConfiguration()
        config.rect = view.bounds
        config.snapshotWidth = NSNumber(value: width)
        return try? await view.takeSnapshot(configuration: config)
    }
}

/// A widget's preview on its card: its tile at its own size, scaled to fit, on the theme's wallpaper colours so Glass
/// shows what it sits on; a page's picture over its tile, or a line until there is one.
struct WidgetPreview: View {
    let widget: Widget
    let model: WidgetTileModel
    let shot: NSImage?
    var look: Look = .shared
    var height: CGFloat = 150

    var body: some View {
        // A page's picture at its own height, which the desk fitted to its content.
        let size = shot.map { CGSize(width: widget.size.width, height: widget.size.width * $0.size.height / max($0.size.width, 1)) }
            ?? CGSize(width: widget.size.width, height: widget.size.height)
        GeometryReader { box in
            let scale = min(1, (box.size.width - 16) / size.width, (height - 16) / size.height)
            tile
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(width: box.size.width, height: height)
        }
        .frame(height: height)
        .background(Self.ground(look.theme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityLabel("Preview of \(widget.title)")
    }

    /// One frame for every kind: the kit's panel on its tile, or a page's picture, which draws the kit's panel itself,
    /// on the see-through tile a page has on the desktop.
    @ViewBuilder private var tile: some View {
        if let shot, model.locked == nil {
            WidgetTile(model: WidgetPreviews.pageGround, look: look).styled(.hud)
                .overlay { Image(nsImage: shot).resizable().interpolation(.high) }
        } else {
            WidgetTile(model: model, look: look).styled(.hud)
        }
    }

    /// The theme's wallpaper colours, as the kit sheet draws them.
    static func ground(_ theme: PilotTheme) -> LinearGradient {
        LinearGradient(colors: [Color(hex: theme.wallpaper.base), Color(hex: theme.wallpaper.glow, opacity: theme.dark ? 0.55 : 0.4), Color(hex: theme.wallpaper.base)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
