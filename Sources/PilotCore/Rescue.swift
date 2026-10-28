import CoreGraphics

/// Bringing back windows a tiler left on hidden workspaces when it stopped (story 72). The tiler hides a window by
/// parking it in a corner of its monitor with a pixel showing, so a stranded window is one almost wholly off every
/// screen. Every rect is in Accessibility coordinates.
public enum Rescue {
    /// Less than a tenth of the window shows on any screen.
    public static func isStranded(_ frame: CGRect, screens: [CGRect]) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        let shown = screens.reduce(0) { sum, screen in
            let part = frame.intersection(screen)
            return part.isNull ? sum : sum + part.width * part.height
        }
        return shown < area / 10
    }

    /// Where stranded windows land: cascaded 40 pt apart from the visible frame's top-left, ten deep, each at its own
    /// size where that fits and never past the frame's edges.
    public static func placements(_ frames: [CGRect], in visible: CGRect) -> [CGRect] {
        frames.enumerated().map { i, frame in
            let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
            let step = CGFloat(i % 10 + 1) * 40
            return CGRect(x: min(visible.minX + step, visible.maxX - width), y: min(visible.minY + step, visible.maxY - height),
                          width: width, height: height)
        }
    }
}

/// Apps named once each, first seen first, with how many times each was named: "Zen (2), Obsidian".
public enum AppCounts {
    public static func firstSeen(_ apps: [String]) -> [(name: String, count: Int)] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0).inserted }.map { app in (app, apps.count { $0 == app }) }
    }
}
