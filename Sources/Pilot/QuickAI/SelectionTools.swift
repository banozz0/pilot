@preconcurrency import Cocoa
import Carbon.HIToolbox
import PilotCore
import SwiftUI

/// The selection pill (Sven Q213 to Q216, after Build 55): highlight text with Hyper held and a left drag, and a pill
/// with Ask AI, Read aloud, Copy and Translate shows where the drag ended; a plain selection never shows it. Translate
/// is the Pilot menu's own (Sven on Build 60): the menu opens on Translate with the selection typed in. Summarise shows
/// while the Summarise extension is installed (Q481): it runs on the selection, a link it reads or the text itself. A
/// listen-only session tap on the left button, beside the keyboard tap, whose mask never gains the mouse (typing-lag
/// rule): enabled only while Hyper is down or its drag is under way, so an idle Pilot sees no click. It takes nothing
/// from the app, posts nothing, and reads the selection only when a button is pressed, as Hyper+Ctrl+A does
/// (SelectionEdit.capture); a drag over one of Pilot's own panels (Quick notes, the menu's field) is read as the pill
/// shows, from that panel's text view, since the pill's click may close the panel first. Not in the skip list's apps
/// (terminals). Engine leaves the tap unarmed while Hyper is the window-drag modifier, whose tap takes that drag from
/// the app (MouseDragTap): Ask AI about selected text, Services and the Selection tools action still reach it.
@MainActor
final class SelectionTools {
    static let shared: SelectionTools = SelectionTools()
    /// Shows the pill at the pointer for the text selected there, for a key or mouse button (no default key).
    static let id = "ai.selectionTools"
    enum Button { case ask, read, copy, translate, summarise }

    /// Tells the keyboard tap a press used the held layer: no quick-tap Escape at Hyper's release, and the bind list
    /// closes or never opens (HyperTap.layerUsed).
    var useLayer: () -> Void = {}
    var front: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// A press on one of Pilot's own panels: the pill's or the Ask AI bubble's, which raise no pill, or another's
    /// (Quick notes, the menu), whose own text the pill works on.
    enum OwnPanel { case selection, text(NSWindow) }
    /// The pill's and the bubble's panels, so a press there raises no second pill and Quick notes stays open under them.
    static let panelID = NSUserInterfaceItemIdentifier("dev.banozz.pilot.selection")
    /// Pilot's panel under a point in AppKit's coordinates; the pill's or the bubble's wins where they overlap another.
    /// Pilot's app window is no panel: its text is read with Pilot in front (SelectionEdit.capture).
    var ownPanel: (CGPoint) -> OwnPanel? = { point in
        let hits = NSApp.windows.filter(\.isVisible).compactMap { SelectionTools.ownPanel($0, at: point) }
        return hits.first { if case .selection = $0 { true } else { false } } ?? hits.first
    }
    /// What a Pilot panel is to a press at `point`; nil where it takes none. The click-through overlays (the window border
    /// over the focused window, Defocus over each screen) pass it to the app below, so they never block the pill (Build 61).
    static func ownPanel(_ window: NSWindow, at point: CGPoint) -> OwnPanel? {
        guard window is NSPanel, !window.ignoresMouseEvents, window.frame.contains(point) else { return nil }
        return window.identifier == panelID ? .selection : .text(window)
    }
    var edit: SelectionEdit = .shared
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var tip: (String) -> Void = { HUD.tip($0, seconds: 3, top: true) }
    /// Translate: the Pilot menu on its Translate branch with the text typed, its engine, pair and Return-copies row.
    var translate: (String) -> Void = { PilotMenu.shared.open(typing: $0, in: .translate) }
    /// The Summarise extension's keyword command (pilot-extensions `summarise`), which takes a link, a path or text as input.
    static let summariser = Extension.CommandID(extension: "summarise", command: "fetch")
    /// Whether the Summarise extension is installed, read as the pill shows: one file's presence, no folder read.
    var summarises: () -> Bool = {
        FileManager.default.fileExists(atPath: Extension.folder.appending(path: summariser.extension).appending(path: Extension.manifestName).path)
    }
    /// Summarise: the extension run on the selection, its page opening on it.
    var summarise: (String) -> Void = { text in
        Task { await ExtensionsModule.perform(summariser.actionID(input: text), in: Extension.folder) }
    }
    /// Puts the pill up with its top-left at a point in AppKit's screen coordinates, or takes it down.
    var present: (SelectionTools, CGPoint) -> Void = { $0.showPanel(at: $1) }
    var dismiss: (SelectionTools) -> Void = { $0.hidePanel() }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hyperDown = false
    /// Where the Hyper press went down, in Quartz coordinates (top-left origin), while its drag is under way.
    private var pressed: CGPoint?
    /// The Pilot panel the drag went down on, until the pill shows.
    private weak var pressedIn: NSWindow?
    /// The selection in Pilot's own panel, read as the pill showed for it (nil inside: none was selected); nil when the
    /// pill is for the app in front.
    private var own: String??
    private var panel: KeyPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// The dragged-over text's bounds, from the press to the release, in AppKit's screen coordinates, while the pill shows.
    private var selection = CGRect.null
    private var task: Task<Void, Never>?

