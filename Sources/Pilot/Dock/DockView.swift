import AppKit
import PilotCore
import SwiftUI

/// The pill's shape (look A, round 1's mock): its corner radius, the gaps inside it.
enum DockPill {
    static let radius: CGFloat = 20
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 6
}

/// Look A (round 1, `shots/zoom-A.png`): the pins and running apps, a hairline, then the widgets, each a rounded sub-pill
/// on a darker fill. No shadow (ADR 0008): a 1 px ring and the window's glass carry the edge. The accent marks the front
/// app alone.
struct DockView: View {
    let dock: DockController
    let tiler: TilerService
    let observers: EngineObservers
    let sources: BarSources
    let store: BarItemsStore
    var extensionBar: ExtensionBar = .shared
    /// Told the pill's size as it changes, so its window fits it.
    var fit: (CGSize) -> Void = { _ in }
    /// The readers the widgets hold while they show.
    @State private var held: Set<BarKind> = []

    var body: some View {
        let size = dock.settings.size, screen = dock.screen() ?? ""
        let slots = store.settings.dockSlots(dock.settings.widgets, extensions: Set(extensionBar.items.filter { $0.face != nil }.map(\.id)))
        let kinds = Set(slots.flatMap(\.kinds))
        // The icons and each widget are views of their own, so a reading's tick redraws its widget, not the pill.
        DockStrip(size: size, hasWidgets: !slots.isEmpty) {
            DockAppRow(dock: dock, tiler: tiler, observers: observers, size: size)
        } widgets: {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                DockWidget(size: size, draws: { !TopBarSlotView.targets(slot, sources.inputs(for: slot.entries), settings: store.settings).isEmpty }) {
                    TopBarSlotView(slot: slot, screen: screen, sources: sources, store: store)
                }
            }
        }
            .environment(\.inTopBar, true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fit($0) }
            .styled(.topBar)
            .pilotTheme()
            .onAppear { sources.readings.hold(kinds, replacing: &held) }
            .onChange(of: kinds) { sources.readings.hold(kinds, replacing: &held) }
            .onDisappear { sources.readings.hold([], replacing: &held) }
    }
}

/// The pins and running apps, a view of its own: windows opening or the front app changing redraw the icons alone.
struct DockAppRow: View {
    let dock: DockController
    let tiler: TilerService
    let observers: EngineObservers
    let size: DockSize

    var body: some View {
        let byApp = Dictionary(grouping: tiler.windows, by: \.bundleId)
        let apps = DockController.apps(pins: dock.pins, running: dock.running, byApp: byApp, front: observers.focusedApp?.bundleIdentifier)
        ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
            DockAppIcon(app: app, size: size, windows: app.bundleID.flatMap { byApp[$0] } ?? [], tiler: tiler)
        }
    }
}

/// One widget in its sub-pill; with nothing to show now (the timer while none runs, an extension not answering) it
/// leaves nothing, its sub-pill too. `draws` is read here, so a reading's change redraws this widget alone.
struct DockWidget<Content: View>: View {
    @Environment(\.ink) private var ink
    let size: DockSize
    var draws: () -> Bool = { true }
    @ViewBuilder let content: () -> Content

    var body: some View {
        if draws() { pill }
    }

    private var pill: some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: size.icon)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line, lineWidth: 1))
    }
}

/// The pill's row, apart from where its icons and widgets come from, so a render draws it with samples.
struct DockStrip<Apps: View, Widgets: View>: View {
    @Environment(\.ink) private var ink
    let size: DockSize
    let hasWidgets: Bool
    @ViewBuilder let apps: () -> Apps
    @ViewBuilder let widgets: () -> Widgets

    var body: some View {
        HStack(spacing: DockPill.spacing) {
            apps()
            if hasWidgets {
                Rectangle().fill(ink.line2).frame(width: 1, height: size.icon * 0.7).padding(.horizontal, 6)
                widgets()
            }
        }
        .padding(.horizontal, DockPill.inset + 4)
        .padding(.top, DockPill.inset)
        .padding(.bottom, DockPill.inset + 2)
        .frame(height: size.pill)
        .overlay(RoundedRectangle(cornerRadius: DockPill.radius, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
        .fixedSize()
    }
}

/// One app: its icon, the dots under it, the front app raised with accent dots. A click opens it, focuses its one window,
/// or lists its windows over it to pick one.
struct DockAppIcon: View {
    @Environment(\.ink) private var ink
    let app: DockApp
    let size: DockSize
    /// Its own windows, from Pilot's tiler.
    var windows: [AeroWindow] = []
    var tiler: TilerService? = nil
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        Button(action: open) {
            VStack(spacing: 3) {
                Image(nsImage: DockIcons.icon(app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.icon - 6, height: size.icon - 6)
                HStack(spacing: 3) {
                    ForEach(0..<app.dots, id: \.self) { _ in
                        Circle().fill(app.front ? ink.accent : ink.text2).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(app.front ? ink.selected : .clear))
        }
        .buttonStyle(.plain)
        .background(ScreenAnchor(box: anchor))
        .help(app.name)
        .accessibilityLabel(app.name)
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
