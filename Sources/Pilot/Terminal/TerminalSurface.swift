import AppKit
import CGhostty
import Synchronization

/// The bar drop's terminal (spec Bar drops T6, T11): Ghostty itself, libghostty v1.3.1 built from source with Sentry off
/// (Scripts/build-ghosttykit.sh) and downloaded as a signed pack on first use (T76, TerminalPack), reading Sven's own Ghostty config, so the drop looks and types like his Ghostty. One shell
/// for Pilot's session, never a panel's: the drop's panel comes and goes around this view, the shell keeps running while
/// hidden, and Pilot quitting ends it (Q108). Started on first open, never at launch.
///
/// Driven as Ghostty's own macOS app drives libghostty (SurfaceView_AppKit.swift, Ghostty.App.swift, MIT, Mitchell
/// Hashimoto and contributors): keys through `interpretKeyEvents` so dead keys and input methods compose, mouse, scroll,
/// the clipboard and focus. Splits, tabs, the inspector and other windows are not the drop's.
@MainActor
class TerminalSurface: NSView, @preconcurrency NSTextInputClient {
    /// What runs, as one shell line; nil runs what Ghostty would (its `command`, else the login shell).
    let command: String?
    /// Called when Ghostty closes the surface: the shell exited (the next start makes a fresh one), or a close bind ran
    /// (Cmd+W), which only hides a shell still running.
    var onClose: (() -> Void)?
    private var surface: ghostty_surface_t?
    /// This view as libghostty holds it (userdata, nsview): retained while the surface lives, released when it is freed.
    private var held: Unmanaged<TerminalSurface>?
    /// The input method's text not yet typed (a dead key, a word being composed).
    private var markedText = ""
    /// The text one keyDown typed, collected from insertText while interpretKeyEvents runs.
    private var keyText: [String]?

    /// libghostty's calls; a surface exists only once GhosttyRuntime has the pack.
    private var api: GhosttyAPI { GhosttyRuntime.api }

