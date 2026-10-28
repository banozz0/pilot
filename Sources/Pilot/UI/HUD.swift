import AppKit
import PilotCore
import SwiftUI

/// Small floating panels: a one-line tip that fades, and the panel every other HUD (the menu, the clipboard) is built on.
@MainActor
enum HUD {
    private static var tipPanel: KeyPanel?
    /// The shown tip: its words, which updateTip changes in place, and the handle updateTip takes.
    private(set) static var tipModel: TipModel?
    /// Where the shown tip opened: every refit centres on it, so whole-point frames never walk the tip sideways.
    private static var tipCentre = CGPoint.zero
    /// The shown tip's fade; nil while a tip stays up until closed (`seconds: .infinity`).
    private(set) static var tipTimer: Timer?
    private static var escMonitors: [Any] = []
    /// Every panel built here (the menu, the clipboard, the overlay, the tips): one above the notes panel, which stays
    /// up while Sven works, so none opens hidden under it.
    static let level = NSWindow.Level(rawValue: NotesPanel.level.rawValue + 1)

    /// A tip's one button (Convert's Cancel and Reveal, card agent-bo-95423211): its words, and what pressing it does.
    struct TipAction {
        let title: String
        let run: @MainActor () -> Void
    }

    /// A one-line message in the middle of the screen that fades after `seconds` (3 by default; `.infinity` keeps it up
    /// until it is closed or replaced, as Convert's progress tip); a click on it or Escape closes it at once
    /// (wireframe ol5Ak83dAho section 5, the alert scripts raise through pilot://alert). Never a modal, never a
    /// notification. Escape still reaches the app in front: the tip only watches for it. `action` puts its button
    /// after the words: pressing it closes the tip, then runs the action, so a tip the action raises stays up. `top`
    /// shows it near the top of the screen instead, clear of the text an action just changed (Quick AI's fix).
    /// `onClose` runs once the tip goes, however it goes (faded, clicked, Escape, its button, another tip): a bind
    /// hint waiting for a key stops waiting (story 122).
    static func tip(_ text: String, seconds: TimeInterval = 3, action: TipAction? = nil, top: Bool = false,
                    onClose: (@MainActor () -> Void)? = nil) {
        prepareTip(text, seconds: seconds, action: action, top: top, onClose: onClose).orderFrontRegardless()
    }

