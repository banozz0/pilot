import AppKit
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

/// The front app's focused element, asked of that app alone; nil while Pilot is in front. Never the system-wide element:
/// with Pilot in front it answers in-process, AppKit and SwiftUI on the asking thread, and off the main thread that
/// deadlocks Accessibility's lock against SwiftUI's (T59).
enum AXFront {
    nonisolated static func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXTimeout.seconds)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXTimeout.seconds)
        return element
    }
}