    init(command: String? = nil) {
        self.command = command
        super.init(frame: CGRect(x: 0, y: 0, width: 760, height: 560))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    var started: Bool { surface != nil }

    /// The shell's name for the drop's header: the command's program, else the login shell Ghostty runs.
    var shellName: String {
        let path = command?.split(separator: " ").first.map(String.init)
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
        return URL(fileURLWithPath: path ?? "sh").lastPathComponent
    }

    /// The shell's pid, 0 until it runs or when it cannot be told apart. libghostty has no pid call and starts the shell
    /// later, on its IO thread, under /usr/bin/login, a child of Pilot's: the shell is the child of the one login that
    /// appeared since start(). The shell's environment cannot mark it: macOS hides it from Pilot after login's setuid.
    /// Pilot runs one terminal; were two starting at once, this answers 0 rather than the other's shell.
    var shellPID: pid_t {
        guard surface != nil else { return 0 }
        if shell == 0 {
            let logins = Self.children(of: getpid()).filter { !childrenBefore.contains($0) && Self.path(of: $0) == "/usr/bin/login" }
            if logins.count == 1 { shell = Self.children(of: logins[0]).first ?? 0 }
        }
        return shell
    }
    private var shell: pid_t = 0
    private var childrenBefore: Set<pid_t> = []

    private static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Starts the shell in the home folder once; a running one stays. False when libghostty or the surface did not start:
    /// nothing is kept, so the next open tries again.
    @discardableResult
    func start() -> Bool {
        guard surface == nil else { return true }
        let began = ContinuousClock.now
        let firstRuntime = !GhosttyRuntime.isMade
        guard let app = GhosttyRuntime.app else { return false }
        var config = api.surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        let held = Unmanaged.passRetained(self)
        let me = held.toOpaque()
        childrenBefore = Set(Self.children(of: getpid()))
        shell = 0
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: me))
        config.userdata = me
        config.scale_factor = scale
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surface = NSHomeDirectory().withCString { home in
            config.working_directory = home
            guard let command else { return api.surface_new(app, &config) }
            return command.withCString { config.command = $0; return api.surface_new(app, &config) }
        }
        guard surface != nil else {
            held.release()
            tblog.error("terminal: libghostty made no surface")
            return false
        }
        self.held = held
        resize()
        shown()
        let ms = Int(began.duration(to: .now) / .milliseconds(1))
        tblog.info("terminal: started in \(ms, privacy: .public) ms\(firstRuntime ? ", libghostty and its config included" : "", privacy: .public)")
        return true
    }

    /// Text to the shell as if typed: a paste for the words, a Return key for each CR (a CR inside a paste never runs the
    /// line).
    func type(_ text: String) {
        guard let surface else { return }
        for (index, part) in text.split(separator: "\r", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.keycode = 36
                key.unshifted_codepoint = 13
                _ = api.surface_key(surface, key)
            }
            if !part.isEmpty { sendText(String(part)) }
        }
    }

    /// The visible screen, one line per row.
    func screenText() -> String {
        guard let surface else { return "" }
        let corner = { (coord: ghostty_point_coord_e) in ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: coord, x: 0, y: 0) }
        let all = ghostty_selection_s(top_left: corner(GHOSTTY_POINT_COORD_TOP_LEFT), bottom_right: corner(GHOSTTY_POINT_COORD_BOTTOM_RIGHT),
                                      rectangle: false)
        var text = ghostty_text_s()
        guard api.surface_read_text(surface, all, &text) else { return "" }
        defer { api.surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Words to the shell as a paste.
    private func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { api.surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// Ends the shell and frees the surface (the shell exited, tests; Pilot quitting ends it anyway).
    func terminate() {
        guard let surface else { return }
        self.surface = nil
        api.surface_free(surface)
        held?.release()
        held = nil
        shell = 0
    }

    /// Ghostty closed the surface. A close bind (Cmd+W) with the shell still running only hides the drop: freeing the
    /// surface would hang up the shell and whatever runs in it (a Claude Code session). Freed once the shell has exited.
    fileprivate func closed() {
        if let surface, api.surface_process_exited(surface) { terminate() }
        onClose?()
    }

    // MARK: Window, size, focus

    private var scale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// Scale and size in pixels; the drop resizes as Ask AI opens beside it or closes.
    private func resize() {
        guard let surface else { return }
        layer?.contentsScale = scale
        api.surface_set_content_scale(surface, scale, scale)
        api.surface_set_size(surface, UInt32(max(bounds.width, 1) * scale), UInt32(max(bounds.height, 1) * scale))
    }

    /// Drawn and focused while in a window: the panel is rebuilt around the view on every open and lets it go on close.
    private func shown() {
        guard let surface else { return }
        api.surface_set_occlusion(surface, window != nil)
        api.surface_set_focus(surface, window != nil && window?.firstResponder === self)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resize(); shown() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize() }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        guard let surface else { return }
        api.surface_set_size(surface, UInt32(max(size.width, 1) * scale), UInt32(max(size.height, 1) * scale))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { api.surface_set_focus(surface, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { api.surface_set_focus(surface, false) }
        return true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        // Ghostty decides which modifiers make text (macos-option-as-alt); the event is rebuilt with only those.
        let wanted = Self.flags(api.surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        let translation = event.modifierFlags.subtracting([.shift, .control, .option, .command]).union(wanted)
        let translated = translation == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translation, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: translation) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let composingBefore = !markedText.isEmpty
        keyText = []
        defer { keyText = nil }
        interpretKeyEvents([translated])
        syncPreedit(clear: composingBefore)
        if let typed = keyText, !typed.isEmpty {
            for text in typed { send(action, event, translation, text: text) }
        } else {
            send(action, event, translation, text: Self.characters(translated), composing: !markedText.isEmpty || composingBefore)
        }
    }

    override func keyUp(with event: NSEvent) { send(GHOSTTY_ACTION_RELEASE, event, event.modifierFlags, text: nil) }

    /// Cmd chords Ghostty binds (Cmd+V, Cmd+C, Cmd+K …) go to it before any menu, as in Ghostty; the rest pass on.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface, window?.firstResponder === self else { return false }
        var key = Self.key(event, GHOSTTY_ACTION_PRESS, event.modifierFlags)
        var flags = ghostty_binding_flags_e(0)
        let bound = (event.characters ?? "").withCString { key.text = $0; return api.surface_key_is_binding(surface, key, &flags) }
        guard bound else { return false }
        keyDown(with: event)
        return true
    }

    private func send(_ action: ghostty_input_action_e, _ event: NSEvent, _ translation: NSEvent.ModifierFlags, text: String?,
                      composing: Bool = false) {
        guard let surface else { return }
        var key = Self.key(event, action, translation)
        key.composing = composing
        // Ghostty encodes control characters itself: it is handed text only from a printable first byte on.
        guard let text, let first = text.utf8.first, first >= 0x20 else { _ = api.surface_key(surface, key); return }
        _ = text.withCString { key.text = $0; return api.surface_key(surface, key) }
    }

    /// NSEvent+Extension.swift's ghosttyKeyEvent: Control and Command never make text, every other modifier did.
    private static func key(_ event: NSEvent, _ action: ghostty_input_action_e, _ translation: NSEvent.ModifierFlags) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event.modifierFlags)
        key.consumed_mods = mods(translation.subtracting([.control, .command]))
        let bare = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        key.unshifted_codepoint = bare?.unicodeScalars.first?.value ?? 0
        return key
    }

    /// NSEvent+Extension.swift's ghosttyCharacters: a lone control character goes without Control, a function key's
    /// private-use character not at all.
    private static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        // The right-hand side, which macos-option-as-alt = right reads (NX_DEVICERALTKEYMASK and friends).
        let raw = flags.rawValue
        if raw & 0x04 != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & 0x2000 != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & 0x40 != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & 0x10 != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: Text input (dead keys, input methods)

    /// AppKit hands text as a String or an attributed one; only the characters count here.
    private static func plain(_ string: Any) -> String { (string as? NSAttributedString)?.string ?? (string as? String) ?? "" }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plain(string)
        unmarkText()
        if keyText != nil { keyText?.append(text); return }
        if !text.isEmpty { sendText(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plain(string)
        if keyText == nil { syncPreedit() }
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        syncPreedit()
    }

    /// Return, Escape, arrows and the rest arrive as commands: they go as keys from keyDown, never from here.
    override func doCommand(by selector: Selector) {}

    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The input method's window sits at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        api.surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, 1))
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func syncPreedit(clear: Bool = true) {
        guard let surface else { return }
        if !markedText.isEmpty {
            markedText.withCString { api.surface_preedit(surface, $0, UInt(markedText.utf8.count)) }
        } else if clear {
            api.surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }

    private func position(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        api.surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        position(event)
        _ = api.surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    /// As Ghostty: precise (trackpad) deltas doubled; the packed scroll mods carry precision in bit 0, momentum from bit 1.
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let precise = event.hasPreciseScrollingDeltas
        let factor = precise ? 2.0 : 1.0
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        api.surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor, (precise ? 1 : 0) | momentum << 1)
    }

    // MARK: Clipboard

    fileprivate func readClipboard(_ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, let text = GhosttyRuntime.pasteboard(location)?.string(forType: .string) else { return false }
        text.withCString { api.surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    /// Ghostty asks before a paste its paste protection flags and before a program reads the clipboard (OSC 52). The drop
    /// has no dialog: Sven's own paste goes, a program's read gets nothing.
    fileprivate func confirmClipboard(_ text: String, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        (request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? text : "").withCString {
            api.surface_complete_clipboard_request(surface, $0, state, true)
        }
    }
}

/// The one libghostty app in Pilot, made on the first terminal: Sven's Ghostty config (with Pilot's look file it includes)
/// unless a test turns it off. Ghostty's resources (terminfo, shell integration; no bundled themes) ship in Pilot.app's Resources
/// (build-app.sh), where libghostty finds them from its executable; GHOSTTY_RESOURCES_DIR points elsewhere (tests).
@MainActor
enum GhosttyRuntime {
    /// Read ~/.config/ghostty and the files it includes; tests turn it off before the first terminal.
    static var userConfig = true {
        didSet { if isMade && userConfig != oldValue { tblog.error("terminal: userConfig changed after libghostty started; ignored") } }
    }
    private static var initialized = false
    /// Kept once made, also when the shell exits: the next Hyper+T opens without reading the config again.
    private static var shared: ghostty_app_t?
    /// A tick is queued: libghostty wakes Pilot once per message, a burst of output needs one tick.
    nonisolated private static let tickQueued = Atomic(false)

    static var isMade: Bool { shared != nil }

    /// The pack's calls once TerminalPack has checked and loaded it (T76), kept for Pilot's session: dlclose cannot unload
    /// libghostty's threads and Metal state, so a pack is mapped once and Remove takes effect when Pilot quits.
    /// With the file it was mapped from: Settings' Remove deletes that, and the next press offers the download again.
    private(set) static var loaded: (api: GhosttyAPI, dylib: URL)?
    static func use(_ api: GhosttyAPI, from dylib: URL) { if loaded == nil { loaded = (api, dylib) } }
    /// A pack is mapped and still on disk: a press opens the shell at once.
    static var isReady: Bool { loaded.map { FileManager.default.fileExists(atPath: $0.dylib.path(percentEncoded: false)) } ?? false }
    /// Read only once the app exists, which needs the pack.
    fileprivate static var api: GhosttyAPI { loaded!.api }

    /// The app, made on first use; nil when the pack is not loaded or libghostty did not start, tried again on the next use.
    static var app: ghostty_app_t? {
        if let shared { return shared }
        guard loaded != nil else {
            tblog.error("terminal: the terminal pack is not loaded")
            return nil
        }
        if !initialized {
            guard api.initialize(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
                tblog.error("terminal: libghostty did not initialise")
                return nil
            }
            initialized = true
        }
        guard let (config, diagnostics) = loadConfig(user: userConfig) else {
            tblog.error("terminal: libghostty made no config")
            return nil
        }
        for line in diagnostics { tblog.info("terminal: ghostty config: \(line, privacy: .public)") }
        var runtime = ghostty_runtime_config_s(
            userdata: nil, supports_selection_clipboard: true, wakeup_cb: ghosttyWakeup, action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard, confirm_read_clipboard_cb: ghosttyConfirmClipboard,
            write_clipboard_cb: ghosttyWriteClipboard, close_surface_cb: ghosttyClose)
        shared = api.app_new(&runtime, config)
        api.config_free(config)
        if shared == nil { tblog.error("terminal: libghostty made no app") }
        return shared
    }

    /// Ghostty's config as the drop reads it, with the problems it reports; the caller frees it.
    private static func loadConfig(user: Bool) -> (ghostty_config_t, [String])? {
        guard let config = api.config_new() else { return nil }
        if user {
            api.config_load_default_files(config)
            api.config_load_recursive_files(config)
        }
        api.config_finalize(config)
        return (config, (0..<api.config_diagnostics_count(config)).map { String(cString: api.config_get_diagnostic(config, $0).message) })
    }

    /// From libghostty's threads: one tick on the main run loop for however many wakeups arrive before it runs.
    nonisolated static func wake() {
        guard tickQueued.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        later {
            tickQueued.store(false, ordering: .releasing)
            if let shared { api.app_tick(shared) }
        }
    }

    /// The selection clipboard is Ghostty.app's own named pasteboard, so copy-on-select behaves as in Sven's Ghostty.
    nonisolated static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: .general
        case GHOSTTY_CLIPBOARD_SELECTION: NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
        default: nil
        }
    }

    /// Sven's Ghostty config as libghostty reads it: its font size and the problems it reports.
    static func userConfigReport() -> (fontSize: Float, diagnostics: [String]) {
        guard app != nil, let (config, diagnostics) = loadConfig(user: true) else { return (0, []) }
        defer { api.config_free(config) }
        var size: Float = 0
        _ = api.config_get(config, &size, "font-size", UInt("font-size".utf8.count))
        return (size, diagnostics)
    }
}

