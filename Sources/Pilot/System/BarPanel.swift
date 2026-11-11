import AppKit
import PilotCore
import SwiftUI

/// Puts a panel on screen and takes it off; a fake in tests, so no test shows one.
@MainActor
protocol BarPanelPresenting: AnyObject {
    /// Called when the panel closes by itself: a click outside it, or Escape.
    var closed: () -> Void { get set }
    /// Shows `content` under `item`, its screen frame (a click there toggles the panel through the item's button).
    func present(_ content: AnyView, under item: CGRect)
    func dismiss()
}

/// The one popover or dropdown hung from a bar item, in either bar (card agent-bo-95422914): a click on the item showing
/// it closes it, a click on another item opens that one in its place; a click outside or Escape closes it (the real
/// presenter's own watch).
@MainActor
final class BarPanel: NSObject {
    static let shared = BarPanel(presenter: BarPanelWindow())

    private let presenter: BarPanelPresenting
    /// The item whose panel shows; nil when none does.
    private(set) var shown: [BarKind]?
    /// The extension whose own item's panel shows (Surfaces v2), with `shown` [.extensions].
    private(set) var shownExtension: String?

    init(presenter: BarPanelPresenting) {
        self.presenter = presenter
        super.init()
        // Reconfiguration invalidates the captured bar anchor; the next click reads its new screen frame.
        NotificationCenter.default.addObserver(self, selector: #selector(close),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        presenter.closed = { [weak self] in
            self?.shown = nil
            self?.shownExtension = nil
        }
    }

    /// Shows `content` under the item `id` (`view`, on screen), or closes it when that item's panel shows.
    func toggle(_ id: [BarKind], under view: NSView?, _ content: AnyView) {
        toggle(id, under: view?.screenFrame, content)
    }

    /// As above, from the item's screen frame; no frame (the item off screen) shows nothing.
    func toggle(_ id: [BarKind], under item: CGRect?, _ content: AnyView) {
        toggle(id, extension: nil, under: item, content)
    }

    /// An extension's own item's popover (Surfaces v2), toggled as an item's.
    func toggle(extension id: String, under view: NSView?, _ content: AnyView) {
        toggle([.extensions], extension: id, under: view?.screenFrame, content)
    }

    private func toggle(_ id: [BarKind], extension ext: String?, under item: CGRect?, _ content: AnyView) {
        if shown == id && shownExtension == ext { return close() }
        guard let item else { return }
        presenter.present(content, under: item)
        (shown, shownExtension) = (id, ext)
    }

    /// What an edit list drives live: the shown bar panel (the Pilot menu) or the open bar drops (the pill).
    enum Kept { case panel, drops }

    /// Views where a click leaves what they drive open (Menu bar › Pilot menu and › Pill), so each change lands in the
    /// open menu or pill as it is made: Settings is Pilot's own window, so its clicks were outside and closed it (Sven on
    /// build 2276).
    private static var keepers: [(box: ScreenAnchor.Box, kept: Kept)] = []
    static func keepOpen(_ box: ScreenAnchor.Box, _ kept: Kept) { keepers.append((box, kept)) }
    static func release(_ box: ScreenAnchor.Box) { keepers.removeAll { $0.box === box } }
    /// Whether a click at `point` (screen points) lands in a keeper of `kept`.
    static func keepsOpen(_ kept: Kept, at point: CGPoint) -> Bool {
        keepers.contains { $0.kept == kept && $0.box.view?.window?.isVisible == true && $0.box.view?.screenFrame?.contains(point) == true }
    }

    /// Takes the shown panel down: after a screen change, or Power's popover once its action runs.
    @objc func close() {
        guard shown != nil else { return }
        presenter.dismiss()
        (shown, shownExtension) = (nil, nil)
    }
}

/// The real panel: borderless and non-activating, over the menu bar's level, KitPopover's chrome on the panels'
/// material (Look's Panels setting, Glass at its strength by default; MaterialBackdrop, the app window's own) clipped to
/// the popover's shape. Closed by a click outside it, by Escape, or by BarPanel.
@MainActor
final class BarPanelWindow: BarPanelPresenting {
    var closed: () -> Void = {}
    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// A menu of this app tracks (a row's ⋯ in the popover): clicks in it are not outside the panel.
    private var menuOpen = false
    private var menuWatch: [NSObjectProtocol] = []

