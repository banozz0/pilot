import Foundation

/// The resize panel's numbers (Q246): width and height in pixels, the aspect locked or not, the percent presets. Every
/// size stays between 1 and `limit` a side; with the aspect locked the other side follows, rounded.
public struct ResizeTarget: Equatable, Sendable {
    /// The size the panel opened on.
    public let originalWidth: Int, originalHeight: Int
    public private(set) var width: Int, height: Int
    public var locked = true

    /// A side no bigger than this: past it a 4x wallpaper's buffer passes a gigabyte.
    public static let limit = 16_384
    public static let presets = [25, 50, 75, 200]

    public init(width: Int, height: Int) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
    }

    private static func clamp(_ v: Double) -> Int { min(limit, max(1, Int(v.rounded()))) }

    public mutating func setWidth(_ w: Int) {
        width = Self.clamp(Double(w))
        if locked { height = Self.clamp(Double(width) * Double(originalHeight) / Double(originalWidth)) }
    }

    public mutating func setHeight(_ h: Int) {
        height = Self.clamp(Double(h))
        if locked { width = Self.clamp(Double(height) * Double(originalWidth) / Double(originalHeight)) }
    }

    /// A preset keeps the aspect whether locked or not.
    public mutating func setPercent(_ percent: Int) {
        width = Self.clamp(Double(originalWidth) * Double(percent) / 100)
        height = Self.clamp(Double(originalHeight) * Double(percent) / 100)
    }

    /// The preset the size is, nil for any other.
    public var percent: Int? {
        Self.presets.first { p in
            width == Self.clamp(Double(originalWidth) * Double(p) / 100) && height == Self.clamp(Double(originalHeight) * Double(p) / 100)
        }
    }

    public var changed: Bool { width != originalWidth || height != originalHeight }

    /// How much each side grows: another image under the same change (Finder's several files).
    public var factor: (x: Double, y: Double) { (Double(width) / Double(originalWidth), Double(height) / Double(originalHeight)) }

    /// `size` under the same factor, each side kept between 1 and the limit.
    public func applied(width w: Int, height h: Int) -> (width: Int, height: Int) {
        let f = factor
        return (Self.clamp(Double(w) * f.x), Self.clamp(Double(h) * f.y))
    }
}

/// The upscale panel's size (Sven, build 62): 2x, 3x or 4x, or a width or height typed with the aspect kept, never under
/// the image's own size nor past 4x or `ResizeTarget.limit` a side. Monitor presets fit or centre-crop each source;
/// impossible requests retain their requested size and explain why they cannot run. The model runs 2x up to 2, else 4x.
public struct UpscaleTarget: Equatable, Sendable {
    public enum Monitor: String, CaseIterable, Sendable {
        case ultrawide34, qhd27, uhd, ultrawide49, fullHD

        public var title: String {
            switch self {
            case .ultrawide34: "34-inch ultrawide"
            case .qhd27: "27-inch QHD"
            case .uhd: "27 / 32-inch 4K"
            case .ultrawide49: "49-inch super ultrawide"
            case .fullHD: "24-inch Full HD"
            }
        }

        public var size: (width: Int, height: Int) {
            switch self {
            case .ultrawide34: (3440, 1440)
            case .qhd27: (2560, 1440)
            case .uhd: (3840, 2160)
            case .ultrawide49: (5120, 1440)
            case .fullHD: (1920, 1080)
            }
        }

        public var label: String { "\(title) · \(size.width) × \(size.height)" }
    }

    public enum Framing: String, CaseIterable, Sendable {
        case fit, fill
        public var title: String { self == .fit ? "Fit whole image" : "Fill & crop" }
    }

    public static let presets = [2, 3, 4]
    public let originalWidth: Int, originalHeight: Int
    public private(set) var width: Int, height: Int
    public private(set) var monitor: Monitor?
    public private(set) var framing: Framing = .fit

    public init(width: Int, height: Int, times: Int = 4) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
        setFactor(Double(times))
    }

    /// The biggest factor the limit allows, 4 at most.
    public var maxFactor: Double {
        min(4, Double(ResizeTarget.limit) / Double(originalWidth), Double(ResizeTarget.limit) / Double(originalHeight))
    }

    public mutating func setFactor(_ f: Double) {
        monitor = nil
        let f = min(maxFactor, max(1, f))
        width = max(1, Int((Double(originalWidth) * f).rounded()))
        height = max(1, Int((Double(originalHeight) * f).rounded()))
    }

    public mutating func setWidth(_ w: Int) { setFactor(Double(w) / Double(originalWidth)) }
    public mutating func setHeight(_ h: Int) { setFactor(Double(h) / Double(originalHeight)) }

    /// CDXC:Upscale 2026-11-07 DECISION: Sven picked A: keep the scale buttons and add named monitor presets with
    /// Fit whole image or Fill & crop. Inches describe the preset; its pixels define the target. Do not stretch.
    public mutating func setMonitor(_ monitor: Monitor, framing: Framing = .fit) {
        self.monitor = monitor
        self.framing = framing
        let size = monitor.size
        let x = Double(size.width) / Double(originalWidth), y = Double(size.height) / Double(originalHeight)
        let f = framing == .fill ? max(x, y) : min(x, y)
        width = framing == .fill ? size.width : max(1, Int((Double(originalWidth) * f).rounded()))
        height = framing == .fill ? size.height : max(1, Int((Double(originalHeight) * f).rounded()))
    }

    /// The preset the size is, nil for a typed one.
    public var times: Int? {
        monitor == nil ? Self.presets.first { width == originalWidth * $0 && height == originalHeight * $0 } : nil
    }

    public var factor: Double {
        if crops { return max(Double(width) / Double(originalWidth), Double(height) / Double(originalHeight)) }
        return Double(width) / Double(originalWidth)
    }
    public var crops: Bool { monitor != nil && framing == .fill }
    /// Whether it makes the image any bigger.
    public var grows: Bool { width > originalWidth || height > originalHeight }

    /// Monitor requests stay exact so an impossible preset is explained, never silently capped to another size.
    public var issue: String? {
        if factor > 4.000001 { return String(format: "Needs %.1f×. This image is too small for this target; the limit is 4×.", factor) }
        if width > ResizeTarget.limit || height > ResizeTarget.limit || (crops && factor > maxFactor + 0.000001) {
            return "This target exceeds the 16,384 px limit."
        }
        if !grows { return "This target does not enlarge the image. Use Resize for a smaller result." }
        return nil
    }

    /// Monitor batches share a destination, while multiplier/custom batches share their original scale factor.
    public func forImage(width w: Int, height h: Int) -> UpscaleTarget {
        var other = UpscaleTarget(width: w, height: h, times: 1)
        if let monitor { other.setMonitor(monitor, framing: framing) }
        else { other.setFactor(times.map(Double.init) ?? factor) }
        return other
    }

    /// Another image's size under the same change (Finder's several files): the preset's factor, or the typed one.
    public func applied(width w: Int, height h: Int) -> (width: Int, height: Int) {
        let other = forImage(width: w, height: h)
        return (other.width, other.height)
    }

    /// The model's pass for a factor: 2 up to 2x, else 4.
    public static func pass(_ factor: Double) -> Int { factor <= 2 ? 2 : 4 }

    /// The result's name after its stem: " 3x" for a whole factor, " 2560x1440" for any other.
    public static func suffix(from w: Int, _ h: Int, to width: Int, _ height: Int) -> String {
        let k = width / max(1, w)
        return k * w == width && k * h == height ? " \(k)x" : " \(width)x\(height)"
    }
}
