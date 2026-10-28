import AppKit
import PilotTiler

/// Where the gap handles are laid; the real ones are panels, tests a fake.
@MainActor
protocol GapHandleSurface: AnyObject {
    func place(_ gaps: [TilerGap])
}

/// The mouse cursor over a gap; the real one is AppKit's, tests a fake.
@MainActor
protocol GapCursor: AnyObject {
    /// The left-right resize cursor for a `vertical` gap (tiles side by side), else the up-down one.
    func resize(vertical: Bool)
    func reset()
}

/// Gap resize (card agent-bo-95423035): after each layout the own tiler hands over every inner gap between two tiles
/// (TilerGaps), and a see-through handle over each shows the resize cursor and passes the press, drags and release to the
/// tiler, which moves the split. A mouse move outside a drag costs Pilot nothing: the window server finds the handle.
@MainActor
final class GapHandles {
    /// The tiler's side of a drag; tests a fake.
    struct Tiler {
        var press: @MainActor () -> Bool = TilerGaps.press
        var drag: @MainActor () -> Void = TilerGaps.drag
        var release: @MainActor () -> Void = TilerGaps.release
    }

    private let cursor: any GapCursor
    private let tiler: Tiler
    private var surface: (any GapHandleSurface)!
    private var over = false
    private var held = false

    init(surface: (any GapHandleSurface)? = nil, cursor: any GapCursor = SystemGapCursor(), tiler: Tiler = Tiler()) {
        self.cursor = cursor
        self.tiler = tiler
        self.surface = surface ?? GapHandlePanels(handles: self)
    }

    func update(_ gaps: [TilerGap]) { surface.place(gaps) }

    func entered(vertical: Bool) {
        over = true
        cursor.resize(vertical: vertical)
    }

    func exited() {
        over = false
        if !held { cursor.reset() }
    }

    func pressed() { held = tiler.press() }

    func dragged() { if held { tiler.drag() } }

    func released() {
        guard held else { return }
        held = false
        tiler.release()
        if !over { cursor.reset() }
    }
}

@MainActor
final class SystemGapCursor: GapCursor {
    func resize(vertical: Bool) { (vertical ? NSCursor.columnResize : NSCursor.rowResize).set() }
    func reset() { NSCursor.arrow.set() }
}

/// One see-through panel per gap, kept and reused as the gaps change, just above the desktop so every window, floating ones
/// included, stays above it and takes its own clicks.
@MainActor
final class GapHandlePanels: GapHandleSurface {
    private unowned let handles: GapHandles
    private var panels: [NSPanel] = []

    init(handles: GapHandles) { self.handles = handles }

    /// An overlay panel (WindowBorderPanel.overlay) that takes a click, also where it is clear, without activating Pilot.
    static func panel() -> NSPanel {
        let panel = WindowBorderPanel.overlay()
        panel.ignoresMouseEvents = false // set, so its clear pixels take the mouse too
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        return panel
    }

    func place(_ gaps: [TilerGap]) {
        for (index, gap) in gaps.enumerated() {
            if index == panels.count {
                let panel = Self.panel()
                panel.contentView = GapHandleView(handles: handles)
                panels.append(panel)
            }
            let panel = panels[index]
            (panel.contentView as? GapHandleView)?.vertical = gap.vertical
            if panel.frame != gap.frame { panel.setFrame(gap.frame, display: false) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for panel in panels.dropFirst(gaps.count) where panel.isVisible { panel.orderOut(nil) }
    }
}

/// A handle's content: the mouse over it and its press, drags and release, told to GapHandles.
@MainActor
final class GapHandleView: NSView {
    private unowned let handles: GapHandles
    var vertical = true

    init(handles: GapHandles) {
        self.handles = handles
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseEntered(with _: NSEvent) { handles.entered(vertical: vertical) }
    override func cursorUpdate(with _: NSEvent) { handles.entered(vertical: vertical) }
    override func mouseExited(with _: NSEvent) { handles.exited() }
    override func mouseDown(with _: NSEvent) { handles.pressed() }
    override func mouseDragged(with _: NSEvent) { handles.dragged() }
    override func mouseUp(with _: NSEvent) { handles.released() }
}
