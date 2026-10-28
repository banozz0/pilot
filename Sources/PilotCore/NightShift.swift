/// Night Shift's on and off, as the app reaches it: Apple's private CoreBrightness client, a fake in tests.
public protocol NightShiftClient {
    /// On or off; nil when this Mac or macOS has no Night Shift Pilot can reach.
    func isOn() -> Bool?
    /// False when macOS refused.
    func set(_ on: Bool) -> Bool
}

/// Omarchy's Super+Ctrl+N nightlight on the Mac (card agent-bo-95422972, story 126): Night Shift on or off, with the
/// tip to show. Night Shift has no public API, so a macOS update can break it; it needs no SIP and no prompt.
public enum NightShift {
    public static func toggle(_ client: any NightShiftClient) -> String {
        guard let on = client.isOn() else { return "Night Shift is not available on this Mac" }
        guard client.set(!on) else { return "macOS refused to change Night Shift" }
        return on ? "Night Shift off" : "Night Shift on"
    }
}
