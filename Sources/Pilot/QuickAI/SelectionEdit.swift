import AppKit
import ApplicationServices
import Clipboard
import PilotCore

/// The selection the box works on (spec ai-selected-text T2), captured as it opens: its text and app, and where
/// Accessibility gave it, the focused element, the selected range and that range's place on screen. The element is only
/// asked off the main thread; Accessibility elements are safe to pass between threads.
struct SelectionTarget: @unchecked Sendable {
    let text: String
    let pid: pid_t
    /// The app's name, for logs and tips.
    let app: String
    let bundleID: String?
    /// The focused element holding the selection; nil when the text came through the app's Copy.
    var element: AXUIElement?
    /// The selected range, UTF-16 as Accessibility counts.
    var range: CFRange?
    /// Accessibility takes a write of the selected text.
    var writable = false
    /// The selection's bounds in AppKit's screen coordinates (bottom-left origin), when the app gives them.
    var bounds: CGRect?
}

/// Reads, replaces and undoes the selection in another app without posting a key (ADR 0001): through Accessibility
/// first, else through the app's own Copy, Paste and Undo menu items pressed through Accessibility (AXMenu), the
/// clipboard borrowed and Sven's copy put back. Accessibility and the menu walk run off the main thread, so the tap
/// never waits on another app.
@MainActor
final class SelectionEdit {
    static let shared = SelectionEdit()

    /// How the replacement went in, so Undo takes the same way back.
    enum Route: Equatable { case accessibility, menu }

    struct Replacement {
        let target: SelectionTarget
        let text: String
        let route: Route
    }

    enum Outcome {
        /// Over the selection; the original kept in the clipboard history.
        case replaced(Replacement)
        /// The app is no longer in front, or its selection moved: the answer is on the clipboard instead.
        case copied
    }

    /// What the app's Copy menu item gave: its text, nothing (no selection), or no enabled Copy to press at all, as in
    /// Ghostex's terminal and chat, whose Edit › Copy no view handles (GPUI greys it out).
    enum MenuCopy: Equatable, Sendable {
        case copied(String), nothing, noCopy
        var text: String? { if case .copied(let text) = self { text } else { nil } }
    }

    /// The app in front.
    struct App: Equatable, Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    /// Everything outside Pilot the edit touches, so a test can stand in for it.
    @MainActor struct World {
        var front: () -> App? = {
            NSWorkspace.shared.frontmostApplication.map { App(pid: $0.processIdentifier, name: $0.localizedName ?? "the app", bundleID: $0.bundleIdentifier) }
        }
        /// The focused element's selection through Accessibility.
        var focused: () async -> SelectionTarget? = { @MainActor in
            let primary = Screens.primaryHeight
            return await offMain { SelectionEdit.readFocused(primaryHeight: primary) }
        }
        /// The selection in Pilot's app window (SelectionEdit.selected): the main window, as the pill's own click may
        /// have made the pill key.
        var own: @MainActor () -> String? = { NSApp?.mainWindow.flatMap(SelectionEdit.selected(in:)) }
        /// The app's selection through its own Copy menu item.
        var menuCopy: (pid_t) async -> MenuCopy = { await SelectionEdit.menuCopy($0) }
        /// The captured element's selection now.
        var selected: (SelectionTarget) async -> String? = { t in await offMain { t.element.flatMap { SelectionEdit.selectedText($0) } } }
        /// The captured element still has the keyboard: the focused element is that very element.
        var stillFocused: (SelectionTarget) async -> Bool = { t in await offMain { SelectionEdit.isFocused(t.element) } }
        /// Writes over the captured element's selection; true once it took (SelectionPrompt.landed).
        var write: (SelectionTarget, String) async -> Bool = { t, s in await offMain { SelectionEdit.write(s, over: t) } }
        /// The text over the app's selection through its Paste menu item.
        var menuPaste: (pid_t, String) async -> Bool = { await SelectionEdit.menuPaste($0, $1) }
        /// The app's own Undo menu item.
        var menuUndo: (pid_t) async -> Bool = { pid in await offMain { AXMenu.press(pid: pid, cmdChar: "Z") } }
        /// The replacement selected again and the original written over it; false having touched nothing when the
        /// replacement is not where it went.
        var restore: (Replacement) async -> Bool = { r in await offMain { SelectionEdit.restore(r) } }
        /// The original into the clipboard history, the clipboard itself left alone.
        var keep: (String, String?) -> Void = { text, app in _ = try? ClipboardHistory.shared.store?.add(.plainText(text, sourceApp: app)) }
        /// On the clipboard as an ordinary copy.
        var copy: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    }

