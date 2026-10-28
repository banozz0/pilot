import CoreGraphics
import Foundation

/// The selection pill's rules (Sven Q214, Q215): Hyper held as the left button goes down, a drag, and the release shows
/// the pill; a plain selection never does. Not in the apps on its skip list (terminals, where a drag selects text all
/// day). Its tap is not armed while Hyper is the window-drag modifier, whose tap takes that drag from the app (Engine).
public enum SelectionPill {
    /// How far the pointer has to travel for a press to be a drag: a Hyper click stays a click.
    public static let minimumDrag: CGFloat = 6
    /// Terminals, editable: Ghostty and Terminal. Ghostex left the list on Build 60 (Sven wants the pill there): its
    /// browser panes copy through Edit › Copy, its terminal and chat grey that item out, and the tip says so (Build 62).
    public static let standardSkip = ["com.mitchellh.ghostty", "com.apple.Terminal"]
    public static let skipKey = "selection.pillSkip"

    /// Why Hyper+drag shows no pill while windows move with Hyper.
    public static let blocked = "Hyper+drag moves windows (Tiling › Hold to move or resize). Pick another modifier there to select text with Hyper+drag."

    /// Whether a press of the left button with Hyper held starts the pill's gesture: not in a skipped app.
    public static func starts(app: String?, skip: [String]) -> Bool { !(app.map(skip.contains) ?? false) }

    /// Whether the release ends a drag from `down`.
    public static func dragged(from down: CGPoint, to up: CGPoint) -> Bool {
        hypot(up.x - down.x, up.y - down.y) >= minimumDrag
    }

    /// The skip list as stored, one bundle id per entry, blanks and repeats dropped; the standard list when none is stored.
    public static func skip(_ stored: [String]?) -> [String] {
        guard let stored else { return standardSkip }
        var seen = Set<String>()
        return stored.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
