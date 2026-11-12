import CoreGraphics

/// Where the pill's drop hangs (spec desktop-controls T5): under the pill's own item on the bar the click came from,
/// kept inside the screen's visible frame, from the bar's lower edge; with no bar (the top bar off, the pill by key only)
/// from the visible frame's top, centred. AppKit's screen coordinates, the origin bottom left.
public enum PillPlacement {
    /// The drop's size: T2's face, 600 wide and a 12 pt shoulder each side, tall enough for a view's tabs and body.
    public static let size = CGSize(width: 624, height: 300)
    /// The room kept to the visible frame's sides and foot.
    public static let edge: CGFloat = 8

    /// The drop's frame for a face of `size`, `item` being the pill's centre along the bar, nil with no item to go by.
    /// `ground` is the flat stretch of the bar's foot the item stands on (its island, the floating strip or the whole
    /// bar, less their rounded corners): the drop's top, shoulders and all, stays on it, so it reads as one shape grown
    /// from that ground, never jutting past an island's end (Sven on build 2276). A ground narrower than the drop centres
    /// the drop under it.
    public static func frame(size: CGSize = size, item: CGFloat?, visible: CGRect, bar: CGRect?, ground: CGRect? = nil) -> CGRect {
        let width = min(size.width, visible.width - 2 * edge)
        let top = min(bar?.minY ?? visible.maxY, visible.maxY)
        let height = max(0, min(size.height, top - visible.minY - edge))
        let centre = bar == nil ? visible.midX : item ?? visible.midX
        var x = (centre - width / 2).rounded()
        if bar != nil, let ground {
            x = ground.width >= width ? min(max(x, ground.minX), ground.maxX - width) : (ground.midX - width / 2).rounded()
        }
        x = min(max(x, visible.minX + edge), visible.maxX - edge - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The flat stretch of a bar window's foot: `window` less a `radius` corner at each end.
    public static func ground(window: CGRect, radius: CGFloat) -> CGRect {
        let r = min(max(0, radius), window.width / 2)
        return CGRect(x: window.minX + r, y: window.minY, width: window.width - 2 * r, height: window.height)
    }
}

/// The pill's views (spec desktop-controls T7): which show and in what order, the one selected, and the extensions'
/// bar items it holds. One selection for every display's pill. Saved apart from the bar, so a theme's Restore never
/// takes it back.
public enum Pill {
    public enum View: String, CaseIterable, Codable, Sendable {
        case music, extensions, activity, controls
    }

    public struct Layout: Codable, Equatable, Sendable {
        public var order: [View]
        public var hidden: Set<View>
        /// The view the compact pill and its drop show; a hidden one gives way to the first shown (`current`).
        public var selected: View
        /// The extensions' ids whose bar items the Extensions view shows, in order.
        public var extensions: [String]

        public static let standard = Layout(order: View.allCases, hidden: [], selected: .music, extensions: [])

        public init(order: [View], hidden: Set<View>, selected: View, extensions: [String]) {
            self.order = order; self.hidden = hidden; self.selected = selected; self.extensions = extensions
        }

        /// A saved layout read leniently: a view this Pilot lacks is dropped, one added since joins at its first place,
        /// a missing field takes the standard's, so an older or newer file still opens.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let words = (try? c.decode([String].self, forKey: .order)) ?? []
            let known = words.compactMap(View.init(rawValue:)).reduce(into: [View]()) { if !$0.contains($1) { $0.append($1) } }
            order = (try? Self.order(known)) ?? View.allCases
            hidden = Set(((try? c.decode([String].self, forKey: .hidden)) ?? []).compactMap(View.init(rawValue:)))
            if hidden.count == View.allCases.count { hidden = [] }
            selected = (try? c.decode(String.self, forKey: .selected)).flatMap(View.init(rawValue:)) ?? .music
            extensions = (try? c.decode([String].self, forKey: .extensions)) ?? []
        }

        /// The views that show, in order: the drop's tabs.
        public var shown: [View] { order.filter { !hidden.contains($0) } }

        /// The view showing now: the selected one, or the first shown when it was hidden.
        public var current: View { shown.contains(selected) ? selected : shown.first ?? .music }

        /// The extensions asked for their bar items on the pill's account: its own, only while Extensions shows.
        public var asked: [String] { current == .extensions ? extensions : [] }

        /// `given` first, then the rest in their first order; refuses a view named twice.
        public static func order(_ given: [View]) throws(ControlError) -> [View] {
            guard Set(given).count == given.count else { throw ControlError(.badValue, "a view is named twice in \(names(given))") }
            return given + View.allCases.filter { !given.contains($0) }
        }

        /// Refuses hiding every view: the pill always shows one.
        public static func hide(_ given: Set<View>) throws(ControlError) -> Set<View> {
            guard given.count < View.allCases.count else { throw ControlError(.badValue, "one view must show; the pill always has one") }
            return given
        }

        /// Refuses a hidden view: the selection is one of the tabs.
        public func select(_ view: View) throws(ControlError) -> View {
            guard !hidden.contains(view) else { throw ControlError(.badValue, "\(view.rawValue) is hidden; show it first") }
            return view
        }

        /// Refuses an empty id or one named twice.
        public static func extensions(_ ids: [String]) throws(ControlError) -> [String] {
            guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
                throw ControlError(.badValue, "an extension is named twice or empty in \(ids.joined(separator: ","))")
            }
            return ids
        }

        public mutating func move(_ view: View, to index: Int) {
            guard let from = order.firstIndex(of: view), order.indices.contains(index) else { return }
            order.insert(order.remove(at: from), at: index)
        }

        public static func names(_ views: [View]) -> String { views.map(\.rawValue).joined(separator: ",") }
    }
}