    private(set) var isShown = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        skipped = SelectionPill.skip(defaults.stringArray(forKey: SelectionPill.skipKey))
    }

    /// The apps where Hyper+drag shows no pill, by bundle id (Sven Q215): the terminals until changed, on the AI page's
    /// Quick AI keys and through `pilot set selection.pillSkip`; read once, kept here for the press.
    var skipped: [String] {
        didSet {
            skipped = SelectionPill.skip(skipped)
            defaults.set(skipped, forKey: SelectionPill.skipKey)
        }
    }

    static func register(into registry: inout ActionRegistry) {
        do {
            try registry.register(Action(id: id, label: "Selection tools", module: .apps, tier: .v1,
                                         keywords: "selection pill popclip ask ai read aloud copy translate") { SelectionTools.shared.showAtPointer() })
        } catch { ailog.error("selection tools: \(String(describing: error), privacy: .public)") }
    }

    // MARK: The gesture

    /// Installed while the binds are armed, off until Hyper goes down.
    func arm(_ on: Bool, layer: HyperTap) {
        useLayer = { [weak layer] in layer?.layerUsed() }
        if on, tap == nil {
            let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                              eventsOfInterest: mask, callback: pillCallback, userInfo: me) else {
                return ailog.error("selection tools: mouse tap not created")
            }
            CGEvent.tapEnable(tap: tap, enable: false)
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.tap = tap
            self.source = source
        } else if !on, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil; source = nil
            pressed = nil
        }
    }

    /// Hyper down or up, from inside the keyboard tap's callback: the WindowServer round trip waits until it returned. A
    /// drag under way keeps the tap on past Hyper's release, for its mouse-up.
    func hyper(_ isDown: Bool) {
        hyperDown = isDown
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hyperDown == isDown else { return }
            self.enable(isDown || self.pressed != nil)
        }
    }

    private func enable(_ on: Bool) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    /// A press with Hyper held starts the gesture; its release a drag away shows the pill. Only flags and a point here.
    /// Any press under Hyper uses the layer, so the bind list never comes up over a drag, the pill's or not (Build 60).
    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            enable(hyperDown || pressed != nil)
        case .tapDisabledByUserInput:
            // Our own enable(false) sends this; re-disabling here looped forever on the main thread (build 59, 55% CPU).
            break
        case .leftMouseDown:
            pressed = nil
            guard hyperDown else { return }
            useLayer()
            let at = event.location
            guard SelectionPill.starts(app: front(), skip: skipped) else { return }
            let panel = ownPanel(CGPoint(x: at.x, y: Screens.primaryHeight - at.y))
            if case .selection = panel { return }
            if case .text(let window) = panel { pressedIn = window } else { pressedIn = nil }
            pressed = at
        case .leftMouseUp:
            guard let down = pressed else { return }
            pressed = nil
            if !hyperDown { enable(false) }
            let up = event.location
            guard SelectionPill.dragged(from: down, to: up) else { return }
            // Quartz's top-left origin to AppKit's bottom-left, on the main screen's height.
            let point = CGPoint(x: up.x, y: Screens.primaryHeight - up.y)
            let start = CGPoint(x: down.x, y: Screens.primaryHeight - down.y)
            let window = pressedIn
            pressedIn = nil
            DispatchQueue.main.async { [weak self] in self?.show(at: point, from: start, in: window) }
        default:
            break
        }
    }

    /// The action: the pill at the pointer, for the text selected there.
    func showAtPointer() { show(at: NSEvent.mouseLocation) }

    private func show(at point: CGPoint, from start: CGPoint? = nil, in window: NSWindow? = nil) {
        own = window.map { SelectionEdit.selected(in: $0) }
        selection = CGRect(origin: start ?? point, size: .zero).union(CGRect(origin: point, size: .zero))
        present(self, point)
        isShown = true
    }

    // MARK: The buttons

    /// A button: the pill goes, then the front app's selection is read and handed on. Never in a password field.
    func press(_ button: Button) {
        close()
        guard !secureInput() else { return tip(QuickFix.password) }
        task?.cancel()
        let own = own
        task = Task {
            let found = if let own { own.flatMap(SelectionEdit.ownTarget) } else { await edit.capture() }
            guard let found else { return tip(own != nil ? SelectionBox.nothingSelected : edit.miss) }
            guard !Task.isCancelled else { return }
            ailog.notice("selection tools: \(String(describing: button), privacy: .public) on \(found.text.count) characters in \(found.app, privacy: .public)")
            switch button {
            case .ask: SelectionBox.shared.open(found)
            case .translate: translate(found.text)
            case .summarise: summarise(found.text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .read: ReadAloud.shared.read(service: found.text)
            case .copy:
                edit.world.copy(found.text)
                tip(SelectionBox.copied)
            }
        }
    }

    /// The pill goes as PopClip's does: the pointer well away from the pill and the selection, a click, key or scroll
    /// anywhere else, another app or Space in front, or ten seconds.
    func close() {
        guard isShown else { return }
        isShown = false
        dismiss(self)
    }

    // MARK: The panel

    static let gap: CGFloat = 12
    /// How far past the pill and the selection the pointer may stray before the pill goes: the way from the release to
    /// the pill lies inside them, so this only absorbs an overshoot and a shaky hand; 100 points is about a finger's
    /// width on the desk, so a deliberate move elsewhere in the window takes it down.
    static let reach: CGFloat = 100

    /// Whether the pointer at `point` has left the pill's `zone` (the pill and the selection) by more than `reach`.
    static func strayed(_ point: CGPoint, from zone: CGRect) -> Bool {
        !zone.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    /// The pill's frame: centred over `point`, a gap above it, else under it at the screen's top; always inside `screen`.
    static func frame(size: CGSize, at point: CGPoint, screen: CGRect) -> CGRect {
        var y = point.y + gap
        if y + size.height > screen.maxY { y = point.y - gap - size.height }
        let x = min(max(point.x - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return CGRect(x: x, y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8), width: size.width, height: size.height)
    }

    func showPanel(at point: CGPoint) {
        hidePanel()
        let look = Look.shared
        let host = NSHostingView(rootView: SelectionPillView(summarise: summarises(), press: { [weak self] in self?.press($0) })
            .allowsWindowActivationEvents(true)
            .styled(.hud, look: look).pilotTheme(look: look))
        host.frame.size = host.fittingSize
        let panel = KeyPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.panelID
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = look.appearance(for: .hud)
        panel.level = HUD.level
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(Self.frame(size: host.frame.size, at: point, screen: visible), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        // Passive watchers while the pill shows, gone with it: other apps' events (global) and Pilot's other windows'
        // (local, handed on untouched); the pill's own clicks are its buttons'. Moves only measure the pointer.
        let zone = panel.frame.union(selection)
        let ends: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: ends.union(.mouseMoved)) { [weak self] event in
                let (type, at) = (event.type, NSEvent.mouseLocation)
                MainActor.assumeIsolated { if type != .mouseMoved || Self.strayed(at, from: zone) { self?.close() } }
            },
            NSEvent.addLocalMonitorForEvents(matching: ends) { [weak self, weak panel] event in
                MainActor.assumeIsolated { if event.window !== panel { self?.close() } }
                return event
            },
        ].compactMap { $0 }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func hidePanel() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private let pillCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tools = Unmanaged<SelectionTools>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    MainActor.assumeIsolated { tools.handle(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}

/// The pill's face: four buttons in one capsule, five with Summarise, Ask AI's sparkle lit, in the style's Ink.
struct SelectionPillView: View {
    @Environment(\.ink) private var ink
    var summarise = false
    var press: (SelectionTools.Button) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            item("Ask AI", symbol: BarParts.dropSymbol(.askAI), lit: true) { press(.ask) }
            rule
            item("Read aloud", symbol: "speaker.wave.2") { press(.read) }
            rule
            item("Copy", symbol: "doc.on.doc") { press(.copy) }
            rule
            item("Translate", symbol: "character.bubble") { press(.translate) }
            if summarise {
                rule
                item("Summarise", symbol: "list.bullet") { press(.summarise) }
            }
        }
        .padding(.horizontal, 6).frame(height: 34)
        .background { Capsule().fill(ink.surface).overlay(Capsule().strokeBorder(ink.windowLine, lineWidth: ink.stroke)) }
        .fixedSize()
        .padding(1)
    }

    private var rule: some View { ink.line.frame(width: 1, height: 18) }

    private func item(_ title: String, symbol: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(lit ? ink.accentInk : ink.muted)
                    .accessibilityHidden(true)
                Text(title).font(ink.ui(13, .medium)).foregroundStyle(ink.text)
            }
            .padding(.horizontal, 11).frame(maxHeight: .infinity).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
