import CoreGraphics

/// Desktop icons left out of captures and recordings (Sven, Q189; the survey's item 5, as CleanShot, Screen Studio and
/// ShareX do): Finder draws them in one window a display at the desktop-icon level (checked on macOS 27, 2026-10-16),
/// apart from the wallpaper (WindowManager's). Captures leave those windows out of ScreenCaptureKit's filter, so the
/// desktop itself is never touched: nothing to hide on screen, nothing to restore, nothing left wrong if Pilot quits.
public enum DesktopIcons {
    public static let finder = "com.apple.finder"

    /// The window level Finder draws the icons at.
    public static var level: Int { Int(CGWindowLevelForKey(.desktopIconWindow)) }

    /// Whether a window is a desktop-icon window: Finder's, at the icon level.
    public static func holdsIcons(bundle: String?, layer: Int) -> Bool { bundle == finder && layer == level }
}
