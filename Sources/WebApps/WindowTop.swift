import AppKit

/// What sits at the top of a web app's window (Sven, Q355): set once in Pilot on Install › Web apps, read by every web
/// app at launch and again whenever Pilot says it changed, so an open web app changes at once.
public enum WindowTop: String, CaseIterable, Sendable {
    /// No title bar and no window buttons: the page fills the window.
    case nothing
    /// As nothing, but pointing at the top-left corner fades the window buttons in over the page on a glass chip.
    case hover
    /// The window buttons on a thin strip coloured like the page, no title text.
    case strip
    /// macOS's title bar with the page's title, as web apps had before.
    case standard

    public static let initial = WindowTop.hover
    /// Pilot's defaults domain and the key in it: a web app reads Pilot's domain, not its own.
    public static let domain = "dev.banozz.pilot"
    public static let key = "webApps.windowTop"
    /// Posted by Pilot when the setting changes, the new raw value as its object.
    public static let changed = Notification.Name("dev.banozz.pilot.webApps.windowTop")

    public var title: String {
        switch self {
        case .nothing: "Nothing on top"
        case .hover: "Buttons on hover"
        case .strip: "Slim strip"
        case .standard: "Standard"
        }
    }

    /// No title bar: the page fills the window.
    public var bare: Bool { self == .nothing || self == .hover }

    /// What Pilot set, read from its domain each time, so a change made after launch is seen.
    public static func saved() -> WindowTop {
        (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String).flatMap(WindowTop.init) ?? initial
    }

    /// Pilot's side: tells every open web app, the suspended ones too, the raw value as the notification's object.
    public func announce() {
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: rawValue, userInfo: nil, deliverImmediately: true)
    }
}

/// Puts a WindowTop on a web app's window and keeps it there. The window buttons are hidden, never removed, so Hyper+W
/// still finds its close button. Accessibility reads a hidden button as disabled, and the tiler floats a window whose
/// full-screen button is: it tiles Pilot's web apps by their bundle id instead (KnownBundleId.pilotWebApp).
@MainActor public final class WindowChrome: NSObject {
    private weak var window: NSWindow?
    public private(set) var top = WindowTop.standard
    /// Over the page's top-left in Buttons on hover; it takes no clicks.
    let corner = HoverCorner()
    /// The strip's colour: the site's theme-color, else what it draws behind its page.
    public var pageColour: NSColor? {
        didSet { if pageColour != oldValue { paintBackground() } }
    }
    private var inFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    public init(window: NSWindow) {
        self.window = window
        super.init()
        corner.isHidden = true
        corner.onHover = { [weak self] in self?.showButtons($0, fade: true) }
        let center = NotificationCenter.default
        // Full screen shows the buttons in its title bar as any app does; leaving it puts the look back.
        center.addObserver(self, selector: #selector(enteringFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(leftFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
    }

    /// The web app's side of WindowTop.announce: each new pick is applied as it comes.
    public func followPilot() {
        DistributedNotificationCenter.default().addObserver(forName: WindowTop.changed, object: nil, queue: .main) { [weak self] note in
            let top = (note.object as? String).flatMap(WindowTop.init) ?? WindowTop.saved()
            MainActor.assumeIsolated { self?.apply(top) }
        }
    }

    /// The window's content: `page` filling it, with the hover corner over its top-left.
    public func host(_ page: NSView) -> NSView {
        let host = NSView()
        for view in [page, corner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor), page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor), page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            corner.topAnchor.constraint(equalTo: host.topAnchor), corner.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            corner.widthAnchor.constraint(equalToConstant: 90), corner.heightAnchor.constraint(equalToConstant: 40),
        ])
        return host
    }

    public func apply(_ top: WindowTop) {
        self.top = top
        guard let window, !inFullScreen else { return }
        // Set before the mask: AppKit lays the title bar out again when the mask changes.
        window.titlebarAppearsTransparent = top != .standard
        window.titleVisibility = top == .standard ? .visible : .hidden
        if top.bare { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        paintBackground()
        corner.isHidden = top != .hover
        showButtons(!top.bare, fade: false)
    }

    /// Slim strip's title bar shows the window's background, so that is the page's colour; full screen and every other
    /// look keep macOS's.
    private func paintBackground() {
        window?.backgroundColor = top == .strip && !inFullScreen ? pageColour ?? .windowBackgroundColor : .windowBackgroundColor
    }

    var buttons: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// Hidden, not see-through: a see-through button still takes the click meant for the page under it.
    func showButtons(_ show: Bool, fade: Bool) {
        let buttons = buttons
        corner.placeChip(around: buttons)
        guard fade else {
            // Hover's hidden buttons wait at clear, ready to fade in; any other look keeps them opaque.
            buttons.forEach { $0.alphaValue = show || top != .hover ? 1 : 0; $0.isHidden = !show }
            corner.chip.alphaValue = show && top == .hover ? 1 : 0
            return
        }
        if show { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = show ? 0.15 : 0.25
            buttons.forEach { $0.animator().alphaValue = show ? 1 : 0 }
            corner.chip.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !show, !self.corner.pointing, self.top == .hover, !self.inFullScreen else { return }
                buttons.forEach { $0.isHidden = true }
            }
        }
    }

    @objc private func enteringFullScreen() {
        corner.isHidden = true
        window?.titlebarAppearsTransparent = false
        window?.backgroundColor = .windowBackgroundColor  // inFullScreen is not true yet
        showButtons(true, fade: false)
    }

    @objc private func leftFullScreen() { apply(top) }
}

/// The top-left corner in Buttons on hover: pointing there shows the window buttons on a glass chip, leaving hides them.
/// It takes no clicks, so the page's own top-left stays clickable while the buttons are away.
@MainActor final class HoverCorner: NSView {
    var onHover: ((Bool) -> Void)?
    private(set) var pointing = false
    /// Under the buttons, which sit in the title bar above the page.
    let chip = NSGlassEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        chip.cornerRadius = 9
        chip.alphaValue = 0
        addSubview(chip)
        // Once: .inVisibleRect follows the view as the window resizes.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { pointing = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { pointing = false; onHover?(false) }

    /// Round the three buttons, wherever this macOS puts them.
    func placeChip(around buttons: [NSButton]) {
        guard window != nil, let first = buttons.first else { return }
        let union = buttons.dropFirst().reduce(convert(first.bounds, from: first)) { $0.union(convert($1.bounds, from: $1)) }
        chip.frame = union.insetBy(dx: -7, dy: -6)
    }
}
