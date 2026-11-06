import AppKit
import PilotCore

/// The terminal's bar drop (spec Bar drops T6, T11, notes › Keys in the terminal): Sven's Ghostty under the top bar, left
/// of Ask AI when both are open (BarDrops); Hyper+T and the bar's TERMINAL item toggle it (Q105), both through `toggle`.
/// Every key the layer does not take reaches the shell: HyperTap passes plain keys, Escape and chords without Hyper to the
/// key window, here the drop. One Escape goes to the shell, a second within 0.4 s closes the drop (DropKeys). Hiding keeps
/// the shell; when it exits the drop closes and the next open starts a fresh one. Snippets do not expand in it
/// (Snippets.isBlocked while a Pilot window has the keyboard).
@MainActor
final class TerminalDrop {
    static let shared = TerminalDrop()
    static let actionID = "terminal.drop"

    private let drops: BarDrops
    private let make: () -> TerminalSurface
    private let tip: (String) -> Void
    /// The shell's view, made on the first open and kept for Pilot's session.
    private(set) var surface: TerminalSurface?

    init(drops: BarDrops = .shared, make: @escaping () -> TerminalSurface = { TerminalSurface() },
         tip: @escaping (String) -> Void = { HUD.tip($0, seconds: 5) }) {
        self.drops = drops
        self.make = make
        self.tip = tip
    }

    /// Hyper+T runs inside the tap's callback, so the drop opens on the run loop's next pass: the first open starts
    /// libghostty and reads the config, and the tap must not wait on that (keys typed meanwhile queue, none is lost).
    static func register(into registry: inout ActionRegistry, drop: @escaping @Sendable @MainActor () -> TerminalDrop = { .shared }) {
        do {
            try registry.register(Action(id: actionID, label: "Drop the terminal", module: .apps, defaultKey: Key("t"), tier: .v1, keywords: "terminal shell") {
                RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { drop().toggle() } }
            })
        } catch { tblog.error("terminal drop action: \(String(describing: error), privacy: .public)") }
    }

    var isShown: Bool { drops.isOpen(.terminal) }

    func toggle() { isShown ? hide() : show() }

    /// Opens on a running shell, or says why not: a terminal that did not start never drops, so no blank panel takes
    /// keys, and the next open tries again. Without its pack on this Mac the press loads or offers it first (T76).
    func show() {
        guard !isShown else { return }
        guard GhosttyRuntime.isReady else { return openPack() }
        let surface = surface ?? {
            let made = make()
            made.onClose = { [weak self] in self?.hide() }
            self.surface = made
            return made
        }()
        guard surface.start() else {
            tip("The terminal did not start; Pilot's log says why")
            return
        }
        drops.open(.terminal, face: face(surface))
    }

    func hide() { drops.close(.terminal) }

    // MARK: The pack (T76)

    /// A load in flight: a second press waits for it.
    private var loading = false

    /// The first press of a session: the installed pack is checked and mapped off the main thread, then the drop opens. A
    /// pack that fails its checks is deleted and offered again; none on this Mac is offered as a download.
    private func openPack() {
        guard !loading else { return }
        let pin = TerminalPack.pin, dylib = TerminalPack.dylib(pin)
        guard GhosttyRuntime.loaded == nil, TerminalPack.isInstalled(pin) else { return offerPack() }
        loading = true
        Task {
            defer { loading = false }
            do {
                let api = try await Task.detached(priority: .userInitiated) {
                    try TerminalPack.load(dylib, sha256: pin.dylibSHA256, requirement: TerminalPack.pilotRequirement())
                }.value
                GhosttyRuntime.use(api, from: dylib)
                show()
            } catch let failure as TerminalPack.Failure where failure == .unsigned {
                tip(failure.message)  // the pack is fine; this Pilot cannot check it
            } catch {
                let why = (error as? TerminalPack.Failure)?.message ?? error.localizedDescription
                tblog.error("terminal pack: \(why, privacy: .public)")
                try? FileManager.default.removeItem(at: dylib.deletingLastPathComponent())
                HUD.tip("\(why). Pilot deleted it", seconds: 10, action: HUD.TipAction(title: "Download again") { self.downloadPack() })
            }
        }
    }

    /// One line: what the press needs, its size, and Download; a download already running shows its progress instead.
    private func offerPack() {
        if case .downloading = ExtrasDownloads.shared.terminal { return followDownload() }
        HUD.tip("Download the terminal (\(TerminalPack.pin.megabytes) MB)", seconds: 10,
                action: HUD.TipAction(title: "Download") { self.downloadPack() })
    }

    /// Starts the download through ExtrasDownloads (Pilot's menu-bar item shows it too) and follows it.
    func downloadPack() {
        ExtrasDownloads.shared.fetchTerminal()
        followDownload()
    }

    /// The download's progress in a lasting tip with Cancel; the shell drops once the pack is in, or the tip says why not.
    private func followDownload(tip shown: TipModel? = nil) {
        func dismiss() { if let shown, HUD.tipModel === shown { HUD.dismissTip() } }
        switch ExtrasDownloads.shared.terminal {
        case .downloading(let share)?:
            let text = "Downloading the terminal · \(Int((share * 100).rounded())) %"
            var tip = shown
            if let shown { HUD.updateTip(text, on: shown) } else {
                HUD.tip(text, seconds: .infinity, action: HUD.TipAction(title: "Cancel") { ExtrasDownloads.shared.cancelTerminal() })
                tip = HUD.tipModel
            }
            withObservationTracking { _ = ExtrasDownloads.shared.terminal } onChange: { [tip] in
                Task { @MainActor in self.followDownload(tip: tip) }
            }
        case .ready?:
            dismiss()
            show()
        case .failed(let why)?:
            HUD.tip(why, seconds: 10, action: HUD.TipAction(title: "Retry") { self.downloadPack() })
        case .preparing?, .absent?, nil:
            dismiss()
        }
    }

    /// Settings' Remove: the shell ends, the drop closes and the packs on disk go; the mapped one leaves when Pilot quits.
    func removePack() throws {
        hide()
        surface?.terminate()
        surface = nil
        ExtrasDownloads.shared.cancelTerminal()
        try TerminalPack.remove()
    }

    /// The shell's view in the drop's window, filling it as the drop moves between alone and beside Ask AI; it keeps the
    /// keyboard itself, so nothing refocuses a field.
    private func face(_ surface: TerminalSurface) -> BarDropFace {
        BarDropFace(panel: { size in
            surface.frame = CGRect(origin: .zero, size: size)
            surface.autoresizingMask = [.width, .height]
            let panel = BarDrops.panel(surface, title: "Terminal", appearance: Look.shared.appearance(for: .quickAI))
            panel.makeFirstResponder(surface)
            return panel
        }, keepsField: false)
    }
}
