import CoreGraphics

/// The border around the focused window (card agent-bo-95422950, story 125; Omarchy's and JankyBorders' coloured
/// frame): whether it shows and where. Not the theme's FocusBorder, which rings Pilot's own controls.
public enum WindowBorder {
    public static let widths = 1...8
    public static let defaultWidth = 2
    /// Smaller than this either way is a sliver, a toolbar or a popover, not a window to mark.
    static let minSide: CGFloat = 40

    public static func clamped(_ width: Int) -> Int { min(max(width, widths.lowerBound), widths.upperBound) }

    /// The focused window as the Accessibility API reports it: a top-left origin frame. AX can still name a minimised
    /// window focused, at its old frame (card agent-bo-95422995). `windowID` is the window server's number, which
    /// Defocus orders its overlay below (card agent-bo-95423220); nil when Accessibility does not give it.
    public struct Window: Equatable, Sendable {
        public var frame: CGRect, subrole: String?, fullScreen: Bool, minimised: Bool, windowID: CGWindowID?
        public init(frame: CGRect, subrole: String?, fullScreen: Bool, minimised: Bool, windowID: CGWindowID? = nil) {
            self.frame = frame; self.subrole = subrole; self.fullScreen = fullScreen; self.minimised = minimised; self.windowID = windowID
        }
    }

    /// The border panel's AppKit frame, the window's grown by `width` (Look keeps it clamped) on every side; nil when no border shows: off, no
    /// window, minimised, fullscreen (or a frame that is a whole screen), not a standard window (dialogs, sheets, panels), a
    /// sliver, or less than half of it on a screen (the tiler parks a hidden workspace's windows in a corner).
    /// `screens` are the screens' whole frames in AX coordinates.
    public static func frame(for window: Window?, on: Bool, width: Int, screens: [CGRect], primaryHeight: CGFloat) -> CGRect? {
        guard on, let window, !window.minimised, !window.fullScreen, window.subrole == "AXStandardWindow" else { return nil }
        let f = window.frame
        guard f.width >= minSide, f.height >= minSide, !screens.contains(f) else { return nil }
        let onScreen = screens.reduce(CGFloat(0)) { sum, s in
            let i = s.intersection(f)
            return i.isNull ? sum : sum + i.width * i.height
        }
        guard onScreen >= f.width * f.height / 2 else { return nil }
        return WindowGeometry.flip(f, primaryHeight: primaryHeight).insetBy(dx: -CGFloat(width), dy: -CGFloat(width))
    }
}