    /// The tip as `tip` sets it up, its panel returned before it shows, so a test can hide it first. The tip takes the
    /// first click even while its non-activating panel is not key: the button's, and the tap that closes it.
    static func prepareTip(_ text: String, seconds: TimeInterval, action: TipAction?, top: Bool = false,
                           onClose: (@MainActor () -> Void)? = nil) -> NSPanel {
        closeTip()
        let model = TipModel(text: text, action: action.map { action in TipAction(title: action.title) { closeTip(); action.run() } })
        model.onClose = onClose
        let panel = makePanel(TipView(model: model)
            .contentShape(.rect).onTapGesture { closeTip() }
            .allowsWindowActivationEvents(true)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { refitTip(model, to: $0) }, shadow: false)
        // The screen makePanel put it on, found by its centre: asking Accessibility again would cost a second read.
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        if top, let f = NSScreen.screens.first(where: { $0.frame.contains(centre) })?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: f.maxY - panel.frame.height - 24))
        }
        tipPanel = panel
        tipModel = model
        tipCentre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        // A lasting tip never fades, so it schedules no timer at all (none with an infinite interval).
        if seconds.isFinite {
            tipTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                Task { @MainActor in fadeTip() }
            }
        }
        let esc: (NSEvent) -> Void = { e in if Int64(e.keyCode) == KeyCode.escape { MainActor.assumeIsolated { closeTip() } } }
        escMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc),
                       NSEvent.addLocalMonitorForEvents(matching: .keyDown) { esc($0); return $0 }].compactMap { $0 }
        return panel
    }

    /// The words of `tip` changed in place (Convert's next file): the same panel, no fade in, its fade left as it
    /// was; the panel refits about its centre once TipView takes the new words. Nothing once another tip replaced it.
    static func updateTip(_ text: String, on tip: TipModel) {
        guard tipModel === tip else { return }
        tip.text = text
    }

    /// The tip's panel fitted to its view's new size about the centre it opened on, so the words never jump; a restyled
    /// tip's window holds its shadow's margins round the face (PopSurface). A window's frame is in whole points: a size
    /// within one of it is the one it opened at, so a tip that never changes never refits.
    private static func refitTip(_ model: TipModel, to face: CGSize) {
        guard tipModel === model, let panel = tipPanel else { return }
        let size = PopSurface.window(face, panel.margins)
        guard abs(panel.frame.width - size.width) >= 1 || abs(panel.frame.height - size.height) >= 1 else { return }
        panel.setFrame(CGRect(x: tipCentre.x - size.width / 2, y: tipCentre.y - size.height / 2, width: size.width, height: size.height), display: true)
    }

    private static func fadeTip() {
        guard let panel = tipPanel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in if tipPanel === panel { closeTip() } }
        }
    }

    /// Closes a tip and its Escape watch, which sees keys pressed in other apps (Bitwarden's unlock, card agent-bo-95422814).
    static func dismissTip() { closeTip() }

    private static func closeTip() {
        let closed = tipModel?.onClose
        tipModel?.onClose = nil
        defer { closed?() }
        tipTimer?.invalidate()
        tipTimer = nil
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
        tipPanel?.orderOut(nil)
        tipPanel = nil
        tipModel = nil
    }

    /// What focusSearch found: the field's editor had the keyboard, the field was given it, it refused, or no field.
    enum SearchFocus: String { case had = "had the keyboard", given = "given the keyboard", refused = "refused the keyboard", noField = "not found" }

    /// Makes a panel's search field its first responder unless its field editor already is, with the caret at the end,
    /// so a letter typed next adds to the search instead of replacing it. SwiftUI's own focus did not always land in
    /// the menu or the clipboard panel (cards agent-bo-95422762 and agent-bo-95422767).
    static func focusSearch(in panel: NSWindow) -> SearchFocus {
        guard let field = searchField(in: panel.contentView) else { return .noField }
        if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate === field { return .had }
        // The search field holding the keyboard by its editor too, as SwiftUI's field editor may name no field as its
        // delegate. Cmd+K's filter holding it is not the search field's: out of Cmd+K before SwiftUI redraws, the filter is
        // still in the panel and the search field takes the keyboard back (every layout, Moody on cef22ca4).
        if let editor = panel.firstResponder as? NSText, field.currentEditor() === editor { return .had }
        guard panel.makeFirstResponder(field) else { return .refused }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        return .given
    }

    /// The caret after the search field's text when it holds the keyboard with all its text selected, as a field SwiftUI
    /// focuses again does, so the next letter adds to the query instead of replacing it (Escape out of Cmd+K's actions,
    /// menu-morph T3). A caret Sven put somewhere himself, or a part he selected, stays where it is.
    static func caretToEnd(in panel: NSWindow?) {
        // The search field by its editor (SwiftUI's field editor may name no field as its delegate); never Cmd+K's filter.
        guard let panel, let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = searchField(in: panel.contentView), field.currentEditor() === editor else { return }
        let length = (editor.string as NSString).length
        guard length > 0, editor.selectedRange() == NSRange(location: 0, length: length) else { return }
        editor.selectedRange = NSRange(location: length, length: 0)
    }

    /// The search field's caret and its text's length; nil when its editor does not have the keyboard.
    static func searchCaret(in panel: NSWindow) -> (selection: NSRange, length: Int)? {
        guard let field = searchField(in: panel.contentView), let editor = panel.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.delegate === field else { return nil }
        return (editor.selectedRange(), (editor.string as NSString).length)
    }

    /// Whether the search field's caret sits at the start or the end of its text with nothing selected, for Left and
    /// Right that step a panel's tabs there (the clipboard's kinds); both false when it lacks the keyboard.
    static func caretEnds(in panel: NSWindow?) -> (atStart: Bool, atEnd: Bool) {
        guard let caret = panel.flatMap(searchCaret) else { return (false, false) }
        return (caret.selection == NSRange(location: 0, length: 0), caret.selection == NSRange(location: caret.length, length: 0))
    }

    /// Shows a panel with a search field (the menu, the clipboard panel). A local monitor offers each key to `handle`
    /// first, so the panel's own keys never type; any other key goes on to the search field, which takes the keyboard
    /// first if it lost it, and once more on the run-loop turn after the show, when SwiftUI's focus should have landed
    /// (cards agent-bo-95422762 and agent-bo-95422767). `keepsSearch` false leaves the keyboard where it is, for an
    /// editor of the panel's own (the clipboard's Edit text, card agent-bo-95422784). `onlyPanel` leaves keys typed in
    /// Pilot's other windows alone, for a panel that stays up (quick notes). `log` gets each check's line; the caller
    /// removes the monitor.
    static func showSearchPanel(_ panel: NSPanel, handle: @escaping @MainActor (UInt16, NSEvent.ModifierFlags, String?) -> Bool,
                                keepsSearch: @escaping @MainActor () -> Bool = { true }, onlyPanel: Bool = false,
                                beforeTyping: @escaping @MainActor () -> Void = {},
                                log: @escaping @MainActor (String) -> Void) -> Any? {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            let taken = MainActor.assumeIsolated {
                searchKey(event, in: panel, handle: handle, keepsSearch: keepsSearch, onlyPanel: onlyPanel, beforeTyping: beforeTyping, log: log)
            }
            return taken ? nil : event
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak panel] in if let panel, keepsSearch() { log("after show: \(refocus(panel))") } }
        return monitor
    }

    /// What the panel's key monitor does with one key: true when `handle` took it; otherwise the key goes on to the search
    /// field, which first runs `beforeTyping` (Line's caret after Escape out of Cmd+K, menu-morph T3) and takes the
    /// keyboard back if it lost it. The monitor and the tests call this one path.
    static func searchKey(_ event: NSEvent, in panel: NSWindow?, handle: @MainActor (UInt16, NSEvent.ModifierFlags, String?) -> Bool,
                          keepsSearch: @MainActor () -> Bool, onlyPanel: Bool = false, beforeTyping: @MainActor () -> Void = {},
                          log: @MainActor (String) -> Void) -> Bool {
        if onlyPanel, event.windowNumber != panel?.windowNumber { return false }
        if handle(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers) { return true }
        if let panel, keepsSearch() {
            beforeTyping()
            log("key \(event.keyCode) passes on: \(refocus(panel))")
        }
        return false
    }

    /// Gives the search field the keyboard if it lacks it, and says what held it for the panel's log line: the first
    /// responder's class, the key window and what focusSearch found.
    private static func refocus(_ panel: NSWindow) -> String {
        let fr = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let key = NSApp.keyWindow.map { $0 === panel ? "the panel" : String(describing: type(of: $0)) } ?? "nil"
        return "first responder \(fr), key window \(key), search field \(focusSearch(in: panel).rawValue)"
    }

    /// The panel's search field: its first editable text field that is not Cmd+K's filter.
    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return isActionsFilter(field) ? nil : field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    /// The prompt Cmd+K's filter shows in every menu layout (Line's line, the actions' popover): the one way to tell it
    /// from the search field, which shows none, as SwiftUI gives neither field a name AppKit can read. In Line the filter
    /// comes first in the view tree.
    static let actionsFilterPrompt = "Filter actions…"

    static func isActionsFilter(_ field: NSTextField) -> Bool {
        (field.placeholderAttributedString?.string ?? field.placeholderString) == actionsFilterPrompt
    }

    /// A non-activating panel: it takes the keyboard while the app Sven was in stays active. `surface` is the style seam's
    /// name for it (ADR 0008): a HUD unless it is the menu, the clipboard panel or the overlay. A surface restyled in the
    /// picked style draws its own pop-up chrome (PopSurface) and is opaque, whatever the Panels material. `shadow`
    /// false: no drawn shadow either, as the menu has none (the tip, Sven 2026-10-09).
    static func makePanel(_ content: some View, surface: StyleSurface = .hud, look: Look = .shared, shadow: Bool = true,
                          ownFace: Bool = false) -> KeyPanel {
        // The style's pop face in its shadow's margins (PopSurface: Toybox's outline and edge need none), but Toybox's menu,
        // which draws its own pop block (ToyMenuFrame), and a menu that says it draws its own (`ownFace`: Line, whose face
        // morphs inside its window, LineMorph).
        let own = (look.style == .toybox || ownFace) && surface == .menu
        let restyled = own ? nil : look.chromeTokens(surface)
        // The menu draws no shadow in any style (B5, Sven 2026-10-09), nor does a face on Glass (Q356).
        let shadowed = shadow && surface != .menu && !look.glassFace(surface)
        let margins = (shadowed ? restyled : nil).map(PopSurface.margins) ?? NSEdgeInsetsZero
        let host = NSHostingView(rootView: restyled == nil ? AnyView(content.styled(surface, look: look).pilotTheme(look: look))
                                 : AnyView(content.popSurface(margins, shadows: shadowed).styled(surface, look: look).pilotTheme(look: look)))
        host.frame.size = host.fittingSize
        let panel = KeyPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.margins = margins
        // Opaque behind the style's own face (design round 4, card agent-bo-95422895); its corners match the panel's.
        let backdrop = MaterialBackdrop(content: host, cornerRadius: look.theme.panelRadius)
        if !own { backdrop.show(.solid, tint: look.glassTint(look.colors.ground)) }
        panel.contentView = backdrop
        // Pilot's palette whatever the Mac's appearance, as the app window is (PanelStyle); a restyled surface's style's.
        panel.appearance = look.appearance(for: surface)
        panel.level = level
        centre(panel, size: host.frame.size)
        return panel
    }

    /// `panel` at `size`, centred on the screen holding the focused window, not NSScreen.main: that follows Pilot's own
    /// key window. Where no screen holds it, it keeps its place.
    static func centre(_ panel: NSWindow, size: CGSize) {
        guard let f = Screens.focusedScreen?.visibleFrame else { return panel.setContentSize(size) }
        panel.setFrame(CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: false)
    }
}

/// The shown tip: its words, which HUD.updateTip changes in place, and its one action.
@Observable @MainActor
final class TipModel {
    var text: String
    let action: HUD.TipAction?
    /// Run once when the tip closes (HUD.tip's `onClose`).
    @ObservationIgnored var onClose: (@MainActor () -> Void)?

    init(text: String, action: HUD.TipAction?) {
        self.text = text
        self.action = action
    }
}

/// The tip's one line, and the action's button after it in the kit's quiet style. The button sits as far in from the
/// panel's edge as keeps its corners concentric with the panel's (clamped for the sharpest and roundest themes); the
/// digits are tabular, so a count ticking up never shifts the line.
struct TipView: View {
    @Environment(\.style) private var style
    let model: TipModel

    init(model: TipModel) {
        self.model = model
    }

    init(text: String, action: HUD.TipAction? = nil) {
        self.init(model: TipModel(text: text, action: action))
    }

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentTip(model: model)
        case .toybox: ToyTip(model: model)
        }
    }

}

