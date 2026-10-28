import PilotCore
import SwiftUI

/// One display's lock screen (Part 04, variant A): since when and the safety unlock's countdown in the top corners, the
/// lock, "Keyboard locked", the ring that fills while Esc is held, Unlock for the mouse, and what no tap can stop.
struct KeyboardLockView: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let model: KeyboardLockModel
    /// Glass behind it (MaterialBackdrop): only a veil of the ground here; solid, the ground itself.
    let glass: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            style.color(\.canvas).opacity(glass ? 0.25 : 0.94)
            VStack(spacing: 14) {
                Image(systemName: "lock").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(style.color(\.text2)).accessibilityHidden(true)
                title
                ring
                HStack(spacing: 8) {
                    Text("Hold")
                    Kbd(text: "esc")
                    Text("for 3 seconds, or")
                }
                .styleText(\.body).foregroundStyle(style.color(\.text2))
                .accessibilityElement(children: .combine)
                // The panel is never key: the first click is the button's, as a tip's is (HUD.prepareTip).
                Button("Unlock", action: unlock).buttonStyle(PilotButtonStyle(primary: true)).allowsWindowActivationEvents(true)
            }
            .padding(16)
        }
        .overlay(alignment: .top) { corners.padding(.horizontal, 24).padding(.top, 20) }
        .overlay(alignment: .bottom) {
            Text("The power button and Touch ID still work.")
                .styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.bottom, 28)
        }
    }

    @ViewBuilder private var title: some View {
        let text = Text("Keyboard locked").foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
        if style.kind == .toybox { text.styleText(\.display) } else { text.font(ink.themeMono(46, weight: .ultraLight)).tracking(-1.4) }
    }

    /// Cleaning since when, and the safety unlock counting down, read once a second.
    private var corners: some View {
        TimelineView(.periodic(from: model.since, by: 1)) { _ in
            let left = max(0, Int(model.until.timeIntervalSince(model.now()).rounded(.up)))
            HStack {
                InstrumentEyebrow(text: "Cleaning · since \(model.since.formatted(date: .omitted, time: .shortened))")
                Spacer()
                InstrumentEyebrow(text: "Auto-unlock \(left / 60):\(String(format: "%02d", left % 60))")
            }
        }
    }

    /// The ring fills over the 3 s Esc is held and empties as it is let go; still while Esc is up.
    private var ring: some View {
        TimelineView(.animation(paused: model.escapeSince == nil)) { _ in
            let held = model.escapeSince.map { model.now().timeIntervalSince($0) / KeyboardLock.escapeHold } ?? 0
            ZStack {
                Circle().stroke(style.color(\.line2), lineWidth: 2)
                Circle().trim(from: 0, to: min(1, max(0, held)))
                    .stroke(style.color(\.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Kbd(text: "esc")
            }
            .frame(width: 84, height: 84)
        }
        .accessibilityHidden(true)
    }
}

/// Binds › Keyboard's Cleaning block (Part 04): Lock keyboard for cleaning with its key or Set key, Lock now, and how a
/// lock ends. The unlock is fixed (Sven, Q471: Esc held 3 s or Unlock, 2 minutes' safety; Q472: the mouse stays live).
struct KeyboardLockCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let edit: (BindEditing) -> Void

    var body: some View {
        let id = KeyboardLockController.actionID
        Tile(title: "Cleaning", symbol: "lock") {
            VStack(spacing: 0) {
                BlockRow(first: true) {
                    line("Lock keyboard for cleaning", "Every key stops until you unlock. The mouse and trackpad keep working.")
                    Spacer(minLength: 12)
                    Button { edit(.init(action: id)) } label: {
                        if let key = engine.binds.store.trigger(for: id) { Kbd(text: key.label) } else { Text("Set key") }
                    }
                    .buttonStyle(PilotButtonStyle())
                    .help("Pick the key that locks the keyboard")
                    Button("Lock now") { engine.keyboardLock.lock() }.buttonStyle(PilotButtonStyle(primary: true))
                }
                BlockRow { line("Unlocks with", "Hold esc for 3 seconds, or click Unlock on the screen.") }
                BlockRow { line("Unlocks by itself after 2 min", "A safety net, so a lost mouse never strands you.") }
            }
        }
    }

    private func line(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
            Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