extension Pill.Layout {
    /// The view `by` steps from the one showing, through the shown views in order, wrapping: the drop's arrows and Tab,
    /// and the Next pill view key.
    public func step(_ by: Int) -> Pill.View {
        let shown = shown
        guard let i = shown.firstIndex(of: current) else { return current }
        return shown[((i + by) % shown.count + shown.count) % shown.count]
    }
}

extension Pill {
    /// What a key does in the open drop (the pill from the keyboard, Sven 2026-11-12): nil passes it on. `rows` is how
    /// many rows the view showing can light, `highlight` the lit one.
    public enum Press: Equatable, Sendable {
        case view(View), row(Int), act(Int), stop(Int), playPause, previous, next

        /// ← → and Tab, Shift-Tab step through the views, 1 to 4 jump to one, ↑ ↓ move the lit row, Return acts on it
        /// (Space too, outside Music), Delete stops a lit Activity row. In Music, Space plays or pauses and Shift-← →
        /// skip: plain arrows are the views', and Control, Option or Command can be the layer key, where an arrow is a
        /// Hyper bind (the tiler's). Any key held with Control, Option or Command passes on.
        public static func of(code: UInt16, shift: Bool, chord: Bool, chars: String?, layout: Layout, rows: Int, highlight: Int?) -> Press? {
            guard !chord else { return nil }
            let music = layout.current == .music
            switch Int64(code) {
            case KeyCode.tab: return .view(layout.step(shift ? -1 : 1))
            case KeyCode.leftArrow, KeyCode.rightArrow:
                let forward = Int64(code) == KeyCode.rightArrow
                if shift { return music ? (forward ? .next : .previous) : nil }
                return .view(layout.step(forward ? 1 : -1))
            case KeyCode.downArrow, KeyCode.upArrow:
                guard rows > 0 else { return nil }
                let down = Int64(code) == KeyCode.downArrow
                guard let highlight else { return .row(down ? 0 : rows - 1) }
                return .row(min(max(highlight + (down ? 1 : -1), 0), rows - 1))
            case KeyCode.returnKey, KeyCode.keypadEnter: return highlight.map(Press.act) ?? (music ? .playPause : nil)
            case KeyCode.space: return music ? .playPause : highlight.map(Press.act)
            case KeyCode.delete, KeyCode.forwardDelete: return layout.current == .activity ? highlight.map(Press.stop) : nil
            default:
                guard !shift, let digit = chars.flatMap(Int.init), layout.shown.indices.contains(digit - 1) else { return nil }
                return .view(layout.shown[digit - 1])
            }
        }
    }
}
