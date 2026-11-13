import AppKit
import PilotCore
import SwiftUI

/// The pill's measures: look A, the macOS Dock at its best (design round 2, Sven 2026-11-13, Q207, over B Tray and C
/// Islands; `~/pages/pilot-dock-round2.html`). The height's parts are DockSize's.
enum DockPill {
    static let radius: CGFloat = 22
    /// The room at the pill's two ends.
    static let ends: CGFloat = 10
    /// The gap between icons, as a share of an icon, so a shrinking row keeps its rhythm.
    static let gapRatio = 0.125
    /// The screen's width less this each side is the widest the pill may be.
    static let sideMargin: CGFloat = 16
    /// The hover's coordinate space, DockView's box, which never moves on screen as the icons grow.
    static let space = "dock"
}

/// The dock on screen: the pill at rest, and while the pointer is over its icons a taller, wider box, so magnified icons
/// have room above the pill. Only the rest pill counts toward the tiler's room (DockSize.room); the box grows back to the
/// pill as the pointer leaves, so between hovers nothing over the windows below takes their clicks.
struct DockView: View {
    let dock: DockController
    let tiler: TilerService
    let observers: EngineObservers
    let sources: BarSources
    let store: BarItemsStore
    var extensionBar: ExtensionBar = .shared
    var calendar: DockCalendar = .shared
    /// Told the box's size as it changes, so its window fits it.
    var fit: (CGSize) -> Void = { _ in }
    /// The readers the widgets hold while they show.
    @State private var held: Set<BarKind> = []
    @State private var hovering = false
    @State private var rest: CGSize = .zero

    var body: some View {
        let size = dock.settings.size, widgets = dock.settings.widgets, options = dock.settings.options, magnify = dock.settings.magnify
        let kinds = DockWidgetSources.kinds(widgets, stats: options.stats), asked = DockWidgetSources.extensions(widgets)
        let reader = DockWidgetSources(sources: sources, extensionBar: extensionBar, calendar: calendar, options: options)
        let reach = size.reach(magnify)
        let byApp = Dictionary(grouping: tiler.windows, by: \.bundleId)
        let apps = DockController.apps(pins: dock.pins, running: dock.running, byApp: byApp, front: observers.focusedApp?.bundleIdentifier)
        // Each widget is a view of its own, so a reading's tick redraws its widget, not the pill.
        let left = dock.settings.widgets(on: .left), right = dock.settings.widgets(on: .right)
        DockStrip(size: size, apps: apps, hasWidgets: !right.isEmpty, maxWidth: DockWindow.widest(),
                  windows: { app in app.bundleID.flatMap { byApp[$0] } ?? [] }, tiler: tiler, dock: dock, style: dock.settings.style, magnify: magnify,
                  origin: hovering ? CGFloat(reach.width) / 2 : 0, onHover: { hovering = $0 },
                  leftWidgets: left.isEmpty ? nil : AnyView(ForEach(left, id: \.self) { slot in DockWidgetView(slot: slot, reader: reader, store: store, dock: dock) })) {
            ForEach(right, id: \.self) { slot in DockWidgetView(slot: slot, reader: reader, store: store, dock: dock) }
        }
            .environment(\.inTopBar, true)
            // The bar's Item colours, so a widget's warning and alert read as they do in the bar (amber, red), not
            // in the accent (the red Sven saw on Maple, whose accent is red; 2026-11-13).
            .environment(\.barItemColours, store.itemColours)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if !hovering { rest = $0 } }
            .frame(width: hovering ? rest.width + CGFloat(reach.width) : nil,
                   height: hovering ? rest.height + CGFloat(reach.height) : nil, alignment: .bottom)
            .coordinateSpace(.named(DockPill.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fit($0) }
            .styled(.topBar)
            .pilotTheme()
            .onAppear { hold(kinds, asked, widgets) }
            .onChange(of: widgets) { hold(kinds, asked, widgets) }
            .onChange(of: options) { hold(kinds, asked, widgets) }
            .onDisappear {
                sources.readings.hold([], replacing: &held)
                extensionBar.hold([], for: Self.holder)
                calendar.stop()
                DockExtras.shared.follow([], options: options)
            }
    }

