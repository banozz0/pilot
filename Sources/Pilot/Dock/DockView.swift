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
    /// The widgets' type over the bar's 12 pt mono: they stand beside 40 to 56 pt icons here, not in a 28 pt bar.
    static let widgetScale: CGFloat = 1.25
    static let widgetGap: CGFloat = 22
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
    /// Told the box's size as it changes, so its window fits it.
    var fit: (CGSize) -> Void = { _ in }
    /// The readers the widgets hold while they show.
    @State private var held: Set<BarKind> = []
    @State private var hovering = false
    @State private var rest: CGSize = .zero

    var body: some View {
        let size = dock.settings.size, screen = dock.screen() ?? ""
        let slots = store.settings.dockSlots(dock.settings.widgets, extensions: Set(extensionBar.items.filter { $0.face != nil }.map(\.id)))
        let kinds = Set(slots.flatMap(\.kinds))
        let byApp = Dictionary(grouping: tiler.windows, by: \.bundleId)
        let apps = DockController.apps(pins: dock.pins, running: dock.running, byApp: byApp, front: observers.focusedApp?.bundleIdentifier)
        // Each widget is a view of its own, so a reading's tick redraws its widget, not the pill.
        DockStrip(size: size, apps: apps, hasWidgets: !slots.isEmpty, maxWidth: DockWindow.widest(),
                  windows: { app in app.bundleID.flatMap { byApp[$0] } ?? [] }, tiler: tiler,
                  origin: hovering ? CGFloat(size.reach.width) / 2 : 0, onHover: { hovering = $0 }) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                DockWidget(size: size, draws: { !TopBarSlotView.targets(slot, sources.inputs(for: slot.entries), settings: store.settings).isEmpty }) {
                    TopBarSlotView(slot: slot, screen: screen, sources: sources, store: store)
                }
            }
        }
            .environment(\.inTopBar, true)
            // The bar's Item colours, so a widget's warning and alert read as they do in the bar (amber, red), not
            // in the accent (the red Sven saw on Maple, whose accent is red; 2026-11-13).
            .environment(\.barItemColours, store.itemColours)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if !hovering { rest = $0 } }
            .frame(width: hovering ? rest.width + CGFloat(size.reach.width) : nil,
                   height: hovering ? rest.height + CGFloat(size.reach.height) : nil, alignment: .bottom)
            .coordinateSpace(.named(DockPill.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fit($0) }
            .styled(.topBar)
            .pilotTheme()
            .onAppear { sources.readings.hold(kinds, replacing: &held) }
            .onChange(of: kinds) { sources.readings.hold(kinds, replacing: &held) }
            .onDisappear { sources.readings.hold([], replacing: &held) }
    }
}

/// One widget, on the glass itself at the dock's scale; with nothing to show now (the timer while none runs, an
/// extension not answering) it leaves nothing. `draws` is read here, so a reading's change redraws this widget alone.
struct DockWidget<Content: View>: View {
    let size: DockSize
    var draws: () -> Bool = { true }
    @ViewBuilder let content: () -> Content

    var body: some View {
        if draws() { DockScaled(scale: DockPill.widgetScale, content: content).frame(height: size.icon) }
    }
}

/// The pill: the pins and running apps fitted to `maxWidth` (smaller down to 32 pt, then a scrolling row; never cut),
/// the Dock's hairline, then the widgets, on glass that follows Look › Glass. Magnifies on hover, unless the row scrolls.
struct DockStrip<Widgets: View>: View {
    @Environment(\.ink) private var ink
    let size: DockSize
    let apps: [DockApp]
    let hasWidgets: Bool
    /// The widest the pill may be: its screen's width less its margins.
    let maxWidth: CGFloat
    var windows: (DockApp) -> [AeroWindow] = { _ in [] }
    var tiler: TilerService?
    /// What stands behind the pill; nil is the live glass or solid fill (DockBacking). A render passes a stand-in, as
    /// glass draws nothing offscreen.
    var backing: ((AnyView) -> AnyView)?
    /// Where the rest pill starts in DockView's box: the hover is measured from there, so the bell stays put as icons grow.
    var origin: CGFloat = 0
    var onHover: (Bool) -> Void = { _ in }
    @ViewBuilder let widgets: () -> Widgets
    @State private var hoverX: CGFloat?
    @State private var widgetsWidth: CGFloat = 0
    @State private var leaving: Task<Void, Never>?

