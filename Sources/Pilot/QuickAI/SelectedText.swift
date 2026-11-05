import AppKit
import ApplicationServices
import Clipboard
import PilotCore

/// The text selected in the focused app (card agent-bo-95423050): read through Accessibility, else, where an app's
/// Accessibility has no selected text (Ghostex's GPUI, Electron apps, Chrome without its accessibility tree), through
/// the app's own Copy, Sven's clipboard put back after (PasteBack.copySelection).
struct SelectedText: Equatable, Sendable {
    let text: String
    let pid: pid_t
    /// The app's name, for logs.
    let app: String

    /// Accessibility's answer first; the app's Copy only when it has none, in the app in front. Nil when neither has
    /// text, or only whitespace.
    @MainActor
    static func focused(accessibility: () async -> SelectedText? = { await axFocused() },
                        copy: () async -> String? = { await copied() },
                        front: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) async -> SelectedText? {
        if let read = await accessibility() { return read }
        guard let app = front(), let text = await copy() else { return nil }
        return SelectedText(text: text, pid: app.processIdentifier, app: app.localizedName ?? "the app")
    }

    /// The app's Copy, with the clipboard history paused meanwhile: the copy is borrowed, not Sven's, and his own goes
    /// back transient, so resuming finds nothing to keep.
    @MainActor
    private static func copied() async -> String? {
        ClipboardHistory.shared.pause()
        defer { ClipboardHistory.shared.resume() }
        return await PasteBack.copySelection(from: .general) { Post.key(KeyCode.c, .cmd) }
    }

    /// The focused element's selection, asked off the main thread: an app that hangs holds this read for AXTimeout's
    /// 0.5 s, never the tap or the menu. Nil when nothing is selected, only whitespace, or the app does not say.
    private static func axFocused() async -> SelectedText? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: read()) }
        }
    }

    private static func read() -> SelectedText? {
        guard let element = AXFront.focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return SelectedText(text: text, pid: pid, app: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app")
    }
}
