import CoreGraphics
import Foundation

/// Where the notification surfaces sit, in screen coordinates (origin bottom left), inside a screen's visible frame so the
/// Dock and the top bar stay clear: cards in the bottom right above the bell's corner; the bell there until Sven moves it,
/// and the drawer beside the bell wherever it is.
public enum NotificationPlacement {
    public static let margin: CGFloat = 16
    public static let gap: CGFloat = 8
    public static let bell = CGSize(width: 40, height: 40)
    public static let cardWidth: CGFloat = 340
    public static let drawerWidth: CGFloat = 380

    public static func bell(in visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - margin - bell.width, y: visible.minY + margin, width: bell.width, height: bell.height)
    }

    /// The top of the room above the bell, for a stack whose foot sits there.
    private static func foot(in visible: CGRect) -> CGFloat { visible.minY + margin + bell.height + gap }

    /// The stack's foot sits above the corner's bell, and above `bell` itself when it is low in the cards' column at any
    /// size, so a 96 pt bell in the corner is never covered (review B2).
    public static func cards(in visible: CGRect, size: CGSize, bell: CGRect? = nil) -> CGRect {
        let x = visible.maxX - margin - size.width
        var y = foot(in: visible)
        if let bell, bell.maxX > x, bell.minX < visible.maxX - margin, bell.minY < visible.midY { y = max(y, bell.maxY + gap) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// How small and large the bell may be pulled (Q42).
    public static let bellSides: ClosedRange<CGFloat> = 28...96

    /// The bell at `origin` (from the visible frame's foot left) at `side`, kept wholly inside the visible frame; the corner
    /// when nothing is saved.
    public static func bell(in visible: CGRect, at origin: CGPoint?, side: CGFloat) -> CGRect {
        let side = min(max(side, bellSides.lowerBound), bellSides.upperBound)
        guard let origin else { return CGRect(x: visible.maxX - margin - side, y: visible.minY + margin, width: side, height: side) }
        return CGRect(x: clamp(visible.minX + origin.x, visible.minX, visible.maxX - side),
                      y: clamp(visible.minY + origin.y, visible.minY, visible.maxY - side), width: side, height: side)
    }

    /// The drawer beside the bell wherever it is: above it if there is room, else below, else beside; flush with the
    /// bell's outer edge on its half of the screen; never past the visible frame.
    public static func drawer(nextTo bell: CGRect, in visible: CGRect, size: CGSize) -> CGRect {
        let w = min(size.width, visible.width - margin * 2), h = min(size.height, visible.height - margin * 2)
        let onRight = bell.midX >= visible.midX, onTop = bell.midY >= visible.midY
        var x = onRight ? bell.maxX - w : bell.minX
        var y: CGFloat
        if !onTop, bell.maxY + gap + h <= visible.maxY - margin { y = bell.maxY + gap }
        else if bell.minY - gap - h >= visible.minY + margin { y = bell.minY - gap - h }
        else if bell.maxY + gap + h <= visible.maxY - margin { y = bell.maxY + gap }
        else {
            // No room above or below: beside it, toward the screen's middle.
            x = onRight ? bell.minX - gap - w : bell.maxX + gap
            y = onTop ? bell.maxY - h : bell.minY
        }
        x = clamp(x, visible.minX + margin, visible.maxX - margin - w)
        y = clamp(y, visible.minY + margin, visible.maxY - margin - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func clamp(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(v, max(low, high))) }
}

/// Where Sven left the bell, one place a display (by its UUID), and which display it was on last. A place is the bell's
/// foot-left corner from that display's visible frame's, and its side.
public struct NotificationBellPlaces {
    public struct Place: Codable, Equatable, Sendable {
        public var x: Double, y: Double, side: Double
    }

    static let placesKey = "notifications.bellPlaces", displayKey = "notifications.bellDisplay", drawerKey = "notifications.drawerSize"
    public static let drawerFirst = CGSize(width: NotificationPlacement.drawerWidth, height: 440)
    public static let drawerMin = CGSize(width: 300, height: 200)
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var lastDisplay: String? { defaults.string(forKey: Self.displayKey) }

    public func place(on display: String) -> Place? { all[display] }

    /// The bell's frame on `display`: its place there, or the corner at the first side.
    public func frame(on display: String?, visible: CGRect) -> CGRect {
        let place = display.flatMap(place(on:))
        return NotificationPlacement.bell(in: visible, at: place.map { CGPoint(x: $0.x, y: $0.y) },
                                          side: place.map { CGFloat($0.side) } ?? NotificationPlacement.bell.width)
    }

    /// Keeps `bell` as dropped on `display`, kept inside its visible frame; returns the frame it keeps.
    @discardableResult
    public func save(_ bell: CGRect, on display: String, visible: CGRect) -> CGRect {
        let kept = NotificationPlacement.bell(in: visible, at: CGPoint(x: bell.minX - visible.minX, y: bell.minY - visible.minY), side: bell.width)
        var places = all
        places[display] = Place(x: kept.minX - visible.minX, y: kept.minY - visible.minY, side: kept.width)
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
        defaults.set(display, forKey: Self.displayKey)
        return kept
    }

    /// The drawer beside `bell` at the size it last closed at. Its place is never kept: a click always opens it beside the
    /// bell, and a move of the drawer lasts until it closes (Q55).
    public func drawer(nextTo bell: CGRect, in visible: CGRect) -> CGRect {
        NotificationPlacement.drawer(nextTo: bell, in: visible, size: drawerSize)
    }

    public var drawerSize: CGSize {
        guard let kept = defaults.array(forKey: Self.drawerKey) as? [Double], kept.count == 2 else { return Self.drawerFirst }
        return CGSize(width: max(kept[0], Self.drawerMin.width), height: max(kept[1], Self.drawerMin.height))
    }

    public func keepDrawerSize(_ size: CGSize) {
        defaults.set([Double(size.width), Double(size.height)], forKey: Self.drawerKey)
    }

    private var all: [String: Place] {
        defaults.data(forKey: Self.placesKey).flatMap { try? JSONDecoder().decode([String: Place].self, from: $0) } ?? [:]
    }
}