    static let holder = "dock"

    /// The widgets' readers held, their extensions asked for the dock even where no bar places them, and Calendar read
    /// (never asked) while a Calendar widget shows.
    private func hold(_ kinds: Set<BarKind>, _ asked: Set<String>, _ widgets: [DockSlot]) {
        sources.readings.hold(kinds, replacing: &held)
        extensionBar.hold(asked, for: Self.holder)
        follow(widgets)
        DockExtras.shared.follow(widgets, options: dock.settings.options)
    }

    private func follow(_ widgets: [DockSlot]) {
        if widgets.contains(.widget(.nextEvent)) || widgets.contains(.widget(.timeline)) { calendar.follow(now: sources.readings.now) } else { calendar.stop() }
    }
}

/// The pill: the pins and running apps fitted to `maxWidth` (smaller down to 32 pt, then a scrolling row; never cut),
/// the Dock's hairline, then the widgets, on the top bar's Solid, Glass or Clear (round 4). Magnifies on hover at
/// `magnify`, unless the row scrolls or it is off.
struct DockStrip<Widgets: View>: View {
    @Environment(\.ink) private var ink
    let size: DockSize
    let apps: [DockApp]
    let hasWidgets: Bool
    /// The widest the pill may be: its screen's width less its margins.
    let maxWidth: CGFloat
    var windows: (DockApp) -> [AeroWindow] = { _ in [] }
    var tiler: TilerService?
    var dock: DockController?
    var style: TopBarBackground = .glass
    var magnify: DockMagnification = .medium
    /// What stands behind the pill; nil is the live ground (DockBacking). A render passes a stand-in on Glass, as glass
    /// draws nothing offscreen.
    var backing: ((AnyView) -> AnyView)?
    /// Where the rest pill starts in DockView's box: the hover is measured from there, so the bell stays put as icons grow.
    var origin: CGFloat = 0
    var onHover: (Bool) -> Void = { _ in }
    /// The widgets set on the left of the apps (Sven, 2026-11-13), behind their own hairline; nil with none there.
    var leftWidgets: AnyView? = nil
    @ViewBuilder let widgets: () -> Widgets
    @State private var hoverX: CGFloat?
    @State private var widgetsWidth: CGFloat = 0
    @State private var leftWidth: CGFloat = 0
    @State private var leaving: Task<Void, Never>?

    init(size: DockSize, apps: [DockApp], hasWidgets: Bool, maxWidth: CGFloat, windows: @escaping (DockApp) -> [AeroWindow] = { _ in [] },
         tiler: TilerService? = nil, dock: DockController? = nil, style: TopBarBackground = .glass, magnify: DockMagnification = .medium,
         backing: ((AnyView) -> AnyView)? = nil, origin: CGFloat = 0, onHover: @escaping (Bool) -> Void = { _ in },
         hoverApp: Int? = nil, leftWidgets: AnyView? = nil, @ViewBuilder widgets: @escaping () -> Widgets) {
        self.size = size; self.apps = apps; self.hasWidgets = hasWidgets; self.maxWidth = maxWidth; self.windows = windows
        self.tiler = tiler; self.dock = dock; self.style = style; self.magnify = magnify; self.backing = backing; self.origin = origin
        self.onHover = onHover; self.leftWidgets = leftWidgets; self.widgets = widgets
        let icon = CGFloat(size.icon), gap = (icon * DockPill.gapRatio).rounded()
        _hoverX = State(initialValue: hoverApp.map { CGFloat($0) * (icon + gap) + icon / 2 })
    }

    /// The hairline and the room either side of it.
    private static var hairline: CGFloat { 25 }

    /// The widest the widgets may be: what the icons leave at their smallest, and never under 40 % of the pill, so many
    /// widgets shrink the icons first, then scroll (Sven, 2026-11-13: never cut, the apps' rule).
    private var widgetsRoom: CGFloat {
        let n = CGFloat(apps.count), small = CGFloat(DockFit.smallest), gap = (small * DockPill.gapRatio).rounded()
        let icons = n > 0 ? n * small + (n - 1) * gap : 0
        let sides = CGFloat((hasWidgets ? 1 : 0) + (leftWidgets == nil ? 0 : 1))
        return max(maxWidth * 0.4, maxWidth - 2 * DockPill.ends - sides * (DockPill.ends + 2 + Self.hairline) - icons)
    }