    func present(_ content: AnyView, under item: CGRect) {
        dismiss()
        let display = NSScreen.screens.first { $0.frame.intersects(item) } ?? NSScreen.main
        let screen = display?.frame ?? .zero
        // A popover that can grow (an extension's chat) keeps inside the room under its item, above the Dock.
        let room = display.map { BarPanelPlacement.room(item: item, visible: $0.visibleFrame) }
        let panel = Self.keyPanel(content.environment(\.barPopoverRoom, room), surface: .barPopovers, level: .popUpMenu) { BarPanelPlacement.frame(item: item, size: $0, screen: screen) }
        self.panel = panel
        // A click anywhere but the panel and its item closes it (BarPanelPlacement.clickCloses); one on the item reaches
        // its button, which toggles through BarPanel.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeFromOutside() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // Escape is used up; a click is passed on whatever it does here.
            let swallow: Bool = MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return false }
                if event.type == .keyDown {
                    guard Int64(event.keyCode) == KeyCode.escape else { return false }
                    // A view in it that takes Escape first (the clock's open day card) gets it instead.
                    if let escape = (panel as? KeyPanel)?.escape { escape() } else { self.closeFromOutside() }
                    return true
                }
                let onPanel = event.window === panel || self.menuOpen || BarPanel.keepsOpen(.panel, at: NSEvent.mouseLocation)
                if BarPanelPlacement.clickCloses(at: NSEvent.mouseLocation, onPanel: onPanel, item: item) { self.closeFromOutside() }
                return false
            }
            return swallow ? nil : event
        } as Any)
        menuWatch = [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)].map { name, open in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open }
            }
        }
    }

    /// `content` in a borderless panel at `level`, at `place(size)` for its size, on KitPopover's backdrop, shown and key
    /// without activating Pilot, so Escape and Option reach it whatever app is in front. The content's own size is
    /// reported as it changes: a reading's rows arrive after the first sample, and the hosting view never resizes the
    /// panel for them, so SwiftUI clipped the taller content's top, with Calm's arrow, at the panel's edge under the menu
    /// bar. The panel refits with its top kept (card agent-bo-95422983). `surface` is the style seam's: a bar item's
    /// dropdown is .barPopovers. `margins` is the clear room round a face that draws its own soft shadow
    /// (Look.chromeMargins); a popover's face has none.
    static func keyPanel(_ content: some View, surface: StyleSurface, margins: NSEdgeInsets = NSEdgeInsetsZero,
                         level: NSWindow.Level, takesKey: Bool = true, place: @escaping (CGSize) -> NSRect) -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.styled(surface).pilotTheme().fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak panel] size in
                guard let panel, panel.frame.size != size else { return }
                panel.setFrame(place(size), display: true)
            })
        host.frame.size = host.fittingSize
        panel.setFrame(place(host.frame.size), display: false)
        let backdrop = MaterialBackdrop(content: host)
        backdrop.frame = host.frame
        panel.contentView = backdrop
        panel.appearance = Look.shared.appearance(for: surface)
        panel.margins = margins
        panel.level = level
        panel.refusesKey = !takesKey  // a notification card never takes it: the app in front keeps its typing
        panel.orderFrontRegardless()
        if takesKey { panel.makeKey() }
        return panel
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        menuWatch.forEach(NotificationCenter.default.removeObserver)
        (menuWatch, menuOpen) = ([], false)
        // The content goes with the panel, and with it a reading popover's watch (PopoverWatch's deinit).
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func closeFromOutside() {
        dismiss()
        closed()
    }
}

/// A borderless panel that takes keys; a nonactivating one does so without activating Pilot. With `escape`, Escape
/// calls it (the Allow prompt, a capture's overlay); the bar's popover watches for it itself, and calls it first when
/// set (the clock's open day card). A resizable one
/// with margins round its face (the notes panel in Instrument) resizes from the face's edges, where Sven sees them, not
/// the window's, out in the clear room its shadow takes. Every Pilot pop-up is one: clear, on every Space, kept while
/// Pilot is inactive, and without the window server's drop shadow (Sven on build 29: the bar's parked edit shelf's; the
/// menu's went in B5), set here once for all of them.
final class KeyPanel: NSPanel {
    var escape: (() -> Void)?
    /// The clear room round a restyled panel's face for its shadow (PopSurface.margins).
    var margins = NSEdgeInsetsZero
    /// Clicks reach it but it never becomes key: a surface that must leave the keyboard with the app in front.
    var refusesKey = false
    override var canBecomeKey: Bool { !refusesKey }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    /// The face's edges under the pointer, whose resize cursor it wears; nil off every edge.
    private var under: FaceEdges?

    /// Resizable from the face's edges once it has margins round it; their resize cursors show as the pointer passes.
    /// `withoutMargins` pulls a margin-less face's own edges too: a borderless window has no frame of its own to pull. Only
    /// the notification drawer asks for it, so every other panel keeps its behaviour (review B3).
    func resizesFromFace(withoutMargins: Bool = false) {
        styleMask.insert(.resizable)
        edgesWithoutMargins = withoutMargins
        if withoutMargins || !NSEdgeInsetsEqual(margins, NSEdgeInsetsZero) { acceptsMouseMovedEvents = true }
    }

