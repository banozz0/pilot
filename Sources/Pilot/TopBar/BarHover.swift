import AppKit
import SwiftUI

/// Shows a tooltip under a bar item and takes it off; a fake in tests, so no test shows one.
@MainActor
protocol BarTooltipPresenting: AnyObject {
    func show(_ text: String, under item: CGRect)
    func hide()
}

/// The top bar's hover (card agent-bo-95423013, design JJPiA9o30SA, Shared 3): the item under the pointer shows its
/// one-line tooltip after 500 ms, and lights nothing, as a macOS menu bar item does (Sven, 2026-10-30: the hover's raised
/// pill read as a plate behind the item). Moving straight on to another
/// item while a tooltip shows swaps it at once, as macOS's own tooltips do. One for every bar, so one tooltip at most.
@MainActor
final class BarHover {
    static let shared = BarHover(presenter: BarTooltipWindow(), sleep: pause, watchClicks: true)
    private static func pause(_ duration: Duration) async { try? await Task.sleep(for: duration) }
    static let delay = Duration.milliseconds(500)

    /// The hovered target, whose tooltip may show.
    private(set) var hovered: UUID?
    private let presenter: BarTooltipPresenting
    private let sleep: @MainActor (Duration) async -> Void
    private var wait: Task<Void, Never>?
    private var showing = false
    /// Whether a click anywhere in Pilot's windows (the bars among them) calls `pressed`; a test calls it itself.
    private let watchClicks: Bool
    private var clicks: Any?

    init(presenter: BarTooltipPresenting, sleep: @escaping @MainActor (Duration) async -> Void, watchClicks: Bool = false) {
        self.presenter = presenter
        self.sleep = sleep
        self.watchClicks = watchClicks
    }

    /// The pointer entered target `id`, which hangs `tooltip` under `item` (its screen frame, read when it shows).
    func enter(_ id: UUID, tooltip: String?, under item: @escaping () -> CGRect?) {
        if watchClicks, clicks == nil {
            // Watched from the first hover on; a click passes on untouched.
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.pressed() }
                return event
            }
        }
        let warm = showing
        endTooltip()
        hovered = id
        guard let tooltip else { return }
        let show = { [weak self] in
            guard let self, self.hovered == id, let frame = item() else { return }
            self.presenter.show(tooltip, under: frame)
            self.showing = true
        }
        if warm { return show() }
        wait = Task { [sleep] in
            await sleep(Self.delay)
            if !Task.isCancelled { show() }
        }
    }

    /// A click on the bar: the tooltip waiting or showing goes, as macOS's do, so it never covers the popover or menu the
    /// click opens; the next one waits for the pointer to enter an item again.
    func pressed() { endTooltip() }

    /// The pointer left target `id`; leaving one already left (another entered first) changes nothing.
    func leave(_ id: UUID) {
        guard hovered == id else { return }
        hovered = nil
        endTooltip()
    }

    private func endTooltip() {
        wait?.cancel()
        wait = nil
        if showing { presenter.hide() }
        showing = false
    }
}

extension View {
    /// The raised pill behind a bar item while what it opens shows (design JJPiA9o30SA direction A); else nothing at all.
    func barHoverPill(_ lit: Bool) -> some View { modifier(InstrumentHoverPill(lit: lit)) }

    /// A top bar target: its tooltip after BarHover's delay.
    func barHoverTarget(_ tooltip: String?) -> some View { modifier(BarHoverTarget(tooltip: tooltip)) }

    /// A top bar target `inset` each side of its ink, the bar's full height, all of it taking the pointer.
    func barTarget(_ tooltip: String?, inset: CGFloat = BarMetrics.inset) -> some View {
        padding(.horizontal, inset).frame(maxHeight: .infinity).barHoverTarget(tooltip)
    }
}

private struct BarHoverTarget: ViewModifier {
    let tooltip: String?
    @State private var id = UUID()
    @State private var anchor = ScreenAnchor.Box()

    func body(content: Content) -> some View {
        let hover = BarHover.shared
        content
            .contentShape(.rect)
            .background(ScreenAnchor(box: anchor))
            .onHover { [anchor] inside in
                if inside { hover.enter(id, tooltip: tooltip, under: { anchor.view?.screenFrame }) } else { hover.leave(id) }
            }
            .onDisappear { hover.leave(id) }
    }
}

/// The real tooltip: a small borderless panel centred 6 pt under the item, kept on its screen, over the bar, never
/// taking a click or the focus. Made once; each show sets its text and frame.
@MainActor
final class BarTooltipWindow: BarTooltipPresenting {
    private lazy var host = NSHostingView(rootView: AnyView(EmptyView()))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }()

    func show(_ text: String, under item: CGRect) {
        host.rootView = AnyView(BarTooltipView(text: text).styled(.topBar).pilotTheme())
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(item) }?.visibleFrame ?? NSScreen.main?.frame ?? .zero
        let x = min(max(item.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        // The view's shadow room (BarTooltipView.shadowRoom) is inside the panel: its pill's top is 6 pt under the item.
        let y = item.minY - 6 + BarTooltipView.shadowRoom - size.height
        panel.appearance = Theme.appearance
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// The tooltip's look (the date's hover shot): one line on the ground, a hairline round it and a soft shadow.
struct BarTooltipView: View {
    static let shadowRoom: CGFloat = 10
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        switch style.kind {
        case .toybox: ToyBarTooltip(text: text).padding(Self.shadowRoom)
        case .instrument: InstrumentBarTooltip(text: text).padding(Self.shadowRoom)
        }
    }

}
