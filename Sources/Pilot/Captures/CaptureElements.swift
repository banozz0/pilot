import ApplicationServices

/// Smart selection's UI elements (Sven Q189): the Accessibility element under a point and its parents up to its
/// window, smallest first, as frames in global points (top left of the main display, y down). The app that owns the
/// window there is asked directly: the overlay covers the screen, so a system-wide hit test would find the overlay.
/// Called off the main thread; a hung app gets half a second per element.
enum CaptureElements {
    static func frames(at point: CGPoint, pid: pid_t, minimum: CGFloat = 8) -> [CGRect] {
        // Never Pilot's own: off the main thread, AppKit would answer in-process and deadlock against SwiftUI (T59).
        guard pid != getpid() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return [] }
        var frames: [CGRect] = []
        for _ in 0..<16 {
            AXUIElementSetMessagingTimeout(element, 0.5)
            if let f = frame(element), f.width >= minimum, f.height >= minimum, f.contains(point), frames.last != f { frames.append(f) }
            guard (value(element, kAXRoleAttribute) as? String) != kAXWindowRole,
                  let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return frames
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let pos = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
