import ApplicationServices

/// How long any Accessibility ask from Pilot waits for an app (card agent-bo-95423031). Binds run inside the key tap,
/// so a hung front app held every key for macOS's default wait; set on the system-wide element, it is the timeout of
/// every element Pilot makes (AXUIElement.h). Elements with their own (the bar's menus, the tiler's) keep theirs.
enum AXTimeout {
    static let seconds: Float = 0.5

    static func applyEverywhere() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}