    var world = World()

    /// Why the last capture found nothing, as a tip: no selection, or an app whose Copy Pilot cannot press.
    private(set) var miss = SelectionBox.nothingSelected

    static func noCopy(_ app: String) -> String { "\(app) shares no selection here: its Edit › Copy is off" }

    /// The selection in the app in front: Pilot's own read directly, else Accessibility's, else the app's Copy menu item
    /// (never a posted key, ADR 0001). Nil when there is none, or only whitespace.
    func capture() async -> SelectionTarget? {
        miss = SelectionBox.nothingSelected
        if let app = world.front(), app.pid == getpid() { return world.own().flatMap(Self.ownTarget) }
        if let read = await world.focused() { return read }
        guard let app = world.front(), app.pid != getpid() else { return nil }
        switch await world.menuCopy(app.pid) {
        case .copied(let text): return SelectionTarget(text: text, pid: app.pid, app: app.name, bundleID: app.bundleID)
        case .nothing: return nil
        case .noCopy:
            ailog.notice("selection: no Accessibility selection and no enabled Copy in \(app.bundleID ?? app.name, privacy: .public)")
            miss = Self.noCopy(app.name)
            return nil
        }
    }

    /// The selection in one of Pilot's own windows, from the text view that has its keyboard (a SwiftUI field's editor
    /// too), never through Accessibility into Pilot itself.
    static func selected(in window: NSWindow) -> String? {
        guard let view = window.firstResponder as? NSTextView else { return nil }
        let range = view.selectedRange()
        return range.length > 0 ? (view.string as NSString).substring(with: range) : nil
    }

    /// Text selected in Pilot's own window as a target: Replace copies it rather than reaching into Pilot (`replace`).
    static func ownTarget(_ text: String) -> SelectionTarget? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SelectionTarget(text: text, pid: getpid(), app: "Pilot", bundleID: Bundle.main.bundleIdentifier)
    }

    /// Ask Pilot AI's text, handed over by the service: Accessibility's selection when it reads the same, else the
    /// front app's selection as the service gave it (Replace then checks it through the app's Copy first).
    func capture(given text: String) async -> SelectionTarget? {
        if let read = await world.focused(), read.text == text { return read }
        guard let app = world.front(), app.pid != getpid(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SelectionTarget(text: text, pid: app.pid, app: app.name, bundleID: app.bundleID)
    }

    /// `text` over the captured selection while its app is still in front with that text still selected; else copied.
    func replace(_ target: SelectionTarget, with text: String) async -> Outcome {
        // Pilot's own window: no Accessibility or menu press into Pilot itself (it runs AppKit on the asking thread).
        guard target.pid != getpid() else { return copied(text, "the selection is in Pilot's own window") }
        guard world.front()?.pid == target.pid else { return copied(text, "\(target.app) is no longer in front") }
        let now = target.element != nil ? await world.selected(target) : await world.menuCopy(target.pid).text
        guard now == target.text else { return copied(text, "the selection moved") }
        if target.writable, await world.write(target, text) { return replaced(target, text, .accessibility) }
        // Paste goes wherever the app's keyboard is: only into the element captured, its selection still the original
        // (a write that half took, or a click meanwhile, never gets the answer pasted in twice or into another field).
        if target.element != nil {
            guard await world.stillFocused(target), await world.selected(target) == target.text else {
                return copied(text, "the focus or the selection moved before Paste")
            }
        }
        guard world.front()?.pid == target.pid else { return copied(text, "\(target.app) is no longer in front") }
        guard await world.menuPaste(target.pid, text) else { return copied(text, "\(target.app) has no Paste") }
        return replaced(target, text, .menu)
    }

    /// The original back over the replacement, the way it went in; false when the app is no longer in front or the
    /// replacement is not where it went (the original is in the clipboard history either way).
    func undo(_ done: Replacement) async -> Bool {
        guard world.front()?.pid == done.target.pid else { return false }
        let undone = switch done.route {
        case .accessibility: await world.restore(done)
        case .menu: await world.menuUndo(done.target.pid)
        }
        ailog.notice("selection box: undo in \(done.target.app, privacy: .public) \(undone ? "done" : "not done", privacy: .public)")
        return undone
    }

    private func replaced(_ target: SelectionTarget, _ text: String, _ route: Route) -> Outcome {
        world.keep(target.text, target.bundleID)
        ailog.notice("selection box: replaced in \(target.app, privacy: .public) by \(route == .menu ? "Paste" : "Accessibility", privacy: .public), \(text.count) characters")
        return .replaced(Replacement(target: target, text: text, route: route))
    }

    private func copied(_ text: String, _ why: String) -> Outcome {
        world.copy(text)
        ailog.notice("selection box: copied, \(why, privacy: .public)")
        return .copied
    }
}