    private var edgesWithoutMargins = false

    override func sendEvent(_ event: NSEvent) {
        if let escape, event.type == .keyDown, Int64(event.keyCode) == KeyCode.escape { return escape() }
        // The right button goes to the view's anchor under it (an extension row's menu), as the bar's window hands it
        // (TopBarPanel): SwiftUI's context menu in a non-activating panel may not open.
        if event.type == .rightMouseDown || event.type == .rightMouseUp, let anchor = ScreenAnchor.AnchorView.taking(event, in: contentView) {
            return anchor.take(event)
        }
        if event.type == .leftMouseDown || event.type == .mouseMoved, styleMask.contains(.resizable),
           edgesWithoutMargins || !NSEdgeInsetsEqual(margins, NSEdgeInsetsZero) {
            let edges = FaceEdges.at(event.locationInWindow, window: frame.size, margins: margins)
            if event.type == .leftMouseDown, let edges { return resizeFace(edges) }
            // The cursor changes only as the pointer crosses onto, along or off an edge.
            if event.type == .mouseMoved, edges != under {
                (edges?.cursor ?? .arrow).set()
                under = edges
            }
        }
        super.sendEvent(event)
    }

    /// Follows the pointer until the button comes up, the edges it grabbed moving with it, never under minSize.
    private func resizeFace(_ edges: FaceEdges) {
        let start = NSEvent.mouseLocation, from = frame
        edges.cursor.set()
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            setFrame(edges.resized(from, by: CGVector(dx: now.x - start.x, dy: now.y - start.y), min: minSize), display: true)
            if event.type == .leftMouseUp { break }
        }
    }
}

/// The edges of a panel's face a point grabs: within `band` points either side of an edge, the corners both of theirs.
struct FaceEdges: OptionSet, Equatable {
    let rawValue: Int
    static let left = FaceEdges(rawValue: 1), right = FaceEdges(rawValue: 2), bottom = FaceEdges(rawValue: 4), top = FaceEdges(rawValue: 8)

    /// The edges `point` (in the window, origin at its foot) grabs on the face `margins` in from a window of `size`; nil
    /// off every edge.
    static func at(_ point: CGPoint, window size: CGSize, margins m: NSEdgeInsets, band: CGFloat = 5) -> FaceEdges? {
        let face = PopSurface.face(CGRect(origin: .zero, size: size), m)
        guard face.insetBy(dx: -band, dy: -band).contains(point), !face.insetBy(dx: band, dy: band).contains(point) else { return nil }
        var edges: FaceEdges = []
        if abs(point.x - face.minX) <= band { edges.insert(.left) }
        if abs(point.x - face.maxX) <= band { edges.insert(.right) }
        if abs(point.y - face.minY) <= band { edges.insert(.bottom) }
        if abs(point.y - face.maxY) <= band { edges.insert(.top) }
        return edges.isEmpty ? nil : edges
    }

    /// `frame` with these edges moved by `delta`, the opposite ones staying put, never smaller than `min`.
    func resized(_ frame: CGRect, by delta: CGVector, min: CGSize) -> CGRect {
        var r = frame
        if contains(.right) { r.size.width = Swift.max(min.width, frame.width + delta.dx) }
        if contains(.left) {
            r.size.width = Swift.max(min.width, frame.width - delta.dx)
            r.origin.x = frame.maxX - r.width
        }
        if contains(.top) { r.size.height = Swift.max(min.height, frame.height + delta.dy) }
        if contains(.bottom) {
            r.size.height = Swift.max(min.height, frame.height - delta.dy)
            r.origin.y = frame.maxY - r.height
        }
        return r
    }

    /// The system's resize cursor for these edges.
    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition = switch self {
        case [.top, .left]: .topLeft
        case [.top, .right]: .topRight
        case [.bottom, .left]: .bottomLeft
        case [.bottom, .right]: .bottomRight
        case .left: .left
        case .right: .right
        case .top: .top
        default: .bottom
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

extension EnvironmentValues {
    /// The most height a bar item's popover may take: from under its item to the foot of the screen's visible frame; nil
    /// where nothing caps it (a page's pane, a render).
    @Entry var barPopoverRoom: CGFloat? = nil
}

extension NSView {
    /// The view's frame in screen coordinates; nil off screen.
    var screenFrame: CGRect? { window.map { $0.convertToScreen(convert(bounds, to: nil)) } }
}
