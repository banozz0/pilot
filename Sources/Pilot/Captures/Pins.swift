import AppKit
import ImageIO
import PilotCore

/// Pinned captures (spec `capture.html` CP9): borderless panels that float over every window and never take the app
/// in front's place; drag one to move it, scroll to zoom, O for its opacity, ⌘C to copy, Escape or ⌘W to close, or
/// its right-click menu. Pins end with Pilot.
@MainActor
enum Pins {
    private(set) static var open: [PinPanel] = []

    /// Pins `image` (`scale` pixels a point) with its top left at `origin` in screen points (bottom-left origin), or
    /// centred on the screen under the pointer.
    @discardableResult
    static func pin(_ image: CGImage, scale: CGFloat, topLeft origin: CGPoint? = nil) -> PinPanel {
        let state = PinState(size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        let panel = PinPanel(image: image, state: state)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let f = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let top = origin ?? CGPoint(x: f.midX - state.frame.width / 2, y: f.midY + state.frame.height / 2)
        panel.setFrame(CGRect(x: top.x, y: top.y - state.frame.height, width: state.frame.width, height: state.frame.height), display: false)
        panel.orderFrontRegardless()
        open.append(panel)
        PilotCapture.log.notice("pinned \(image.width)×\(image.height)")
        return panel
    }

    static func closed(_ panel: PinPanel) { open.removeAll { $0 === panel } }

    /// The newest capture in `folder` as an image and its scale (from its DPI, 2 when it has none); nil when there is none.
    nonisolated static func newest(in folder: URL) -> (CGImage, CGFloat)? { newestFile(in: folder).flatMap(load) }

    /// The newest capture's file in `folder`, Pin's and Edit the last capture's.
    nonisolated static func newestFile(in folder: URL) -> URL? {
        CaptureFiles.recent(captures: folder, recordings: folder, limit: 50).first { $0.kind == .capture }?.url
    }

    /// An image file and its scale, from its DPI (2 when it has none).
    nonisolated static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let dpi = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIWidth] as? Double
        return (image, CGFloat((dpi ?? 144) / 72))
    }
}

/// One pin: the capture at its zoom, a hairline round it (no Pilot pop-up casts a shadow), see-through at its opacity.
final class PinPanel: NSPanel {
    private(set) var state: PinState
    let image: CGImage

    init(image: CGImage, state: PinState) {
        self.image = image
        self.state = state
        super.init(contentRect: CGRect(origin: .zero, size: state.frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(image: image)
    }

    override var canBecomeKey: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        var next = state
        next.scrolled(dy)
        apply(next)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command), c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (Int64(event.keyCode), command, c) {
        case (KeyCode.escape, _, _), (_, true, "w"): unpin()
        case (_, true, "c"): copyImage()
        case (_, false, "o"): var next = state; next.nextOpacity(); apply(next)
        case (_, false, "0"), (_, true, "0"): var next = state; next.actualSize(); apply(next)
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Actual size", action: #selector(actualItem), keyEquivalent: "0").target = self
        menu.addItem(.separator())
        for value in PinState.opacities {
            let item = menu.addItem(withTitle: "Opacity \(Int(value * 100)) %", action: #selector(opacityItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = state.opacity == value ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeItem), keyEquivalent: "w").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? NSView())
    }

    @objc private func copyItem() { copyImage() }
    @objc private func actualItem() { var next = state; next.actualSize(); apply(next) }
    @objc private func closeItem() { unpin() }
    @objc private func opacityItem(_ item: NSMenuItem) {
        var next = state
        next.setOpacity(item.representedObject as? CGFloat ?? 1)
        apply(next)
    }

    /// The new zoom and opacity; the pin grows or shrinks from its top left.
    func apply(_ next: PinState) {
        state = next
        alphaValue = state.opacity
        let top = CGPoint(x: frame.minX, y: frame.maxY)
        setFrame(CGRect(x: top.x, y: top.y - state.frame.height, width: state.frame.width, height: state.frame.height), display: true)
    }

    func copyImage() {
        guard let png = PilotCapture.png(image, scale: CGFloat(image.width) / state.size.width) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    func unpin() {
        orderOut(nil)
        Pins.closed(self)
    }
}

/// The pinned capture drawn to the panel's size with a hairline round it.
final class PinView: NSView {
    private let still: NSImage

    init(image: CGImage) {
        still = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        still.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}
