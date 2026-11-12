// Pilot (scrolling layout, spec Projects/Pilot/specs/scrolling-layout.html): a scrolling root lays each child out as a
// column on one horizontal strip per workspace, at the column's own width, and scrolls the strip the least that shows
// the focused column whole (Hyprland's focus_fit_method = 1, ChainYourMac). Layout itself is layoutScrolling in
// layoutRecursive.swift; the strip's arithmetic and the column calls are here.
import AppKit
import PilotCore

/// One strip's columns, left to right: where each starts on the strip and how wide it is. A column of fraction f is
/// f × (usable + gap) − gap wide (niri's rule), so three thirds and their two gaps fill the usable width exactly and full
/// is the usable width; a lone column is always full (Omarchy's fullscreen_on_one_column).
struct Strip {
    /// Every column's width until Hyper+R changes one, half the usable width (Sven's Q42, 2026-10-12): two columns fill
    /// the screen and the rest wait to be scrolled to; a lone one is full.
    static let automaticWidth: CGFloat = 1.0 / 2
    /// How long a strip scroll glides, eased out (GlideSet): one speed, smooth and fast at once (Sven, 2026-10-12).
    static let glide: Duration = GlideSet.duration

    let usable: Rect
    let columns: [(x: CGFloat, width: CGFloat)]
    var length: CGFloat { columns.last.map { $0.x + $0.width } ?? 0 }

    init(fractions: [CGFloat], usable: Rect, gap: CGFloat) {
        self.usable = usable
        var x: CGFloat = 0
        columns = fractions.map { fraction in
            let width = fractions.count == 1 ? usable.width : max(1, fraction * (usable.width + gap) - gap)
            defer { x += width + gap }
            return (x, width)
        }
    }

    /// The offset nearest `offset` that shows column `index` whole, landing it on the usable edge (the outer gap from the
    /// monitor's); never past either end of the strip, so no empty space shows while a column is off screen. `centre`
    /// always, or on overflow when the column is not whole at `offset`, puts it in the middle instead (T9).
    func offset(showing index: Int?, from offset: CGFloat, centre: PilotBlock.CentreMode = .never) -> CGFloat {
        var offset = offset
        if let index, columns.indices.contains(index) {
            let column = columns[index]
            let whole = column.x >= offset - 0.5 && column.x + column.width <= offset + usable.width + 0.5
            if centre == .always || centre == .overflow && !whole { return self.offset(centring: index) }
            if column.x < offset {
                offset = column.x
            } else if column.x + column.width > offset + usable.width {
                offset = column.x + column.width - usable.width
            }
        }
        return offset.coerce(in: 0 ... max(0, length - usable.width))
    }

    /// The offset that puts column `index` in the middle, as far as the strip's ends allow.
    func offset(centring index: Int) -> CGFloat {
        let column = columns[index]
        return (column.x + column.width / 2 - usable.width / 2).coerce(in: 0 ... max(0, length - usable.width))
    }

    /// Each column's frame at `offset`. One wholly past an edge of `monitor` is pulled back to keep `sliver` points on
    /// screen: macOS clamps any frame further out to 40 points showing (probe, 2026-10-12).
    func frames(at offset: CGFloat, on monitor: Rect, sliver: CGFloat) -> [Rect] {
        columns.map { column in
            let x = (usable.minX + column.x - offset).coerce(in: monitor.minX + sliver - column.width ... max(monitor.minX + sliver - column.width, monitor.maxX - sliver))
            return Rect(topLeftX: x, topLeftY: usable.minY, width: column.width, height: usable.height)
        }
    }
}

extension TilingContainer {
    /// The column the strip keeps in view: the focused window's when it is on this strip, else the most recent. Focus is
    /// asked first: an auto layout's rebuild binds every window again, which leaves the last one the most recent.
    @MainActor
    var focusedColumnIndex: Int? {
        let column = focus.windowOrNil.flatMap(column(of:)) ?? mostRecentChild
        return children.firstIndex { $0 === column }
    }

    /// The child of this strip that holds `node`: the window itself, or the stack a join made.
    func column(of node: TreeNode) -> TreeNode? {
        node.parentsWithSelf.first { $0.parent === self }
    }

    /// A column without a width takes the automatic one, or its app's (T11); once a window opens or closes, so the strip
    /// has another number of columns, every column does, and what Hyper+R set is gone (spec scrolling-layout T8).
    @MainActor
    func fitColumnWidths() {
        let refit = children.count != fittedColumns
        fittedColumns = children.count
        for child in children where refit || child.columnWidth == nil {
            child.columnWidth = child.anyLeafWindowRecursive?.app.rawAppBundleId.flatMap { config.scrollingAppWidths[$0] }
                ?? Strip.automaticWidth
        }
    }

    /// This strip's columns over `usable`: at their own widths, or all equal so every one is on screen.
    @MainActor
    func strip(usable: Rect, gap: CGFloat, equalWidths: Bool = false) -> Strip {
        Strip(fractions: children.map { equalWidths ? 1 / CGFloat(children.count) : $0.columnWidth ?? config.scrollingNewWidth }, usable: usable, gap: gap)
    }
}