// libghostty calls these from its own threads (the renderer's, the IO thread's), so they live outside the main actor and
// hop onto it; a closure written inside a main-actor type would trap on the first call off the main thread.

/// Later, on the main run loop in any mode: a block on the main queue would wait out a nested run loop (a test's, a menu's).
fileprivate func later(_ work: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated(work) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// The view behind libghostty's userdata, retained until `work` has run on the main run loop: a close or a clipboard
/// request may reach Pilot after the view let go of its surface.
private func withView(_ userdata: UnsafeMutableRawPointer?, _ work: @escaping @MainActor (TerminalSurface) -> Void) {
    guard let userdata else { return }
    let bits = UInt(bitPattern: Unmanaged<TerminalSurface>.fromOpaque(userdata).retain().toOpaque())
    later {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        work(Unmanaged<TerminalSurface>.fromOpaque(pointer).takeRetainedValue())
    }
}

private func surfaceView(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurface? {
    userdata.map { Unmanaged<TerminalSurface>.fromOpaque($0).takeUnretainedValue() }
}

private func ghosttyWakeup(_: UnsafeMutableRawPointer?) { GhosttyRuntime.wake() }

/// Window, tab, split and app actions are Ghostty.app's, not the drop's: none is performed here.
private func ghosttyAction(_: ghostty_app_t?, _: ghostty_target_s, _: ghostty_action_s) -> Bool { false }

private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    // A paste starts from a key on the main thread.
    guard Thread.isMainThread else { return false }
    let view = UInt(bitPattern: userdata), state = UInt(bitPattern: state)
    return MainActor.assumeIsolated {
        surfaceView(UnsafeMutableRawPointer(bitPattern: view))?.readClipboard(location, UnsafeMutableRawPointer(bitPattern: state)) ?? false
    }
}

private func ghosttyConfirmClipboard(_ userdata: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?,
                                     _ request: ghostty_clipboard_request_e) {
    let string = text.map { String(cString: $0) } ?? ""
    // The request's state crosses as a number: it stays Ghostty's until completed.
    let request = request.rawValue, state = UInt(bitPattern: state)
    withView(userdata) { $0.confirmClipboard(string, UnsafeMutableRawPointer(bitPattern: state), ghostty_clipboard_request_e(rawValue: request)) }
}

/// Copies (Cmd+C, copy-on-select) land on the pasteboard; a program's write that Ghostty wants confirmed (OSC 52) does not.
private func ghosttyWriteClipboard(_: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?,
                                   _ count: Int, _ confirm: Bool) {
    guard !confirm, let content else { return }
    let text = (0..<count).lazy.compactMap { index -> String? in
        let item = content[index]
        guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { return nil }
        return String(cString: data)
    }.first
    guard let text else { return }
    later {
        guard let board = GhosttyRuntime.pasteboard(location) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// Handled after Ghostty returns from the call that closed it. Its flag is "would ask before closing", not "the shell
/// lives" (an idle prompt says false), so closed() asks libghostty whether the shell exited.
private func ghosttyClose(_ userdata: UnsafeMutableRawPointer?, _: Bool) {
    withView(userdata) { $0.closed() }
}
