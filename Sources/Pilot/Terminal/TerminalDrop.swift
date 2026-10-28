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
    /// keys, and the next open tries again.
    func show() {
        guard !isShown else { return }
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