    /// Each side's room: its own width while both fit the widgets' room, else that room shared by their widths, so the
    /// rule holds on each side: shrink, then scroll, never cut.
    private func room(_ width: CGFloat) -> CGFloat {
        let total = (hasWidgets ? widgetsWidth : 0) + (leftWidgets == nil ? 0 : leftWidth)
        return total <= widgetsRoom || total == 0 ? width : widgetsRoom * width / total
    }

    /// The left side's run before the icons: its end, its widgets as shown, and its hairline.
    private var leftRun: CGFloat { leftWidgets == nil ? 0 : DockPill.ends + 2 + min(leftWidth, room(leftWidth)) + Self.hairline }

    /// What the pill spends besides its icons: its ends, the hairlines and the widgets as they show.
    private var fixed: Double {
        Double(2 * DockPill.ends + leftRun + (hasWidgets ? Self.hairline + min(widgetsWidth, room(widgetsWidth)) + DockPill.ends + 2 : 0))
    }

    var body: some View {
        let fit = DockFit.fit(apps: apps.count, icon: size.icon, gapRatio: DockPill.gapRatio, fixed: fixed, available: Double(maxWidth))
        // Bottom-aligned: magnified icons grow upward, and the hairline and widgets stay on the rest icons' line.
        let iconLine = CGFloat(DockSize.bottom + DockSize.lane + DockSize.laneGap)
        let rule = Rectangle().fill(ink.text.opacity(0.22)).frame(width: 1, height: size.icon * 0.62).frame(height: size.icon).padding(.bottom, iconLine)
        let row = HStack(alignment: .bottom, spacing: 0) {
            if let leftWidgets {
                widgetRow(leftWidgets, width: $leftWidth)
                    .frame(height: size.icon)
                    .padding(.leading, DockPill.ends + 2)
                    .padding(.trailing, 12)
                    .padding(.bottom, iconLine)
                rule.padding(.trailing, 12)
            }
            icons(fit).padding(.horizontal, DockPill.ends)
            if hasWidgets {
                rule.padding(.trailing, 12)
                widgetRow(AnyView(widgets()), width: $widgetsWidth)
                    .frame(height: size.icon)
                    .padding(.leading, 12)
                    .padding(.bottom, iconLine)
                    .padding(.trailing, DockPill.ends + 2)
            }
        }
        .frame(height: size.pill, alignment: .bottom)
        let shape = RoundedRectangle(cornerRadius: DockPill.radius, style: .continuous)
        let shown = style.shown(transparency: Look.shared.transparency)
        Group {
            if let backing, shown == .glass { backing(AnyView(row)) } else { row.modifier(DockBacking(shape: shape, style: shown)) }
        }
        // Solid: a ring in the ink. Glass: the macOS Dock's edge, a light inner hairline lit brighter along the top, as
        // Pilot's Frost draws one (Sven on build 2470). Clear is nothing, as the top bar's: no ring either.
        .overlay {
            switch shown {
            case .solid: shape.strokeBorder(ink.text.opacity(0.16), lineWidth: 1)
            case .glass: shape.strokeBorder(.white.opacity(0.18), lineWidth: 1).litEdge(shape, .white.opacity(0.38))
            case .clear: EmptyView()
            }
        }
        .fixedSize()
    }

    /// The widgets at their own width while it fits `widgetsRoom`, else in a row that scrolls, its far end faded. The
    /// width is measured on the row itself, never the scroll's frame, so the fit never feeds back on itself.
    @ViewBuilder
    private func widgetRow(_ content: AnyView, width: Binding<CGFloat>) -> some View {
        let row = HStack(spacing: DockFaceMetrics.widgetGap) { content }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
        let room = room(width.wrappedValue)
        if width.wrappedValue > room {
            ScrollView(.horizontal, showsIndicators: false) { row }
                .frame(width: room)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        } else {
            row
        }
    }

