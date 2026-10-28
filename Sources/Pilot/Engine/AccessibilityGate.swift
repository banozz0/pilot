import ApplicationServices
import AppKit
import Observation

/// Onboarding step one. Prompts once, then polls AXIsProcessTrusted so the grant is seen live: no restart.
@Observable @MainActor
final class AccessibilityGate {
    private(set) var isTrusted: Bool
    /// System Settings › Privacy & Security › Accessibility, where Pilot's switch lives.
    static let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    var onGranted: () -> Void = {}
    private var poll: Timer?

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Shows the macOS prompt (once per app identity) and opens the Accessibility pane with the drag panel beside it, then
    /// watches for the grant. A row left by an older signature of Pilot keeps the prompt from showing: the panel says so.
    func request() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(opts)
        if isTrusted { onGranted(); return }
        NSWorkspace.shared.open(Self.pane)
        PermissionDragPanel.show(.accessibility)
        startPolling()
    }

    func startPolling() {
        guard poll == nil, !isTrusted else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        poll?.tolerance = 0.1
    }

    func check() {
        #if DEBUG
        guard !seeded else { return }
        #endif
        let now = AXIsProcessTrusted()
        guard now != isTrusted else { return }
        isTrusted = now
        if now {
            poll?.invalidate(); poll = nil
            onGranted()
        }
    }

    #if DEBUG
    /// The renders draw the every-day dropdown, which needs Accessibility the test process never has.
    /// Set by a seed, so no later check puts the real answer back mid-render.
    private var seeded = false
    func seed(trusted: Bool) {
        seeded = true
        poll?.invalidate()
        poll = nil
        isTrusted = trusted
    }
    #endif
}
