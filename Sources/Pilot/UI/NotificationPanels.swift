import AppKit
import Observation
import PilotCore
import SwiftUI

/// What the panels show, handed to their views. Words stay in memory.
@Observable @MainActor
final class NotificationCardsModel {
    var cards: [NotificationEntry] = []
    var drawer: [NotificationEntry] = []
    var unread = 0
    /// The bell's side, which a right-drag on it pulls (Q42).
    var bellSide = NotificationPlacement.bell.width
}

/// The visible frame the cards, bell and drawer sit in: the main display's, so they stay together.
@MainActor private func notificationScreen() -> CGRect {
    (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
}

/// Pilot's own notification surfaces. The panels are made as things arrive and dropped as they go, never activate Pilot,
/// and never take key status: the app in front keeps its typing, and Notification Center's own panel stays open.
@MainActor
final class NotificationPanels: NotificationPresenting {
    let model = NotificationCardsModel()
    private var cardsPanel: KeyPanel?
    private var bellPanel: KeyPanel?
    private var drawerPanel: KeyPanel?
    private var outsideClicks: Any?
    private var screenWatch: (any NSObjectProtocol)?

    private let bellPlaces = NotificationBellPlaces(defaults: UserDefaults.pilot())

    func begin() {
        guard bellPanel == nil else { return }
        let start = bellFrame()
        model.bellSide = start.width
        let bell = NotificationBell(model: model) { [weak self] in self?.bellDropped($0) }
        // A pull sets the frame itself before the side, so a new size only ever keeps the bell's corner where it is.
        bellPanel = BarPanelWindow.keyPanel(bell, surface: .barPopovers, level: HUD.level, takesKey: false) { [weak self] size in
            self?.bellPanel.map { CGRect(origin: $0.frame.origin, size: size) } ?? start
        }
        // A display change moves the corner: all three follow.
        screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replace() }
        }
    }

    func update(cards: [NotificationEntry], drawer: [NotificationEntry], unread: Int) {
        model.cards = Array(cards.prefix(NotificationFeed.cardLimit).reversed())
        model.drawer = drawer
        model.unread = unread
        if model.cards.isEmpty {
            closeCards()
        } else if cardsPanel == nil {
            cardsPanel = BarPanelWindow.keyPanel(NotificationCardStack(model: model), surface: .barPopovers, level: HUD.level, takesKey: false) { [weak self] in
                NotificationPlacement.cards(in: notificationScreen(), size: $0, bell: self?.bellPanel?.frame)
            }
        }
    }

    func end() {
        closeCards()
        closeDrawer()
        close(&bellPanel)
        screenWatch.map(NotificationCenter.default.removeObserver)
        screenWatch = nil
        model.cards = []
        model.drawer = []
        model.unread = 0
    }

    func say(_ text: String) { HUD.tip(text, seconds: 3) }

    /// The display the bell was left on, while it is connected, else the main one; and the bell's frame there.
    private func bellScreen() -> NSScreen? {
        let last = bellPlaces.lastDisplay
        return NSScreen.screens.first { $0.displayUUID == last } ?? NSScreen.screens.first ?? NSScreen.main
    }

    private func bellFrame() -> CGRect {
        let screen = bellScreen()
        return bellPlaces.frame(on: screen?.displayUUID, visible: screen?.visibleFrame ?? notificationScreen())
    }

    /// A drag or pull let go: the bell stays on the display holding its middle, inside it, remembered there.
    private func bellDropped(_ frame: CGRect) {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) ?? bellScreen(), let id = screen.displayUUID else { return }
        let kept = bellPlaces.save(frame, on: id, visible: screen.visibleFrame)
        bellPanel?.setFrame(kept, display: true)
        model.bellSide = kept.width
        placeCards()
    }

    /// The cards above the bell when it sits low in their column.
    private func placeCards() {
        guard let cardsPanel else { return }
        cardsPanel.setFrame(NotificationPlacement.cards(in: notificationScreen(), size: cardsPanel.frame.size, bell: bellPanel?.frame), display: true)
    }

    func toggleDrawer() {
        if drawerPanel != nil { return closeDrawer() }
        let panel = makeDrawer()
        panel.escape = { [weak self] in self?.closeDrawer() }
        drawerPanel = panel
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeDrawer() }
        }
    }

    /// The drawer moves and resizes as a widget does (Q42, Sven 2026-11-10): dragged by its header, pulled at its edges.
    /// It opens beside the bell wherever that is, at the size it last had (Q55).
    private func makeDrawer() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = MaterialBackdrop(content: NSHostingView(rootView: NotificationDrawer(model: model).styled(.barPopovers).pilotTheme()))
        panel.appearance = Look.shared.appearance(for: .barPopovers)
        panel.level = HUD.level
        panel.resizesFromFace(withoutMargins: true)
        panel.minSize = NotificationBellPlaces.drawerMin
        panel.setFrame(drawerFrame(), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        return panel
    }

    /// Beside the bell, on its display: at `size` while open, else at the size it last closed at. No autosave name: one
    /// restores its saved frame over this place, which kept 2182's drawer bottom right (Q55).
    private func drawerFrame(size: CGSize? = nil) -> CGRect {
        let bell = bellPanel?.frame ?? bellFrame()
        let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: bell.midX, y: bell.midY)) } ?? bellScreen())?.visibleFrame ?? notificationScreen()
        return size.map { NotificationPlacement.drawer(nextTo: bell, in: visible, size: $0) } ?? bellPlaces.drawer(nextTo: bell, in: visible)
    }

    func openApp(named name: String) {
        guard let bundle = AppsModule.bundles(named: [name])[name] else { return }
        AppsModule.open(bundle: bundle)
    }

    private func replace() {
        bellPanel?.setFrame(bellFrame(), display: true)
        placeCards()
        if let drawerPanel { drawerPanel.setFrame(drawerFrame(size: drawerPanel.frame.size), display: true) }
        model.bellSide = bellPanel?.frame.width ?? model.bellSide
    }

    private func closeDrawer() {
        if let drawerPanel { bellPlaces.keepDrawerSize(drawerPanel.frame.size) }
        outsideClicks.map(NSEvent.removeMonitor)
        outsideClicks = nil
        close(&drawerPanel)
    }

    private func closeCards() { close(&cardsPanel) }

    private func close(_ panel: inout KeyPanel?) {
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The bell, with a count of what arrived since the drawer last opened. A click opens the drawer, a drag takes it anywhere,
/// a right-drag pulls it bigger or smaller from the corner nearest the press, as Hyper+right-drag pulls a widget (Q42, Q55).
struct NotificationBell: View {
    @Environment(\.style) private var style
    let model: NotificationCardsModel
    let dropped: (CGRect) -> Void

    var body: some View {
        let side = model.bellSide
        KitPopover(width: side, inset: side / 4, arrow: false) {
            Image(systemName: "bell.fill").font(.system(size: side * 0.35)).foregroundStyle(style.color(\.text2)).frame(width: side / 2, height: side / 2)
        }
        .overlay(alignment: .topTrailing) {
            if model.unread > 0 {
                Text(model.unread > 99 ? "99+" : "\(model.unread)").font(.system(size: max(9, side * 0.22), weight: .bold)).foregroundStyle(style.color(\.onAccent))
                    .padding(.horizontal, 4).padding(.vertical, 1).background(style.color(\.accent), in: Capsule()).offset(x: 3, y: -3)
            }
        }
        .extensionGlass()
        .overlay { BellHandle(model: model, dropped: dropped) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.unread > 0 ? "Notifications, \(model.unread) new" : "Notifications")
        .accessibilityAction { PilotNotifications.shared.toggleDrawer() }
        .allowsWindowActivationEvents(true)
    }
}

/// The bell's mouse: a press that comes up within a click's slop is a click; past it, a left press moves the panel and a
/// right press pulls its side, the opposite corner staying put. The panel never takes key, so the app in front keeps typing.
private struct BellHandle: NSViewRepresentable {
    let model: NotificationCardsModel
    let dropped: (CGRect) -> Void

    final class Handle: NSView {
        var model: NotificationCardsModel?
        var dropped: ((CGRect) -> Void)?
        private var press: (start: CGPoint, frame: CGRect, right: Bool, moved: Bool)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { begin(right: false) }
        override func rightMouseDown(with event: NSEvent) { begin(right: true) }
        override func mouseDragged(with event: NSEvent) { follow() }
        override func rightMouseDragged(with event: NSEvent) { follow() }
        override func mouseUp(with event: NSEvent) { end() }
        override func rightMouseUp(with event: NSEvent) { end() }

        private func begin(right: Bool) {
            guard let window else { return }
            press = (NSEvent.mouseLocation, window.frame, right, false)
        }

        private func follow() {
            guard var held = press, let window else { return }
            let now = NSEvent.mouseLocation, dx = now.x - held.start.x, dy = now.y - held.start.y
            guard held.moved || hypot(dx, dy) > MouseDragTap.clickSlop else { return }
            held.moved = true
            press = held
            let from = held.frame
            guard held.right else { return window.setFrameOrigin(CGPoint(x: from.minX + dx, y: from.minY + dy)) }
            // The corner nearest the press follows the pointer; the side grows by the larger pull.
            let left = held.start.x < from.midX, bottom = held.start.y < from.midY
            let grow = max(left ? -dx : dx, bottom ? -dy : dy)
            let side = min(max(from.width + grow, NotificationPlacement.bellSides.lowerBound), NotificationPlacement.bellSides.upperBound)
            let frame = CGRect(x: left ? from.maxX - side : from.minX, y: bottom ? from.maxY - side : from.minY, width: side, height: side)
            window.setFrame(frame, display: true)
            model?.bellSide = side
        }

        private func end() {
            guard let held = press, let window else { return }
            press = nil
            if held.moved { dropped?(window.frame) } else if !held.right { PilotNotifications.shared.toggleDrawer() }
        }
    }

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.model = model
        view.dropped = dropped
    }
}

