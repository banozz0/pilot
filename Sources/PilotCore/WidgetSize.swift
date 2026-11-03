import Foundation

// MARK: - Size classes

extension Widget {
    /// The four layouts every widget draws (Sven, Q727/Q729): its tile's size in points picks one, or Edit widget's Layout
    /// keeps one. Native tiles draw each class their own way (DeskKitPanel); a page gets `size-<class>` on its `<html>`.
    /// - Strip: short and wide, under 110 points tall and at least 1.6 times as wide: one line.
    /// - Large: big in both, at least 240 wide and 185 tall.
    /// - Wide: any other rectangle at least 1.3 times as wide as it is tall.
    /// - Square: the rest, near-square and small, and any portrait shape.
    /// Today's default sizes: 240×160, 260×160 and 300×170 are Wide; 260×220, 260×230, 280×200 and 280×260 Large.
    public enum SizeClass: String, CaseIterable, Codable, Sendable {
        case strip, square, wide, large

        public static let stripHeight = 110.0, stripRatio = 1.6, wideRatio = 1.3
        public static let largeWidth = 240.0, largeHeight = 185.0
        /// How far past a line a size must go to leave the class it has: a drag never flickers between two.
        public static let slack = 10.0

        /// The class a size falls in, with no class before it.
        public init(width: Double, height: Double) {
            if height < Self.stripHeight, width >= Self.stripRatio * height { self = .strip }
            else if width >= Self.largeWidth, height >= Self.largeHeight { self = .large }
            else if width >= Self.wideRatio * height { self = .wide }
            else { self = .square }
        }

        /// The class a size falls in when it had `previous`: it keeps that one while the size is within `slack` points
        /// of it, either way on either side.
        public init(width: Double, height: Double, after previous: SizeClass?) {
            let fresh = SizeClass(width: width, height: height)
            guard let previous, previous != fresh else { self = fresh; return }
            let near = [-Self.slack, 0, Self.slack]
            let held = near.contains { dw in near.contains { dh in SizeClass(width: width + dw, height: height + dh) == previous } }
            self = held ? previous : fresh
        }

        public init(_ size: CGSize, after previous: SizeClass? = nil) {
            self.init(width: size.width, height: size.height, after: previous)
        }

        /// The class on a page's `<html>`.
        public var css: String { "size-\(rawValue)" }
        public var title: String { rawValue.capitalized }
    }

    /// The name a placement keeps its Layout under, among its own values: absent for Auto.
    public static let layoutName = "layout"
    /// What Layout may be: auto, or a class.
    public static let layoutWords = ["auto"] + SizeClass.allCases.map(\.rawValue)

    /// Whether Pilot offers its Layout for this widget: every widget, unless it declares a setting of that name itself.
    public var offersLayout: Bool { !settings.contains { $0.name == Self.layoutName } }

    /// The class a placement keeps (Edit widget's Layout), nil for Auto: by its size.
    public func layout(of placement: Placement) -> SizeClass? {
        offersLayout ? placement.values?[Self.layoutName]?.string.flatMap(SizeClass.init(rawValue:)) : nil
    }
}