// MARK: - Live

extension SelectionEdit {
    /// `work` on a global queue, so Accessibility into a slow app holds that queue, never the main thread.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) } }
    }

    /// The focused element's selection, with its range, bounds and whether it takes a write. Never Pilot's own:
    /// Accessibility into its own process runs AppKit on the asking thread (AXMenu), so it is never asked (AXFront).
    nonisolated static func readFocused(primaryHeight: CGFloat) -> SelectionTarget? {
        // The front app's, with AXTimeout's wait: a hung app answers no faster, never Accessibility's default 6 s.
        guard let element = AXFront.focusedElement() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid(), let text = selectedText(element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let range = selectedRange(element)
        return SelectionTarget(text: text, pid: pid, app: app?.localizedName ?? "the app", bundleID: app?.bundleIdentifier, element: element,
                               range: range, writable: settable.boolValue, bounds: range.flatMap { bounds(of: $0, in: element, primaryHeight: primaryHeight) })
    }

    /// Whether `element` is the focused element now.
    nonisolated static func isFocused(_ element: AXUIElement?) -> Bool {
        guard let element, let focused = AXFront.focusedElement() else { return false }
        return CFEqual(focused, element)
    }

    nonisolated static func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    nonisolated static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// The range's bounds, flipped from Accessibility's top-left origin to AppKit's; nil for an empty or absurd rect.
    nonisolated static func bounds(of range: CFRange, in element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var cf = range
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return WindowGeometry.flip(rect, primaryHeight: primaryHeight)
    }

    /// `text` over the element's selection, then checked: an app may say yes and change nothing.
    nonisolated static func write(_ text: String, over target: SelectionTarget) -> Bool {
        guard let element = target.element else { return false }
        let before = characterCount(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        return SelectionPrompt.landed(countBefore: before, countAfter: characterCount(element), original: target.text,
                                      replacement: text, selectedAfter: selectedText(element))
    }

    /// The replacement selected again from where the original started, and the original written over it, only when
    /// the selected range then reads the replacement exactly.
    nonisolated static func restore(_ done: SelectionEdit.Replacement) -> Bool {
        guard let element = done.target.element, let start = done.target.range?.location else { return false }
        var range = CFRange(location: start, length: done.text.utf16.count)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              selectedText(element) == done.text else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, done.target.text as CFString) == .success
    }

    /// The app's Copy, the history paused meanwhile: the copy is borrowed, and Sven's goes back transient. The menu
    /// walk runs off the main thread; PasteBack watches for the copy once it is pressed.
    static func menuCopy(_ pid: pid_t) async -> MenuCopy {
        ClipboardHistory.shared.pause()
        defer { ClipboardHistory.shared.resume() }
        var pressed = false
        let text = await PasteBack.copySelection(from: .general) {
            pressed = await offMain { AXMenu.press(pid: pid, titles: ["Copy"], orShortcut: "C", modifiers: 0) }
            return pressed
        }
        return text.map(MenuCopy.copied) ?? (pressed ? .nothing : .noCopy)
    }

    /// `text` on the clipboard (transient) and the app's Paste pressed off the main thread; Sven's copy goes back half
    /// a second after the press (PasteBack). False when the app has no Paste to press.
    static func menuPaste(_ pid: pid_t, _ text: String) async -> Bool {
        await PasteBack.paste(text, to: .general) { await offMain { AXMenu.press(pid: pid, titles: ["Paste"], orShortcut: "V", modifiers: 0) } }
    }
}
