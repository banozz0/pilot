import CoreGraphics

/// What one display's capture overlay is doing (spec `capture.html` CP3): every display is grabbed at the press and
/// frozen, and Sven drags an area or picks a window on the still. Points are the display's own, from its top left, y
/// down. Releasing a drag takes the area at once; a click without a drag takes the window under it.
/// Escape always closes, whatever else is going on, so the overlay can never hold the keys.
public struct CaptureSelection: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case area, window }

    public enum Key: Equatable, Sendable { case escape, space, enter, tab, left, right, up, down, smart }

    public enum Outcome: Equatable, Sendable {
        case none
        /// Close every display's overlay, taking nothing.
        case close
        /// The area, in this display's points.
        case area(CGRect)
        /// A window by its window server id.
        case window(UInt32)
        /// Copy the colour of the pixel under this point.
        case colour(CGPoint)
        /// Copy it as `rgb(r, g, b)` (Shift+Tab, P72).
        case rgb(CGPoint)
        /// Move the pointer here (an arrow key): the overlay warps the cursor over itself, nothing is posted to an app.
        case pointer(CGPoint)
    }

    /// An on-screen window, front first, its frame in this display's points.
    public struct Window: Equatable, Sendable {
        public let id: UInt32
        public let frame: CGRect
        /// The process that owns it, which a recording of one app records; 0 when not known.
        public let owner: Int32

        public init(id: UInt32, frame: CGRect, owner: Int32 = 0) {
            self.id = id
            self.frame = frame
            self.owner = owner
        }
    }

    /// The display in its own points: origin zero, its size.
    public let bounds: CGRect
    public private(set) var mode: Mode
    public private(set) var pointer: CGPoint
    /// The area being dragged, whole points, inside the display.
    public private(set) var area: CGRect?
    public let windows: [Window]
    private var anchor: CGPoint?
    /// Smart selection (A, Sven Q189): a drag snaps to its content on release (the overlay trims it), and with nothing
    /// dragged the UI element under the pointer is ringed and a click or Return takes it.
    public private(set) var smart = false
    /// The UI element under the pointer, in this display's points, which the overlay looks up while smart is on.
    public var element: CGRect?

    /// A drag shorter than this either way is a click.
    public static let click: CGFloat = 4

    /// `smart` starts with smart selection on: Capture a UI element (P72).
    public init(size: CGSize, windows: [Window] = [], mode: Mode = .area, pointer: CGPoint = .zero, smart: Bool = false) {
        bounds = CGRect(origin: .zero, size: size)
        self.windows = windows
        self.mode = mode
        self.pointer = Self.clamp(pointer, to: bounds)
        self.smart = smart && mode == .area
    }

    /// The window the pointer is over, front first.
    public var hovered: Window? { windows.first { $0.frame.contains(pointer) } }

    public var isDragging: Bool { anchor != nil }

    public mutating func move(to point: CGPoint) {
        pointer = Self.clamp(point, to: bounds)
        if let anchor { area = Self.rect(anchor, pointer) }
        if let element, !element.contains(pointer) { self.element = nil }
    }

    public mutating func press(at point: CGPoint) {
        move(to: point)
        guard mode == .area else { return }
        anchor = pointer
        area = nil
    }

    public mutating func release(at point: CGPoint) -> Outcome {
        move(to: point)
        defer { anchor = nil }
        switch mode {
        case .area:
            if let area, area.width >= Self.click || area.height >= Self.click { return .area(area) }
            self.area = nil
            if smart, let element { return .area(element) }
            return hovered.map { .window($0.id) } ?? .none
        case .window:
            return hovered.map { .window($0.id) } ?? .none
        }
    }

    public mutating func key(_ key: Key, shift: Bool = false) -> Outcome {
        switch key {
        case .escape:
            return .close
        case .space:
            mode = mode == .area ? .window : .area
            anchor = nil
            area = nil
            smart = false
            element = nil
            return .none
        case .smart:
            smart.toggle()
            mode = .area
            element = nil
            return .none
        case .enter:
            // Nothing dragged: the whole display.
            if mode == .window, let hovered { return .window(hovered.id) }
            if smart, area == nil, let element { return .area(element) }
            return .area(area ?? bounds)
        case .tab:
            return shift ? .rgb(pointer) : .colour(pointer)
        case .left, .right, .up, .down:
            let step: CGFloat = shift ? 10 : 1
            let delta: CGPoint = switch key {
            case .left: CGPoint(x: -step, y: 0)
            case .right: CGPoint(x: step, y: 0)
            case .up: CGPoint(x: 0, y: -step)
            default: CGPoint(x: 0, y: step)
            }
            move(to: CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y))
            return .pointer(pointer)
        }
    }

    /// The rectangle between two corners, in whole points.
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let x0 = min(a.x, b.x).rounded(.down), y0 = min(a.y, b.y).rounded(.down)
        let x1 = max(a.x, b.x).rounded(.up), y1 = max(a.y, b.y).rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// `rect` in a display's points as whole pixels of its image at `scale`, grown out to the pixel grid and kept inside
    /// an image of `pixels`.
    public static func pixels(_ rect: CGRect, scale: CGFloat, within pixels: CGSize) -> CGRect {
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        return r.intersection(CGRect(origin: .zero, size: pixels))
    }

    /// Windows in global points (top left of the main display, y down) as one display's: those that touch it, clipped
    /// to it, in their order, a sliver under `minimum` points either way left out.
    public static func windows(_ global: [Window], on display: CGRect, minimum: CGFloat = 20) -> [Window] {
        global.compactMap { w in
            let clipped = w.frame.intersection(display)
            guard !clipped.isNull, clipped.width >= minimum, clipped.height >= minimum else { return nil }
            return Window(id: w.id, frame: clipped.offsetBy(dx: -display.minX, dy: -display.minY), owner: w.owner)
        }
    }
}
