import AppKit
import Observation
import OSLog
import PilotCore
import SwiftUI

let olog = Logger(subsystem: "dev.banozz.pilot", category: "overlay")

/// The hold-Hyper overlay (story 55, wireframe ol5Ak83dAho section 1): the layer key held its delay with no other key shows
/// that sublayer's binds in a non-activating panel (PilotCore's HoldOverlay times it, OverlayPage picks the rows); Shift,
/// Ctrl or Alt turns the page, any key or the release closes it. Styled as the app window is (PanelStyle, story 105). Its
/// footer's Edit what shows, clicked while Hyper is held, closes it and opens Binds › Overlay (story 56).
@MainActor
final class HyperOverlay {
    private var state = HoldOverlay()
    private var timer: Timer?
    /// Built at the first show and kept, hidden between shows: a new panel at every hold cost 58 to 75 ms of the main
    /// thread (2026-10-10, idle CPU). A Look change it was built under drops it, so the next show builds it afresh.
    private(set) var panel: KeyPanel?
    private let shown = OverlayModel()
    private let look: Look
    /// The rows of the page shown, given the sublayer.
    var rows: (BindsPage.Sublayer) -> [BindsPage.Row] = { _ in [] }
    /// Settings › General's hold delay, read at each press.
    var delay: () -> TimeInterval = { HoldOverlay.delay }
    /// Settings › General's switch, read at each press: off, a press closes as a release would and starts no timer.
    var enabled: () -> Bool = { true }
    /// Brings the panel up; the tests' keeps it off Sven's screen.
    var order: (NSPanel) -> Void = { $0.orderFrontRegardless() }

    init(look: Look = .shared) { self.look = look }

    func layer(down: Bool, held: Modifiers = []) {
        timer?.invalidate()
        guard down, enabled() else { return apply(state.layerUp()) }
        let delay = delay()
        state.layerDown(at: ProcessInfo.processInfo.systemUptime, delay: delay)
        _ = state.modifiers(held)
        // A hair past the delay, so the tick never lands a float's width short of it.
        timer = Timer.scheduledTimer(withTimeInterval: delay + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.apply($0.state.tick(at: ProcessInfo.processInfo.systemUptime)) } }
        }
    }

    func modifiers(_ held: Modifiers) { apply(state.modifiers(held)) }

    func key() {
        timer?.invalidate()
        apply(state.key())
    }

    /// The footer's link: the overlay closes as a key would close it, and the window opens on Binds › Overlay.
    private func editWhatShows() {
        key()
        AppWindowController.shared.open(AppPlace(.overlay))
        olog.notice("overlay: edit what shows")
    }

    /// The panel changes after the tap callback returns (building rows and a hosting view is no work for it), in order,
    /// so a late draw never reopens a closed overlay.
    private func apply(_ change: HoldOverlay.Change) {
        guard change != .none else { return }
        DispatchQueue.main.async { [self] in
            switch change {
            case .none: return
            case .show(let page), .redraw(let page): if state.showing && state.sublayer == page { draw(page) }
            case .hide:
                panel?.orderOut(nil)
                olog.notice("overlay hidden")
            }
        }
    }

    /// The page in the kept panel, fitted to it and centred again on the screen holding the focused window.
    func draw(_ page: BindsPage.Sublayer) {
        shown.title = page.title
        shown.rows = rows(page)
        // Built now, it is already fitted and centred; kept, it takes the page's size and the focused screen again.
        let p: KeyPanel
        if let kept = panel, let host = (kept.contentView as? MaterialBackdrop)?.content {
            host.layoutSubtreeIfNeeded()
            HUD.centre(kept, size: host.fittingSize)
            p = kept
        } else {
            p = build()
        }
        p.title = page.title   // what Accessibility reads as the window's title
        order(p)
        olog.notice("overlay shown: \(page.title, privacy: .public), \(self.shown.rows.count) binds")
    }

    /// The panel, dropped at any change to the Look it is built in (style, theme, material). Only those are
    /// watched: tracking the build itself would watch the page it shows too, and drop the panel at every show.
    private func build() -> KeyPanel {
        withObservationTracking { _ = (look.style, look.theme, look.materialValues) } onChange: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        let p = HUD.makePanel(ShownOverlay(model: shown) { [weak self] in self?.editWhatShows() }, surface: .overlay, look: look)
        panel = p
        return p
    }
}

/// The page the overlay's kept panel shows, changed in place at each show.
@Observable @MainActor
final class OverlayModel {
    var title = ""
    var rows: [BindsPage.Row] = []
}

private struct ShownOverlay: View {
    let model: OverlayModel
    let edit: () -> Void

    var body: some View { OverlayView(title: model.title, rows: model.rows, edit: edit) }
}

struct OverlayView: View {
    @Environment(\.style) private var style
    let title: String
    let rows: [BindsPage.Row]
    /// The footer's Edit what shows; nil draws none (Pilot page's preview of the overlay).
    var edit: (() -> Void)?

    var body: some View {
        // As many binds as five columns hold; the footer counts the rest (InstrumentOverlay.fit).
        let fit = InstrumentOverlay.fit(rows)
        switch style.kind {
        case .instrument: InstrumentOverlay(title: title, rows: fit.rows, more: fit.more, edit: edit)
        case .toybox: ToyOverlay(title: title, rows: fit.rows, more: fit.more, edit: edit)
        }
    }
}

/// The overlay's foot (story 56): how many binds did not fit, and Edit what shows, the link to Binds › Overlay. The
/// panel never takes key focus, so the link takes the first click as the tip's button does. Nothing when neither applies.
struct OverlayFooter: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let more: Int
    let edit: (() -> Void)?

    var body: some View {
        if more > 0 || edit != nil {
            VStack(spacing: 0) {
                switch style.kind {
                case .instrument: InstrumentRule()
                case .toybox: ToyRule()
                }
                HStack(spacing: 10) {
                    if more > 0 { Text("+ \(more) more").font(ink.ui(12)).foregroundStyle(ink.muted) }
                    Spacer(minLength: 16)
                    if let edit {
                        AccentLink(title: "Edit what shows", action: edit).allowsWindowActivationEvents(true)
                            .help("Binds › Overlay: pick the binds holding Hyper shows")
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 18).frame(height: 34)
            }
        }
    }
}