/// The drawer: what arrived since the setting went on, newest first, in memory only.
struct NotificationDrawer: View {
    @Environment(\.style) private var style
    let model: NotificationCardsModel

    var body: some View {
        // The panel's size, which Sven sets by pulling its edges; the list takes the height the header leaves.
        GeometryReader { space in face(width: space.size.width).frame(height: space.size.height, alignment: .top) }
    }

    private func face(width: CGFloat) -> some View {
        KitPopover(width: width, inset: 0, arrow: false) {
            HStack {
                Text("Notifications").styleText(\.strong).foregroundStyle(style.color(\.text))
                // The header drags the panel: a hosting view never lets a press move its window by its background.
                WindowDragArea().frame(maxWidth: .infinity).frame(height: 24)
                if !model.drawer.isEmpty {
                    Button("Clear all") { PilotNotifications.shared.clearDrawer() }.buttonStyle(.pilotSoft)
                }
            }
            .padding(12)
            .background { WindowDragArea() }
            Divider()
            if model.drawer.isEmpty {
                EmptyState(title: "No notifications yet", line: "What macOS shows from now on appears here. It stays in memory.").padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.drawer) { row(for: $0) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .extensionGlass()
        .allowsWindowActivationEvents(true)
    }

    private func row(for entry: NotificationEntry) -> some View {
        NotificationFace(entry: entry, icon: 26, time: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { PilotNotifications.shared.press(.open, id: entry.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { PilotNotifications.shared.press(.open, id: entry.id) }
            .overlay(alignment: .topTrailing) {
                IconButton(symbol: "xmark", label: "Remove", size: 18, glyph: 9) { PilotNotifications.shared.removeFromDrawer(entry.id) }
                    .padding(4)
            }
    }
}

/// The cards, newest nearest the corner, each on the top bar's glass while Look's Glass is on, else KitPopover's panel.
struct NotificationCardStack: View {
    let model: NotificationCardsModel

    var body: some View {
        VStack(alignment: .trailing, spacing: NotificationPlacement.gap) {
            ForEach(model.cards) { NotificationCard(entry: $0) }
        }
        .allowsWindowActivationEvents(true)
    }
}

/// One notification's card: the app's icon and name, then its lines. A click opens it; its close and buttons always show,
/// since hover reports nothing in a window of an app that isn't active, as Pilot never is.
struct NotificationCard: View {
    let entry: NotificationEntry

    var body: some View {
        KitPopover(width: NotificationPlacement.cardWidth, inset: 12, arrow: false) {
            NotificationFace(entry: entry, icon: 34)
                .contentShape(.rect)
                .onTapGesture { PilotNotifications.shared.press(.open, id: entry.id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { PilotNotifications.shared.press(.open, id: entry.id) }
            if !entry.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.actions, id: \.self) { name in
                        Button(name) { PilotNotifications.shared.press(.button(name), id: entry.id) }
                            .buttonStyle(.pilot)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "xmark", label: "Close", size: 20, glyph: 10) { PilotNotifications.shared.press(.close, id: entry.id) }
                .padding(4)
        }
        .extensionGlass()
        .accessibilityElement(children: .contain)
    }
}

/// A notification's lines beside its app's icon, on a card and in a drawer row; `time` adds when it arrived.
struct NotificationFace: View {
    @Environment(\.style) private var style
    let entry: NotificationEntry
    let icon: CGFloat
    var time = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(name: entry.app ?? "", size: icon, glyph: "bell.fill")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let app = entry.app { Text(app).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1) }
                    if time { Text(entry.arrived, style: .relative).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1) }
                }
                Text(entry.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(2)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
                if !entry.body.isEmpty {
                    Text(entry.body).foregroundStyle(style.color(\.text2)).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 14)
        }
    }
}