    /// The icons at the fitted size, on one baseline; past the smallest size a row that scrolls, its far end faded.
    @ViewBuilder
    private func icons(_ fit: DockFit) -> some View {
        let icon = CGFloat(fit.icon), gap = (icon * DockPill.gapRatio).rounded()
        let row = HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(apps.enumerated()), id: \.offset) { i, app in
                DockAppIcon(app: app, icon: icon, scale: fit.scrolls ? 1 : scale(at: CGFloat(i) * (icon + gap) + icon / 2, icon: icon),
                            windows: windows(app), tiler: tiler, dock: dock)
            }
        }
        .padding(.top, DockSize.top)
        .padding(.bottom, DockSize.bottom)
        .animation(.spring(duration: 0.25, bounce: 0), value: hoverX == nil)
        .contentShape(Rectangle())
        // Off: no hover at all, so the box never grows over the windows below.
        .onContinuousHover(coordinateSpace: .named(DockPill.space)) { phase in if magnify != .off { hover(phase) } }
        if fit.scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row }
                .frame(width: max(0, maxWidth - CGFloat(fixed)))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.95),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        } else {
            row
        }
    }

    /// The pointer over the row, from the rest row's first icon. Leaving waits a beat before the box shrinks, so the
    /// window's resize under the pointer never flickers the hover off and on.
    private func hover(_ phase: HoverPhase) {
        switch phase {
        case .active(let at):
            leaving?.cancel()
            leaving = nil
            if hoverX == nil { onHover(true) }
            hoverX = at.x - origin - leftRun - DockPill.ends
        case .ended:
            hoverX = nil
            leaving?.cancel()
            leaving = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                onHover(false)
            }
        }
    }

    /// The Dock's bell: up to `magnify` at the pointer, falling to none three icons either side.
    private func scale(at centre: CGFloat, icon: CGFloat) -> CGFloat {
        guard let x = hoverX else { return 1 }
        let d = abs(x - centre) / (icon * CGFloat(DockSize.reachIcons))
        guard d < 1 else { return 1 }
        return 1 + CGFloat(magnify.scale - 1) * (cos(d * .pi) + 1) / 2
    }
}

/// The pill's ground, the top bar's three (TopBarBackground, as shown at Look's Transparency): Solid the theme's bar
/// ground; Glass Liquid Glass in the bar's tint whether Look › Glass is on or not, as the bar's (Look's Blur: Full
/// regular, Light clear, Off the tint alone); Clear nothing the eye sees, yet the gaps between icons still take the click
/// (TopBarColour.clearGround).
struct DockBacking<S: Shape>: ViewModifier {
    @Environment(\.style) private var tokens
    let shape: S
    let style: TopBarBackground
    var look: Look = .shared

    func body(content: Content) -> some View {
        switch style {
        case .solid: content.background(shape.fill(TopBarColour.themeGround(tokens)))
        case .clear: content.background(shape.fill(TopBarColour.clearGround))
        case .glass:
            let tint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
            if let glass = look.glassBlur.glass { content.glassEffect(glass.tint(tint), in: shape) } else { content.background(shape.fill(tint)) }
        }
    }
}