    init(size: DockSize, apps: [DockApp], hasWidgets: Bool, maxWidth: CGFloat, windows: @escaping (DockApp) -> [AeroWindow] = { _ in [] },
         tiler: TilerService? = nil, backing: ((AnyView) -> AnyView)? = nil, origin: CGFloat = 0, onHover: @escaping (Bool) -> Void = { _ in },
         hoverApp: Int? = nil, @ViewBuilder widgets: @escaping () -> Widgets) {
        self.size = size; self.apps = apps; self.hasWidgets = hasWidgets; self.maxWidth = maxWidth; self.windows = windows
        self.tiler = tiler; self.backing = backing; self.origin = origin; self.onHover = onHover; self.widgets = widgets
        let icon = CGFloat(size.icon), gap = (icon * DockPill.gapRatio).rounded()
        _hoverX = State(initialValue: hoverApp.map { CGFloat($0) * (icon + gap) + icon / 2 })
    }

    /// What the pill spends besides its icons: its ends, the hairline and the widgets as last measured.
    private var fixed: Double { Double(2 * DockPill.ends + (hasWidgets ? 25 + widgetsWidth : 0)) }

    var body: some View {
        let fit = DockFit.fit(apps: apps.count, icon: size.icon, gapRatio: DockPill.gapRatio, fixed: fixed, available: Double(maxWidth))
        // Bottom-aligned: magnified icons grow upward, and the hairline and widgets stay on the rest icons' line.
        let iconLine = CGFloat(DockSize.bottom + DockSize.lane + DockSize.laneGap)
        let row = HStack(alignment: .bottom, spacing: 0) {
            icons(fit).padding(.horizontal, DockPill.ends)
            if hasWidgets {
                Rectangle().fill(ink.text.opacity(0.22)).frame(width: 1, height: size.icon * 0.62)
                    .frame(height: size.icon).padding(.bottom, iconLine).padding(.trailing, 12)
                HStack(spacing: DockPill.widgetGap) { widgets() }
                    .frame(height: size.icon)
                    .padding(.leading, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widgetsWidth = $0 }
                    .padding(.bottom, iconLine)
                    .padding(.trailing, DockPill.ends + 2)
            }
        }
        .frame(height: size.pill, alignment: .bottom)
        let shape = RoundedRectangle(cornerRadius: DockPill.radius, style: .continuous)
        Group {
            if let backing { backing(AnyView(row)) } else { row.modifier(DockBacking(shape: shape)) }
        }
        .overlay(shape.strokeBorder(ink.text.opacity(0.16), lineWidth: 1))
        .fixedSize()
    }

    /// The icons at the fitted size, on one baseline; past the smallest size a row that scrolls, its far end faded.
    @ViewBuilder
    private func icons(_ fit: DockFit) -> some View {
        let icon = CGFloat(fit.icon), gap = (icon * DockPill.gapRatio).rounded()
        let row = HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(apps.enumerated()), id: \.offset) { i, app in
                DockAppIcon(app: app, icon: icon, scale: fit.scrolls ? 1 : scale(at: CGFloat(i) * (icon + gap) + icon / 2, icon: icon),
                            windows: windows(app), tiler: tiler)
            }
        }
        .padding(.top, DockSize.top)
        .padding(.bottom, DockSize.bottom)
        .animation(.spring(duration: 0.25, bounce: 0), value: hoverX == nil)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(DockPill.space)) { phase in hover(phase) }
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
            hoverX = at.x - origin - DockPill.ends
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

    /// The Dock's bell: up to DockSize.magnify at the pointer, falling to none three icons either side.
    private func scale(at centre: CGFloat, icon: CGFloat) -> CGFloat {
        guard let x = hoverX else { return 1 }
        let d = abs(x - centre) / (icon * CGFloat(DockSize.reachIcons))
        guard d < 1 else { return 1 }
        return 1 + CGFloat(DockSize.magnify - 1) * (cos(d * .pi) + 1) / 2
    }
}

/// The pill's ground: with Look › Glass on, Liquid Glass in the bar's tint (Look's Blur: Full regular, Light clear, Off
/// the tint alone); off, the theme's solid bar ground.
struct DockBacking<S: Shape>: ViewModifier {
    @Environment(\.style) private var style
    let shape: S
    var look: Look = .shared

    func body(content: Content) -> some View {
        let tint = Color(nsColor: TopBarColour.tint(.theme, style: style, look: look))
        if look.glass, let glass = look.glassBlur.glass {
            content.glassEffect(glass.tint(tint), in: shape)
        } else if look.glass {
            content.background(shape.fill(tint))
        } else {
            content.background(shape.fill(TopBarColour.themeGround(style)))
        }
    }
}

/// A view drawn `scale` times its own size and laid out at that size (the bar's parts have one fixed size).
struct DockScaled<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var natural: CGSize = .zero

    var body: some View {
        content().fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            .scaleEffect(scale)
            .frame(width: natural.width * scale, height: natural.height * scale)
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
        .background(ScreenAnchor(box: anchor))
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