extension TreeNode {
    /// Every window of this column waits in `corner` at the column's size, a jump (no glide crosses onto the display
    /// beside it), and is no longer laid out anywhere, so drops and focus lookups skip it; the next layout that shows it
    /// jumps back for the same reason. A window the mouse holds is left to the mouse.
    @MainActor
    func hideColumn(_ size: CGSize, in corner: OptimalHideCorner, of monitor: MonitorInfo, span: ClosedRange<CGFloat>?) {
        lastAppliedLayoutPhysicalRect = nil
        lastAppliedLayoutVirtualRect = nil
        if let window = self as? Window {
            guard window.windowId != currentlyManipulatedWithMouseWindowId else { return }
            window.setAxFrame(window.cornerTopLeft(corner, on: monitor, width: size.width), size, span: span)
        }
        for child in children { child.hideColumn(size, in: corner, of: monitor, span: span) }
    }
}

extension MonitorInfo {
    /// The x a scrolling column on this monitor keeps within: up to the nearest display beside it at the same height on
    /// either side, open where there is none (a sliver and the hide corner sit past an open edge).
    func columnSpan(among monitors: [MonitorInfo]) -> ClosedRange<CGFloat> {
        var span = -CGFloat.greatestFiniteMagnitude ... CGFloat.greatestFiniteMagnitude
        for other in monitors.map(\.rect) where other.topLeftCorner != rect.topLeftCorner
            && min(other.maxY, rect.maxY) - max(other.minY, rect.minY) > 0.5
        {
            if other.maxX <= rect.minX + 0.5 { span = max(span.lowerBound, other.maxX) ... span.upperBound }
            if other.minX >= rect.maxX - 0.5 { span = span.lowerBound ... min(span.upperBound, other.minX) }
        }
        return span
    }
}

extension Window {
    /// The scrolling strip this window's column is on, and the column; nil outside a scrolling workspace.
    @MainActor
    var scrollingColumn: (strip: TilingContainer, column: TreeNode)? {
        guard let root = try? nodeWorkspace?.rootTilingContainer, root.layout == .scrolling, let column = root.column(of: self) else { return nil }
        return (root, column)
    }

    /// The column steps to the next width in the settings' list (`forward`), or the one before, round from the widest to
    /// the narrowest; false outside a scrolling workspace.
    @MainActor @discardableResult
    func cycleColumnWidth(forward: Bool) -> Bool {
        guard let (_, column) = scrollingColumn else { return false }
        let widths = config.scrollingWidths.sorted(), current = column.columnWidth ?? config.scrollingNewWidth
        let next = forward
            ? widths.first { $0 > current + 0.001 } ?? widths.first
            : widths.last { $0 < current - 0.001 } ?? widths.last
        guard let next else { return false }
        column.columnWidth = next
        return true
    }

    /// The column goes full width, or back to the width it had before (T10, ChainYourMac's ⌃⌥F); one already full without
    /// a width to go back to takes the automatic one. False outside a scrolling workspace.
    @MainActor @discardableResult
    func toggleColumnMaximised() -> Bool {
        guard let (_, column) = scrollingColumn else { return false }
        let width = column.columnWidth ?? config.scrollingNewWidth
        if let before = column.widthBeforeMaximise {
            column.columnWidth = before
        } else if width >= 1 {
            column.columnWidth = Strip.automaticWidth
        } else {
            column.columnWidth = 1
            column.widthBeforeMaximise = width
        }
        return true
    }

    /// The window leaves the stack its column holds for a column of its own right after it (T10, ChainYourMac's pop out of
    /// a stack); the one left alone in the stack becomes its column. False outside a strip or for a column of one window.
    @MainActor @discardableResult
    func leaveStack() throws -> Bool {
        guard let (root, column) = scrollingColumn, column !== self, let index = root.children.firstIndex(where: { $0 === column }) else { return false }
        try unbindFromParent()
        try bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: index + 1)
        return true
    }

    /// The strip scrolls to put this window's column in the middle, as far as its ends allow; false outside a
    /// scrolling workspace.
    @MainActor @discardableResult
    func centreColumn() -> Bool {
        guard let (root, column) = scrollingColumn, let monitor = nodeWorkspace?.workspaceMonitor,
              let index = root.children.firstIndex(where: { $0 === column }) else { return false }
        let strip = root.strip(usable: monitor.visibleRectPaddedByOuterGaps, gap: CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal))
        root.stripOffset = strip.offset(centring: index)
        return true
    }
}

extension Rect {
    /// The narrowest a column cut back at a bordered edge still peeks: narrower, most apps' minimum width would push the
    /// window over its neighbour, so it hides instead.
    static let narrowestPeek: CGFloat = 200

    /// A column that would reach over the display beside a bordered edge, cut back to its part within `span` (ADR 0014 as
    /// amended 2026-11-12, Sven: "show left half still even though i have my monitor on the left"), so it peeks as a
    /// column past the open edge does without crossing; nil with less than `narrowestPeek` left. An app that refuses the
    /// narrower width is kept inside `span` by FrameSteps' read-back.
    func peek(within span: ClosedRange<CGFloat>) -> Rect? {
        let left = max(minX, span.lowerBound), right = min(maxX, span.upperBound)
        guard right - left >= Self.narrowestPeek else { return nil }
        return Rect(topLeftX: left, topLeftY: minY, width: right - left, height: height)
    }

    /// Whether the two share any area: a frame touching another display's edge does not reach onto it.
    func overlaps(_ other: Rect) -> Bool {
        min(maxX, other.maxX) - max(minX, other.minX) > 0.5 && min(maxY, other.maxY) - max(minY, other.minY) > 0.5
    }
}