/// One app: its icon on nothing (no tile behind any icon), a dot under it while it runs, the front app's dot a wider
/// accent capsule. A click opens it, focuses its one window, or lists its windows over it to pick one.
struct DockAppIcon: View {
    @Environment(\.ink) private var ink
    let app: DockApp
    let icon: CGFloat
    var scale: CGFloat = 1
    /// Its own windows, from Pilot's tiler.
    var windows: [AeroWindow] = []
    var tiler: TilerService? = nil
    /// Its Keep in Dock and Remove from Dock edit this dock's own pins; nil in a render.
    var dock: DockController? = nil
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        Button(action: open) {
            VStack(spacing: DockSize.laneGap) {
                Image(nsImage: DockIcons.icon(app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: icon * scale, height: icon * scale)
                // A fixed lane, drawn or not, so every icon stands on one baseline.
                Color.clear.frame(width: icon, height: DockSize.lane).overlay {
                    if app.running {
                        Capsule().fill(app.front ? ink.accent : ink.text.opacity(0.85)).frame(width: app.front ? 16 : 5, height: DockSize.lane)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ScreenAnchor(box: anchor, rightClick: { showMenu() }))
        .help(app.name)
        .accessibilityLabel(app.front ? "\(app.name), in front" : app.running ? "\(app.name), open" : app.name)
    }

    private func open() {
        let mine = windows
        switch app.click {
        case .listWindows:
            BarPanel.shared.toggle(dock: app.bundleID ?? app.name, under: anchor.view,
                                   AnyView(DockWindowList(app: app.name, windows: mine) { id in focus(id) }))
        case .focusWindow:
            if let id = mine.first?.id { focus(id) } else { activate() }
        case .activate:
            activate()
        }
    }

    /// The right-click menu (Sven on build 2454): Open, its windows, Show in Files, Keep in Dock or Remove from Dock
    /// (Pilot's own pins), Quit; over the icon.
    private func showMenu() {
        guard let view = anchor.view else { return }
        BarPanel.shared.close()
        let sections = DockMenuItem.menu(app, windows: windows).map { $0.map(row) }
        BarMenu.show(Array(sections.joined(separator: [BarMenu.Row.separator])), under: view)
    }

    private func row(_ item: DockMenuItem) -> BarMenu.Row {
        .pick(item.title) { [app, dock] in
            switch item {
            case .open: activate()
            case .window(let id, _, _): focus(id)
            // Pilot Files on the app's folder, the app picked (Sven, 2026-11-13).
            case .showInFiles: if let url = app.url { FilesWindows.shared.newWindow(url.deletingLastPathComponent(), selecting: url) }
            case .keepInDock: dock?.keep(app)
            case .removeFromDock: dock?.unpin(app)
            case .quit: if let pid = app.pid { NSRunningApplication(processIdentifier: pid)?.terminate() }
            }
        }
    }

    private func focus(_ id: Int) {
        BarPanel.shared.close()
        guard let tiler else { return activate() }
        Task { await tiler.perform("dock.focusWindow:\(id)") { try await $0.run(.focusWindow(id: id)) } }
    }

    /// Opens the app, or brings it forward when it runs: macOS activates an app it is asked to open.
    private func activate() {
        BarPanel.shared.close()
        if let bundle = app.bundleID, AppsModule.open(bundle: bundle) { return }
        guard let url = app.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { docklog.error("dock open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// An app's windows over its icon (round 1, look A): its name and count, then one row per window with its workspace;
/// a pick focuses that window through the tiler.
struct DockWindowList: View {
    @Environment(\.ink) private var ink
    let app: String
    let windows: [AeroWindow]
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(app.uppercased()) · \(windows.count) WINDOWS")
                .font(ink.mono(11)).foregroundStyle(ink.muted)
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(windows, id: \.id) { window in
                Button { pick(window.id) } label: {
                    HStack(spacing: 10) {
                        Text(window.title.isEmpty ? app : window.title).font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("WS \(window.workspace)").font(ink.mono(11)).foregroundStyle(ink.text2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink.line2, lineWidth: 1))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .barPopover(width: 340)
    }
}

/// App icons by path, read once each; bounded, so a day of launching apps never grows it past `limit`.
@MainActor
enum DockIcons {
    private static let made: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func icon(_ app: DockApp) -> NSImage {
        let path = app.url?.path(percentEncoded: false) ?? ""
        if let image = made.object(forKey: path as NSString) { return image }
        let image = path.isEmpty ? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() : NSWorkspace.shared.icon(forFile: path)
        made.setObject(image, forKey: path as NSString)
        return image
    }
}

extension DockWindow {
    /// The pill the window shows: the dock's apps and widgets, fitting the window to its size.
    func draw(_ dock: DockController, observers: EngineObservers, sources: BarSources) {
        // The closure holds only these four, never the Engine.
        make = { [weak self] in
            let host = NSHostingView(rootView: DockView(dock: dock, tiler: observers.tiler, observers: observers, sources: sources, store: .shared,
                                                        fit: { self?.fit($0) }))
            host.sizingOptions = []
            return host
        }
    }
}
